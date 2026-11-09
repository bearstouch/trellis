// The one ordered list of pages. Sidebar, Previous/Next and search are all built from it.
// `p` is the path from the docs root, `t` the title, `d` a one-line description, `k` extra search keywords.
// Section headings for search live in search-index.js (python3 website/update-search-index.py).
window.TRELLIS_DOCS = {
    github: "https://github.com/bearstouch/trellis",
    download: "https://github.com/bearstouch/trellis/releases/latest",
    contract: "https://github.com/bearstouch/trellis/tree/master/docs",
    groups: [
        {
            title: "User guide",
            pages: [
                { p: "index.html", t: "Introduction", d: "What Trellis is and how it's organized", k: "overview about native terminal macos" },
                { p: "guide/getting-started.html", t: "Getting started", d: "Install Trellis and open your first space", k: "install dmg download requirements first launch tour cli" },
                { p: "guide/concepts.html", t: "Concepts", d: "Spaces, tabs, splits, panes and sessions", k: "model space tab pane session split broker stopped running" },
                { p: "guide/settings.html", t: "Settings", d: "Every section of the Settings window", k: "preferences appearance sessions broker keyboard themes agents automation remote control updates" },
                { p: "guide/keyboard-shortcuts.html", t: "Keyboard shortcuts", d: "Default shortcuts and how to change them", k: "keys bindings chords hotkeys rebind cmd option" },
                { p: "guide/troubleshooting.html", t: "Troubleshooting", d: "Fixes for common problems", k: "problems help recovery font keychain path broker reset" },
            ],
        },
        {
            title: "Features",
            pages: [
                { p: "features/workspace.html", t: "Spaces, tabs & splits", d: "Organize sessions in the sidebar", k: "space tab split pane rename color close maximize sidebar" },
                { p: "features/terminal.html", t: "Terminal", d: "Search, copy and paste, links, fonts", k: "find search paste review copy links ligatures images metal renderer scrollback" },
                { p: "features/shell-integration.html", t: "Shell integration", d: "zsh, bash and fish prompts and exit codes", k: "zsh bash fish prompt marks directory exit status osc" },
                { p: "features/projects.html", t: "Projects", d: "Reusable project layouts in the library", k: "project library launch clone git repositories import export" },
                { p: "features/tasks.html", t: "Tasks", d: "Run .trellis/launch.json tasks", k: "launch.json tasks run commands" },
                { p: "features/agents.html", t: "Coding agents", d: "Claude Code, Codex and pi side by side", k: "ai claude codex pi agent hooks needs you", tag: "Preview" },
                { p: "features/sidebar.html", t: "Right sidebar", d: "The dock of tools beside your panes", k: "dock right sidebar panels" },
                { p: "features/files.html", t: "Files", d: "Browse the focused project", k: "file tree finder editor path" },
                { p: "features/changes.html", t: "Changes", d: "Review and stage git changes", k: "git diff stage unstage review" },
                { p: "features/command-palette.html", t: "Command palette", d: "Every action in one list", k: "palette actions search shift cmd p" },
                { p: "features/directory-jump.html", t: "Directory jump", d: "Go back to recent directories", k: "jump directory cd frecency z" },
                { p: "features/scratchpad.html", t: "Scratchpad", d: "Write and run scripts beside your panes", k: "scratchpad script editor run" },
                { p: "features/ssh-hosts.html", t: "SSH hosts", d: "Saved hosts and ~/.ssh/config", k: "ssh host keychain password config connect" },
                { p: "features/remote-workspaces.html", t: "Remote workspaces", d: "Sessions that live on a remote host", k: "remote linux helper reconnect broker host space", tag: "Preview" },
                { p: "features/themes.html", t: "Themes", d: "Built-in themes and your own JSON themes", k: "colors theme json light dark opacity blur" },
                { p: "features/notifications.html", t: "Notifications", d: "Busy, input and desktop alerts", k: "notification bell busy needs input alert" },
            ],
        },
        {
            title: "Automation",
            pages: [
                { p: "automation/cli.html", t: "trellis CLI", d: "Control Trellis from your shell", k: "cli command line install link trellis" },
                { p: "automation/api.html", t: "Automation API", d: "Grants, the control socket and layouts", k: "api json-rpc socket grant token layout scripts" },
                { p: "automation/mcp.html", t: "MCP server", d: "Let agents drive Trellis", k: "mcp model context protocol agents remote control http" },
            ],
        },
        {
            title: "More",
            pages: [
                { p: "privacy.html", t: "Privacy & data", d: "What Trellis stores and sends", k: "privacy telemetry data files keychain updates uninstall" },
                { href: "https://github.com/bearstouch/trellis/blob/master/CHANGELOG.md", t: "Changelog", d: "What's new in each release", k: "release notes versions" },
            ],
        },
    ],
};
