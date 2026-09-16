# NotchClip 0.6.7

Build 18 · macOS 14 or later · Apple silicon

## Animation refinement

Reopening the clipboard while it is closing now preserves the content opacity
and immediately resumes the reveal. On displays without a notch, the panel's
overall opacity is preserved as well. This removes an avoidable opacity reset
during rapid shortcut toggles while retaining the existing spring timing.

## Validation

- 261 Swift tests passed using a clean temporary build directory.
- Release app built and signed with Developer ID and hardened runtime.
- App notarization accepted by Apple; ticket stapled and validated.
- DMG notarization accepted by Apple; ticket stapled and validated. Gatekeeper
  reports `accepted`, with source `Notarized Developer ID`.
- Mounted installer verified as version 0.6.7 (18), with the Applications
  shortcut, saved icon positions, and background configuration intact.
- Live animation inspection could not be completed because the desktop tool
  timed out when selecting NotchClip. A visual check of rapid close/reopen on
  notched and external displays remains useful before public announcement.

This build includes the pre-existing working-tree fixes present before the
animation refinement. It is not a build of the last Git commit alone.

## Artifact

`dist/NotchClip-0.6.7-arm64.dmg`

SHA-256: `aa286e8abbeb00a3f6925051cfc7ff03f8787043ac8975aaec455b9212c6f931`

Apple submission IDs:

- App: `80eaf52b-0392-4f87-bae2-5f11d8729a47`
- DMG: `1b3dada1-87c0-4c7d-9ae5-1bcb2a9b9cce`

For this build, the Finder layout was generated directly with temporary
`ds-store` and `mac-alias` tooling instead of the packaging script's Finder
automation. The app and DMG were notarized separately; the repository's existing
release scripts were left unchanged by this refinement.
