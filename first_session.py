"""
Captain — first-session pipeline (headless validation).

Given a photo of a home and the home's street address, this script:
  1. Searches and scrapes public real estate / county-records pages via Firecrawl.
  2. Uses an LLM to extract structured property facts from the scraped content.
  3. Reuses the existing rendered home (from prototype-output/) if present;
     otherwise renders it fresh.
  4. Extracts the home's color palette via vision LLM.
  5. Outputs an HTML "mock first-session result" page that previews what the
     iOS app would show the user after they take their first-session photo.
"""

from __future__ import annotations

import base64
import json
import os
import sys
import time
import traceback
from pathlib import Path

import requests
from dotenv import load_dotenv
from openai import OpenAI

# Reuse rendering + palette functions from the prototype script.
sys.path.insert(0, str(Path(__file__).parent))
from render_prototype import (  # noqa: E402
    VARIANTS,
    extract_palette,
    make_thumbnail,
    render_variant,
)

ROOT = Path(__file__).parent
INPUT_DIR = ROOT / "first-session-input"
OUTPUT_DIR = ROOT / "first-session-output"
RENDER_REUSE_DIR = ROOT / "prototype-output"  # existing renders to reuse
SUPPORTED_EXTS = {".jpg", ".jpeg", ".png", ".webp"}

# Vision + web-content extraction. Architectural style / materials want
# real visual reasoning, so mini rather than nano.
EXTRACTION_MODEL = os.getenv("CAPTAIN_EXTRACTION_MODEL", "gpt-5.4-mini")
FIRECRAWL_BASE = "https://api.firecrawl.dev"
SEARCH_LIMIT = 5  # firecrawl results
MAX_SCRAPED_CHARS_PER_RESULT = 8000  # cap context per source

# Open-ended extraction: no predefined fields. The model returns a flat list of
# natural-language "features" — anything notable about THIS home derived from
# the photo and/or the scraped web content. Each feature is lightly tagged
# (source + loose category) for downstream filtering by chat/radar, but the
# vocabulary is intentionally not fixed.
FEATURES_SCHEMA = {
    "type": "object",
    "properties": {
        "features": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "text": {
                        "type": "string",
                        "description": (
                            "One natural-language fact or observation about "
                            "this specific home. Concise, concrete, never "
                            "speculative."
                        ),
                    },
                    "source": {
                        "type": "string",
                        "enum": ["image", "web", "both"],
                    },
                    "category": {
                        "type": "string",
                        "description": (
                            "Loose tag for downstream filtering. Examples: "
                            "architecture, exterior, landscaping, history, "
                            "neighborhood, climate, systems, layout. Use what "
                            "fits; do not force a fit."
                        ),
                    },
                },
                "required": ["text", "source", "category"],
                "additionalProperties": False,
            },
        },
        "source_urls": {
            "type": "array",
            "items": {"type": "string"},
            "description": "URLs that actually contributed facts",
        },
    },
    "required": ["features", "source_urls"],
    "additionalProperties": False,
}


def find_photo() -> Path | None:
    for p in sorted(INPUT_DIR.iterdir()):
        if p.is_file() and p.suffix.lower() in SUPPORTED_EXTS:
            return p
    return None


def read_address() -> str:
    addr_file = INPUT_DIR / "address.txt"
    if not addr_file.exists():
        print(f"ERROR: missing {addr_file}", file=sys.stderr)
        sys.exit(1)
    return addr_file.read_text().strip()


def firecrawl_search(api_key: str, query: str) -> list[dict]:
    """Search + scrape via Firecrawl. Returns list of result dicts with markdown."""
    print(f"  [firecrawl] searching: {query!r}")
    resp = requests.post(
        f"{FIRECRAWL_BASE}/v2/search",
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        json={
            "query": query,
            "limit": SEARCH_LIMIT,
            "scrapeOptions": {
                "formats": ["markdown"],
                "onlyMainContent": True,
            },
        },
        timeout=180,
    )
    if not resp.ok:
        print(f"  [firecrawl] HTTP {resp.status_code}: {resp.text[:500]}")
        resp.raise_for_status()
    payload = resp.json()
    # Firecrawl v2 returns {"success": true, "data": {"web": [...]}} or
    # {"data": [...]} depending on version. Handle both.
    data = payload.get("data")
    if isinstance(data, dict):
        results = data.get("web") or data.get("results") or []
    elif isinstance(data, list):
        results = data
    else:
        results = []
    print(f"  [firecrawl] got {len(results)} result(s)")
    return results


def extract_home_features(
    client: OpenAI, address: str, photo: Path, search_results: list[dict]
) -> dict:
    """Open-ended extraction: return a flat list of features about THIS home.

    Combines visual evidence from the photo with content scraped from the web.
    No predefined fields — each feature is a natural-language observation
    lightly tagged by source and a loose category for downstream filtering.
    """
    context_parts: list[str] = []
    for i, r in enumerate(search_results[:SEARCH_LIMIT], 1):
        url = (
            r.get("url")
            or (r.get("metadata") or {}).get("sourceURL")
            or (r.get("metadata") or {}).get("url")
            or "unknown"
        )
        title = (
            r.get("title")
            or (r.get("metadata") or {}).get("title")
            or "(no title)"
        )
        md = r.get("markdown") or r.get("content") or ""
        if not md:
            continue
        context_parts.append(
            f"\n=== Source {i}: {title}\nURL: {url}\n\n"
            f"{md[:MAX_SCRAPED_CHARS_PER_RESULT]}\n"
        )
    web_context = "".join(context_parts) or "(no web sources scraped)"

    sys_prompt = (
        "You are quietly building up context about a specific US single-family "
        "home for an app whose purpose is to help its owner take care of it. "
        "You are given the home's address, a photograph of the front of the "
        "home, and the contents of a few web pages found by searching the "
        "address (real estate listings, county records, etc.).\n\n"
        "Your job: produce a flat list of natural-language FEATURES — concrete, "
        "useful facts about THIS home that would help the app give better, "
        "more tailored advice over time. Use the photograph and the web "
        "content together; neither source is privileged.\n\n"
        "What to capture (non-exhaustive — capture anything genuinely useful):\n"
        " - Visible architecture and exterior materials (siding type, roof "
        "material, window style, porch, chimney, distinctive trim, door color).\n"
        " - Visible landscaping (mature trees, shrubs, lawn condition, garden "
        "beds, hardscaping, fencing).\n"
        " - History and age (year built, era, architectural style).\n"
        " - Layout facts when present (approximate square footage, bedrooms, "
        "bathrooms, stories, lot size).\n"
        " - Climate context derivable from location (USDA hardiness zone, "
        "general climate notes — Cleveland-area Ohio is hardiness zone 6a/6b "
        "for example).\n"
        " - Neighborhood character if clearly indicated.\n"
        " - Anything else specific and observable.\n\n"
        "Hard rules:\n"
        " - DO NOT include sale prices, last sale dates, current market value, "
        "tax assessments, Zestimates, or any other financial or valuation "
        "information. This app deliberately avoids financial surfaces.\n"
        " - DO NOT speculate. If you are not sure of a fact, leave it out.\n"
        " - DO NOT include generic statements that would be true of any home "
        "(\"has a roof,\" \"located in the United States\"). Only specifics.\n"
        " - Each feature item should be one self-contained, concrete sentence "
        "fragment or short sentence. Concise, no fluff.\n"
        " - Tag source as 'image' if the fact is visible in the photo, 'web' "
        "if it comes from scraped content, 'both' if independently confirmed "
        "by both.\n"
        " - Category is a free-form short tag (architecture, exterior, "
        "landscaping, history, layout, climate, neighborhood, etc.). Use what "
        "fits naturally; don't force a fit.\n"
        " - In source_urls, list ONLY URLs that actually contributed facts."
    )

    photo_bytes = photo.read_bytes()
    ext = photo.suffix.lower().lstrip(".")
    mime = "jpeg" if ext == "jpg" else ext
    img_data_url = (
        f"data:image/{mime};base64,"
        f"{base64.b64encode(photo_bytes).decode()}"
    )

    user_content = [
        {
            "type": "text",
            "text": (
                f"Target address: {address}\n\n"
                f"Photograph of the front of the home is attached.\n\n"
                f"Scraped web content for this address:\n{web_context}"
            ),
        },
        {"type": "image_url", "image_url": {"url": img_data_url}},
    ]

    print(f"  [extract] calling {EXTRACTION_MODEL} (vision + web) "
          f"with {len(web_context)} chars of web context")
    resp = client.chat.completions.create(
        model=EXTRACTION_MODEL,
        messages=[
            {"role": "system", "content": sys_prompt},
            {"role": "user", "content": user_content},
        ],
        response_format={
            "type": "json_schema",
            "json_schema": {
                "name": "home_features",
                "schema": FEATURES_SCHEMA,
                "strict": True,
            },
        },
    )
    return json.loads(resp.choices[0].message.content)


def get_or_render_home(
    client: OpenAI, photo: Path, work_dir: Path
) -> dict[str, Path]:
    """Reuse renderings from prototype-output if present; otherwise render."""
    reuse_dir = RENDER_REUSE_DIR / photo.stem
    if all((reuse_dir / f"{v}.png").exists() for v in VARIANTS):
        print(f"  [render] reusing existing renders from {reuse_dir}")
        return {v: reuse_dir / f"{v}.png" for v in VARIANTS}

    print(f"  [render] rendering fresh into {work_dir}")
    work_dir.mkdir(parents=True, exist_ok=True)
    out: dict[str, Path] = {}
    for variant, prompt in VARIANTS.items():
        vname, path, err = render_variant(client, photo, variant, prompt, work_dir)
        if err:
            print(f"    [{vname}] ERROR: {err}")
        else:
            out[vname] = path
    return out


def pick_current_season() -> str:
    m = time.localtime().tm_mon
    if m in (3, 4, 5):
        return "spring"
    if m in (6, 7, 8):
        return "summer"
    if m in (9, 10, 11):
        return "fall"
    return "winter"


def render_mock_html(
    address: str,
    photo_thumb: Path,
    rendering: Path,
    palette: list[str],
    extraction: dict,
    current_season: str,
) -> str:
    """Mock first-session preview.

    On the 'user-visible' phone surface: just the rendered home, a soft
    greeting, and the home's palette as a subtle accent strip. No facts,
    no profile card. Captured features live in a debug panel below the
    phone, for our review only — they are CONTEXT for chat/radar in the
    real app, never a screen the user sees.
    """
    accent = palette[0] if palette else "#888"
    accent2 = palette[1] if len(palette) > 1 else accent
    rendering_rel = os.path.relpath(rendering, OUTPUT_DIR)
    thumb_rel = os.path.relpath(photo_thumb, OUTPUT_DIR)

    palette_swatches = "".join(
        f'<div class="swatch" style="background:{c}" title="{c}"></div>'
        for c in palette
    )

    features = extraction.get("features", []) or []
    # Group by category for readable debug display (still flat data underneath).
    by_cat: dict[str, list[dict]] = {}
    for f in features:
        by_cat.setdefault(f.get("category") or "other", []).append(f)
    feature_blocks = ""
    for cat in sorted(by_cat):
        items = "".join(
            f'<li><span class="src src-{f.get("source", "")}">'
            f'{f.get("source", "")}</span> {f.get("text", "")}</li>'
            for f in by_cat[cat]
        )
        feature_blocks += (
            f'<div class="cat"><div class="cat-name">{cat}</div>'
            f'<ul>{items}</ul></div>'
        )
    if not feature_blocks:
        feature_blocks = "<em>no features captured</em>"

    sources_html = "".join(
        f'<li><a href="{u}" target="_blank">{u}</a></li>'
        for u in extraction.get("source_urls", [])
    ) or "<li><em>none</em></li>"

    return f"""<!doctype html>
<html><head><meta charset="utf-8"><title>Captain — first session preview</title>
<style>
  :root {{ --accent: {accent}; --accent2: {accent2}; }}
  body {{
    font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif;
    background: #f5f1ea; color: #2a2a2a; margin: 0; padding: 0;
  }}
  .phone {{
    max-width: 420px; margin: 32px auto 8px; background: #fff;
    border-radius: 36px; overflow: hidden;
    box-shadow: 0 12px 48px rgba(0,0,0,0.12);
    aspect-ratio: 9/19.5; display: flex; flex-direction: column;
  }}
  .hero {{
    flex: 1; padding: 32px 24px 16px;
    background: linear-gradient(180deg,
      color-mix(in srgb, var(--accent2) 18%, white) 0%,
      white 70%);
    display: flex; flex-direction: column; align-items: center;
  }}
  .greeting {{
    font-size: 13px; color: #888; letter-spacing: 0.5px;
    text-transform: lowercase; margin-bottom: 4px; align-self: flex-start;
  }}
  .h-name {{
    font-size: 14px; color: var(--accent); font-weight: 500;
    align-self: flex-start; margin-bottom: 24px;
  }}
  .home-img {{
    width: 100%; aspect-ratio: 1/1; object-fit: cover;
    border-radius: 16px;
    box-shadow: 0 4px 16px rgba(0,0,0,0.08);
  }}
  .palette {{
    display: flex; gap: 3px; margin-top: 20px; height: 6px;
    width: 80px; border-radius: 3px; overflow: hidden;
  }}
  .swatch {{ flex: 1; }}
  .chat-bar {{
    margin: auto 16px 24px; padding: 14px 18px;
    background: #f4f1ec; border-radius: 24px;
    color: #888; font-size: 14px;
    display: flex; justify-content: space-between; align-items: center;
  }}
  .handle {{
    width: 36px; height: 4px; background: #ccc; border-radius: 2px;
    margin: 0 auto 8px;
  }}

  .debug {{
    max-width: 720px; margin: 24px auto 48px; padding: 0 20px;
    color: #444; font-size: 13px;
  }}
  .debug h3 {{
    margin: 24px 0 8px; color: #888; font-size: 11px;
    text-transform: uppercase; letter-spacing: 1px; font-weight: 600;
  }}
  .debug .lede {{ color: #888; font-size: 12px; margin-bottom: 16px; }}
  .cat {{ margin-bottom: 14px; }}
  .cat-name {{
    font-size: 11px; text-transform: uppercase; letter-spacing: 0.5px;
    color: var(--accent); font-weight: 600; margin-bottom: 4px;
  }}
  .cat ul {{ margin: 0; padding-left: 16px; line-height: 1.55; }}
  .src {{
    display: inline-block; font-size: 10px; padding: 1px 6px;
    border-radius: 8px; margin-right: 6px; text-transform: uppercase;
    letter-spacing: 0.5px; vertical-align: 1px;
  }}
  .src-image {{ background: #e8f1f9; color: #3a6a99; }}
  .src-web {{ background: #f1ecdf; color: #806b30; }}
  .src-both {{ background: #ecf3e8; color: #4a7a3a; }}
  details {{ margin-top: 8px; }}
  summary {{ cursor: pointer; color: #666; }}
  .debug img.orig {{
    width: 140px; border-radius: 8px; margin-top: 8px; display: block;
  }}
</style></head><body>

<div class="phone">
  <div class="hero">
    <div class="greeting">welcome home</div>
    <div class="h-name">{address}</div>
    <img class="home-img" src="{rendering_rel}" alt="rendered home">
    <div class="palette">{palette_swatches}</div>
  </div>
  <div>
    <div class="handle"></div>
    <div class="chat-bar">
      <span>ask about your home…</span>
      <span>📷</span>
    </div>
  </div>
</div>

<div class="debug">
  <h3>captured context (debug only — not user-visible)</h3>
  <div class="lede">
    These features are stored as context for chat and radar. They are never
    rendered as a profile screen. Rendered season: {current_season} ·
    generated {time.strftime('%Y-%m-%d %H:%M')} · {len(features)} feature(s)
    captured.
  </div>
  {feature_blocks}
  <details>
    <summary>source urls ({len(extraction.get("source_urls", []))})</summary>
    <ul>{sources_html}</ul>
  </details>
  <details>
    <summary>original photo</summary>
    <img class="orig" src="{thumb_rel}" alt="original">
  </details>
</div>

</body></html>"""


def main() -> int:
    load_dotenv(ROOT / ".env")
    if not os.getenv("OPENAI_API_KEY"):
        print("ERROR: OPENAI_API_KEY missing", file=sys.stderr)
        return 1
    fc_key = os.getenv("FIRECRAWL_API_KEY")
    if not fc_key:
        print("ERROR: FIRECRAWL_API_KEY missing", file=sys.stderr)
        return 1

    photo = find_photo()
    if not photo:
        print(f"ERROR: no photo found in {INPUT_DIR}", file=sys.stderr)
        return 1
    address = read_address()
    print(f"Photo:   {photo.name}")
    print(f"Address: {address}\n")

    OUTPUT_DIR.mkdir(exist_ok=True)
    client = OpenAI()
    current_season = pick_current_season()

    # 1. Property lookup via Firecrawl + LLM extraction
    print("Step 1: property data lookup")
    query = f"{address} property details year built square feet"
    try:
        search_results = firecrawl_search(fc_key, query)
    except Exception as e:  # noqa: BLE001
        print(f"  firecrawl failed: {e}")
        search_results = []

    extraction = extract_home_features(client, address, photo, search_results)
    (OUTPUT_DIR / "features.json").write_text(json.dumps(extraction, indent=2))
    print(f"  extracted: {len(extraction.get('features', []))} feature(s), "
          f"{len(extraction.get('source_urls', []))} contributing source(s)")

    # 2. Rendering (reuse existing if available)
    print("\nStep 2: rendering")
    work_dir = OUTPUT_DIR / "render"
    renderings = get_or_render_home(client, photo, work_dir)
    current_render = renderings.get(current_season) or renderings.get("base")
    if not current_render:
        print("ERROR: no rendering available", file=sys.stderr)
        return 1

    # 3. Palette extraction
    print("\nStep 3: palette extraction")
    try:
        palette = extract_palette(client, photo)
        print(f"  palette: {palette}")
    except Exception as e:  # noqa: BLE001
        print(f"  palette failed: {e}")
        palette = []

    # 4. Thumbnail of original (for debug section)
    thumb = OUTPUT_DIR / "original-thumb.jpg"
    make_thumbnail(photo, thumb)

    # 5. Render mock first-session HTML
    print("\nStep 4: writing mock HTML")
    html = render_mock_html(
        address=address,
        photo_thumb=thumb,
        rendering=current_render,
        palette=palette,
        extraction=extraction,
        current_season=current_season,
    )
    out_html = OUTPUT_DIR / "first-session.html"
    out_html.write_text(html)

    print(f"\nDone. Open: {out_html}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nInterrupted.")
        sys.exit(130)
    except Exception:  # noqa: BLE001
        traceback.print_exc()
        sys.exit(1)
