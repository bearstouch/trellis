#!/usr/bin/env python3
"""Exercise actual bundle assembly/signing in isolation, without opening windows.

Usage: python3 scripts/test-feasibility-launcher.py <compiled Swift bin path>
"""
from pathlib import Path
import hashlib
import os
import shutil
import stat
import subprocess
import sys
import tempfile


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    products = Path(sys.argv[1]).resolve()
    project = Path(__file__).resolve().parent.parent
    if not (products / "Trellis").is_file():
        raise SystemExit("Build the app first and supply its Swift bin path.")
    with tempfile.TemporaryDirectory(prefix="trellis launcher ") as temporary:
        root = Path(temporary)
        (root / "scripts").mkdir()
        (root / ".build").mkdir()
        launcher = root / "scripts/run-feasibility.sh"
        shutil.copy2(project / "scripts/run-feasibility.sh", launcher)
        icon = root / "Design/AppIcon/AppIcon.icns"
        icon.parent.mkdir(parents=True)
        shutil.copy2(project / "Design/AppIcon/AppIcon.icns", icon)
        built = root / "Swift build products"
        built.mkdir()
        shutil.copy2(products / "Trellis", built / "Trellis")
        resources = built / "SwiftTerm_SwiftTerm.bundle"
        shutil.copytree(products / "SwiftTerm_SwiftTerm.bundle", resources)
        theme_resources = built / "Trellis_TrellisCore.bundle"
        shutil.copytree(products / "Trellis_TrellisCore.bundle", theme_resources)
        shader = resources / "Shaders.metal"
        shader.chmod(0o444)
        source_hash = digest(built / "Trellis")
        tools = root / "tools"
        tools.mkdir()
        (tools / "swift").write_text(
            '#!/bin/sh\nset -eu\n'
            'if [ "$*" = "build --configuration debug --show-bin-path" ]; then\n'
            '  printf "%s\\n" "$TRELLIS_TEST_PRODUCTS"\n'
            'elif [ "$*" != "build --configuration debug" ]; then\n'
            '  exit 2\nfi\n'
        )
        (tools / "open").write_text(
            '#!/bin/sh\nprintf "%s\\n" "$@" > "$TRELLIS_TEST_OPEN_LOG"\n'
        )
        for tool in tools.iterdir():
            tool.chmod(0o755)
        log = root / "open.log"
        env = dict(os.environ, PATH=str(tools) + ":" + os.environ["PATH"],
                   TRELLIS_TEST_PRODUCTS=str(built), TRELLIS_TEST_OPEN_LOG=str(log))
        destination = root / ".build/Trellis.app"
        executable = destination / "Contents/MacOS/Trellis"
        seal = destination / "Contents/_CodeSignature/CodeResources"

        def run(*arguments, success=True):
            result = subprocess.run(["sh", str(launcher), *arguments], env=env,
                                    capture_output=True, text=True)
            assert (result.returncode == 0) == success, result.stdout + result.stderr
            assert not list((root / ".build").glob("trellis-feasibility.*")), "staging was not cleaned"

        def verify():
            subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(destination)], check=True)
            assert seal.is_file(), "assembled app has no sealed resources"
            assert digest(built / "Trellis") == source_hash, "signing changed the Swift build product"
            assert stat.S_IMODE(shader.stat().st_mode) == 0o444
            assert (destination / "Contents/Resources/Trellis_TrellisCore.bundle/Themes/example-minimal.theme.json").is_file()
            assert digest(destination / "Contents/Resources/AppIcon.icns") == digest(icon)

        run("--build-only")
        verify()
        assert not log.exists(), "build-only opened an app"
        first_inode = executable.stat().st_ino
        run("--fixture", "argument with spaces")
        verify()
        assert executable.stat().st_ino != first_inode, "running executable was overwritten in place"
        assert log.read_text().splitlines() == [str(destination), "--args", "--fixture", "argument with spaces"]

        # A packaging failure must not replace a working, signed installation.
        before = (digest(executable), digest(seal), log.read_bytes())
        missing_resources = built / "missing-resources"
        resources.rename(missing_resources)
        run("--build-only", success=False)
        missing_resources.rename(resources)
        verify()
        assert before == (digest(executable), digest(seal), log.read_bytes())
        missing_themes = built / "missing-themes"
        theme_resources.rename(missing_themes)
        run("--build-only", success=False)
        missing_themes.rename(theme_resources)
        verify()
        assert before == (digest(executable), digest(seal), log.read_bytes())
    print("PASS: sealed fresh bundles, repeat assembly, read-only resources, unchanged source, argument forwarding, build-only, and failed-build preservation")


if __name__ == "__main__":
    main()
