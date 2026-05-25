"""
Captain — rendered-home prototype.

Takes every image in ./prototype-photos/ and produces, for each one:
  - a base stylized "nostalgic portrait" rendering
  - four seasonal variants (spring, summer, fall, winter)
  - a dominant-color palette extracted from the original photo

Writes outputs to ./prototype-output/ and generates index.html for review.
"""

from __future__ import annotations

import base64
import os
import sys
import time
import traceback
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import json
import re

from dotenv import load_dotenv
from openai import OpenAI
from PIL import Image

ROOT = Path(__file__).parent
PHOTOS_DIR = ROOT / "prototype-photos"
OUTPUT_DIR = ROOT / "prototype-output"
MODEL = os.getenv("CAPTAIN_RENDER_MODEL", "gpt-image-2")
# Vision-required but trivial reasoning (give me 6 hex codes). Nano is fine.
PALETTE_MODEL = os.getenv("CAPTAIN_PALETTE_MODEL", "gpt-5.4-nano")
SIZE = "1024x1024"
QUALITY = "medium"  # ~$0.053/image at 1024x1024
PALETTE_COLORS = 6
MAX_PARALLEL = 4  # concurrent API calls
SUPPORTED_EXTS = {".jpg", ".jpeg", ".png", ".webp"}

BASE_STYLE = (
    "Render this house in the style of a Charles Schulz Peanuts comic strip — "
    "the same visual register as Charlie Brown's neighborhood. Confident, slightly "
    "uneven hand-drawn black outlines done with a brush or dip pen. Flat color "
    "fills inside the outlines, with little or no shading or gradients. A "
    "limited, mid-century palette: muted, slightly desaturated, with the warm "
    "feel of vintage four-color newsprint. Simplified shapes — windows, doors, "
    "siding, and roof rendered cleanly without photographic detail. Charmingly "
    "imperfect, never sterile. Emphatically NOT a photograph, NOT a 3D render, "
    "NOT anime, NOT a digital flat-vector illustration, NOT watercolor, NOT a "
    "lush painterly storybook scene. Think specifically of how Schulz would draw "
    "a house in a Sunday Peanuts strip — friendly, nostalgic, immediately "
    "recognizable as that style.\n\n"
    "Preserve the home's identity faithfully: the same overall proportions, roof "
    "shape and material, door color and shape, window placement, siding pattern "
    "and color, porch, chimney, and any prominent trees, shrubs, or landscaping "
    "attached to the home. A viewer who knows this house should recognize it "
    "instantly.\n\n"
    "Framing: center the SUBJECT home as the portrait. Exclude any neighboring "
    "buildings, parked vehicles, or unrelated structures from view. If the source "
    "photo is tilted or shot at an awkward angle, subtly straighten the "
    "perspective so the home reads square-on and centered. The home should fill "
    "most of the canvas.\n\n"
    "No address signals: do NOT include any street numbers, house numbers, "
    "mailbox lettering, address plaques, or any other text or numerals that "
    "would indicate a specific address. If the source photograph shows a "
    "visible street number on the house or on a mailbox, omit it entirely "
    "rather than guessing — the rendered home should carry no address text of "
    "any kind.\n\n"
    "Seasonal-decoration cleanup: if the source photograph shows seasonal "
    "decorations (Halloween pumpkins, Christmas wreaths, holiday lights, autumn "
    "leaf piles, summer flower pots, snow on the ground), do NOT carry those "
    "decorations into the rendering unless they are appropriate to the season "
    "being rendered. Render the home in a clean, season-appropriate state."
)

VARIANTS: dict[str, str] = {
    "base": BASE_STYLE,
    "spring": BASE_STYLE + (
        " Render the scene in early spring: fresh new green leaves just emerging, "
        "blossoming trees if any are present, soft pastel morning light, a hint of "
        "mist, the ground waking up."
    ),
    "summer": BASE_STYLE + (
        " Render the scene in mid-summer: lush full green foliage, warm late-afternoon "
        "sun casting long soft shadows, a deep blue sky with a few clouds, vibrant but "
        "not garish color."
    ),
    "fall": BASE_STYLE + (
        " Render the scene in mid-autumn: foliage in warm reds, oranges, and yellows, "
        "golden-hour light, a scattering of fallen leaves on the ground and walkways, "
        "the air feeling crisp."
    ),
    "winter": BASE_STYLE + (
        " Render the scene in winter: a fresh layer of snow on the roof, ground, and "
        "any trees; bare deciduous branches; soft cool blue-grey light of an overcast "
        "winter afternoon; warm yellow glow from any windows; possibly a simple wreath "
        "on the front door."
    ),
}


def find_photos() -> list[Path]:
    if not PHOTOS_DIR.exists():
        return []
    return sorted(
        p for p in PHOTOS_DIR.iterdir()
        if p.is_file() and p.suffix.lower() in SUPPORTED_EXTS
    )


def extract_palette(client: OpenAI, photo: Path) -> list[str]:
    """Ask a vision model for the home's distinctive color palette.

    Explicitly focuses on the house (door, siding, trim, roof, accent features),
    ignoring sky, lawn, road, and neighboring buildings.
    """
    img_bytes = photo.read_bytes()
    ext = photo.suffix.lower().lstrip(".")
    mime = "jpeg" if ext == "jpg" else ext
    data_url = f"data:image/{mime};base64,{base64.b64encode(img_bytes).decode()}"

    prompt = (
        f"Look at THE HOUSE in this photograph (not the sky, not the lawn, not "
        f"the road, not any neighboring buildings). Return exactly "
        f"{PALETTE_COLORS} hex color codes that capture the home's distinctive "
        f"palette — its door color, siding, trim, roof, shutters, porch, and any "
        f"prominent accent features. Distinctive accents like a colored front "
        f"door MUST be represented. Avoid duplicates and avoid muddy averages; "
        f"these should be colors that, used as accents in an app, would feel "
        f"like \"this home.\" Respond with JSON only, of the form: "
        f'{{"palette": ["#rrggbb", "#rrggbb", ...]}}'
    )
    resp = client.chat.completions.create(
        model=PALETTE_MODEL,
        messages=[{
            "role": "user",
            "content": [
                {"type": "text", "text": prompt},
                {"type": "image_url", "image_url": {"url": data_url}},
            ],
        }],
        response_format={"type": "json_object"},
    )
    raw = resp.choices[0].message.content or "{}"
    try:
        data = json.loads(raw)
        colors = data.get("palette") or []
    except json.JSONDecodeError:
        colors = re.findall(r"#[0-9a-fA-F]{6}", raw)
    cleaned: list[str] = []
    for c in colors:
        if isinstance(c, str) and re.fullmatch(r"#[0-9a-fA-F]{6}", c):
            cleaned.append(c.lower())
    return cleaned[:PALETTE_COLORS]


def render_variant(
    client: OpenAI,
    photo: Path,
    variant_name: str,
    prompt: str,
    out_dir: Path,
) -> tuple[str, Path | None, str | None]:
    """Call the image edit endpoint. Returns (variant_name, output_path_or_None, error_or_None)."""
    out_path = out_dir / f"{variant_name}.png"
    if out_path.exists():
        return variant_name, out_path, None  # skip if already rendered
    try:
        with open(photo, "rb") as f:
            result = client.images.edit(
                model=MODEL,
                image=f,
                prompt=prompt,
                size=SIZE,
                quality=QUALITY,
                n=1,
            )
        b64 = result.data[0].b64_json
        out_path.write_bytes(base64.b64decode(b64))
        return variant_name, out_path, None
    except Exception as e:  # noqa: BLE001
        return variant_name, None, f"{type(e).__name__}: {e}"


def make_thumbnail(src: Path, dst: Path, max_dim: int = 512) -> None:
    img = Image.open(src)
    if img.mode != "RGB":
        img = img.convert("RGB")
    img.thumbnail((max_dim, max_dim))
    img.save(dst, format="JPEG", quality=85)


def render_html(results: list[dict]) -> str:
    rows = []
    for r in results:
        palette_html = "".join(
            f'<div class="swatch" style="background:{c}" title="{c}"></div>'
            for c in r["palette"]
        )
        variant_cells = []
        for v in ["base", "spring", "summer", "fall", "winter"]:
            entry = r["variants"].get(v)
            if entry and entry.get("path"):
                rel = Path(entry["path"]).relative_to(OUTPUT_DIR)
                variant_cells.append(
                    f'<td><div class="label">{v}</div>'
                    f'<a href="{rel}" target="_blank"><img src="{rel}"></a></td>'
                )
            else:
                err = (entry or {}).get("error") or "missing"
                variant_cells.append(
                    f'<td><div class="label">{v}</div>'
                    f'<div class="err">{err}</div></td>'
                )

        original_rel = Path(r["thumb"]).relative_to(OUTPUT_DIR)
        rows.append(f"""
        <tr>
          <td>
            <div class="label">{r['name']}</div>
            <a href="{original_rel}" target="_blank"><img src="{original_rel}"></a>
            <div class="palette">{palette_html}</div>
          </td>
          {''.join(variant_cells)}
        </tr>""")

    return f"""<!doctype html>
<html><head><meta charset="utf-8"><title>Captain rendering prototype</title>
<style>
  body {{ font-family: -apple-system, BlinkMacSystemFont, sans-serif;
          background:#1a1a1a; color:#eee; margin:0; padding:24px; }}
  h1 {{ font-weight:500; margin:0 0 8px; }}
  .meta {{ color:#888; margin-bottom:24px; font-size:13px; }}
  table {{ border-collapse:collapse; width:100%; }}
  td {{ vertical-align:top; padding:12px; border-bottom:1px solid #333; }}
  td img {{ width:240px; height:240px; object-fit:cover; border-radius:6px;
            display:block; background:#222; }}
  .label {{ font-size:12px; text-transform:uppercase; letter-spacing:0.5px;
            color:#888; margin-bottom:6px; }}
  .palette {{ display:flex; gap:2px; margin-top:8px; width:240px; }}
  .swatch {{ flex:1; height:24px; border-radius:3px; }}
  .err {{ color:#c66; font-size:12px; width:240px; height:240px;
          display:flex; align-items:center; justify-content:center;
          background:#2a1a1a; border-radius:6px; padding:8px;
          word-break:break-word; }}
</style></head><body>
<h1>Captain — rendered home prototype</h1>
<div class="meta">model: {MODEL} · quality: {QUALITY} · size: {SIZE} ·
  rendered: {len(results)} home(s) · {time.strftime('%Y-%m-%d %H:%M')}</div>
<table>
  <tr>
    <td><div class="label">original + palette</div></td>
    <td><div class="label">base</div></td>
    <td><div class="label">spring</div></td>
    <td><div class="label">summer</div></td>
    <td><div class="label">fall</div></td>
    <td><div class="label">winter</div></td>
  </tr>
  {''.join(rows)}
</table>
</body></html>"""


def main() -> int:
    load_dotenv(ROOT / ".env")
    if not os.getenv("OPENAI_API_KEY"):
        print("ERROR: OPENAI_API_KEY not found in .env", file=sys.stderr)
        return 1

    photos = find_photos()
    if not photos:
        print(f"No photos found in {PHOTOS_DIR}. "
              f"Add .jpg/.jpeg/.png/.webp files and rerun.")
        return 1

    OUTPUT_DIR.mkdir(exist_ok=True)
    client = OpenAI()

    total_calls = len(photos) * len(VARIANTS)
    est_cost = total_calls * 0.053
    print(f"Found {len(photos)} photo(s). Will make up to "
          f"{total_calls} API call(s) (~${est_cost:.2f}).")
    print("Skipping any variants already rendered (rerun-safe).\n")

    results: list[dict] = []
    for photo in photos:
        name = photo.stem
        out_dir = OUTPUT_DIR / name
        out_dir.mkdir(exist_ok=True)
        thumb_path = out_dir / "original.jpg"
        if not thumb_path.exists():
            make_thumbnail(photo, thumb_path)

        try:
            palette = extract_palette(client, photo)
        except Exception as e:  # noqa: BLE001
            print(f"  [palette] {name}: failed ({e})")
            palette = []

        print(f"Rendering {name}...")
        variants: dict[str, dict] = {}
        with ThreadPoolExecutor(max_workers=MAX_PARALLEL) as ex:
            futures = {
                ex.submit(render_variant, client, photo, vname, prompt, out_dir): vname
                for vname, prompt in VARIANTS.items()
            }
            for fut in as_completed(futures):
                vname, path, err = fut.result()
                if err:
                    print(f"  [{vname}] ERROR: {err}")
                    variants[vname] = {"error": err}
                else:
                    print(f"  [{vname}] ok")
                    variants[vname] = {"path": str(path)}

        results.append({
            "name": name,
            "thumb": str(thumb_path),
            "palette": palette,
            "variants": variants,
        })

    index = OUTPUT_DIR / "index.html"
    index.write_text(render_html(results))
    print(f"\nDone. Open: {index}")
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
