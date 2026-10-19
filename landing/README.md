# Trellis landing page

The static product page for Trellis, built with [Vite](https://vite.dev). It's plain HTML, CSS and a small script, with no framework. The design uses Inter with `cv05`, neutral greys and blue/purple accents, and Trellis's phosphor green for small touches.

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

## Analytics

The page reports to a self-hosted [Plausible](https://plausible.io) instance through the bundled `@plausible-analytics/tracker` module (`src/analytics.js`), so no third-party script is loaded. It's off unless `PLAUSIBLE_HOST` is set at build time:

```sh
PLAUSIBLE_HOST=https://plausible.your.domain npm run build   # site ID defaults to the SITE_URL host
PLAUSIBLE_DOMAIN=other.site.id                                # optional override
```

On Railway, add `PLAUSIBLE_HOST` (and optionally `PLAUSIBLE_DOMAIN`) as service variables. The Dockerfile passes `PLAUSIBLE_HOST` to the build and to nginx, which adds it to the CSP `connect-src`. Use the origin only, with no path. Events are never sent from `localhost`. To keep your own visits out, set `localStorage.plausible_ignore = "true"` in the browser console on the live site.

The tracker records pageviews, referrers and UTM tags, scroll depth and time on page by itself, along with these events:

| Event | Props | When |
| --- | --- | --- |
| `Section View` | `section`: hero, features, terminal, automation, hosts, themes, privacy, install, faq, cta | A section reaches mid-screen, once per visit. Doesn't count as interaction for bounce rate |
| `Nav Click` | `section` | A link in the top nav |
| `Download` | `location` (hero, cta), `version` | A download button |
| `GitHub` | `location` (nav, hero, cta, faq, footer) | A link to the repo |
| `Footer Link` | `link` (releases, changelog, docs, license, bearstouch) | A footer link |
| `Contribute Click` | | The CONTRIBUTING.md link in the FAQ |
| `Screenshot Open` | `shot` | A screenshot opened in the lightbox |
| `FAQ Open` | `question` | An FAQ answer expanded |
| `Copy` | `snippet` (cli-install, automation) | Text copied from a code block |
| `Outbound Link: Click` | `url` | Any link off the site (sent by the tracker) |

With analytics built in, the footer shows a line saying the site uses Plausible and the app has none. Without `PLAUSIBLE_HOST` the line stays hidden.

To tag another element, add `data-track="Event Name"`; each `data-track-<key>="value"` attribute becomes a prop.

In Plausible, add each event as a **custom event goal** under **Site settings → Goals**. Then add the props (`section`, `location`, `version`, `link`, `shot`, `question`, `snippet`, `url`) under **Custom properties**, so you can break goals down by them. One useful funnel is Visit / → `Section View` (section = install) → `Download`.

## SEO and sharing

`index.html` carries the canonical URL, Open Graph and Twitter tags, and `SoftwareApplication` JSON-LD. The build also writes `robots.txt` and `sitemap.xml`. Absolute URLs come from `SITE_URL`, which defaults to `https://trellis.bearstouch.com`:

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

The `Dockerfile` builds the site with Node 22 and serves `dist/` with nginx. nginx listens on `$PORT`, which Railway injects; it defaults to 8080. The config (`nginx/default.conf.template`) sets gzip, immutable caching for hashed `/assets/`, `no-cache` for HTML, and security headers including a CSP that only allows `api.github.com` (and `PLAUSIBLE_HOST`, when set) for fetches.

1. In Railway, create a service from the `bearstouch/trellis` GitHub repo.
2. Set **Settings → Root Directory** to `landing`. `railway.json` selects the Dockerfile builder.
3. Add a `SITE_URL` variable with the public address, e.g. `https://trellis.bearstouch.com`.
4. Generate a domain, or attach your own.

Locally:

```sh
docker build -t trellis-landing landing
docker run --rm -e PORT=8080 -p 8080:8080 trellis-landing   # http://localhost:8080
```
