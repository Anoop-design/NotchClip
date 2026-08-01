# NotchClip

Personal macOS clipboard history. Control–V (or any shortcut you record in Settings) morphs the MacBook notch into a translucent, Dynamic-Island-style panel holding your entire searchable history (macOS 14+).

## Requirements

- **macOS 14.0+**
- **Xcode / Swift toolchain** with Swift 5.9+ (Swift Package Manager)
- Select the active developer directory as needed:

  ```bash
  xcode-select -p
  # or for a specific Xcode.app:
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  ```

  `scripts/build-app.sh` respects an existing `DEVELOPER_DIR`; otherwise it uses the active `xcrun` / Swift toolchain. No third-party dependencies; no network required to build.

## Build, test, bundle, verify

From the repository root:

```bash
# Describe / compile (optional scratch path keeps the tree clean)
xcrun --sdk macosx swift package describe
xcrun --sdk macosx swift build
xcrun --sdk macosx swift test

# Assemble a locally ad-hoc-signed native-architecture app (default: dist/NotchClip.app)
scripts/build-app.sh

# Or write somewhere unique (refuses to overwrite an existing path)
scripts/build-app.sh --output /tmp/notchclip-v1/NotchClip.app

# Read-only bundle checks (no launch, sign, or mutation)
scripts/verify-app.sh /tmp/notchclip-v1/NotchClip.app

# Build a branded drag-to-Applications installer around a signed app
scripts/build-dmg.sh \
  --app /tmp/notchclip-v1/NotchClip.app \
  --output /tmp/NotchClip-0.4.0-arm64.dmg
```

The app packaging script builds the **release** SwiftPM product, generates the `.icns` app icon, signs the completed bundle, and verifies it strictly. Its default ad-hoc signature makes a personal Apple Silicon build executable locally. `build-dmg.sh` creates a branded 680×440 Finder installer with the app, an Applications shortcut, fixed icon positions, and a saved background/layout.

## Developer ID signing and notarization

A normal Gatekeeper-approved distribution requires a paid Apple Developer team, a `Developer ID Application` certificate/private key in Keychain, and a `notarytool` credential profile.

Create the Keychain profile through a secure prompt (do not put an app-specific password directly on the command line):

```bash
xcrun notarytool store-credentials "notchclip-notary" \
  --apple-id "YOUR_APPLE_ID" \
  --team-id "YOUR_TEAM_ID"
```

Then run the end-to-end release command:

```bash
scripts/release-notarized.sh \
  --identity "Developer ID Application: Your Name (TEAMID)" \
  --keychain-profile "notchclip-notary"
```

That pipeline signs the app with hardened runtime and a secure timestamp; submits and staples the app; builds and signs the polished DMG; submits and staples the DMG; then validates with `codesign`, `stapler`, `hdiutil`, and Gatekeeper. It refuses to overwrite an existing output.

**Architecture:** the produced bundle is **native only** (the host CPU). It is not a universal binary unless you add that later.

## Using the app (local)

Open the `.app` yourself from Finder. The local ad-hoc signature is sufficient for this locally built copy, but it is not suitable for distribution to other Macs.

NotchClip has **one surface**. Control–V morphs the notch into a translucent panel
containing the entire searchable history — there is no second window.

| Action | Behavior |
|--------|----------|
| **Control–V** | Global hotkey toggles the clipboard panel (Carbon exclusive registration). Re-recordable in Settings › General › Shortcut; Reset to Default restores Control–V. |
| **Menu bar** | NotchClip menu: Show Clipboard, Pause/Resume, Settings, Quit |
| **Search** | The search field holds focus for the whole presentation — just type to filter. Command–F returns focus to it. |
| **List** | The complete history, sectioned into Pinned, Today, Yesterday, and Earlier. Up/Down move, Page Up/Down jump, Home/End go to the ends. |
| **Preview** | The selected clip's **complete** contents, with real line breaks (monospaced for markup), plus its source, time, and retained size. |
| **Filters** | Command–1 through Command–6 select All, Pinned, Text, Links, Images, or Files. Also available from the menu in the search header. |
| **Paste** | Return writes the exact selected entry to the general pasteboard, closes the panel, restores the previous app, and sends Command–V (the first-run setup explains and requests Accessibility for automatic delivery). |
| **Pin / delete** | Command–P pins, Command–Delete deletes, or use the row context menu. Pinning sorts an entry to the top and preserves it during “clear unpinned.” |
| **Drag out** | Drag a row's artwork directly into pasteboard-aware destinations / input fields |
| **Quick Look** | Command–Y previews supported images and files; Escape closes the preview. |
| **Escape** | Narrows before closing: clears the search, then resets the filter, then dismisses. |
| **Click outside** | Dismisses the panel |

## Clipboard content

Captures accessible pasteboard flavors, including:

- Plain text, RTF, HTML  
- URLs  
- Images (e.g. PNG/TIFF)  
- File URL lists  
- Other serialized types that fit the size policy  

**Skipped whole:** `org.nspasteboard.TransientType`, `ConcealedType`, and `AutoGeneratedType` markers. Oversized representations are not truncated (see caps below).

## Persistence

- **History & payloads:** `~/Library/Application Support/NotchClip/`  
  - `metadata/` — entry metadata (atomic JSON repository)  
  - `payloads/` — retained pasteboard bytes only  
- **History lifetime:** kept **indefinitely** until you clear unpinned items or clear all history in Settings. There is no automatic time-based purge of clipboard history.
- **File copies:** original file URLs are **references**. NotchClip does **not** copy source files into storage. If a file is moved or deleted, drag-out / preview for that original path will not work (missing-file state is detected).
- **Preferences:** local `UserDefaults` (e.g. link-preview fetch toggle).
- **Launch at Login:** optional in Settings → General. NotchClip uses macOS Service Management to register the signed main app as a user-controlled login item.

## Link previews (privacy)

When **Fetch link previews** is enabled (default), visible HTTP/HTTPS URL rows may trigger a metadata request. The destination (or its metadata host) can see your Mac’s IP and similar request details. Previews are cached **only on this Mac**:

- Cache root: `~/Library/Caches/NotchClip/LinkPreviews/`  
- Disk: up to 200 records / 64 MiB / 30-day TTL; memory LRU 32 / 16 MiB  
- Preview images capped at **1 MiB**  

Disable the toggle to stop network metadata fetches. **Clear Link Preview Cache** in Settings wipes the local cache. Clear All history also clears the link-preview cache.

## Size caps (from code)

| Limit | Value | Behavior |
|-------|--------|----------|
| Per representation | **64 MiB** (`PasteboardParser.defaultMaxRepresentationBytes`) | Representation **skipped whole** if larger; never truncated and re-labeled |
| Per capture (total retained) | **128 MiB** (`PasteboardSnapshotter.defaultTotalRetainedBytes`) | Further representations omitted once the budget is exhausted |

## Package layout

| Target | Role |
|--------|------|
| `NotchClipCore` | Models, pasteboard parse/write, storage, monitor, panel geometry, scope/projection filtering, link-preview policy/cache |
| `NotchClip` | Menu-bar app, unified notch history panel, hotkey, Quick Look, drag-out |
| `NotchClipCoreTests` | Deterministic unit tests |

Bundle identity (source of truth: `Packaging/Info.plist`): `com.anoop.notchclip`, agent app (`LSUIElement` = true, no Dock icon), macOS 14.0 minimum.

On first launch, NotchClip shows a one-time explanation before asking macOS for Accessibility access. The permission is used only to deliver Command–V to the app that was active before the notch opened. If setup is deferred, it remains available from the menu bar and Settings; macOS always requires the user to approve the switch in Privacy & Security.

## Current status & known limitations

- **Native architecture only** — the local path uses an ad-hoc signature; the release path supports Developer ID, notarization, stapling, and Gatekeeper validation.  
- A polished drag-to-Applications DMG workflow and custom app icon are included. A real notarized artifact still requires the developer certificate and notary credentials described above.  
- See [docs/UX_AUDIT.md](docs/UX_AUDIT.md) for the full gap list.
- GUI automation / interactive GUI tests are not part of the package test suite.  
- The current atomic JSON history store is appropriate for a personal v1, but an indexed SQLite/FTS migration is planned before histories reach many thousands of entries.
- Copies distributed to other Macs will require Developer ID signing and notarization for normal Gatekeeper acceptance.

The product and on-device intelligence decisions are recorded in [docs/DESIGN_AUDIT.md](docs/DESIGN_AUDIT.md).

## License

Private / unlicensed until specified.
