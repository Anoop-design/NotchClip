import { videoConfig } from "./video-config.js"

export function streamPlayerUrl(value) {
  if (typeof value !== "string" || !value.trim()) return null

  const input = value.trim()
  if (/[\u0000-\u0020\u007f\\]/.test(input)) return null

  let url
  try {
    url = new URL(input)
  } catch {
    return null
  }

  if (url.protocol !== "https:" || url.username || url.password || url.port) return null
  const suppliedPath = input.match(/^https:\/\/[^/?#]+([^?#]*)/i)?.[1]
  if (suppliedPath !== url.pathname) return null

  const customerHost = /^customer-[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.cloudflarestream\.com$/.test(url.hostname)
  const legacyHost = url.hostname === "iframe.videodelivery.net"
  const validPath = customerHost
    ? /^\/[a-f0-9]{32}\/iframe\/?$/i.test(url.pathname)
    : legacyHost && /^\/[a-f0-9]{32}\/?$/i.test(url.pathname)

  if (!validPath) return null

  // Keep playback deliberate, even if the copied embed URL includes autoplay.
  url.search = ""
  url.hash = ""
  url.searchParams.set("controls", "true")
  url.searchParams.set("preload", "metadata")
  url.searchParams.set("primaryColor", "#ededed")
  url.searchParams.set("letterboxColor", "transparent")
  return url.href
}

export function mountStreamPlayer(document, embedUrl) {
  const frame = document.querySelector("[data-stream-player]")
  const src = streamPlayerUrl(embedUrl)
  if (!frame || !src || frame.querySelector("iframe")) return

  const iframe = document.createElement("iframe")
  iframe.className = "stream-player"
  iframe.src = src
  iframe.title = "NotchClip walkthrough"
  iframe.loading = "lazy"
  iframe.allow = "encrypted-media; picture-in-picture; fullscreen"
  iframe.allowFullscreen = true
  iframe.referrerPolicy = "strict-origin-when-cross-origin"
  frame.append(iframe)

  const placeholder = frame.querySelector("[data-video-placeholder]")
  if (placeholder) placeholder.hidden = true
}

if (typeof document !== "undefined") {
  mountStreamPlayer(document, videoConfig.streamEmbedUrl)

  document.querySelectorAll("[data-download]").forEach((link) => {
    link.addEventListener("click", () => {
      if (typeof window.cloudflare?.webAnalytics?.track === "function") {
        window.cloudflare.webAnalytics.track("download", { placement: link.dataset.download })
      }
    })
  })
}
