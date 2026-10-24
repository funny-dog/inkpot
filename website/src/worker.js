// Inkpot 官站 Worker：静态资源之外的下载跳转与版本信息接口

const GITHUB_API = "https://api.github.com";
const CACHE_TTL_SECONDS = 600;

async function fetchLatestRelease(env) {
  const repo = env.GITHUB_REPO || "funny-dog/inkpot";
  const response = await fetch(`${GITHUB_API}/repos/${repo}/releases/latest`, {
    headers: {
      "User-Agent": "inkpot-website",
      Accept: "application/vnd.github+json",
    },
    signal: AbortSignal.timeout(5000),
    cf: { cacheTtl: CACHE_TTL_SECONDS, cacheEverything: true },
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
    assets.find((asset) => /\.zip$/i.test(asset.name))
  );
}

function releaseSummary(release) {
  const asset = pickDownloadAsset(release);
  return {
    tag_name: release.tag_name,
    name: release.name,
    published_at: release.published_at,
    html_url: release.html_url,
    download_url: asset ? asset.browser_download_url : null,
    asset_name: asset ? asset.name : null,
    asset_size: asset ? asset.size : null,
  };
}

async function handleRelease(request, env) {
  const cache = caches.default;
  const cacheKey = new Request(new URL("/__release-cache", request.url), { method: "GET" });
  const cached = await cache.match(cacheKey);
  if (cached) {
    return cached;
  }
  try {
    const release = await fetchLatestRelease(env);
    const response = new Response(JSON.stringify(releaseSummary(release)), {
      headers: {
        "Content-Type": "application/json; charset=utf-8",
        "Cache-Control": `public, max-age=${CACHE_TTL_SECONDS}`,
      },
    });
    await cache.put(cacheKey, response.clone());
    return response;
  } catch (error) {
    return new Response(JSON.stringify({ error: String(error) }), {
      status: 502,
      headers: { "Content-Type": "application/json; charset=utf-8" },
    });
  }
}

function handleDownload(env) {
  const repo = env.GITHUB_REPO || "funny-dog/inkpot";
  return Response.redirect(`https://github.com/${repo}/releases/latest`, 302);
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    switch (url.pathname) {
      case "/api/release":
        return handleRelease(request, env);
      case "/download":
        return handleDownload(env);
      default:
        return env.ASSETS.fetch(request);
    }
  },
};
