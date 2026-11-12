"""MkDocs hooks for the public docs build (mkdocs.public.yml only).

The public site is end-user documentation, not the behavior contract in docs/.

- A page in docs-public/pages/ replaces the docs/ page at the same path, or adds a new one. The user guide (home,
  getting started, features) lives there, written for people who use Trellis.
- Pages still taken from docs/ (the automation reference) lose what only matters to contributors: requirement IDs,
  requirement and verification sections, and ID tables.
- Only pages in the public nav are published; links from them to any other page point at the same file on GitHub.
"""

import posixpath
import re
from pathlib import Path

from mkdocs.structure.files import File

GITHUB_DOCS = "https://github.com/bearstouch/trellis/blob/master/docs/"
PAGES = Path(__file__).with_name("pages")
# Inline Markdown links and images to a relative .md target, with an optional #anchor.
LINK = re.compile(r"(\]\()([^)\s#:]+\.md)(#[^)\s]*)?(\))")

_ID = r"`?\b(?:FR|API2?|INT|MAC|EX)-[A-Z]*\d+[a-z]?\b`?"
# "(FR-W08)", "(API-01, API-02)", "(FR-RW02, FR-RW17)", "(`FR-A05`)".
ID_PARENS = re.compile(rf"\s*\(\s*{_ID}(?:\s*(?:,|and|/|–|-)\s*{_ID})*\s*\)")
# "the [API-06 code](errors.md)" → "the [error code](errors.md)".
ID_LINK_TEXT = re.compile(rf"\[{_ID} ([^\]]+)\]")
ID_BARE = re.compile(_ID)
CONTRACT_SECTIONS = re.compile(
    r"^(requirements|verification|contract acceptance|implementation notes.*|release verification|definition of done.*|milestones)$", re.I
)
ID_TABLE_HEADER = re.compile(r"^\|\s*ID\s*\|", re.I)

# An anchor to a heading whose requirement IDs were stripped: "#errors-api2-03" → "#errors".
ANCHOR_ID = re.compile(r"-(?:fr|api2?|int|mac|ex)-[a-z]*\d+[a-z]?(?=-|$)")

# Contributor pages with a user-guide equivalent: links to them go to the guide instead of GitHub.
GUIDE_FOR = {"release/README.md": ("getting-started.md", "#install-the-command-line-tool")}

_published: set[str] = set()


def _nav_pages(items):
    for item in items:
        value = next(iter(item.values())) if isinstance(item, dict) else item
        if isinstance(value, list): yield from _nav_pages(value)
        elif isinstance(value, str) and value.endswith(".md"): yield value


def on_files(files, config):
    # User guide pages from docs-public/pages replace (or add to) the docs/ pages at the same path.
    for path in sorted(PAGES.rglob("*.md")):
        uri = path.relative_to(PAGES).as_posix()
        if existing := files.get_file_from_path(uri): files.remove(existing)
        files.append(File(uri, str(PAGES), config["site_dir"], config["use_directory_urls"]))
    # The public nav is the allow-list: a page that isn't in it is never published, even if it isn't excluded.
    nav = set(_nav_pages(config["nav"]))
    for f in [f for f in files if f.is_documentation_page() and f.src_uri not in nav]: files.remove(f)
    _published.clear()
    _published.update(f.src_uri for f in files if f.is_documentation_page() and not f.inclusion.is_excluded())
    return files


def strip_contract(markdown):
    """Removes requirement IDs, contract-only sections and ID tables from a docs/ page. Code blocks are kept as is."""
    out, skip_level, in_code, in_id_table = [], None, False, False
    for line in markdown.split("\n"):
        if line.lstrip().startswith(("```", "~~~")): in_code = not in_code
        heading = None if in_code else re.match(r"^(#{1,6})\s+(.*?)\s*$", line)
        if heading:
            level, title = len(heading.group(1)), ID_PARENS.sub("", heading.group(2)).strip()
            if skip_level is not None and level <= skip_level: skip_level = None
            if skip_level is None and CONTRACT_SECTIONS.match(title): skip_level = level; continue
            line = f"{heading.group(1)} {title}"
        if skip_level is not None: continue
        if not in_code:
            if ID_TABLE_HEADER.match(line): in_id_table = True; continue
            if in_id_table:
                if line.startswith("|"): continue
                in_id_table = False
            line = ID_LINK_TEXT.sub(r"[\1]", line)
            line = ID_PARENS.sub("", line)
            line = ID_BARE.sub("", line) if ID_BARE.search(line) and not line.startswith("    ") else line
        out.append(line)
    return re.sub(r"\n{3,}", "\n\n", "\n".join(out))


def on_page_markdown(markdown, page, config, files):
    if not page.file.abs_src_path.startswith(str(PAGES)): markdown = strip_contract(markdown)

    base = posixpath.dirname(page.file.src_uri)

    def rewrite(m):
        target = posixpath.normpath(posixpath.join(base, m.group(2)))
        if target.startswith("../"):
            return m.group(0)
        if target in _published:
            anchor = m.group(3) or ""
            if not (PAGES / target).exists(): anchor = ANCHOR_ID.sub("", anchor)
            return f"{m.group(1)}{m.group(2)}{anchor}{m.group(4)}"
        if target in GUIDE_FOR:
            guide, anchor = GUIDE_FOR[target]
            return f"{m.group(1)}{posixpath.relpath(guide, base or '.')}{anchor}{m.group(4)}"
        return f"{m.group(1)}{GITHUB_DOCS}{target}{m.group(3) or ''}{m.group(4)}"

    return LINK.sub(rewrite, markdown)
