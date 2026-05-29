# Captain — Product Requirements Document (v1)

**Version:** 1.4
**Last updated:** May 28, 2026
**Status:** Draft — personal pet project, under active build

---

## Table of contents

1. The pitch in one paragraph
2. Identity and framing
3. Target user
4. Why this exists (problem statement)
5. Guiding principles
6. V1 scope
7. UI/UX
8. Example use cases
9. Data sources and integrations
10. What's explicitly out of scope for v1
11. Parking lot — ideas to revisit post-v1
12. Open questions
13. Success criteria

## Glossary of key terms

Terms used throughout this document with specific meanings:

- **The home profile** — the dynamically maintained record of facts about the specific home (location, age, systems, plants, appliances, etc.).
- **The personal profile** — the dynamically maintained record of the user's preferences, household context, and how they want to be talked to.
- **The rendered home** — the stylized illustration of the user's home that anchors the UI, responsive to season, weather, time of day, and home state.
- **The calendar / passport / biography** — the timeline of everything that has been done to the home (past) and everything coming up (future). Used interchangeably throughout the doc; "passport" emphasizes the eventual transferable artifact, "biography" emphasizes the emotional/narrative framing.
- **The radar** — what's on the user's plate right now (upcoming reminders, seasonal nudges, forward-dated items, recent observations). Accessed via the bottom sheet on the home screen.
- **The scavenger hunt** — the optional "I just moved in" guided workflow that walks new owners through finding and photographing key home systems and features.
- **The digest** — the twice-weekly notification (Friday and Monday) summarizing what's relevant.

---

## 1. The pitch in one paragraph

Captain is an AI-powered mobile app that helps a homeowner take care of their home — proactively, intelligently, and in a way that's tailored to their specific house and their specific life. Unlike generic AI chat tools, Captain is purpose-built for a single domain, so it doesn't require the user to "figure out how to prompt." It accumulates context over time (about the home, the owner, what's been done) and uses that context to be genuinely useful when the user shows up. The home — not the task list — is the main character.

## 2. Identity and framing

**The home is the main character.** Captain is the home's biographer; the user is the steward. Every interaction adds to the home's record. This framing should be felt throughout the product — in tone, in defaults, in what gets emphasized — even if it's never said explicitly to the user.

This identity choice shapes downstream decisions:

- Accumulation feels meaningful, not like data entry.
- Eventual handoff to a future owner feels natural ("you're handing them your home's story").
- Captain's voice is observant and attentive, not barky or task-driven.
- The app's center of gravity is the home's profile and history, not a to-do list.

## 3. Target user

Primary: young or first-time homeowners who care about their home, are reasonably organized, comfortable opening apps on their own, and overwhelmed (or expecting to be overwhelmed) by the cognitive load of homeownership. They want help remembering, deciding, and learning — not a nag system.

Secondary: any homeowner of any experience level who wants a single intelligent place to manage their home.

Out of scope: renters, people not responsible for their home, and multi-property functionality (for v1).

## 4. Why this exists (problem statement)

Homeownership carries a large, mostly invisible cognitive load — and most of it is temporal. Knowing *what to do when* is harder than knowing how. Generic AI tools are reactive and require the user to know what to ask. Existing homeowner apps are mostly passive databases or chore lists. No one has built a domain-specific AI app that accumulates context about a specific home and a specific person and uses that to be proactively, gently useful.

## 5. Guiding principles

These are tiebreakers for any decision in v1.

1. **The home is the main character.** When in doubt, design around the home, not the tasks.
2. **Simple, intuitive, intelligent, tailored — in that order of priority over "feature-rich."** A small set of things done exquisitely well beats many things done okay.
3. **The barrier to entry should be low enough that a lazy person can succeed.** A motivated user can go as deep as they want, but it should never be required.
4. **Reduce burden; never add it.** No stress-inducing surfaces (e.g., cost tracking) in v1.
5. **Accumulation, not data entry.** Every interaction should make the home's profile richer as a byproduct, never as a chore.
6. **Distinctive over generic.** Captain should not look or feel like every other AI chat app. It should be aesthetically pleasing, visually engaging, and tailored to the home.

## 6. V1 scope

V1 is intentionally focused. A small set of capabilities, done well, all in service of the home as the main character.

**Platform and geography assumptions for v1:**

- **iOS only.** Android comes later. All design and engineering decisions can assume iPhone.
- **United States only.** All integrations, data sources, units, and content can assume US homes. International support is a post-v1 concern.

### 6.1 First-session experience: photo of the house

The very first thing the user does after downloading Captain is take or upload a photo of the front of their home.

From that single photo, Captain attempts to derive:

- Street number (via OCR if visible)
- Address (via GPS at time of capture, refined by OCR)
- Public-record data tied to the address: year built, square footage, lot size, last sale date, etc.
- Visual cues: roof material, siding type, approximate landscaping style, presence of features like a deck, fence, porch
- Climate context: hardiness zone, typical weather patterns, season

Captain then presents what it thinks it knows and lets the user confirm or correct via chat. This becomes the seed of the home profile.

The same photo also drives **UI customization**: the app's color palette, accent imagery, and home-screen visual are derived from the photo so the app feels like *theirs* from the first session. This is the first "aha" moment of the product.

**Setup validation.** Before kicking off the (~30-second) extraction + rendering pipeline, a quick stage-0 check geocodes the address (US Census) and runs a small vision classifier over the photo to confirm it's actually a residential home exterior. Bad input (made-up address, indoor selfie, floor-plan screenshot) gets a specific friendly error inline so the user can correct and resubmit without burning the long pipeline. The classifier is lenient — only catches clear mismatches; soft-fails open on its own errors so it never blocks a real user.

**Speculative pre-render.** The current-season home rendering — the slowest stage by far — is kicked off the moment the user picks their photo in the form, in parallel with them typing the address. By the time they tap submit, the render is usually mostly or fully done, and the loading screen often only covers the remaining ~15s of search + extraction + finalization instead of the full ~45s.

### 6.2 The scavenger hunt — "I just moved in" mode

After the first-session photo flow, new owners can opt into a guided tour of the home — a curated checklist of safety essentials, mechanicals, "worth knowing" first-timer wins, and about-you items. v1 ships with **18 items across 5 categories**:

- **About your home** (5 branch questions): home_basics confirmation, heat source, water source, sewer/septic, basement/crawl space
- **Safety essentials** (5): main water shutoff, gas shutoff (only when gas heat), electrical panel, smoke + CO detectors, sump pump (only when basement)
- **Mechanicals** (3): HVAC unit + filter, water heater, thermostat
- **Worth knowing** (3 first-timer wins): sewer cleanout, dryer vent path, GFCI outlets
- **About you** (2): who lives here, how Captain should talk to you

Items are a mix of photo-required ("show me your breaker box") and text-only ("what heats your home?"). The catalog is trimmed by design for v1 — easier to validate the flow before expanding.

**Adaptive: branch questions gate dependents.** The five "About your home" items appear at the top of the list. As the user answers them, dependent items appear: answering `heat_source` with "natural gas" reveals `gas_shutoff`; answering `has_basement` with "full" reveals `sump_pump`; items that don't apply (e.g., oil-tank questions on a gas-heated home) never surface.

**Adaptive: already-known suppression.** Each catalog item declares a small list of profile keywords. When Captain loads the tour, it scans `home.md` and `user.md` for matches and surfaces a quiet "already known" pill on those items, with the matched snippet shown as a "Captain seems to know this already — confirm or update?" card inside the item. Users who've already discussed their HVAC in chat aren't asked from scratch.

**Document upload at the start.** Before walking the tour, the user can photograph their inspection report, seller's disclosure, closing docs, or appliance manuals. A vision LLM extracts what it can — heat source, water heater specs, electrical panel notes, GFCI locations, etc. — and pre-fills the relevant items as "from your docs" with a confirmation step. Items pre-filled this way still require the user to tap save before they commit to the profile; Captain never auto-writes from raw doc extractions without user agency. Personal items (household composition, talking style) deliberately opt out of doc extraction.

**Fully self-paced.** Start, leave at any time, resume. Every action writes immediately to the `hunt_progress` table — closing the app mid-item leaves it pending; the next open picks up where the user left off. The home-screen banner stays visible until every applicable item is resolved (done, skipped, or marked not applicable), then disappears. The user can mark any item not-applicable themselves if Captain's branch detection guesses wrong.

**Same memory pipeline as chat.** Each completed item synthesizes an exchange tagged `[scavenger hunt: <title>]` and runs it through the regular `update_memory_from_exchange`, which:

- rewrites `home.md` (for home facts) and `user.md` (for owner facts) — the rewriter routes by category, so the "Heat source" answer lands in the home profile's Systems section, while "Who lives here" lands in the owner profile's Preferences;
- extracts any dated/recurring entries into the calendar (e.g., "Planning to upgrade the furnace in fall 2026" → a `future` calendar entry with `occurred_at: 2026-09-01`);
- invalidates the radar cache so the next /radar regenerates against the richer context.

Photos attached to an item are passed to the profile rewriter as vision context, so visible-only facts (an appliance's brand from the data plate, a panel's amperage, a thermostat model) make it into the profile without the user having to transcribe.

### 6.3 The home profile

A dynamically evolving record of the home itself: location, age, size, systems, materials, plants, appliances, recent work, known quirks. The profile grows as the user interacts — every chat, every photo, every logged action contributes.

The profile is visible to the user (transparent, browseable, editable) but they should rarely need to edit it directly. Captain should infer and ask.

### 6.4 The personal profile

A separate record of the homeowner's preferences and context: willingness to DIY, household size, presence of pets or kids, style preferences, chemical sensitivities, time availability, and **how they want to be talked to** (e.g., explain-the-basics vs. assume-expertise, terse vs. conversational). Kept separate from the home profile so it travels with the user if they move.

Like the home profile, this grows through interaction, not forms. Captain infers tone preferences from how the user writes and what they ask — someone who says "what's a P-trap?" gets jargon defined inline going forward; someone who casually mentions re-soldering copper gets treated as experienced. The user can also state preferences directly ("stop explaining the basics") and Captain updates the profile accordingly.

Tone calibration applies to chat responses, digest copy, and any other surface where Captain speaks.

### 6.5 Chat (omnipresent, not primary)

A chat input is available from anywhere in the app. Users can ask anything about their home, log what they did, get advice, or identify issues from photos.

Chat is the workhorse but not the front door. The home screen is the home.

**Photo uploads in chat are a first-class input.** The user can attach a photo to any chat message, and Captain extracts whatever's useful:

- Appliance and equipment labels → model, serial, age, typical lifespan, manuals
- Plants → species identification, care needs, seasonal considerations
- Receipts and documents → log the purchase or work into the calendar/profile
- Visible problems (stains, cracks, leaks, pests, lawn issues) → diagnosis and next steps
- Anything else worth noting → silently added to the home profile

Every chat photo also enriches the home profile and may produce a calendar entry as a side effect.

**Photo input — library or camera.** The chat input's brass camera button opens a quick menu: pick from the photo library (multi-select, ordered) or take a photo in-app right now. Captures and library picks stack into a single pending strip so a user can mix sources within one message. Both flows hit the same vision extraction pipeline.

**Conversation history — threads, not an endless scroll.** Chat is broken into discrete conversations so a year-long history doesn't collapse into one wall of text — both for the user's sake (revisiting past topics is meaningful) and the model's (every turn ships the recent window, not the full archive). The bucketing rule is **active-window, not midnight**: when the chat surface opens, Captain resumes the most recent conversation if its last message was within 12 hours; otherwise it starts fresh on the next send. This handles "I'm hammering on a problem late into the night" (11pm → 1am stays together) and "I'm back the next day" (sleep, return to a fresh thread) without a hard date cliff. A small clock affordance in the chat header opens the history list — past threads in reverse-chronological order, each with a short LLM-generated title written in the background after the first exchange ("wax ring on the upstairs toilet"). Tap a row to pin the chat surface to that thread and continue it. Swipe to delete. A "Start a new conversation" button at the top of the list breaks threads on demand for users who'd rather decide for themselves. The window length is configurable via `CAPTAIN_ACTIVE_CONVERSATION_WINDOW_SECONDS` so we can tune it once real usage suggests a different number. Implementation: `conversations` table with denormalized `last_message_at` for cheap active lookup + cheap history sort; `backend/chat.py:maybe_generate_title` runs as part of the post-exchange background task; iOS surface in `ConversationHistoryView.swift`.

Captain's chat behavior:

- Speaks in plain language, defines jargon inline unless the personal profile signals expertise
- Asks clarifying questions when useful, not reflexively
- Helps the user *decide* what to do and *who* to call — including reading reviews and surfacing options — rather than just dumping search results
- Quietly updates the home profile, personal profile, and calendar as a side effect of conversation
- **Draws out durable details.** When a conversation naturally surfaces a specific the user will want a year from now — bags of mulch used, paint brand, plant counts, filter size, vendor name — Captain asks one short follow-up at the *end* of its response. Help first, ask second. One question per turn. Never asks about prices or costs (no financial surfaces per §10).
- **Stays in its lane.** A lightweight scope gate runs before each chat turn. Off-topic messages (homework help, coding, dating, etc.) and capability-overreach asks (generate an image, send an email, place an order) get a quiet redirect rather than a long answer. Lenient by default; only catches clear cases.

**Two tools the chat model can reach for, deciding on its own when each fits:**

- **`web_search`** — live web lookup via Firecrawl. Used when the user's question genuinely requires current or local information the model can't be confident of from training: current contractor reviews in the user's area, recent regulatory or rebate changes, current local conditions where the home-screen weather context isn't enough. iOS shows a live "searching the web for X" indicator on the assistant bubble while the search is in flight so the user can see what's being looked up. Empty / failed searches surface plainly ("couldn't find live info on that") and Captain proceeds with what it knows — never fabricates sources.
- **`find_products`** — product recommendations via Firecrawl scoped to Amazon. Used when the conversation surfaces a concrete product the user might want to order (restocking a filter, picking up a stain, finding a pet-safe lawn product). The pattern is offered, never pushed — "want me to pull up a few options?". Single recommendations render inline as a markdown link in Captain's prose; comparisons of 2-3 picks render as compact cards under the bubble that tap through to the affiliate URL. The model is told never to mention price in prose (PRD §5). Re-recommends brands the user has used before when the profile carries that context. See §11.8 for the business-model framing this enables.

### 6.6 Home screen

The default screen on app open is anchored by the home itself, not a feed of tasks. It surfaces what's relevant right now in a way that doesn't disrupt the emotional tone of arriving at one's home. Detailed UI/UX specification for the home screen is in §7.4.

### 6.7 The calendar / passport

A browsable timeline of everything that's been done to the home: maintenance, repairs, plantings, purchases, observations. This is the "home's biography" — the artifact that accumulates over time.

In v1, this is auto-populated from chat and photos. Calendar entries are text-based — they describe what was logged, observed, or extracted — because v1 does not persist user-uploaded images (see §9.3). Users can scroll back and see the history, tap any entry for context, and see related entries linked together.

**The calendar is equally forward-looking.** When the user mentions a future intent in chat — "I'll get to the gutters next month," "planning to repaint the deck in May," "want to replace the dishwasher this fall" — Captain captures it as a forward-dated entry and surfaces it when the time comes. The same is true of inferred future items: filter replacements, seasonal tasks, warranties expiring, equipment approaching end-of-life. The user can see and edit upcoming items just like past ones.

The calendar is the single source of truth for both what *was* done and what's coming up.

**Biographer surfaces — Captain occasionally speaks unbidden.** The calendar isn't just a log; it's the source the home's biographer draws on. When a calendar entry's date lines up with today (one or more years ago, within a small day window), the home screen carries a single quiet "on this day" line above the chat input — written fresh each day by a small LLM call against the matched entry. On most days there's nothing to say (especially early in a home's history) and the surface renders nothing, which is correct. When it does appear, it should feel like a friend noticing an anniversary, not a notification. Implementation: `backend/biographer.py` + `GET /biographer`, cached 24h, invalidated whenever the calendar changes. The line is intentionally short (under ~16 words), italic, and tone-calibrated against the owner profile.

### 6.8 Notifications

Two per week, opt-in, ideally on by default but easy to silence:

- **Friday morning:** "Here's what to think about for your weekend." Action-oriented, short.
- **Monday morning:** "Here's the week ahead." Reflective and planning-oriented.

No other push notifications in v1. The proactive value of Captain otherwise depends on the user opening the app — which is fine, given the digest cadence gives Captain a heartbeat.

## 7. UI/UX

The UI is meant to be aha-worthy in its own right — independent of the functionality underneath. Captain should not look or feel like another generic AI chat app with a house icon.

### 7.1 Design philosophy

Three principles drive every UI/UX decision:

1. **The home is the emotional center.** Captain assumes the user loves their home and cares about taking good care of it. The UI should evoke emotion — warmth, nostalgia, pride, attachment — not productivity. This is closer to a love letter to a home than a property management dashboard.
2. **One surface, minimal navigation.** No bottom tab bar, no hamburger menu, no tab switcher. The whole app is one fluid surface anchored by the home. The user moves through states via gesture and direct interaction, not by navigating between screens.
3. **Calm by default, accessible when needed.** The first thing the user sees should be their home, not their to-do list. Functional things (radar items, profiles, history) are easy to reach but never visually dominant on arrival.

### 7.2 The rendered home

The first-session photo isn't just stored — Captain renders the user's home as a stylized illustration. The current style is a Charles Schulz / Peanuts register: confident hand-drawn outlines, flat color fills, limited mid-century palette, charming imperfection. Same house, same proportions, same key features (door color, porch, trees, siding), but rendered as a piece of art rather than a photograph. The intended emotional register is **nostalgic** — something that feels like a memory of home, a portrait, a keepsake. Not a real estate listing photo.

The rendered home is responsive to context:

- **Seasons.** Spring blossoms, summer foliage, autumn color, winter snow. The home image quietly shifts across the year.
- **Weather.** Rain, snow, sunshine, dusk, night with lit windows.
- **Time of day.** Morning light, midday, sunset, evening.
- **State of the home.** Subtle, occasional cues — an overgrown lawn if mowing has slipped, a wreath on the door in December, leaves on the ground in late October.

Every time the user opens Captain, they see a portrait of their home in this moment. That alone is meant to be the daily reason to come back.

This was a meaningful technical bet (see §12) and early prototyping has been encouraging — the Schulz register reads cleanly across the test homes we've tried, and the seasonal variants land with the right emotional weight. Worth continuing to validate on more home types.

**Render guardrails:**

- No text or numerals anywhere in the image. The prompt explicitly forbids street numbers, mailbox lettering, address plaques, name plaques, decorative monograms, license plates, dates carved into stonework, security yard signs, realtor signs, and any other text. A wrong-but-confident number on a rendered home would feel sloppy and break trust.
- No neighboring buildings, vehicles, or unrelated structures — the subject home is centered and fills most of the canvas.
- Seasonal decorations in the source photo are cleaned up unless they're appropriate to the season being rendered.

### 7.3 Color palette derived from the home

Captain extracts a color palette from the user's first-session photo — door color, siding, trim, foliage, sky — and uses it throughout the app. Accents, button colors, chat bubble tones, card backgrounds, digest text accents. Two users' Captain apps look visibly different from each other because their homes are different. This is one of the underused tricks in mobile design and it lands hard here because the home is right there as the source of truth.

### 7.4 The home screen

The default screen on app open:

- **The rendered home is the dominant visual** — full bleed or near-full bleed, central, beautiful. This is the first thing the user sees.
- **Minimal text on the home itself.** Maybe a soft one-line greeting, maybe nothing. Definitely no list of tasks visible on arrival.
- **The omnipresent chat input** sits at the bottom of the screen and is always accessible. It includes both a text field and a prominent camera button — photo uploads should feel as primary as typing. The empty state can show a rotating, context-aware suggestion ("ask about your hydrangeas") that hints at capability without being noisy.
- **A subtle indicator that there are items on the radar** — see §7.5. Visible enough that the user knows things are there, quiet enough that it doesn't disrupt the emotional tone.

### 7.5 The radar — accessible but not in the user's face

What's on the radar right now is important but should not be the first thing the user sees. The home and its emotional tone come first.

**Two streams flow into the radar:**

- **Calendar items.** Future-dated entries Captain has captured from chat (intents like "planning to repaint the deck in May") plus recurring patterns ("I always mow on Saturdays").
- **AI-generated suggestions.** Two to four concrete things worth considering in the next 30 days, generated against the home profile, owner profile, calendar, weather, and current date. Specific to *this* home and *this* owner — never generic homeowner advice. Cached for two hours; refreshed when the profile or calendar meaningfully changes.

**The home-screen surface:** a compact card between the weather widget and the chat input. The card surfaces a tone-calibrated lead line ("a couple things to consider this week" / "nothing pressing on your radar"), a breakdown of the two streams ("3 coming up · 4 to consider"), and a small cluster of category icons hinting at what's inside. Beneath those, a single peek row shows the most relevant item — the soonest calendar entry in the next two weeks, or the top suggestion otherwise.

**Tapping the card opens the full radar view** as a sheet — two sections ("Coming up" / "Things to consider") with each item's reason and timeframe. This replaces the originally-proposed pull-up bottom-sheet gesture (which collapsed radar + calendar + biography into one sweep); the simpler card + sheet pattern lands the same intent with clearer affordances and less gesture learning. The full home biography lives in the profile drawer instead (see §7.7).

**Tap any item to start a chat about it.** Each calendar entry and each suggestion in the radar sheet is itself a tappable button. Tap one and the radar dismisses, the chat surface opens, and Captain auto-sends the first message — a tight 3-4 sentence what/why/when/how primer specific to this home and owner, ending with an open invitation to follow up ("want me to talk through the options?"). The user types their actual question from there. The primer is persisted as a regular assistant message (no fabricated user turn in scroll-back), so chat history reads naturally on subsequent visits and the LLM stays grounded if the user asks follow-ups. PRD §7.6's "input is context-aware" promise is realized through this flow — the context arrives as Captain's opening message rather than a pre-filled draft in the user's input, which is what people actually want when they tap an item to "learn more."

### 7.6 The chat surface

Tapping the chat input expands chat into the foreground. The rendered home recedes — shrinks to the top, dims, or scrolls partially out of view — but doesn't disappear entirely. The home stays as visible context for the conversation. When the chat is dismissed, the home returns to full presence.

Chat behavior in this surface:

- Photo upload is prominent and easy.
- When chat is opened from a specific context (a calendar entry, a profile field, a radar item), the input is context-aware and can pre-fill or scope the conversation accordingly.

### 7.7 The home profile and personal profile — quietly accessible

Both profiles are maintained automatically in the background by Captain — this is the magic. They should not be primary user flows. The user can access and edit them if they want, but Captain's promise is that they don't have to.

Access lives in a small, unobtrusive corner of the home screen (e.g., a small avatar or icon in the top corner) that opens a simple settings/profile surface. Both profiles are available together in that surface. The user rarely visits, which is the point.

Editing is always possible but never required.

### 7.8 Gesture and navigation summary

The entire v1 app navigates with:

- **Tap chat input** → enter chat (full-screen cover)
- **Tap the radar card** → open the full radar sheet
- **Tap corner avatar** → access profiles and full calendar
- **Tap a radar item, calendar entry, or chat suggestion** → enter chat with that context

No tab bar. No hamburger menu. No back buttons except where iOS conventions require them. Sheets dismiss via a chevron-down button or standard iOS swipe-down.

### 7.9 Risks and things to validate

- **Rendered home quality.** The biggest bet. If renderings are inconsistent or unflattering across home types, the central emotional hook falls apart. Worth prototyping with several real home photos before committing.
- **Gesture discoverability.** A heavily gesture-driven UI can be confusing for less-technical users. v1 ships a one-time decaying brass-ring affordance (the "gesture hint") on the radar card and the corner avatar, persisted per device in `UserDefaults` and re-armed on `AppState.reset()`. Implementation: `ios/Captain/Util/GestureHint.swift` + `.gestureHint(.key)` view modifier. New hinted surfaces add a `Key` case and one modifier line at the callsite.
- **Feeling "thin."** A single-screen app can feel like there's not much to it. The rendered home, the accumulating record, and the responsive seasonal/weather updates are the antidotes — but they need to be strong enough to carry that weight.

## 8. Example use cases

Concrete scenarios illustrating how the v1 capabilities come together. These span different seasons, emotional registers, and combinations of features.

### 8.1 The first session (proactive context-building from a photo)

Sarah just closed on her first house and downloads Captain. She takes a photo of the front. Within seconds, Captain shows her: "Looks like a 1962 Cape Cod in University Heights, OH — about 1,840 sq ft, hardiness zone 6a. I can see what looks like a wood-shingle roof, a front porch, and two mature maples. Anything I got wrong?" The app's color palette has shifted to warm greens and the muted red of her front door. She corrects one detail in chat and Captain saves the rest.

### 8.2 The HVAC filter loop (memory + inventory + commerce)

Six months after Sarah mentioned in chat that she'd replaced her HVAC filter and bought a pack of three, Captain surfaces in her Friday digest: "You're due for a filter change this weekend — and this is your last one from the pack you bought in November. Want me to pull up the same one on Amazon?" One tap reorders. The calendar logs both the replacement and the purchase.

### 8.3 The weekend planning nudge (weather + seasonality + preference-aware)

Friday morning Captain notes: "Rain is forecast Sunday afternoon, so Saturday's better for mowing. Your last mow was 11 days ago. Also — the lilacs are about a week from blooming based on your zone, no action needed, just thought you'd want to know." The personal profile knows Sarah likes a heads-up on plants because she's mentioned watching them before.

### 8.4 The diagnostic photo (image extraction + decide-then-call)

Mike sees a brown ring on his bedroom ceiling and snaps it in chat. Captain replies: "That looks like a water stain, probably from a slow leak above. Given that's directly below your upstairs bathroom, the likely culprits are the toilet wax ring, a supply line, or a tub drain — in roughly that order. Before calling anyone: check if the ring is damp or dry, and look around the toilet base for any softness in the floor. If it's dry, you might be looking at an old stain from before you owned the place. If it's damp, this is a plumber job, not a handyman one — and worth doing soon. Want me to find a few well-reviewed plumbers nearby?"

### 8.5 The forward-dated intent (passive future capture)

In casual chat, Mike says "I'm planning to repaint the deck sometime in May once it warms up." Captain doesn't make a big deal of it — just replies normally — but quietly adds a forward-dated calendar entry. In late April, his Monday digest includes: "You mentioned wanting to repaint the deck in May. Want to talk through prep, or is it still on the back burner?"

### 8.6 The new-owner scavenger hunt (opt-in guided workflow)

Sarah opts into the "I just moved in" mode the night she moves in. She finds and photographs her water shutoff and breaker box that evening, then closes the app. Three days later she picks it back up on a Saturday morning and knocks out the HVAC, water heater, and smoke detectors. Two weeks later she finishes the rest. There's no schedule, no nagging — the workflow is just there when she wants it. Each photo populates the home profile silently, so by the time she's done, Captain knows her house in a way that would have taken her months to capture on her own.

### 8.7 The tone calibration (personal profile shaping behavior)

Early on, Sarah asks "what's a P-trap?" Captain defines it inline and notes she's a first-time owner. Months later, after she's casually mentioned re-caulking her tub and replacing an outlet, Captain stops defining basics and starts treating her as more capable. When she eventually asks about replacing a wax ring, the response skips the "the wax ring is the seal between..." and goes straight to the steps. She never asked for this — Captain just adjusted.

### 8.8 The seasonal preparation (proactive, tailored to home and owner)

Late February, Monday digest: "Spring's a few weeks out. Based on your home, here's what's worth thinking about over the next month — your panicle hydrangeas can be pruned now, your gutters probably want a check after all the winter debris, and your AC will need its annual once-over before the first hot week. Want to talk through any of these or just leave them on the calendar?" Items the user engages with get more detail; items they ignore quietly stay in the calendar without nagging.

### 8.9 The "who do I call" judgment (web search + reasoning, not just search)

Mike's dishwasher is making a grinding noise. He describes it in chat. Captain replies: "Grinding from a dishwasher is usually one of two things — debris stuck in the chopper blade or a failing drain pump motor. Worth checking the chopper area yourself first (it's a 10-minute job, here's what to do); if it grinds when empty after that, it's the pump and you'll want an appliance repair tech, not a plumber. Your dishwasher is a Bosch 500 series from about 2019 based on what you photographed last spring — still possibly under extended warranty if you registered it. Want me to check the warranty period and find local Bosch-authorized techs?"

### 8.10 The accumulating biography (the long-game value moment)

Two years in, Sarah is showing her sister around the house and pulls up Captain. The rendered home on the screen is the home in late summer, sunlight on the porch. She pulls up the bottom sheet and scrolls back through the calendar: the day she moved in, the scavenger hunt entries that taught Captain about her water heater and breaker box, the HVAC service from last fall, the perennial bed she planted in spring, the new water heater, the painter she liked, the contractor she didn't. It feels less like a chore log and more like the story of a house being cared for. When she eventually sells, she'll be able to hand all of this to the next owner — and that idea, more than any single feature, is why she's still using Captain.

## 9. Data sources and integrations

Captain depends on external data and services to feel intelligent and tailored. V1 priorities: minimize cost, avoid lock-in, defer anything that isn't essential to the core experience.

### 9.1 In v1 — core infrastructure

These are required for the app to function at all.

- **LLM provider with vision and tool use.** The model powers chat, image extraction, web search reasoning, and digest generation. The architecture keeps the underlying LLM swappable behind a thin abstraction layer (`backend/llm.py`) so the model (and provider) can be changed easily as costs shift or better models ship. All callsites in `chat.py`, `profiles.py`, `radar.py`, `hunt.py`, and `biographer.py` go through `llm.chat_completion(...)` (OpenAI-shaped surface — chosen because every callsite was already written against it and vision payloads use the OpenAI image_url shape). Provider selection is per env var (`CAPTAIN_LLM_PROVIDER`, defaults to `openai`); adding Anthropic is a single module change with no callsite churn. `render_prototype.py` and `first_session.py` still call OpenAI directly because they use the image-generation API and a passed-in client, respectively — extending the abstraction to cover those is a small future change.
- **Authentication and accounts.** Basic auth is required so users don't lose their home profile if they reinstall or get a new phone. A managed auth service (e.g., Clerk, Supabase Auth, Firebase Auth) is preferable to rolling our own.
- **Database.** Stores the home profile, personal profile, calendar entries, and chat history. The schema carries a `users` table and a `user_id` foreign key on `home` from v1, even though every row sits under a single default user (`DEFAULT_USER_ID = 1`). This is prophylactic structure for the multi-tenancy migration in §11.10 — adding the column at v1 cost a few lines; retrofitting it later would compound across every query.
- **Usage telemetry.** A small `events` table (`event_type`, optional JSON `payload`, `user_id`, `home_id`, timestamp) records the minimum signal needed to measure §13 success criteria — `home_screen_view`, `first_session_start`, `first_session_done` (with elapsed seconds), `chat_turn`, `hunt_item_done`, `radar_card_open`, `radar_item_tap`, `profile_drawer_open`. Server-side events are logged from the handlers directly; client-side events go through `POST /events` (fire-and-forget on iOS). Inspect via `GET /debug/events` (dev convenience). No third-party analytics SDK in v1 — keeps things private at the pet-project tier and lets us defer the analytics-vendor decision.
- **Push notifications.** APNs via a managed service (e.g., OneSignal, Firebase, Expo) for the Friday and Monday digests.

### 9.2 In v1 — data and context

These power the user-facing intelligence.

- **Weather forecast data.** Needed for weekend planning, seasonal nudges, and "should I do this outside today" questions. The National Weather Service API is free for US use and sufficient for v1.
- **Hardiness zone.** Derivable from coordinates against publicly available USDA data — no API or cost.
- **Geocoding.** The address the user enters at first-session needs to become latitude/longitude for the weather feed. The US Census Bureau's geocoder is free, no key, generous limits, and excellent coverage of US residential addresses — used server-side. (Originally planned to use Apple MapKit on-device; server-side Census fits the architecture better and lets the backend independently validate addresses during setup.)
- **Property details via web search scraping.** Rather than paying for a property data aggregator (ATTOM, Regrid, etc.), v1 attempts to gather year built, square footage, lot size, last sale date, and similar by performing a web search against the user's address. The LLM extracts what's available from public listings, county records sites, and real estate pages. Coverage is expected to be inconsistent: some addresses will return rich data, others will return little. Captain should degrade gracefully — for example, by asking the user to confirm or fill in missing details. Worth validating early with a handful of test addresses to see what realistic coverage looks like before committing further on this path.
- **Web search.** Used both for property details (above) and for the "who do I call" judgment layer, current local info, and anything the model doesn't know directly. A cheap search API (Brave Search, Tavily) is preferred over rolling our own scraper.
- **Image understanding via the LLM.** Rather than integrating dedicated plant ID, OCR, or appliance recognition services, v1 relies on the LLM's native vision capability for photo-derived extraction. Good enough for v1 use cases.

### 9.3 Image handling philosophy for v1

The flow for every user-uploaded photo:

1. User uploads a photo (first-session house, future scavenger hunt, chat).
2. The LLM extracts everything useful from the image (text, structured fields, observations, descriptions).
3. The extracted information is written to the home profile, personal profile, or calendar.
4. The image is retained on the backend so the chat UI can display the bubble (now and on subsequent app launches).

The original PRD position was "extract and dump" to minimize storage. v1 currently retains chat photos for two reasons: (a) the chat UX is much better if the user can scroll back through a conversation and still see the photos they sent, and (b) at the personal-pet-project scale, storage cost is negligible. The first-session photo is kept regardless because it drives the rendered home and palette.

The tradeoffs:

- Storage grows linearly with chat usage. Acceptable at pet-project scale; would need a cleanup policy at real scale.
- Re-querying an image later isn't currently supported — extraction happens once, in the moment. Possible to revisit since the photo is still there.
- The calendar / passport is still text-only — calendar entries describe what was observed but don't link to the photo.

These tradeoffs are acceptable for a pet-project v1 and worth revisiting if the product grows.

### 9.4 Deferred to post-v1

- **Amazon Product Advertising API.** v1 reaches Amazon via Firecrawl-scoped web search and Amazon Associates affiliate links (§6.5 `find_products` + §11.8). The full PA-API gives richer structured data (price, ratings, stock) but isn't required for the v1 product-card flow.
- **External calendar integration.** No syncing reminders to Google Calendar or Apple Calendar in v1. Captain's internal calendar is the only one.
- **Zillow, Redfin, Realtor.com, or other valuation APIs.** Mostly locked to licensed real estate professionals and not aligned with v1's "no financial stress surfaces" principle anyway.
- **Dedicated reviews APIs (Yelp Fusion, Google Maps reviews).** Web search returning review-rich pages should be enough for v1's "who do I call" use case.
- **Persistent image storage and photo timeline.** See §9.3.
- **Smart home integrations (Nest, Ring, Hue, etc.).** Already out of scope per §10; listed here for completeness.
- **Voice input.** Already out of scope per §10.
- **Android.** v1 is iOS-only.
- **International support.** v1 is US-only.

## 10. What's explicitly out of scope for v1

Captured here so they're not forgotten but also not built.

- Cost tracking, estimates, budgets, financial views
- Booking/scheduling contractors directly through the app
- Smart home integrations (Nest, Ring, Hue, etc.)
- Community or social features
- Multi-home / multi-property support
- Voice input
- Marketplace or e-commerce beyond simple affiliate links in chat

## 11. Parking lot — ideas to revisit post-v1

### 11.1 The house passport as a transferable artifact

The home profile + calendar should eventually be packageable as a "passport" the seller can hand to the next owner. This is potentially Captain's most powerful growth mechanic: every home sale is a possible new user. Realtors could recommend it at closing. Worth designing v1 in a way that doesn't preclude this later.

### 11.2 Camera as primary input

Generalize the photo-of-the-house pattern further: any photo, anywhere in the app, is an opportunity for Captain to observe and ask. V1 supports photo upload in chat and the scavenger hunt; future iterations could make the camera even more central (e.g., a dedicated "show Captain something" surface, or passive scanning during walkthroughs).

### 11.3 Captain remembers what you said you'd do

If the user mentions in chat that they'll do something "next month," Captain loops back. (V1 captures these as forward-dated calendar entries; a future iteration could add more proactive, conversational follow-up — "hey, you mentioned the gutters back in March — still on your list?")

### 11.4 Voice input

Useful when the user is physically working on something and can't type. Defer until v1 is solid.

### 11.5 Comparison to similar homes

"Homes built in the 1970s in your area typically need X around now." Gently social without being creepy. Lets Captain make confident recommendations based on more than first principles.

### 11.6 Inside/outside or systems-based navigation

Considered and rejected as a primary UX split because users think in problems, seasons, and systems rather than geography. A house-diagram view (tap parts of the house) may be worth exploring as a secondary navigation layer once v1 is shipped.

### 11.7 Emergency mode

A panic-flow for "water is coming through the ceiling" situations — shutoff guidance, documentation for insurance, same-day pro lookup. In v1, chat is meant to be quick enough to serve this need; a dedicated mode could come later if usage suggests it.

### 11.8 Business model

Affiliate links (Amazon, etc.) covered in chat are the v1 default — modest revenue, low intrusion. The Amazon flow is wired in v1: the chat model can invoke `find_products` (see §6.5) and Captain wraps the returned URLs with our Amazon Associates tag (`CAPTAIN_AMAZON_TAG`). Links work without an affiliate account configured — they just don't earn — so the feature runs end-to-end in dev. FTC disclosure ("Captain earns from qualifying purchases.") renders as a quiet footer below product cards.

Multi-retailer (Home Depot, Lowe's, Walmart, Target) is structured but not wired — each `ProductPick` already carries a `retailer` field, and each retailer needs its own affiliate-network signup (Impact Radius, Rakuten) and URL-builder. Adding one is small.

Real monetization decisions beyond affiliate (subscription, lead gen, etc.) deferred until product-market signal is clear. The choice will shape the product, so worth picking deliberately when the time comes.

### 11.9 "What would it look like…" — user-driven home visualizations

The same rendering pipeline that powers the home portrait could let the user *try things on*. The owner asks (in chat, with a photo, or from a profile field) and Captain produces a fresh rendering of their home with the change applied — a pool in the backyard, the front door painted navy, a flagstone walkway replacing the concrete, the panicle hydrangeas in front of the porch instead of the boxwoods, a pergola off the deck. The rendered home is already the emotional anchor of the app; turning it into a *what-if* canvas extends that anchor into the planning phase of homeownership and makes Captain the place you go to *imagine* changes, not just track them.

Why this fits Captain (and not any random AI image tool):

- Captain already knows the home — proportions, materials, palette, landscaping, style — so the generated variant can preserve the home's identity in a way generic prompts can't.
- It pairs naturally with the existing "decide what to do" judgment layer in chat: see the change, then talk through cost ranges, vendors, seasonal timing, what to ask for in a quote, etc.
- It pairs naturally with `find_products` (the affiliate flow): a paint color the user likes in the rendering links to that paint at a retailer; a pool render leads into the contractor conversation.
- It pairs naturally with the calendar / passport: a saved visualization becomes a forward-dated entry ("planning to repaint the front door navy"), and later, after the work is done, the same visualization sits next to the after-photo as part of the home's story.

Open questions worth a real prototype before committing:

- How much can the model be pushed before the home's identity slips? Small swaps (door color, plant choice) are likely safe; large additions (a pool, a dormer) may drift the architecture in ways that break the illusion.
- Should this generate one rendering or a small set the user can compare?
- Should saved visualizations be public-ish (e.g., shareable with a spouse or a contractor as part of a quote-request) or strictly private?
- Pricing/cost framing: the PRD's "no financial stress surfaces" rule (§5) probably means the rendering itself never quotes a dollar figure, but the conversation around it can still help the user think about what to budget for.

### 11.10 Multiple people on one home

Homes are usually cared for by more than one person — spouses or partners, roommates, adult kids living at home, an in-law unit, a property manager helping out. v1 assumes a single owner per home (§3, §6.4); a future iteration should let a household share the same Captain so the home's profile, calendar, and chat history are common ground.

What makes this hard the right way:

- **The home profile is shared; the personal profile is not.** Two people in the same home need *one* home story — same calendar, same vendor list, same "the porch boards near the steps are loose" observation — but tone calibration, DIY comfort, and how Captain talks to each person should be individual. The two-profile split in §6.3 / §6.4 already lines up with this.
- **Chat history: shared or separate?** Both have merit. Shared lets one partner pick up where the other left off ("Sam asked the plumber about the wax ring yesterday — here's what they said"). Separate keeps personal threads private and avoids cross-talk. A reasonable default: one shared chat thread for the home, with individual messages still attributed to whoever sent them.
- **Who can do what?** Most actions are collaborative by default. The interesting cases are destructive ones (deleting calendar entries, resetting profiles) and account-level ones (inviting another person, removing one). A simple owner / member split is probably enough for v1-of-this-feature.
- **Notifications.** The Friday + Monday digests (§6.8) should fan out per person, calibrated to each personal profile's tone and timing preferences, but pulling from one shared home + calendar.
- **The "biographer's instinct" stays singular.** Captain still speaks *about the home* in one voice. It just learns who's talking on each turn and adjusts how it speaks back.

Worth designing the data model with this in mind sooner rather than later — even before the feature ships — because retrofitting multi-tenancy onto a single-user schema is the kind of thing that compounds in pain over time. The current single-home simplification in v1 (see backend/store.py) should be expected to evolve. Some of that prep is already in: v1 carries a `users` table and a `user_id` FK on `home`; multiple conversations per home are already a first-class concept (with active-window resume + history list — see §6.5); the profile rewriter is serialized by a per-process `threading.Lock` in `backend/profiles.py` so concurrent chat turns can't race the read-modify-write of `home.md` / `user.md` (when multi-home arrives, swap to a `dict[home_id, Lock]`). What's still pending: auth, per-home scoping on the in-memory job tables (`_jobs`, `_chat_jobs`, `_prerenders`), per-user push-notification routing, and the shared-chat-vs-separate question above.

Related: the house passport (§11.1) is the *handoff* version of this same shape — many people over the home's lifetime, ownership changes hands. Multi-user is the *concurrent* version.

## 12. Open questions

Things still genuinely unresolved and worth thinking about further.

- **The cold-start vs. accumulated state.** What does the home screen look like on day 1 (empty) versus day 90 (rich)? Both need to feel valuable. The photo-driven first session helps day 1, but the gap needs more thought.
- **The notification fatigue problem.** Two digests/week is the v1 answer but it's untested. Need to watch this closely once real users exist.
- **The "who do I call" experience.** Captain helping the user decide what kind of pro and what to ask is a judgment layer over web search. The prompt design and product surface for this need more thought — it's a key differentiator vs. just being a chatbot.
- **How much does Captain initiate vs. wait?** Inside the app (not via notifications), how proactive should Captain be when the user opens it? A balance between "useful nudge" and "calm space" needs to be tuned.
- **What's the second "aha" moment?** The photo + UI customization is the first-session aha. The second one — the moment that converts a casual user into a returning one — is not yet identified.

## 13. Success criteria (informal, for a pet project)

For v1 to feel like a success:

- A new user can finish the first session in under five minutes and come away feeling like the app is "theirs."
- The app accumulates meaningful context over a month of light use without ever asking the user to fill out a form.
- Captain handles a realistic homeownership question (e.g., "should I be worried about this stain on the ceiling?") in a way that feels noticeably better than ChatGPT — because of context, tone, and follow-through, not raw model quality.
- The user opens the app on their own at least once a week without being prompted.
- Looking at the home's profile and calendar after 90 days feels rewarding — like the home has a story.
