"""Refuse any plugin in this public marketplace that is not on tools-allowlist.txt (MSD #53757 D25(1)).

The AI Momentum build already refuses to publish one; this is the second lock, run by GitHub on every
push and pull request, so a plugin added by hand or by a faulty build still cannot stay here unnoticed.
Usage: python3 .github/check_plugins.py [repository root]
"""
import json
import sys
from pathlib import Path

ALLOWLIST = "tools-allowlist.txt"


def problems(root: Path) -> list[str]:
    allow_file = root / ALLOWLIST
    if not allow_file.is_file():
        return [f"{ALLOWLIST} is missing, so no plugin may be listed here"]
    allowed = {line.strip() for line in allow_file.read_text().splitlines()
               if line.strip() and not line.lstrip().startswith("#")}
    found = []
    manifest = root / ".claude-plugin" / "marketplace.json"
    if manifest.is_file():
        try:
            found += [str(p.get("name")) for p in json.loads(manifest.read_text()).get("plugins") or []]
        except (ValueError, AttributeError) as e:
            return [f".claude-plugin/marketplace.json could not be read: {e}"]
    plugins = root / "plugins"
    if plugins.is_dir():
        found += [d.name for d in plugins.iterdir() if d.is_dir()]
    return [f"'{name}' is in this public marketplace but not in {ALLOWLIST}" for name in sorted(set(found) - allowed)]


if __name__ == "__main__":
    errors = problems(Path(sys.argv[1] if len(sys.argv) > 1 else "."))
    for error in errors:
        print(f"::error::{error}")
    print("OK: every plugin is on the allowlist" if not errors else f"{len(errors)} problem(s)")
    sys.exit(1 if errors else 0)
