#!/usr/bin/env python3
"""Print explicit affected ExUnit paths + smoke; never fall back to all tests."""
import json
import re
import subprocess
import sys
from pathlib import Path


def git(*args):
    return subprocess.check_output(["git", *args], text=True, stderr=subprocess.DEVNULL)


def select(base, head):
    root = Path.cwd()
    tests = sorted(root.glob("apps/*/test/**/*_test.exs"))
    smoke = {
        "apps/pidro_engine/test/unit/card_test.exs",
        "apps/pidro_server/test/pidro_server_web/controllers/error_json_test.exs",
    }
    selected = {path for path in smoke if (root / path).is_file()}
    try:
        git("merge-base", "--is-ancestor", base, head)
        files = git("diff", "--name-only", "--no-renames", base, head).splitlines()
    except subprocess.CalledProcessError:
        print("Unknown change range: smoke only; impact/release coverage unverified", file=sys.stderr)
        return sorted(selected)

    # Follow module references transitively, including aliases and test support. This
    # is conservative static impact selection, not a claim to resolve dynamic dispatch.
    sources = {path: path.read_text() for path in root.glob("apps/**/*.ex")
               if "/lib/" in str(path) or "/test/support/" in str(path)}
    module_pattern = re.compile(r"\bdefmodule\s+([A-Z][\w.]*)")
    impacted = set()
    for file in files:
        path = root / file
        if path in tests:
            selected.add(file)
        if file.endswith(".ex"):
            # Read both sides so renamed/deleted modules still select their consumers.
            text = sources.get(path, "")
            try:
                text += "\n" + git("show", f"{base}:{file}")
            except subprocess.CalledProcessError:
                pass
            impacted.update(module_pattern.findall(text))

    while impacted:
        names = impacted | {module.rsplit(".", 1)[-1] for module in impacted}
        references = re.compile(r"(?<![\w.])(?:" + "|".join(map(re.escape, sorted(names))) + r")(?!\w)")
        added = set()
        for path, source in sources.items():
            if references.search(source):
                added.update(module_pattern.findall(source))
        if added <= impacted:
            break
        impacted.update(added)
    else:
        references = None

    changed_assets = {Path(file).name for file in files if not file.endswith((".md", ".ex", ".exs"))}
    for path in tests:
        source = path.read_text()
        if (references and references.search(source)) or any(name in source for name in changed_assets):
            selected.add(str(path.relative_to(root)))
        # Shared fixtures can affect an entire app, but never unrelated umbrella apps.
        if any((file.endswith("/test_helper.exs") or "/test/support/" in file)
               and file.split("/", 2)[:2] == list(path.relative_to(root).parts[:2])
               for file in files):
            selected.add(str(path.relative_to(root)))
    print(f"Feature selection: {len(selected)} affected/smoke files; full regression deferred", file=sys.stderr)
    return sorted(selected)


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        sys.exit("usage: python3 scripts/ci-affected.py BASE [HEAD]")
    print(json.dumps(select(sys.argv[1], sys.argv[2] if len(sys.argv) == 3 else "HEAD")))
