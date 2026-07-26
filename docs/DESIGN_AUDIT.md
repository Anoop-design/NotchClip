# NotchClip product and design audit

## Outcome

> **Superseded 2026-07-26.** The original two-surface split described below was
> replaced by a single unified panel. The reasoning that produced the split is
> kept because it still explains the constraints; the decisions section now
> describes what shipped.

The notch is the app. Control–V morphs it into a translucent panel that holds the
entire searchable clipboard history, and gets a clip into the app the user was
already using. There is no second window.

### Why the original two-surface split was abandoned

The first design split the product into a bounded four-clip "quick shelf" at the
notch and a separate resizable "All Clips" library window. In practice:

- The shelf grew to eight clips and gained horizontal scrolling anyway, because a
  fixed handful was never enough to find the clip you wanted.
- Reaching real history meant a second, opaque, title-barred window appearing over
  everything — which read as a different application launching, not as the notch
  expanding.
- Two surfaces meant two layouts, two selection models, two preview lifecycles, and
  a handoff between them that needed its own dismissal reason and focus choreography.
- The library spent its width on a 300pt static sidebar and a mostly-empty inspector,
  leaving the clip list — the actual content — the narrowest column.

The bounded shelf was solving for glanceability. Search-first with keyboard
navigation solves the same problem without capping what you can reach.

## Unified panel decisions

- One surface: an all-black HUD that grows from the notch, sized ~620×420.
  A 780×620 translucent version was tried and rejected — the blur made it read
  as "a window near the notch" rather than "the notch, open", and the size
  read as a slab. Solid black + compact keeps the hardware illusion.
- Captures are acknowledged in place: while the panel is closed, a successful
  capture swells the notch into a brief "Copied · Source" lip that retracts
  after ~1.5s (`CapturePulsePolicy`). The pulse window is never key and is
  click-through, so it cannot steal focus or block menu-bar clicks; ⌃V cancels
  it instantly.
- The search field owns focus for the entire presentation. Typing filters; there is
  no separate "enter search mode".
- The list is the complete history, sectioned Pinned / Today / Yesterday / Earlier,
  at ~44pt per row (~7 visible; the rest scroll).
- The preview pane shows the selection's **complete** content. Row summaries still
  use the collapsed 200-character `previewText`, but the pane loads the full retained
  payload off-main so long text and code keep their line structure.
- Filters moved from a sidebar to ⌘1–⌘6 plus a compact menu, returning that width
  to content.
- Selection uses the accent colour with a leading marker. In a keyboard-driven
  picker the selected row must be identifiable without hunting.
- Escape narrows before it closes: clear the query, then reset the scope, then
  dismiss. Destructive-feeling gestures are never the first thing Escape does.
- The cap over the physical camera housing stays true black so the shell reads as
  continuous hardware; only the body is glass. Reduce Transparency gets an opaque
  surface, Reduce Motion drops the geometry morph.
- Pin, delete, and Quick Look are on the row context menu and on ⌘P / ⌘Delete / ⌘Y.
  Delete is deliberately not a bare keystroke.

## Focus and paste lifecycle

The panel preserves the app that was active before NotchClip appeared. A successful selection writes the exact entry on the dedicated paste queue, closes the panel, returns focus, then dispatches Command–V when Accessibility permission is available. Without that permission, the clipboard write still succeeds and the destination is reactivated for a manual Command–V.

Collapsing to one surface removed the handoff entirely: there is no longer a dismissal reason that hands focus to a second window, and no window-swap during which a paste could target the wrong destination.

## Accessibility

- Rows are named keyboard/VoiceOver destinations carrying kind, pin state, missing-file state, source, and time.
- AppKit drag bridges are folded into one semantic row element rather than exposed as duplicate controls.
- Pin, paste, and delete are available as named accessibility actions.
- Controls retain macOS focus rings, search behavior, and minimum target sizes.
- Reduce Motion removes the geometry morph; Reduce Transparency selects opaque chrome.

## Apple on-device Foundation Models

Foundation Models should **not** be in the v1 retrieval or paste path.

- The relevant on-device language model APIs begin on macOS 26, while NotchClip supports macOS 14.
- Runtime availability alone is insufficient. On the audit Mac, the model reported available but rejected the current `en_IN` locale, so any future feature must also gate locale, context availability, and actual inference errors.
- The best later use is opt-in generation of a short title and three or four tags for long text/code clips, shown in the preview pane.
- A generative model is not the right base primitive for semantic search. Start with indexed lexical search, then consider local Natural Language sentence embeddings.
- Vision should handle image OCR on macOS 14+.
- A language model must never be the privacy boundary for password/secret detection.

Before any automatic enrichment, add excluded-app controls, a deliberate private/pause mode, deterministic secret-pattern exclusions, and a way to clear generated metadata. Generated data must be stored separately and must never change the original paste payload.

## Remaining scale work

The v1 store atomically persists JSON metadata and retained payload files. Lazy previews and debounced library search remove the largest immediate UI costs, but indefinite history will eventually require an indexed SQLite/FTS store with paged queries. That migration should precede semantic indexing or automatic model enrichment.
