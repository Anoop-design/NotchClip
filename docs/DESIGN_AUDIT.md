# NotchClip product and design audit

## Outcome

The notch is a quick action surface, not the clipboard archive. It has one job: expose a predictable working set and get a clip into the app the user was already using. Search, filtering, destructive actions, and long-term browsing belong in a standard Mac window.

This produces two complementary surfaces:

1. **Quick Paste shelf** — a transient Dynamic-Island-style notch expansion with eight clip positions and one All Clips destination.
2. **All Clips library** — a durable, resizable macOS window for the complete searchable history.

## Quick shelf decisions

- Hard limit: **eight clips** (`QuickShelfPolicy.itemLimit`, asserted by `testShelfHasHardEightItemLimit`).
- Ordering: up to the three newest pinned clips (`preferredPinnedLimit`), then the newest recent clips. Either group backfills unused positions.
- Horizontally scrolling layout. At the expanded width roughly five of the eight cards are on screen at once; Left/Right moves selection and scrolls the focused card into view. The limit still holds the shelf to a bounded working set rather than the whole archive.
- Search was removed. Command–F collapses the notch and opens All Clips with search focused.
- Left/Right traverses the eight clips and the All Clips tile. Return pastes a clip or opens the library.
- Click pastes; dragging the preview inserts the retained clipboard representation into another app.
- Pin is visible as a badge. Pin/unpin remains in the context menu; delete is kept out of the transient shelf to prevent accidental destructive actions.
- Space is only meaningful for retained images and files that Quick Look can actually preview.
- The shell is forced dark because it is visually continuous with the physical notch. Reduce Motion and Reduce Transparency continue to use their system-specific paths.

## All Clips decisions

- Standard titled, resizable macOS window rather than a second borderless island.
- Native sidebar scopes: All Items, Pinned, Text, Links, Images, and Files.
- Native list with Pinned and Recent sections, search, source/timestamp metadata, missing-file states, and system light/dark appearance.
- Search is independent from the quick shelf and debounced before filtering.
- Rows support exact-entry paste, drag, pin/unpin, conditional Quick Look, and confirmed deletion.
- Keyboard: Up/Down selects, Return pastes, Space previews, Command–F focuses search, and Escape clears search before closing.
- Empty history, no results, paused capture, storage failure, and capture error each have an explicit state.
- Image/file previews are requested only as rows become visible. The notch and library have separate preview-surface lifecycles so a handoff does not cancel the incoming surface.

## Focus and paste lifecycle

Opening All Clips from the notch is a dedicated dismissal reason. The notch finishes its collapse before the library is presented, and the transition neither restores the previous app nor starts a paste.

Both surfaces preserve the app that was active before NotchClip appeared. A successful selection writes the exact entry on the dedicated paste queue, closes NotchClip's active surface, returns focus, then dispatches Command–V when Accessibility permission is available. Without that permission, the clipboard write still succeeds and the destination is reactivated for a manual Command–V.

## Accessibility

- The shelf cards and All Clips tile are named keyboard/VoiceOver destinations.
- AppKit drag bridges are folded into one semantic card/row element rather than exposed as duplicate controls.
- Pin, paste, and delete are available as named accessibility actions where appropriate.
- Native semantic type and colors are used in the library. Controls retain macOS focus rings, search behavior, and minimum target sizes.
- Reduce Motion removes the geometry morph; Reduce Transparency selects opaque chrome.

## Apple on-device Foundation Models

Foundation Models should **not** be in the v1 retrieval or paste path.

- The relevant on-device language model APIs begin on macOS 26, while NotchClip supports macOS 14.
- Runtime availability alone is insufficient. On the audit Mac, the model reported available but rejected the current `en_IN` locale, so any future feature must also gate locale, context availability, and actual inference errors.
- The best later use is opt-in generation of a short title and three or four tags for long text/code clips inside All Clips.
- A generative model is not the right base primitive for semantic search. Start with indexed lexical search, then consider local Natural Language sentence embeddings.
- Vision should handle image OCR on macOS 14+.
- A language model must never be the privacy boundary for password/secret detection.

Before any automatic enrichment, add excluded-app controls, a deliberate private/pause mode, deterministic secret-pattern exclusions, and a way to clear generated metadata. Generated data must be stored separately and must never change the original paste payload.

## Remaining scale work

The v1 store atomically persists JSON metadata and retained payload files. Lazy previews and debounced library search remove the largest immediate UI costs, but indefinite history will eventually require an indexed SQLite/FTS store with paged queries. That migration should precede semantic indexing or automatic model enrichment.
