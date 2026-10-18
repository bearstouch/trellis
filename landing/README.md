# Trellis landing page

The static product page for Trellis, built with [Vite](https://vite.dev). It's plain HTML, CSS and a small script, with no framework. The design follows the LayerX look: Inter with `cv05`, LayerX greys and blue/purple accents, and Trellis's phosphor green for small touches.

```sh
cd landing
npm install
npm run dev        # http://localhost:5173
npm run build      # outputs dist/
npm run preview    # serves dist/
```

## Screenshots

Screenshots live in `src/assets/shots/`. Each `data-shot="name"` slot in `index.html` uses `src/assets/shots/<name>.png` (`.jpg` and `.webp` also work). A missing file renders a "Screenshot coming soon" frame, so the page builds either way. Clicking a screenshot opens it full size.

| File | What to capture |
| --- | --- |
| `hero.png` | The full workspace (a copy of `docs/images/trellis-workspace.png`) |
| `tabs.png` | The sidebar with several windows and color-labeled tabs, one showing the busy bar or **Input** label |
| `splits.png` | One tab with 3–4 nested splits running different programs (htop, git log, an editor) |
| `shell.png` | A failed command flagged in the scrollback, with shell integration on |
| `hosts.png` | File → Hosts… with a few saved hosts |
| `themes.png` | Settings → Themes with the live preview |

Capture windows with ⌘⇧4 then Space, from a demo workspace so your real data stays out of the shot:

```sh
swift run Trellis --state-directory "$PWD/.build/demo-state"
```

## Live data

On load the page asks the GitHub API for the star count and the latest release tag. If that fails (offline, rate-limited), the static labels stay: "GitHub" and "Download for macOS".

## SEO and sharing

`index.html` carries the canonical URL, Open Graph and Twitter tags, and `SoftwareApplication` JSON-LD. The build also writes `robots.txt` and `sitemap.xml`. Absolute URLs come from `SITE_URL`, which defaults to `https://trellis.layerx.xyz`:

```sh
SITE_URL=https://your.domain npm run build
```

On Railway, add `SITE_URL` as a service variable; the Dockerfile passes it to the build.

The share card `public/og.png` (1200×630) is rendered from `og/og.html` with `npm run og`, which needs Google Chrome. Rerun it after changing the hero screenshot.

The site icons in `public/` come from the app icon artwork in `Design/AppIcon`; regenerate them with `npm run icons` (needs `rsvg-convert` and ImageMagick):

| File | Use |
| --- | --- |
| `favicon.ico` | 16, 32 and 48 px, for browsers and tools that only read `.ico` |
| `favicon.svg` | Sharp tab icon in modern browsers (the simplified 16–32 px artwork), also used in the nav and footer |
| `apple-touch-icon.png` | 180 px, opaque, for iOS home screens |
| `icon-192.png`, `icon-512.png` | Web manifest icons, transparent |
| `icon-maskable-512.png` | Opaque, for Android's masked icon shapes |

## Deploying on Railway

The `Dockerfile` builds the site with Node 22 and serves `dist/` with nginx. nginx listens on `$PORT`, which Railway injects; it defaults to 8080. The config (`nginx/default.conf.template`) sets gzip, immutable caching for hashed `/assets/`, `no-cache` for HTML, and security headers including a CSP that only allows `api.github.com` for fetches.

1. In Railway, create a service from the `layerx-labs/trellis` GitHub repo.
2. Set **Settings → Root Directory** to `landing`. `railway.json` selects the Dockerfile builder.
3. Add a `SITE_URL` variable with the public address, e.g. `https://trellis.layerx.xyz`.
4. Generate a domain, or attach your own.

Locally:

```sh
docker build -t trellis-landing landing
docker run --rm -e PORT=8080 -p 8080:8080 trellis-landing   # http://localhost:8080
```
