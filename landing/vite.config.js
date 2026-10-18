import { defineConfig, loadEnv } from "vite";

// Canonical, Open Graph and sitemap URLs must be absolute. Set SITE_URL at build time
// (a Railway service variable, `SITE_URL=… npm run build`, or landing/.env).
function seo(siteURL) {
    return {
        name: "trellis-seo",
        transformIndexHtml: (html) => html.replaceAll("%SITE_URL%", siteURL),
        generateBundle() {
            const today = new Date().toISOString().slice(0, 10);
            this.emitFile({ type: "asset", fileName: "robots.txt", source: `User-agent: *\nAllow: /\n\nSitemap: ${siteURL}/sitemap.xml\n` });
            this.emitFile({
                type: "asset",
                fileName: "sitemap.xml",
                source: `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n  <url><loc>${siteURL}/</loc><lastmod>${today}</lastmod></url>\n</urlset>\n`,
            });
        },
    };
}

export default defineConfig(({ mode }) => {
    const env = loadEnv(mode, process.cwd(), "");
    const siteURL = (process.env.SITE_URL || env.SITE_URL || "https://trellis.layerx.xyz").replace(/\/+$/, "");
    return {
        base: "/",
        plugins: [seo(siteURL)],
        build: { outDir: "dist", assetsInlineLimit: 0 },
    };
});
