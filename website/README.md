# NotchClip website

A static product page served by the existing `notchclip` Cloudflare Worker. Content lives in `public/index.html`, the shared visual styles in `public/styles.css`, and the video setting in `public/video-config.js`.

## Add the hero video

1. Upload the walkthrough to Cloudflare Stream and wait for processing to finish.
2. Open the video's embed code and copy only the iframe's `src` URL.
3. Paste that URL into `streamEmbedUrl` in `public/video-config.js`.
4. Preview the page, check playback, and deploy the website.

For example:

```js
streamEmbedUrl: "https://customer-YOUR-CUSTOMER-CODE.cloudflarestream.com/YOUR-32-CHARACTER-VIDEO-UID/iframe"
```

The setting is public; no API token or account credentials are needed. Use a public video UID, not a temporary signed playback token. The legacy `https://iframe.videodelivery.net/VIDEO_UID` format is also supported.

The player appears below the hero copy and download button. It uses the video's first frame as its poster, shows playback controls, and waits for the visitor to press play. Copied query options are replaced with the site's settings, so a copied autoplay option cannot start playback unexpectedly. Clearing the setting restores the placeholder. An invalid URL also leaves the placeholder visible.

The video area matches the uploaded clip at 3324 × 2160 (277:180); its aspect ratio is set on `.video-frame` in the stylesheet. Keep this aligned with the uploaded video if you change its format. If Stream's allowed origins are restricted, include both the production hostname and any preview hostname used for playback checks.

## Local development and checks

```sh
npm ci
npm run dev
npm run check
npm run deploy:check
```

There is no separate asset build step. `deploy:check` runs Wrangler's dry run using the existing Worker configuration. The focused tests cover URL validation, manual playback settings, the empty video state, and the Worker's security headers and request handling.

## Deploy

```sh
npm run deploy
```

This updates the existing `notchclip` Worker. For a reviewable version without changing its active deployment, use the installed Wrangler:

```sh
npm run preview:upload
```

Current app downloads point to NotchClip 0.6.7 for Apple silicon. When changing the app release, update all three download links and the version text in `public/index.html` together.

## Reviewed preview — 16 September 2026

- Preview: https://staging-notchclip.anoopdigitalmarketing1.workers.dev/
- Worker version: `199b716b-d2df-4420-b5bc-b6ded5d0055a`
- Saved production version: `2ea1e070-e364-4b2f-8a7b-ad32189c6a81` (not changed by the preview upload).
- Checked desktop light/dark appearance, 320px/390px/768px responsive widths, visible keyboard focus, tabular numerals, and the existing app download.
- Four video/Worker checks and Wrangler dry run passed. Deployed scripts, stylesheet, and font match the reviewed source; browser console is clear.
- Hero video: `Clip-notch 2.mp4`, Stream ID `7be212b941a663c4a0f38a0458fcf028`, 17.1 seconds, 3324 × 2160. The existing public Stream upload is embedded directly. Playback was verified in the published preview, including keyboard activation, an advancing video timeline, a matching mobile frame, and no browser console errors.
