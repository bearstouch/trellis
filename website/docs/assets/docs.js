// Trellis user guide: header, sidebar, pager, table of contents, search, theme toggle.
(function () {
    "use strict";
    const DOCS = window.TRELLIS_DOCS;
    if (!DOCS) return;
    const body = document.body;
    const root = body.dataset.root || "";
    const current = body.dataset.page || "index.html";
    const pages = DOCS.groups.flatMap((g) => g.pages.map((p) => ({ ...p, group: g.title })));
    const local = pages.filter((p) => p.p);
    const url = (p) => (p.href ? p.href : root + p.p);
    const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
    const isMac = /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent);

    const icons = {
        menu: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" aria-hidden="true"><path d="M4 7h16M4 12h16M4 17h16"/></svg>',
        search: '<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" aria-hidden="true"><circle cx="11" cy="11" r="6.5"/><path d="m20 20-4.2-4.2"/></svg>',
        sun: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" aria-hidden="true"><circle cx="12" cy="12" r="4"/><path d="M12 2.5v2M12 19.5v2M4.6 4.6l1.4 1.4M18 18l1.4 1.4M2.5 12h2M19.5 12h2M4.6 19.4 6 18M18 6l1.4-1.4"/></svg>',
        moon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M20 14.5A8 8 0 1 1 9.5 4a6.5 6.5 0 0 0 10.5 10.5Z"/></svg>',
        auto: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true"><circle cx="12" cy="12" r="8"/><path d="M12 4a8 8 0 0 1 0 16Z" fill="currentColor"/></svg>',
        github: '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M12 2a10 10 0 0 0-3.2 19.5c.5.1.7-.2.7-.5v-1.7c-2.8.6-3.4-1.3-3.4-1.3-.5-1.2-1.1-1.5-1.1-1.5-.9-.6.1-.6.1-.6 1 .1 1.5 1 1.5 1 .9 1.5 2.4 1.1 2.9.8.1-.7.4-1.1.6-1.3-2.2-.3-4.6-1.1-4.6-5a3.9 3.9 0 0 1 1-2.7 3.6 3.6 0 0 1 .1-2.7s.8-.3 2.8 1a9.6 9.6 0 0 1 5 0c1.9-1.3 2.8-1 2.8-1 .5 1.4.2 2.4.1 2.7a3.9 3.9 0 0 1 1 2.7c0 3.9-2.4 4.7-4.6 5 .4.3.7.9.7 1.9V21c0 .3.2.6.7.5A10 10 0 0 0 12 2Z"/></svg>',
        download: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 4v11m0 0-4.5-4.5M12 15l4.5-4.5M5 19h14"/></svg>',
    };

    // Header
    const top = document.getElementById("topbar");
    if (top) {
        top.innerHTML =
            `<button class="icon-btn menu-btn" type="button" aria-label="Open navigation" aria-controls="sidebar" aria-expanded="false">${icons.menu}</button>` +
            `<a class="brand" href="${root}index.html"><img src="${root}assets/trellis.svg" alt="" width="28" height="28"><span>Trellis</span><span class="sub">Docs</span></a>` +
            `<button class="search-btn" type="button" aria-haspopup="dialog">${icons.search}<span class="label"><span class="label-long">Search docs…</span></span><kbd>${isMac ? "⌘" : "Ctrl "}K</kbd></button>` +
            `<nav class="topnav" aria-label="Site">` +
            `<a class="hide-sm" href="${DOCS.download}">${icons.download}<span>Download</span></a>` +
            `<a href="${DOCS.github}" aria-label="Trellis on GitHub">${icons.github}<span class="hide-sm">GitHub</span></a>` +
            `<button class="icon-btn theme-btn" type="button"></button></nav>`;
    }

    // Sidebar
    const side = document.getElementById("sidebar");
    if (side) {
        side.innerHTML = DOCS.groups
            .map((g) => {
                const items = g.pages
                    .map((p) => {
                        const cur = p.p === current ? ' aria-current="page"' : "";
                        const tag = p.tag ? `<span class="tag">${esc(p.tag)}</span>` : "";
                        return `<li><a href="${url(p)}"${cur}><span>${esc(p.t)}</span>${tag}</a></li>`;
                    })
                    .join("");
                return `<h2>${esc(g.title)}</h2><ul>${items}</ul>`;
            })
            .join("");
        const active = side.querySelector('[aria-current="page"]');
        if (active) active.scrollIntoView({ block: "center" });
        const menuBtn = top && top.querySelector(".menu-btn");
        const setNav = (open) => { body.classList.toggle("nav-open", open); if (menuBtn) menuBtn.setAttribute("aria-expanded", String(open)); };
        if (menuBtn) menuBtn.addEventListener("click", () => setNav(!body.classList.contains("nav-open")));
        document.addEventListener("click", (e) => { if (body.classList.contains("nav-open") && !side.contains(e.target) && !(menuBtn && menuBtn.contains(e.target))) setNav(false); });
        document.addEventListener("keydown", (e) => { if (e.key === "Escape") setNav(false); });
    }

    // Pager and footer
    const idx = local.findIndex((p) => p.p === current);
    const pager = document.getElementById("pager");
    if (pager && idx >= 0) {
        const prev = local[idx - 1], next = local[idx + 1];
        pager.setAttribute("aria-label", "Previous and next page");
        pager.innerHTML =
            (prev ? `<a class="prev" href="${url(prev)}" rel="prev"><small>← Previous</small>${esc(prev.t)}</a>` : "") +
            (next ? `<a class="next" href="${url(next)}" rel="next"><small>Next →</small>${esc(next.t)}</a>` : "");
        const foot = document.createElement("footer");
        foot.className = "page-foot";
        foot.innerHTML = `<span>Trellis user guide</span><a href="${DOCS.github}/edit/master/website/docs/${current}">Edit this page on GitHub</a>`;
        pager.after(foot);
    }

    // Heading anchors and the "On this page" list
    const doc = document.querySelector(".doc");
    const slug = (s) => s.toLowerCase().replace(/[^\w\s-]/g, "").trim().replace(/\s+/g, "-");
    const heads = doc ? Array.from(doc.querySelectorAll("h2, h3")) : [];
    heads.forEach((h) => {
        if (!h.id) h.id = slug(h.textContent);
        const a = document.createElement("a");
        a.className = "anchor"; a.href = "#" + h.id; a.textContent = "#"; a.setAttribute("aria-label", "Link to this section");
        h.appendChild(a);
    });
    const toc = document.getElementById("toc");
    if (toc && heads.length > 1) {
        toc.setAttribute("aria-label", "On this page");
        toc.innerHTML = "<h2>On this page</h2><ul>" +
            heads.map((h) => `<li><a href="#${h.id}" class="${h.tagName === "H3" ? "sub" : ""}">${esc(h.firstChild.textContent.trim())}</a></li>`).join("") + "</ul>";
        const links = new Map(Array.from(toc.querySelectorAll("a")).map((a) => [a.getAttribute("href").slice(1), a]));
        const spy = () => {
            let cur = heads[0];
            for (const h of heads) if (h.getBoundingClientRect().top < 120) cur = h;
            links.forEach((a) => a.classList.remove("active"));
            const a = links.get(cur.id); if (a) a.classList.add("active");
        };
        window.addEventListener("scroll", spy, { passive: true }); spy();
    }

    // Wrap tables for horizontal scrolling; copy buttons on code blocks
    if (doc) {
        doc.querySelectorAll("table").forEach((t) => {
            if (t.parentElement.classList.contains("table-wrap")) return;
            const w = document.createElement("div"); w.className = "table-wrap"; t.replaceWith(w); w.appendChild(t);
        });
        doc.querySelectorAll("pre").forEach((pre) => {
            const b = document.createElement("button");
            b.type = "button"; b.className = "copy-btn"; b.textContent = "Copy";
            b.addEventListener("click", async () => {
                const text = pre.querySelector("code") ? pre.querySelector("code").innerText : pre.innerText;
                try { await navigator.clipboard.writeText(text.replace(/^\$ /gm, "")); b.textContent = "Copied"; } catch { b.textContent = "Press ⌘C"; }
                setTimeout(() => (b.textContent = "Copy"), 1500);
            });
            pre.appendChild(b);
        });
    }

    // Theme: auto -> light -> dark
    const themeBtn = top && top.querySelector(".theme-btn");
    const getTheme = () => { try { return localStorage.getItem("trellis-docs-theme") || "auto"; } catch { return "auto"; } };
    const applyTheme = (t) => {
        if (t === "auto") document.documentElement.removeAttribute("data-theme"); else document.documentElement.setAttribute("data-theme", t);
        if (themeBtn) {
            themeBtn.innerHTML = icons[t === "light" ? "sun" : t === "dark" ? "moon" : "auto"];
            const label = `Appearance: ${t === "auto" ? "match system" : t}. Click to change.`;
            themeBtn.setAttribute("aria-label", label); themeBtn.title = label;
        }
    };
    applyTheme(getTheme());
    if (themeBtn) themeBtn.addEventListener("click", () => {
        const next = { auto: "light", light: "dark", dark: "auto" }[getTheme()];
        try { localStorage.setItem("trellis-docs-theme", next); } catch { /* storage unavailable: still switch for this view */ }
        applyTheme(next);
    });

    // Search over page titles, descriptions, keywords and section headings
    // Section headings come from assets/search-index.js (generated); without it, only this page's headings are searchable.
    const indexScript = document.createElement("script");
    indexScript.src = root + "assets/search-index.js"; indexScript.async = true;
    document.head.appendChild(indexScript);
    let entries = [];
    const buildEntries = () => {
        const sections = window.TRELLIS_SEARCH || {};
        entries = [];
        local.forEach((p) => {
            entries.push({ title: p.t, sub: p.group + " · " + p.d, href: url(p), hay: (p.t + " " + p.d + " " + (p.k || "")).toLowerCase(), weight: 2 });
            let hs = sections[p.p] || [];
            if (p.p === current && !hs.length) hs = heads.map((h) => [h.id, h.firstChild.textContent.trim()]);
            hs.forEach(([id, text]) => entries.push({ title: text, sub: p.t, href: url(p) + "#" + id, hay: (text + " " + p.t).toLowerCase(), weight: 1 }));
        });
    };

    const overlay = document.createElement("div");
    overlay.className = "search-overlay";
    overlay.innerHTML =
        '<div class="search-panel" role="dialog" aria-modal="true" aria-label="Search the docs">' +
        '<input type="search" placeholder="Search the docs" aria-label="Search the docs" role="combobox" aria-controls="search-results" aria-expanded="true" aria-autocomplete="list" autocomplete="off" spellcheck="false">' +
        '<ul class="search-results" id="search-results" role="listbox"></ul>' +
        '<div class="search-hint"><span><kbd>↑</kbd> <kbd>↓</kbd> to move</span><span><kbd>↩</kbd> to open</span><span><kbd>esc</kbd> to close</span></div></div>';
    body.appendChild(overlay);
    const input = overlay.querySelector("input");
    const list = overlay.querySelector(".search-results");
    let results = [], sel = 0, lastFocus = null;
    const mark = (s, q) => { const t = esc(s); if (!q) return t; const i = s.toLowerCase().indexOf(q); return i < 0 ? t : esc(s.slice(0, i)) + "<mark>" + esc(s.slice(i, i + q.length)) + "</mark>" + esc(s.slice(i + q.length)); };
    const render = () => {
        const q = input.value.trim().toLowerCase();
        const words = q.split(/\s+/).filter(Boolean);
        if (!words.length) results = local.map((p) => entries.find((e) => e.href === url(p))).slice(0, 12);
        else results = entries
            .map((e) => { if (!words.every((w) => e.hay.includes(w))) return null; const t = e.title.toLowerCase(); return { e, s: e.weight * 2 + (t.startsWith(q) ? 6 : t.includes(q) ? 3 : 0) }; })
            .filter(Boolean).sort((a, b) => b.s - a.s).slice(0, 20).map((r) => r.e);
        sel = 0;
        list.innerHTML = results.length
            ? results.map((r, i) => `<li role="option" id="sr-${i}" aria-selected="${i === sel}"><a href="${r.href}" tabindex="-1">${mark(r.title, words[0] || "")}<small>${esc(r.sub)}</small></a></li>`).join("")
            : `<li class="search-empty" role="option" aria-disabled="true">No results for “${esc(input.value)}”</li>`;
        input.setAttribute("aria-activedescendant", results.length ? "sr-0" : "");
    };
    const move = (d) => {
        if (!results.length) return;
        sel = (sel + d + results.length) % results.length;
        list.querySelectorAll("li").forEach((li, i) => li.setAttribute("aria-selected", String(i === sel)));
        const li = list.children[sel]; li.scrollIntoView({ block: "nearest" }); input.setAttribute("aria-activedescendant", li.id);
    };
    const open = () => { buildEntries(); lastFocus = document.activeElement; overlay.classList.add("open"); input.value = ""; render(); input.focus(); };
    const close = () => { overlay.classList.remove("open"); if (lastFocus) lastFocus.focus(); };
    input.addEventListener("input", render);
    input.addEventListener("keydown", (e) => {
        if (e.key === "ArrowDown") { e.preventDefault(); move(1); }
        else if (e.key === "ArrowUp") { e.preventDefault(); move(-1); }
        else if (e.key === "Enter" && results[sel]) { e.preventDefault(); close(); location.href = results[sel].href; }
        else if (e.key === "Escape") { e.preventDefault(); close(); }
        else if (e.key === "Tab") e.preventDefault();
    });
    list.addEventListener("click", (e) => { if (e.target.closest("a")) close(); });
    overlay.addEventListener("click", (e) => { if (e.target === overlay) close(); });
    const searchBtn = top && top.querySelector(".search-btn");
    if (searchBtn) searchBtn.addEventListener("click", open);
    document.addEventListener("keydown", (e) => {
        const typing = /INPUT|TEXTAREA|SELECT/.test(document.activeElement.tagName);
        if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") { e.preventDefault(); overlay.classList.contains("open") ? close() : open(); }
        else if (e.key === "/" && !typing && !overlay.classList.contains("open")) { e.preventDefault(); open(); }
    });
})();
