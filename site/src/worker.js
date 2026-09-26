const RELEASE_API = "https://api.github.com/repos/HustleCoding/stale/releases/latest";
const RELEASES = "https://github.com/HustleCoding/stale/releases/latest";

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname !== "/download") return env.ASSETS.fetch(request);
    try {
      const res = await fetch(RELEASE_API, {
        headers: { "User-Agent": "stale-site", Accept: "application/vnd.github+json" },
        cf: { cacheTtl: 300, cacheEverything: true },
      });
      const release = await res.json();
      const dmg = release.assets?.find((a) => a.name.endsWith(".dmg"));
      if (dmg) return Response.redirect(dmg.browser_download_url, 302);
    } catch {}
    return Response.redirect(RELEASES, 302);
  },
};
