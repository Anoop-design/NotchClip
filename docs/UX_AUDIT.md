# NotchClip UX and design audit

Audit of the shipped v0.4.0 code, 2026-07-25. Every claim below is grounded in a file
reference; nothing here is inferred from the README.

This document complements [DESIGN_AUDIT.md](DESIGN_AUDIT.md), which records the *product
decisions*. Where the two disagree, DESIGN_AUDIT.md has been corrected to match the code.

Findings are split into three kinds, because they deserve different responses:

- **Defects** — the code does something a user would call wrong.
- **Gaps** — table-stakes features for this product category that are simply absent.
- **Decisions worth revisiting** — deliberate choices, listed with their cost.

---

## A. Defects

### A1. Text clips are permanently truncated to 200 characters, everywhere

**The single highest-impact issue.**

`PasteboardParser.makePreview` collapses all whitespace and caps at 200 characters
(`PasteboardParsing.swift:237-239`). That string is stored as `previewText` and is the
*only* text the UI ever renders — including the library inspector's detail pane, whose
default case is `Text(entry.previewText)` (`ClipboardLibraryView.swift:922`).

Consequences:

- A 40-line code snippet displays as a single unbroken 200-character line. All indentation
  and line structure is gone, in the one surface designed to show detail.
- Anything past character 200 is invisible in the entire app.
- Meanwhile `makeSearchText` retains the **full, untruncated** content
  (`PasteboardParsing.swift:245-263`). So search can match a word the user can never see.
  Searching for a term, getting a hit, and finding no trace of it in the result is a real
  and confusing failure.

The full bytes are on disk the whole time — `payloadRefs` holds the complete
`public.utf8-plain-text` representation. Nothing reads it for display.

**Fix:** load the full plain-text payload for the *selected* entry only, off-main, using
the same shape as `PreviewLoader.load` (`HistoryModel.swift:559`). Render it in the
inspector with preserved newlines and `.textSelection(.enabled)`. Keep the 200-char
collapsed `previewText` for row summaries, where it is correct. Scoped, uses machinery
that already exists, and does not touch the capture path.

### A2. Link previews default to ON and are never disclosed during onboarding

`AppPreferences.load` returns `fetchLinkPreviews: true` when the key is unset
(`AppPreferences.swift:14-17`). With it on, every visible HTTP/HTTPS row triggers an
`LPMetadataProvider` fetch, so the destination site learns the user's IP.

The behaviour is documented honestly in Settings → Privacy and in the README. But the
onboarding tour is two steps — welcome and Accessibility (`ProductOnboardingView.swift:8-11`)
— and never mentions it. A user who copies a private or internal URL causes a network
request to that host without having been told, at any point they were actually looking.

For an app whose pitch is "local only, no telemetry, no cloud," this is the one place
where the default contradicts the promise.

**Fix (pick one):** default it off and let the first link row offer to enable it; or add a
line to the onboarding permission step. The former is more consistent with the rest of the
product's posture.

### A3. Every copy is O(n) in the full history

`ClipboardEngine.ingestLocked` fetches `repository.allEntries()` and linearly scans for a
fingerprint match (`ClipboardEngine.swift:508`). `PersistentClipboardRepository.upsert`
decodes the entire `history.json`, mutates one element, and re-encodes the whole file
(`ClipboardRepository.swift:158-168`).

So each individual copy costs a full decode + full encode + linear scan, and history is
kept indefinitely by design. At a few thousand entries with images this becomes a visible
stall on every copy — on the main-actor-adjacent capture path.

DESIGN_AUDIT.md already names the SQLite/FTS migration. This is the concrete mechanism and
the reason it should come before any other data feature.

### A4. Dead state from removed features

- `PanelVisualState.focusRequestID` / `requestSearchFocus()` are documented as driving
  `@FocusState` (`PanelVisualState.swift:18-27`). `PanelRootView` has no search field and
  no `@FocusState` — shelf search was removed. `NotchPanelController.finishKeyAndFocus()`
  still calls it (`NotchPanelController.swift:382`) and nothing consumes it.
- `AppCoordinator.openSettings()` and `settingsOpen` (`AppCoordinator.swift:22,180`) are
  never called or read; the menu uses `SettingsLink`.

Harmless at runtime, but both are traps: they read as live wiring.

### A5. Silent no-ops on oversized content

A representation over 64 MiB is skipped whole, and a capture whose representations are all
skipped returns `.ignoredEmpty`, which `HistoryModel.applyCaptureResult` handles with
`break` (`HistoryModel.swift:264`). The user copies a large image and *nothing appears* —
no row, no message. The `captureError` banner already exists and is the natural home for
"That item was too large to keep (over 64 MiB)."

---

## B. Gaps — table stakes for a clipboard manager

All confirmed absent by search across `Sources/`.

| Gap | Why it matters | Rough cost |
|---|---|---|
| **Launch at login** | A clipboard manager that isn't running misses history, and there is no way to notice until you need a clip that was never captured. Arguably the highest user-visible value here. | Small — `SMAppService.mainApp` + a Settings toggle |
| **Configurable shortcut** | ⌃V is fixed (`NotchClipHotKey`, `HotKeySeam.swift:65-71`) and registered `kEventHotKeyExclusive` (`CarbonHotKeyRegistrar.swift:63`), so it is claimed system-wide. ⌃V is also a standard Cocoa emacs-style binding (page-down in text views), so the collision is structural, not hypothetical. The author clearly anticipated conflict — there is a full registration-error path surfaced in the menu and Settings — but no way to actually resolve one. | Medium — recorder UI + persistence; the `HotKeyRegistering` seam is already there |
| **⌘1–⌘8 direct select** | The shelf holds eight items but only arrow traversal, so reaching item 8 is seven keypresses in a surface whose entire purpose is speed. Digit selection is the norm in this category. | Small — extend the `keyMonitor` switch (`NotchPanelController.swift:736`) |
| **Paste as plain text** | Pasting rich text into a styled document and having it carry source formatting is the most common clipboard-manager annoyance. The engine already retains every representation separately, so writing only `public.utf8-plain-text` is a filter over existing data. | Small — a `paste(entry:preferring:)` variant |
| **History retention limit** | History is unbounded forever. Combined with A3 this is both a performance and a privacy exposure — a clip from six months ago is still on disk. | Small — a "keep for N days" sweep at launch |
| **Excluded applications** | Nothing retained from password managers unless they set `ConcealedType`. Many apps don't. DESIGN_AUDIT.md lists this as a prerequisite for any future enrichment; it is really a prerequisite for the current feature set. | Small–medium — bundle-ID denylist checked in `ClipboardSourceProvider` |
| **Bulk selection / undo** | Library deletion is one row at a time behind a confirm dialog, with no undo. Cleaning up a noisy history is tedious. | Medium |

---

## C. Decisions worth revisiting

These are deliberate and defensible. Listed with their cost so they can be re-decided
rather than rediscovered.

### C1. Eight scrolling cards in a 660pt shelf

The shelf is capped at eight (`QuickShelfPolicy.itemLimit`), rendered as 100×108 cards in a
horizontal `ScrollView` with `.scrollIndicators(.never)` (`PanelContentView.swift:106,136`).
At the expanded width about five are visible; the only affordance for the rest is 3pt of
horizontal padding deliberately exposing a sliver of the next card
(`PanelContentView.swift:131-133`).

The trade-off: a transient, keyboard-driven HUD where a third of the content is off-screen
with no scrollbar. Arrow keys do scroll the selection into view, so keyboard users are
fine; mouse users may not realise more exists. Either widen the panel, drop to six, or make
the scroll cue more explicit. Worth noting this is also the exact tension the original
four-card decision was meant to avoid.

### C2. No delete on the shelf

Intentional — keeps destructive actions out of a transient surface. Reasonable. But pin is
available there, so the shelf is not purely non-destructive, and the asymmetry may read as
an omission rather than a choice.

### C3. Space beeps for text clips in the library

`quickLookSelection` calls `NSSound.beep()` for anything that isn't an image or file list
(`ClipboardLibraryController.swift:221-229`). Once A1 is fixed and the inspector shows full
text, Space could reasonably expand the text instead of rejecting the gesture. A beep is a
harsh response to a reasonable action.

---

## Suggested order

1. **A1** — full text in the inspector. Biggest gap between what is stored and what is shown.
2. **Launch at login** — small, and the app is not dependable without it.
3. **A2** — link-preview default. Small, and it is a stated-values issue.
4. **⌘1–8 and paste-as-plain-text** — two small changes that disproportionately affect daily speed.
5. **A3** — the storage migration. Largest, and it gates retention limits and any future indexing.
6. **A4, A5** — cleanup and feedback polish.

## Not assessed

Interaction quality of the notch morph, real-world Accessibility/VoiceOver behaviour, and
the packaging/notarization path were not exercised — they need a running app and, for the
test suite, an Xcode installation (`swift test` cannot resolve XCTest under Command Line
Tools).
