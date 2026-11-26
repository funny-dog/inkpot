// Inkpot 官站 Worker：静态资源之外的下载跳转与版本信息接口

const GITHUB_API = "https://api.github.com";
const CACHE_TTL_SECONDS = 600;
const ERROR_CACHE_TTL_SECONDS = 60;

async function fetchLatestRelease(env) {
  const repo = env.GITHUB_REPO || "funny-dog/inkpot";
  const response = await fetch(`${GITHUB_API}/repos/${repo}/releases/latest`, {
    headers: {
      "User-Agent": "inkpot-website",
      Accept: "application/vnd.github+json",
    },
    signal: AbortSignal.timeout(5000),
  });
  if (!response.ok) {
    throw new Error(`GitHub API ${response.status}`);
  }
  return response.json();
}

function pickDownloadAsset(release) {
  const assets = release.assets || [];
  return (
    assets.find((asset) => /\.dmg$/i.test(asset.name)) ||
    assets.find((asset) => /\.zip$/i.test(asset.name) && !/windows/i.test(asset.name)) ||
    assets.find((asset) => /\.zip$/i.test(asset.name))
  );
}

function pickWindowsAsset(release) {
  const assets = release.assets || [];
  return assets.find((asset) => /windows.*\.zip$/i.test(asset.name));
}

function releaseSummary(release) {
  const asset = pickDownloadAsset(release);
  const windowsAsset = pickWindowsAsset(release);
  return {
    tag_name: release.tag_name,
    name: release.name,
    published_at: release.published_at,
    html_url: release.html_url,
    download_url: asset ? asset.browser_download_url : null,
    asset_name: asset ? asset.name : null,
    asset_size: asset ? asset.size : null,
    windows_download_url: windowsAsset ? windowsAsset.browser_download_url : null,
    windows_asset_size: windowsAsset ? windowsAsset.size : null,
  };
}

function securityHeaders(extra = {}) {
  return {
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "strict-origin-when-cross-origin",
    ...extra,
  };
}

async function handleRelease(request, env, ctx) {
  if (request.method !== "GET" && request.method !== "HEAD") {
    return new Response(null, { status: 405, headers: securityHeaders({ Allow: "GET, HEAD" }) });
  }
  const cache = caches.default;
  const cacheKey = new Request(new URL("/__release-cache", request.url), { method: "GET" });
  const cached = await cache.match(cacheKey);
  if (cached) {
    return request.method === "HEAD" ? new Response(null, { status: cached.status, headers: cached.headers }) : cached;
  }
  try {
    const release = await fetchLatestRelease(env);
    const response = new Response(JSON.stringify(releaseSummary(release)), {
      headers: securityHeaders({
        "Content-Type": "application/json; charset=utf-8",
        "Cache-Control": `public, max-age=${CACHE_TTL_SECONDS}`,
      }),
    });
    const putPromise = cache.put(cacheKey, response.clone());
    if (ctx && typeof ctx.waitUntil === "function") ctx.waitUntil(putPromise);
    else await putPromise;
    return request.method === "HEAD" ? new Response(null, { status: response.status, headers: response.headers }) : response;
  } catch {
    const errorResponse = new Response(JSON.stringify({ error: "Release information unavailable" }), {
      status: 502,
      headers: securityHeaders({
        "Content-Type": "application/json; charset=utf-8",
        "Cache-Control": `public, max-age=${ERROR_CACHE_TTL_SECONDS}`,
      }),
    });
    return request.method === "HEAD" ? new Response(null, { status: 502, headers: errorResponse.headers }) : errorResponse;
  }
}

function handleDownload(request, env) {
  if (request.method !== "GET" && request.method !== "HEAD") {
    return new Response(null, { status: 405, headers: securityHeaders({ Allow: "GET, HEAD" }) });
  }
  const repo = env.GITHUB_REPO || "funny-dog/inkpot";
  return Response.redirect(`https://github.com/${repo}/releases/latest`, 302);
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    switch (url.pathname) {
      case "/api/release":
        return handleRelease(request, env, ctx);
      case "/download":
        return handleDownload(request, env);
      default:
        return env.ASSETS.fetch(request);
    }
  },
};
