# Releasing NotchClip

NotchClip updates itself with [Sparkle 2](https://sparkle-project.org). Every
shipped build trusts exactly one EdDSA public key (`SUPublicEDKey` in
`Packaging/Info.plist`) and one feed URL (`SUFeedURL`). Neither can be changed
for copies already installed, so treat both as permanent.

## The signing key

The EdDSA **private** key lives in the login Keychain as a generic password:

| field | value |
| --- | --- |
| service | `https://sparkle-project.org` |
| account | `ed25519` |
| label | `Private key for signing Sparkle updates` |

It is the only thing that can authorize an update for every installed copy of
NotchClip. **If it is lost, no installed copy can ever be updated again** —
every user would have to download a new build by hand. Back it up offline now:

```sh
# Print the public key (safe to share; must match SUPublicEDKey).
.build/artifacts/sparkle/Sparkle/bin/generate_keys -p

# Export the private key to a file, then move that file to offline storage.
# Write it outside the repository; it must never be committed.
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x ~/sparkle-private-key.txt

# Restore it on another Mac (or after a Keychain loss):
.build/artifacts/sparkle/Sparkle/bin/generate_keys -f ~/sparkle-private-key.txt
```

Never commit the exported private key.

`.build/artifacts/` only exists after SwiftPM has resolved the Sparkle binary
artifact, so run `swift build` once on a fresh clone before using these tools.

## If a build hangs on "Downloading binary artifact"

SwiftPM's downloader has been observed hanging indefinitely on this machine
while fetching Sparkle's XCFramework — no network traffic, no error, no
timeout. It resolves from SwiftPM's shared archive cache instead, so seeding
that cache by hand fixes it:

```sh
curl -L https://github.com/sparkle-project/Sparkle/releases/download/2.9.4/Sparkle-for-Swift-Package-Manager.zip \
  -o ~/Library/Caches/org.swift.swiftpm/artifacts/https___github_com_sparkle_project_Sparkle_releases_download_2_9_4_Sparkle_for_Swift_Package_Manager_zip
```

The cache file name is the artifact URL with every non-alphanumeric character
replaced by `_`; update both the version in the URL and in the file name when
Sparkle is upgraded. Clearing `~/Library/Caches/org.swift.swiftpm` brings the
hang back, so re-seed before a release rather than mid-release.

## Release checklist

1. **Bump both version keys in `Packaging/Info.plist`.**
   Sparkle compares `CFBundleVersion` (the appcast's `sparkle:version`), not
   `CFBundleShortVersionString`. Shipping two builds with the same
   `CFBundleVersion` means the second update is never offered.
   - `CFBundleShortVersionString` — the marketing version users see.
   - `CFBundleVersion` — must strictly increase on every release.

2. **Build, sign, notarize, and staple the DMG.**

   ```sh
   scripts/release-notarized.sh \
     --identity "Developer ID Application: Anoop Chandrashekar (7YYS5MW5QM)" \
     --keychain-profile AC_NOTARY
   ```

   Sparkle's framework and its nested helpers (`Installer.xpc`,
   `Downloader.xpc`, `Autoupdate`, `Updater.app`) are signed inside-out by
   `scripts/build-app.sh` before the outer app signature, with the hardened
   runtime and a secure timestamp. Notarization fails if any of them is
   missing a signature.

3. **Confirm the app carried a working updater.**

   `release-notarized.sh` runs `scripts/verify-app.sh` on the app before it
   notarizes, so a release that reaches the DMG stage has already passed. Run
   it by hand against any bundle produced by `scripts/build-app.sh` directly:

   ```sh
   scripts/verify-app.sh <path>/NotchClip.app
   ```

   It asserts `Contents/Frameworks/Sparkle.framework` is embedded and that
   `SUFeedURL`, `SUPublicEDKey`, and `SUEnableAutomaticChecks` are present. A
   build that ships without them can never be fixed in place.

4. **Collect the release DMGs in one directory and generate the appcast.**

   Keep older DMGs in the same directory — `generate_appcast` re-emits an entry
   for each one and can build binary deltas between them.

   ```sh
   scripts/make-appcast.sh --releases dist/releases
   ```

   The script refuses to run if the Keychain key does not match the
   `SUPublicEDKey` compiled into the app, and refuses to emit an unsigned feed.

   The first run shows a macOS Keychain prompt asking to let `generate_appcast`
   read the signing key — choose **Always Allow**, or the run blocks forever
   waiting on the dialog. On a machine without the key in its Keychain (CI, a
   second Mac), pass the exported key instead:
   `scripts/make-appcast.sh --releases dist/releases --ed-key-file <path>`.

5. **Publish `appcast.xml` and every DMG it references.**

   The feed URL baked into the app is:

   ```
   https://anoop-design.github.io/NotchClip/appcast.xml
   ```

   so `appcast.xml` must be served from the `NotchClip` GitHub Pages site, and
   each DMG must be reachable at
   `https://anoop-design.github.io/NotchClip/<dmg-filename>` — the default
   `--download-url-prefix`. If you host the DMGs somewhere else (GitHub
   Releases assets, for example), pass the matching `--download-url-prefix` to
   `make-appcast.sh`, or the feed will advertise downloads that 404.

   **The repository must be public** (or the assets otherwise publicly hosted)
   for GitHub Pages to serve the feed. Sparkle sends no credentials.

6. **Test the update path before announcing.** Install the *previous* release,
   then publish the new one and use “Check for Updates…” from the menu bar. A
   mismatch between the appcast signature and `SUPublicEDKey` shows up here as
   a silently rejected update.

## Known limitation

NotchClip is an `LSUIElement` agent, so Sparkle's update window can open behind
the frontmost app. There is no user-driver delegate wired up yet; adding one
that calls `NSApp.activate` on update presentation is the fix if this becomes
a complaint.
