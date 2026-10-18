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

## Deploying on Railway

The `Dockerfile` builds the site with Node 22 and serves `dist/` with nginx. nginx listens on `$PORT`, which Railway injects; it defaults to 8080. The config (`nginx/default.conf.template`) sets gzip, immutable caching for hashed `/assets/`, `no-cache` for HTML, and security headers including a CSP that only allows `api.github.com` for fetches.

1. In Railway, create a service from the `layerx-labs/trellis` GitHub repo.
2. Set **Settings → Root Directory** to `landing`. `railway.json` selects the Dockerfile builder.
3. Generate a domain, or attach your own.

Locally:

```sh
docker build -t trellis-landing landing
docker run --rm -e PORT=8080 -p 8080:8080 trellis-landing   # http://localhost:8080
```
