# Open-source distribution

NotchClip is distributed under the MIT license. See [LICENSE](../LICENSE).

- Source: https://github.com/Anoop-design/NotchClip
- Signed downloads: https://github.com/Anoop-design/NotchClip-Downloads/releases
- Build and contribution starting point: [README](../README.md)
- Signing and update-feed workflow: [Releasing](RELEASING.md)

## Publishing builds

Keep clipboard data, environment files, signing certificates, and private keys
outside the repository. Local Cloudflare state, build outputs, and unrelated
reference projects are excluded through `.gitignore`.

The checked-in Sparkle key is a public verification key. The private update
signing key stays in the maintainer's Keychain and must never be published.
Forks distributing their own builds should use their own bundle identifier,
update feed, and signing keys.

The website includes Inter under its bundled font license. Sparkle retains its
own license. The project's MIT license does not replace third-party licenses.
