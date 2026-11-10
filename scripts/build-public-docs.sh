#!/bin/sh
# Builds the public docs (mkdocs.public.yml) into site-public/ for https://bearstouch.com/trellis/docs/.
# Needs python3 and curl. Uses .venv-docs/ with the pinned docs-public/requirements.txt.
set -eu
cd "$(dirname "$0")/.."

MERMAID_VERSION=11.17.2
MERMAID_SHA512=V6K3C8EBdEsPFZXSKMJe6ppQOENxuHARr9GvHX4hh47lAbhMRD9qf4oEK7LoaRQxULMa80/qt5gHO73aCleBBg==

if [ ! -x .venv-docs/bin/mkdocs ]; then python3 -m venv .venv-docs; fi
.venv-docs/bin/pip install --quiet --disable-pip-version-check -r docs-public/requirements.txt

.venv-docs/bin/mkdocs build --strict --clean --config-file mkdocs.public.yml

# Material would load Mermaid from unpkg, which the landing CSP blocks; ship a pinned, verified copy instead.
if grep -rlq 'class="mermaid"' site-public --include='index.html'; then
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    curl -fsSL "https://registry.npmjs.org/mermaid/-/mermaid-$MERMAID_VERSION.tgz" -o "$tmp/mermaid.tgz"
    actual=$(openssl dgst -sha512 -binary "$tmp/mermaid.tgz" | openssl base64 -A)
    if [ "$actual" != "$MERMAID_SHA512" ]; then echo "error: mermaid $MERMAID_VERSION tarball checksum mismatch" >&2; exit 1; fi
    tar -xzf "$tmp/mermaid.tgz" -C "$tmp" package/dist/mermaid.min.js
    cp "$tmp/package/dist/mermaid.min.js" site-public/assets/javascripts/mermaid.min.js
fi

# The landing CSP allows no inline or third-party scripts; fail here rather than on the live site.
if grep -rEl '<script>|<script [^>]*src="https?://' site-public --include='*.html'; then
    echo "error: inline or external <script> in the public docs (see files above)" >&2; exit 1
fi
if grep -rl 'fonts.googleapis.com' site-public --include='*.html'; then echo "error: Google Fonts link in the public docs" >&2; exit 1; fi
echo "Public docs built in site-public/"
