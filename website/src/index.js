const SECURITY_HEADERS = {
  "Content-Security-Policy": "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; frame-src https://*.cloudflarestream.com https://iframe.videodelivery.net; object-src 'none'; base-uri 'self'; form-action 'none'; frame-ancestors 'none'; upgrade-insecure-requests",
  "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
  "Referrer-Policy": "strict-origin-when-cross-origin",
  "X-Content-Type-Options": "nosniff",
  "X-Frame-Options": "DENY"
}

export default {
  async fetch(request, env) {
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method Not Allowed", {
        status: 405,
        headers: { Allow: "GET, HEAD" }
      })
    }

    const assetRequest = request.method === "HEAD"
      ? new Request(request.url, { method: "GET", headers: request.headers })
      : request
    const assetResponse = await env.ASSETS.fetch(assetRequest)
    const headers = new Headers(assetResponse.headers)

    for (const [name, value] of Object.entries(SECURITY_HEADERS)) {
      headers.set(name, value)
    }

    return new Response(request.method === "HEAD" ? null : assetResponse.body, {
      status: assetResponse.status,
      statusText: assetResponse.statusText,
      headers
    })
  }
}
