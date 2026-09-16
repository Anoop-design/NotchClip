import assert from "node:assert/strict"
import test from "node:test"
import { streamPlayerUrl, mountStreamPlayer } from "../public/script.js"
import worker from "../src/index.js"

const uid = "6b9e68b07dfee8cc2d116e4c51d6a957"
const streamUrl = `https://customer-example.cloudflarestream.com/${uid}/iframe`

test("accepts Stream iframe URLs and keeps playback manual", () => {
  for (const input of [streamUrl, `https://iframe.videodelivery.net/${uid}`]) {
    const result = new URL(streamPlayerUrl(`${input}?autoplay=false&controls=false&ad-url=https://example.com#ad`))
    assert.equal(result.searchParams.has("autoplay"), false)
    assert.equal(result.searchParams.has("ad-url"), false)
    assert.equal(result.searchParams.get("controls"), "true")
    assert.equal(result.searchParams.get("preload"), "metadata")
    assert.equal(result.hash, "")
  }
})

test("rejects empty, malformed, credentialed, and untrusted embed URLs", () => {
  const invalid = [
    "", "  ", null, undefined, {}, "not a URL",
    streamUrl.replace("https:", "http:"),
    streamUrl.replace("https://", "https://user:password@"),
    streamUrl.replace(".com/", ".com:8443/"),
    streamUrl.replace(".com/", ".com.evil.example/"),
    streamUrl.replace("customer-example", "example"),
    streamUrl.replace("/iframe", "/manifest/video.m3u8"),
    streamUrl.replace(uid, "not-a-video-id"),
    streamUrl.replace(uid, `${uid}/extra`),
    streamUrl.replace("https://", "https:"),
    streamUrl.replace(uid, `other/../${uid}`),
    streamUrl.replace(uid, `other/%2e%2e/${uid}`),
    `https://iframe.videodelivery.net/${uid}/iframe`,
    `javascript:alert(1)`,
    `${streamUrl}\n?autoplay=true`
  ]
  for (const input of invalid) assert.equal(streamPlayerUrl(input), null, String(input))
})

function playerDocument() {
  const placeholder = { hidden: false }
  const children = []
  const frame = {
    querySelector(selector) {
      return selector === "iframe" ? children[0] : placeholder
    },
    append(node) { children.push(node) }
  }
  return {
    placeholder,
    children,
    document: {
      querySelector() { return frame },
      createElement(tag) { assert.equal(tag, "iframe"); return {} }
    }
  }
}

test("keeps the placeholder for blank configuration and mounts a titled player once", () => {
  const { document, placeholder, children } = playerDocument()
  mountStreamPlayer(document, "")
  assert.equal(placeholder.hidden, false)
  assert.equal(children.length, 0)

  mountStreamPlayer(document, streamUrl)
  mountStreamPlayer(document, streamUrl)
  assert.equal(children.length, 1)
  assert.equal(placeholder.hidden, true)
  assert.equal(children[0].title, "NotchClip walkthrough")
  assert.equal(children[0].allowFullscreen, true)
  assert.equal(children[0].referrerPolicy, "strict-origin-when-cross-origin")
  assert.equal(children[0].style, undefined)
  assert.equal(children[0].allow.includes("autoplay"), false)
})

test("allows only Stream frame origins while preserving static response behavior", async () => {
  const requests = []
  const env = { ASSETS: { async fetch(request) {
    requests.push(request)
    return new Response("asset body", { status: 200, headers: { "Content-Type": "text/html", ETag: "asset-v1" } })
  } } }
  const getResponse = await worker.fetch(new Request("https://notchclip.example/"), env)
  assert.equal(await getResponse.text(), "asset body")
  assert.equal(getResponse.headers.get("ETag"), "asset-v1")
  const csp = getResponse.headers.get("Content-Security-Policy")
  assert.match(csp, /frame-src https:\/\/\*\.cloudflarestream\.com https:\/\/iframe\.videodelivery\.net;/)
  assert.match(csp, /script-src 'self';/)
  assert.match(csp, /style-src 'self';/)
  assert.match(csp, /frame-ancestors 'none';/)
  assert.equal(getResponse.headers.get("X-Frame-Options"), "DENY")

  const headResponse = await worker.fetch(new Request("https://notchclip.example/", { method: "HEAD" }), env)
  assert.equal(requests[1].method, "GET")
  assert.equal(await headResponse.text(), "")
  assert.equal(headResponse.headers.get("ETag"), "asset-v1")

  const postResponse = await worker.fetch(new Request("https://notchclip.example/", { method: "POST" }), env)
  assert.equal(postResponse.status, 405)
  assert.equal(postResponse.headers.get("Allow"), "GET, HEAD")
  assert.equal(requests.length, 2)
})
