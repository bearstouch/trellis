import { init, track as send } from "@plausible-analytics/tracker";

// Plausible on the self-hosted instance named by PLAUSIBLE_HOST at build time. Without it every call
// is a no-op. Pageviews, scroll depth, time on page, outbound links and downloads come from the tracker;
// the events below fill in the journey between landing and the download.
const { host, domain } = __PLAUSIBLE__;
export const enabled = Boolean(host && domain);
if (enabled) init({ domain, endpoint: `${host}/api/event`, outboundLinks: true, fileDownloads: true, logging: false });

export function track(name, props = {}, { interactive = true } = {}) {
    if (enabled) send(name, { props, interactive });
}

// Links and buttons tagged data-track="Event" send that event; data-track-<key>="value" become props.
export function trackTaggedClicks(extraProps = () => ({})) {
    const onClick = (event) => {
        if (event.type === "auxclick" && event.button !== 1) return;
        const el = event.target.closest("[data-track]");
        if (!el) return;
        const props = {};
        for (const [key, value] of Object.entries(el.dataset)) {
            if (key.startsWith("track") && key !== "track") props[key[5].toLowerCase() + key.slice(6)] = value;
        }
        track(el.dataset.track, { ...props, ...extraProps(el) });
    };
    document.addEventListener("click", onClick);
    document.addEventListener("auxclick", onClick);
}

// One non-interactive "Section View" per section, when it reaches the middle of the viewport.
export function trackSectionViews(sections) {
    const seen = new IntersectionObserver((entries) => {
        for (const entry of entries) {
            if (!entry.isIntersecting) continue;
            seen.unobserve(entry.target);
            track("Section View", { section: entry.target.dataset.section || entry.target.id }, { interactive: false });
        }
    }, { rootMargin: "-45% 0px -45% 0px" });
    sections.forEach((section) => seen.observe(section));
}

// FAQ questions people open.
export function trackFAQ(items) {
    for (const item of items) {
        item.addEventListener("toggle", () => {
            if (item.open) track("FAQ Open", { question: item.querySelector("summary")?.textContent.trim() ?? "" });
        });
    }
}

// Copying a tagged snippet (data-snippet="name"), e.g. the CLI install command.
export function trackCopies() {
    document.addEventListener("copy", () => {
        const node = document.getSelection()?.anchorNode;
        const snippet = (node?.nodeType === Node.ELEMENT_NODE ? node : node?.parentElement)?.closest("[data-snippet]");
        if (snippet) track("Copy", { snippet: snippet.dataset.snippet });
    });
}
