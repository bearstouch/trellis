import "@fontsource-variable/inter";
import "@fontsource/jetbrains-mono/400.css";
import "./style.css";
import { enabled as analyticsEnabled, track, trackCopies, trackFAQ, trackSectionViews, trackTaggedClicks } from "./analytics.js";

const REPO = "bearstouch/trellis";
document.documentElement.classList.add("js");

// Screenshots: any slot whose file is missing from src/assets/shots shows a placeholder,
// so the page builds before every shot exists.
const shots = import.meta.glob("./assets/shots/*.{png,jpg,webp}", { eager: true, query: "?url", import: "default" });
const shotURL = (name) => Object.entries(shots).find(([path]) => path.replace(/^.*\/|\.\w+$/g, "") === name)?.[1];

const lightbox = document.querySelector(".lightbox");
const lightboxImg = lightbox.querySelector("img");
let opener = null;

for (const slot of document.querySelectorAll("[data-shot]")) {
    const url = shotURL(slot.dataset.shot);
    const alt = slot.dataset.alt ?? "";
    if (!url) {
        slot.innerHTML = `<div class="shot-placeholder" role="img" aria-label="${alt}"><div><span>Screenshot coming soon</span>${alt}</div></div>`;
        continue;
    }
    const img = Object.assign(document.createElement("img"), { src: url, alt, decoding: "async" });
    if (slot.dataset.shot !== "hero") img.loading = "lazy";
    const button = Object.assign(document.createElement("button"), { type: "button", className: "shot-open" });
    button.setAttribute("aria-label", `Enlarge screenshot: ${alt}`);
    button.append(img);
    button.addEventListener("click", () => {
        opener = button;
        track("Screenshot Open", { shot: slot.dataset.shot });
        lightboxImg.src = url; lightboxImg.alt = alt;
        lightbox.showModal();
    });
    slot.append(button);
}

lightbox.querySelector(".lightbox-close").addEventListener("click", () => lightbox.close());
lightbox.addEventListener("click", (event) => { if (event.target === lightbox) lightbox.close(); });
lightbox.addEventListener("close", () => opener?.focus());

// Nav border once the page scrolls.
const nav = document.querySelector(".nav");
const onScroll = () => nav.classList.toggle("scrolled", window.scrollY > 8);
window.addEventListener("scroll", onScroll, { passive: true });
onScroll();

// Reveal on scroll.
const observer = new IntersectionObserver((entries) => {
    for (const entry of entries) if (entry.isIntersecting) { entry.target.classList.add("in"); observer.unobserve(entry.target); }
}, { rootMargin: "0px 0px -8% 0px" });
document.querySelectorAll(".reveal").forEach((el) => observer.observe(el));

// Journey events (see analytics.js). Download clicks carry the release shown on the button, once known.
let releaseTag = null;
trackTaggedClicks((el) => (el.dataset.track === "Download" ? { version: releaseTag ?? "unknown" } : {}));
trackSectionViews(document.querySelectorAll("main section[id], main section[data-section]"));
trackFAQ(document.querySelectorAll(".faq details"));
trackCopies();
document.querySelectorAll("[data-analytics-note]").forEach((el) => { el.hidden = !analyticsEnabled; });

// GitHub stars and latest release. Failures leave the static labels in place.
const compact = (n) => (n >= 1000 ? `${(n / 1000).toFixed(n >= 10000 ? 0 : 1)}k` : String(n));
async function github(path) {
    const response = await fetch(`https://api.github.com/repos/${REPO}${path}`, { headers: { Accept: "application/vnd.github+json" } });
    if (!response.ok) throw new Error(String(response.status));
    return response.json();
}
github("").then((repo) => {
    if (typeof repo.stargazers_count !== "number") return;
    document.querySelectorAll("[data-stars]").forEach((el) => {
        el.textContent = `★ ${compact(repo.stargazers_count)}`;
        el.hidden = false;
    });
}).catch(() => {});
github("/releases/latest").then((release) => {
    const tag = /^v?\d+\.\d+\.\d+$/.test(release.tag_name ?? "") ? release.tag_name.replace(/^v/, "") : null;
    releaseTag = tag;
    if (tag) document.querySelectorAll("[data-download-label]").forEach((el) => { el.textContent = `Download ${tag} for macOS`; });
}).catch(() => {});
