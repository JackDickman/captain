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

from dataclasses import dataclass
from typing import Callable


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
    ),
    HuntItem(
        id="water_source",
        title="Water source",
        category="About your home",
        description="City water or a private well.",
        has_photo=False,
        question_prompt="On city/municipal water, or a well?",
        placeholder="e.g. \"city water\" or \"private well, pressure tank in basement\"",
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
