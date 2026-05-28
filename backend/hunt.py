"""
Scavenger hunt — the opt-in guided tour through the home (PRD §6.2).

Each item is one stop on the tour. The user provides either a photo
(for things to look at — water shutoff, HVAC unit, breaker box) or a
short written answer (for facts about the home or themselves — heat
source, who lives here). On completion, the captured info is fed
through the existing profile rewriter so it integrates naturally into
home.md / user.md.

The catalog is intentionally trimmed for v1: 5 branch questions, 5
safety essentials, 3 mechanicals, 3 first-timer "worth knowing" wins,
and 2 owner-profile items. Total 18 — enough to be meaningfully
useful, small enough that finishing feels achievable.

Adaptivity is rule-based, not LLM-based: each item can declare a
`show_if(state)` predicate where `state` is a dict mapping item_id →
the user's captured notes for completed items. Items without a rule
are always shown.
"""

from __future__ import annotations

import base64
import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from . import llm


# Vision extraction over uploaded docs. Mini gives us solid OCR + spatial
# reasoning over multi-page inspection reports without the cost of full
# models. Swappable per env var.
DOCS_MODEL = os.getenv("CAPTAIN_DOCS_MODEL", "gpt-5.4-mini")


# Structured-output schema for /hunt/documents extraction. We ask the
# model for an array of {item_id, notes} pairs — items where it found
# nothing useful are simply omitted, no "null notes" filler.
DOC_EXTRACTION_SCHEMA = {
    "type": "object",
    "properties": {
        "extractions": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "item_id": {
                        "type": "string",
                        "description": (
                            "Must exactly match one of the item ids "
                            "listed in the prompt."
                        ),
                    },
                    "notes": {
                        "type": "string",
                        "description": (
                            "Concise one-sentence summary of what the "
                            "documents say about this item. Include "
                            "specifics (brand, model, year, capacity, "
                            "location) when present."
                        ),
                    },
                },
                "required": ["item_id", "notes"],
                "additionalProperties": False,
            },
        },
    },
    "required": ["extractions"],
    "additionalProperties": False,
}


@dataclass(frozen=True)
class HuntItem:
    id: str
    title: str
    category: str
    # One-sentence description shown on the item card / detail screen.
    description: str
    # True = needs a photo to submit. False = text answer only.
    has_photo: bool
    # Optional hint shown above the photo capture / answer input.
    where_to_look: str | None = None
    # The question the user is answering (always shown).
    question_prompt: str | None = None
    # Placeholder text for the answer field.
    placeholder: str | None = None
    # Applicability rule. Receives current state ({item_id: notes}).
    # None = always shown.
    show_if: Callable[[dict[str, str]], bool] | None = None
    # Lowercase keywords used for "already-known" suppression — if any
    # appear in home.md (case-insensitive substring match), Captain
    # suggests it already has this info and asks the user to confirm
    # rather than walking through from scratch. Defaults to empty (no
    # auto-detection — user fills in normally).
    profile_keywords: tuple[str, ...] = ()
    # Short hint Captain prepends to the LLM extraction prompt when
    # scanning uploaded documents. Tells the model what to look for in
    # an inspection report / disclosure / closing docs for this item.
    # Empty means "skip this item during doc extraction" — used for
    # truly personal items (household composition, talking style).
    docs_hint: str = ""


# -------- applicability helpers --------

def _has(text: str, words: list[str]) -> bool:
    """Case-insensitive substring match against any of `words`."""
    lo = (text or "").lower()
    return any(w in lo for w in words)


def _heat_uses_gas(state: dict[str, str]) -> bool:
    """Gas-related items only show when the heat source mentions gas.
    Falls open (False = hide) when the branch hasn't been answered yet —
    the user answers branch questions first, then dependents reveal."""
    return _has(state.get("heat_source", ""), ["gas", "propane"])


def _has_basement(state: dict[str, str]) -> bool:
    """Sump-pump-type items only show when the home has a basement
    (full, partial, or finished). Slab / no answer / 'no' all hide."""
    answer = (state.get("has_basement") or "").lower()
    if not answer:
        return False
    # Explicit negatives win even if other words sneak in.
    if any(w in answer for w in [" no ", "no basement", "slab only", "none"]):
        if not any(w in answer for w in ["yes", "full", "partial", "half", "finished"]):
            return False
    return _has(answer, [
        "basement", "yes", "full", "partial",
        "half", "finished", "unfinished",
    ])


# -------- the catalog --------

ITEMS: list[HuntItem] = [
    # ----- About your home (branch questions, always at the top) -----
    HuntItem(
        id="home_basics",
        title="Confirm the basics",
        category="About your home",
        description="Year built, square footage, anything Captain pulled wrong.",
        has_photo=False,
        question_prompt=(
            "Captain pulled some details from public records during your "
            "first session. Anything wrong, or worth adding? (\"All "
            "looks right\" is fine.)"
        ),
        placeholder="e.g. \"1962, not 1965; we finished the attic in 2023\"",
        # Year built and sqft are usually surfaced in first-session, so
        # home.md mention is expected — we don't suppress on these.
        docs_hint=(
            "Year built, square footage, lot size, bedrooms/bathrooms — "
            "usually on the first page of an inspection report."
        ),
    ),
    HuntItem(
        id="heat_source",
        title="Heat source",
        category="About your home",
        description="What heats your home — this shapes a lot of what comes next.",
        has_photo=False,
        question_prompt=(
            "What's your primary heat source? Gas furnace, electric, oil, "
            "heat pump, or other?"
        ),
        placeholder="e.g. \"natural gas forced-air furnace; wood stove in the den\"",
        profile_keywords=(
            "heat pump", "natural gas", "gas furnace", "oil furnace",
            "oil heat", "electric heat", "baseboard", "boiler",
            "radiant", "wood stove", "propane",
        ),
        docs_hint=(
            "Heating system type (furnace / boiler / heat pump), fuel "
            "(gas, oil, electric, propane), and any notes on age."
        ),
    ),
    HuntItem(
        id="water_source",
        title="Water source",
        category="About your home",
        description="City water or a private well.",
        has_photo=False,
        question_prompt="On city/municipal water, or a well?",
        placeholder="e.g. \"city water\" or \"private well, pressure tank in basement\"",
        profile_keywords=(
            "well water", "private well", "city water", "municipal water",
            "pressure tank",
        ),
        docs_hint=(
            "Water supply — municipal vs. private well. Inspection "
            "reports usually call this out on the plumbing page."
        ),
    ),
    HuntItem(
        id="sewer_type",
        title="Sewer or septic",
        category="About your home",
        description="Municipal sewer or septic tank.",
        has_photo=False,
        question_prompt=(
            "City sewer or septic? If septic, roughly where's the tank and "
            "when was it last pumped, if you know?"
        ),
        placeholder="e.g. \"septic, tank near the back fence, pumped 2023\"",
        profile_keywords=(
            "septic", "city sewer", "municipal sewer", "leach field",
        ),
        docs_hint=(
            "Sewer / septic — type, and if septic, tank location and "
            "last pump date when noted."
        ),
    ),
    HuntItem(
        id="has_basement",
        title="Basement or crawl space",
        category="About your home",
        description="Tells Captain whether to ask about sumps and crawl-space items.",
        has_photo=False,
        question_prompt=(
            "Full basement? Partial? Crawl space? Slab? Some mix?"
        ),
        placeholder="e.g. \"full basement, partially finished\"",
        profile_keywords=(
            "basement", "crawl space", "crawlspace", "slab", "cellar",
        ),
        docs_hint=(
            "Foundation type — basement (full / partial / finished), "
            "crawl space, slab, or some combination."
        ),
    ),

    # ----- Safety essentials -----
    HuntItem(
        id="water_shutoff",
        title="Main water shutoff",
        category="Safety essentials",
        description=(
            "The single most important valve in the house — cuts all "
            "water in a leak."
        ),
        has_photo=True,
        where_to_look=(
            "Usually where the main line enters the house — basement near "
            "the front foundation wall, a utility room, or a crawl-space "
            "access. On a slab, often in the garage. On a well, near the "
            "pressure tank."
        ),
        question_prompt="Briefly, where is it?",
        placeholder="e.g. \"basement utility room, behind the laundry tub\"",
        # Inspection reports rarely note the location precisely — but
        # they sometimes describe valve type / condition.
        docs_hint=(
            "Main water shutoff — location notes, valve type "
            "(ball / gate), or any condition notes."
        ),
    ),
    HuntItem(
        id="gas_shutoff",
        title="Gas shutoff",
        category="Safety essentials",
        description=(
            "The valve that cuts gas to the house. Knowing where it is "
            "is half the battle — you'll need a wrench to turn it."
        ),
        has_photo=True,
        where_to_look=(
            "Usually outside next to the gas meter — a quarter-turn yellow "
            "handle. Sometimes also a shutoff at the furnace or each "
            "appliance."
        ),
        question_prompt="Where's the meter?",
        placeholder="e.g. \"south side, by the AC condenser\"",
        show_if=_heat_uses_gas,
        docs_hint=(
            "Gas meter / shutoff location notes from the inspection's "
            "exterior or gas-system section."
        ),
    ),
    HuntItem(
        id="electrical_panel",
        title="Electrical panel",
        category="Safety essentials",
        description=(
            "The breaker box. Knowing what's labeled (and what isn't) is "
            "gold in any power problem."
        ),
        has_photo=True,
        where_to_look=(
            "Basement, garage, utility closet, or hallway. Older homes "
            "sometimes have it outside near the meter."
        ),
        question_prompt="Anything labeled? Any breakers you don't know what they control?",
        placeholder="e.g. \"labels are illegible from the previous owner — need to redo them\"",
        profile_keywords=(
            "breaker box", "electrical panel", "service panel",
            "main panel", "amp service", "amperage",
        ),
        docs_hint=(
            "Electrical panel — main amperage (100A / 200A), brand "
            "(Square D, FPE, Zinsco, etc.), number of breakers, any "
            "noted issues (FPE recalls, double-tapping, rust)."
        ),
    ),
    HuntItem(
        id="smoke_co_detectors",
        title="Smoke + CO detectors",
        category="Safety essentials",
        description="Where they are and roughly how old.",
        has_photo=False,
        question_prompt=(
            "Where are your smoke and CO detectors? Any sense of how old "
            "they are? (10 years is typical lifespan.)"
        ),
        placeholder="e.g. \"every hallway + basement near the stairs; replaced when we moved in 2024\"",
        docs_hint=(
            "Smoke and CO detectors — how many, where (every bedroom, "
            "every floor), and the inspector's notes on age or function."
        ),
    ),
    HuntItem(
        id="sump_pump",
        title="Sump pump",
        category="Safety essentials",
        description=(
            "If you have one, knowing where it is and whether it works "
            "matters the next time a storm doesn't quit."
        ),
        has_photo=True,
        where_to_look=(
            "A pit in the basement floor, usually a corner, with a "
            "discharge pipe heading up and out."
        ),
        question_prompt="Battery backup? Any history of issues?",
        placeholder="e.g. \"no backup; runs heavily in spring\"",
        show_if=_has_basement,
        profile_keywords=(
            "sump pump", "sump pit", "battery backup",
        ),
        docs_hint=(
            "Sump pump — presence, age, battery backup, any noted "
            "issues (cycling, sticking, dry pit)."
        ),
    ),

    # ----- Mechanicals -----
    HuntItem(
        id="hvac_unit",
        title="HVAC unit + filter",
        category="Mechanicals",
        description=(
            "A photo of the indoor unit + filter slot, plus the filter "
            "size if you can read it."
        ),
        has_photo=True,
        where_to_look=(
            "Basement, attic, utility closet, or garage. The filter slot "
            "is usually a small door or slot on the return-air side."
        ),
        question_prompt="If the filter size is visible, what is it? When was it last changed?",
        placeholder="e.g. \"16x25x1; replaced last month\"",
        profile_keywords=(
            "hvac", "furnace", "air handler", "air conditioner",
            "ac unit", "merv", "filter size",
        ),
        docs_hint=(
            "HVAC / furnace / AC — brand (Carrier, Trane, Lennox, Goodman, "
            "etc.), model, install year, filter size, condition. Heat "
            "pumps too."
        ),
    ),
    HuntItem(
        id="water_heater",
        title="Water heater",
        category="Mechanicals",
        description=(
            "Photo of the unit. The data plate (brand, model, year) is "
            "the key info — handy when it eventually fails."
        ),
        has_photo=True,
        where_to_look=(
            "Basement, utility closet, or garage. Tankless units are "
            "usually wall-mounted near a wall vent."
        ),
        question_prompt="Tank or tankless? Rough age, if you know?",
        placeholder="e.g. \"50-gal gas tank, installed 2018\"",
        profile_keywords=(
            "water heater", "hot water heater", "tankless", "tank water",
        ),
        docs_hint=(
            "Water heater — type (tank / tankless / heat pump), brand, "
            "capacity (gallons), fuel (gas / electric), install year, "
            "any noted condition."
        ),
    ),
    HuntItem(
        id="thermostat",
        title="Thermostat",
        category="Mechanicals",
        description=(
            "Smart, programmable, or analog? Helps Captain give better "
            "seasonal nudges."
        ),
        has_photo=False,
        question_prompt="What kind do you have? Brand/model if you know it.",
        placeholder="e.g. \"Nest 3rd gen\" or \"plain dial thermostat from the 80s\"",
        profile_keywords=(
            "thermostat", "nest", "ecobee", "honeywell thermostat",
            "smart thermostat",
        ),
        docs_hint=(
            "Thermostat — type (smart / programmable / dial), brand if "
            "noted."
        ),
    ),

    # ----- Worth knowing (the first-timer wins) -----
    HuntItem(
        id="sewer_cleanout",
        title="Sewer cleanout",
        category="Worth knowing",
        description=(
            "A capped pipe a plumber can clear a clog from. Most homes "
            "have one — most owners don't know it."
        ),
        has_photo=True,
        where_to_look=(
            "Outside near the foundation, often the side facing the "
            "street. A black or white capped pipe sticking out of the "
            "ground. Indoors, sometimes a Y-fitting on the main drain "
            "stack in the basement."
        ),
        question_prompt="Where is it? Any markings?",
        placeholder="e.g. \"back of the garage, by the AC condenser\"",
        # Inspection reports usually note the cleanout in the plumbing
        # section when accessible.
        docs_hint=(
            "Sewer cleanout — location, accessibility, any notes from "
            "the plumbing section."
        ),
    ),
    HuntItem(
        id="dryer_vent_path",
        title="Dryer vent path",
        category="Worth knowing",
        description=(
            "Lint-clogged dryer vents are a top cause of house fires. "
            "Knowing the path (and length) helps Captain remind you "
            "when to clean it."
        ),
        has_photo=False,
        question_prompt=(
            "Where's the dryer, and where does its vent exit the house? "
            "Any sense of how long the run is?"
        ),
        placeholder="e.g. \"first-floor laundry, vents out the side wall ~5 ft away\"",
        docs_hint=(
            "Dryer vent — location of laundry, vent exit, any noted "
            "issues (long run, kinks, lint buildup)."
        ),
    ),
    HuntItem(
        id="gfci_outlets",
        title="GFCI outlets",
        category="Worth knowing",
        description=(
            "The outlets with TEST/RESET buttons — bathrooms, kitchen, "
            "garage, outside. One GFCI sometimes controls others further "
            "down the line, so knowing the resets saves a service call."
        ),
        has_photo=False,
        question_prompt=(
            "Roughly where are they? Any you know are linked (resetting "
            "one resets others)?"
        ),
        placeholder="e.g. \"kitchen, both baths, garage; the garage one trips the outside outlet too\"",
        docs_hint=(
            "GFCI outlets — inspectors test these, so the electrical "
            "section often lists which areas have them and which "
            "should but don't."
        ),
    ),

    # ----- About you -----
    HuntItem(
        id="household_composition",
        title="Who lives here",
        category="About you",
        description=(
            "Captain calibrates everything against this — yard chemicals, "
            "alarm checks, project timing."
        ),
        has_photo=False,
        question_prompt=(
            "Who lives here? Pets (names, breeds), kids, work-from-home, "
            "anyone in or out a lot?"
        ),
        placeholder="e.g. \"me + my partner, both WFH; Jackie, 8yo yellow lab who sniffs everything\"",
    ),
    HuntItem(
        id="your_style",
        title="How Captain should talk to you",
        category="About you",
        description="DIY comfort, level of jargon, anything to avoid.",
        has_photo=False,
        question_prompt=(
            "How experienced are you as a homeowner? Want Captain to "
            "define basics, or skip the explanations? Any sensitivities "
            "(chemicals, fragrances, dust)?"
        ),
        placeholder="e.g. \"first-time owner, explain the basics; avoid strong fragrances\"",
    ),
]


# -------- public API --------

ITEMS_BY_ID: dict[str, HuntItem] = {item.id: item for item in ITEMS}


def state_from_progress(progress_rows: list[dict]) -> dict[str, str]:
    """Build the {item_id → notes_text} state map from done rows. Used
    by show_if predicates to gate conditional items."""
    return {
        row["item_id"]: row.get("notes") or ""
        for row in progress_rows
        if row.get("status") == "done"
    }


def applicable_items(state: dict[str, str]) -> list[HuntItem]:
    """Items whose show_if currently passes (or which have no rule)."""
    return [
        item for item in ITEMS
        if item.show_if is None or item.show_if(state)
    ]


def profile_mentions(item: HuntItem, home_md: str) -> str | None:
    """If any of `item.profile_keywords` appear in `home_md` (case-
    insensitive substring match), return the first ~120 characters of
    surrounding context. Caller surfaces this as a "Captain seems to
    know this already" hint on the item.

    Returns None when there's no match or the item has no keywords."""
    if not item.profile_keywords or not home_md:
        return None
    low = home_md.lower()
    for kw in item.profile_keywords:
        idx = low.find(kw)
        if idx < 0:
            continue
        # Snip the matched span + some surrounding context, trimmed to
        # avoid pulling in markdown noise on either side.
        start = max(0, idx - 40)
        end = min(len(home_md), idx + len(kw) + 80)
        snippet = home_md[start:end].strip()
        # Collapse newlines and excessive whitespace so the hint sits
        # as one inline line in the UI.
        snippet = " ".join(snippet.split())
        # Ellipsis hints when we trimmed.
        prefix = "…" if start > 0 else ""
        suffix = "…" if end < len(home_md) else ""
        return f"{prefix}{snippet}{suffix}"
    return None


def docs_extraction_items() -> list[HuntItem]:
    """Items eligible for being auto-filled by uploaded documents — i.e.
    those that have a non-empty docs_hint. Personal items
    (household_composition, your_style) deliberately opt out."""
    return [item for item in ITEMS if item.docs_hint]


def _build_docs_prompt() -> str:
    """Construct the system prompt for the document-extraction LLM call.
    Enumerates every item eligible for doc auto-fill alongside its hint,
    then sets the conservatism bar (only return what's explicitly in
    the docs)."""
    item_lines = "\n".join(
        f"- `{item.id}` ({item.title}): {item.docs_hint}"
        for item in docs_extraction_items()
    )
    return (
        "You're extracting structured information from documents a "
        "homeowner just uploaded — typically an inspection report, "
        "seller's property disclosure, closing docs, or appliance "
        "manuals. Captain will use what you extract to pre-fill items "
        "in a guided home tour so the user can confirm rather than "
        "answer from scratch.\n\n"
        "BE CONSERVATIVE. Only return items where the documents "
        "EXPLICITLY state an answer. Don't infer, generalize, or guess. "
        "If a category isn't covered in the documents, OMIT it from "
        "your response — the user will fill those in manually.\n\n"
        "For each returned item, `notes` should be a concise one-sentence "
        "summary in plain language, including specifics (brand, model, "
        "install year, capacity, fuel, location) when the documents "
        "include them.\n\n"
        "NEVER return:\n"
        " - prices, costs, or dollar figures (Captain deliberately "
        "avoids financial framing)\n"
        " - personal information about prior owners\n"
        " - speculative repairs the inspector merely flagged\n\n"
        "Items you may return (use the exact id):\n"
        f"{item_lines}"
    )


def extract_from_documents(photo_paths: list[Path]) -> list[dict]:
    """Send all uploaded document photos to the vision LLM and ask for
    structured extractions. Returns a list of {item_id, notes} dicts —
    only items where the model found real info. Errors and malformed
    responses return an empty list (graceful degradation; the user can
    still fill items in manually).
    """
    if not photo_paths:
        return []

    content: list[dict] = [
        {"type": "text", "text": _build_docs_prompt()},
    ]
    for p in photo_paths:
        try:
            raw = p.read_bytes()
        except OSError as e:
            print(f"[hunt-docs] couldn't read {p}: {e}")
            continue
        suffix = p.suffix.lower().lstrip(".")
        mime = "jpeg" if suffix == "jpg" else suffix
        content.append({
            "type": "image_url",
            "image_url": {
                "url": (
                    f"data:image/{mime};base64,"
                    f"{base64.b64encode(raw).decode()}"
                ),
            },
        })

    if len(content) == 1:
        # All images failed to read.
        return []

    try:
        resp = llm.chat_completion(
            model=DOCS_MODEL,
            messages=[{"role": "user", "content": content}],
            response_format={
                "type": "json_schema",
                "json_schema": {
                    "name": "hunt_doc_extraction",
                    "schema": DOC_EXTRACTION_SCHEMA,
                    "strict": True,
                },
            },
        )
    except Exception as e:  # noqa: BLE001
        print(f"[hunt-docs] LLM call failed: {e}")
        return []

    try:
        payload = json.loads(resp.text or "{}")
        extractions = payload.get("extractions") or []
    except (json.JSONDecodeError, KeyError, AttributeError) as e:
        print(f"[hunt-docs] response parse failed: {e}")
        return []

    print(f"[hunt-docs] extracted {len(extractions)} item(s) from "
          f"{len(photo_paths)} document(s)")
    return extractions
