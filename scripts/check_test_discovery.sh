#!/usr/bin/env bash
# Test-discovery guard (sweep S5(c); the D-444/ADR-0207 II-2a incident class).
#
# Zig runs a file's named `test "…"` blocks only when the file participates
# in the test module's discovery graph — a plain `const x = @import(...)`
# whose namespace is only partially analyzed does NOT reliably pull tests
# in. `component_wasi_p2.zig` sat outside the graph and its in-file tests
# (including a pre-existing one) never ran in ANY test step.
#
# Rather than approximate the compiler's discovery rules statically, this
# guard asks the compiler: `zig build test-list` (a custom list runner over
# the default module, whose `-Dwasi=p3` is the maximal file set) prints every
# DISCOVERED test name; every named test block present under src/ must appear
# in that listing.
#
# A file whose tests intentionally live outside the core test module can
# carry `// TEST-DISCOVERY-EXEMPT: <reason>` on lines 1-5.
#
# Modes:
#   bash scripts/check_test_discovery.sh          informational
#   bash scripts/check_test_discovery.sh --gate   exit 1 on findings

set -euo pipefail
MODE="${1:-info}"
cd "$(dirname "$0")/.."

listing=$(mktemp)
trap 'rm -f "$listing"' EXIT
if ! zig build test-list > "$listing" 2>/dev/null; then
    echo "[check_test_discovery] FAIL — 'zig build test-list' did not run" >&2
    exit 1
fi
# Qualified names look like "<namespace>.test.<name>"; membership is checked
# on the raw <name> (first ".test." split).
sed -E 's/^.*\.test\.//' "$listing" | sort -u > "$listing.names"

# Name extraction + comparison in python: test names may contain escaped
# quotes/backslashes, which the listing prints raw.
findings=$(PYTHONIOENCODING=utf-8 python3 - "$listing.names" <<'PYEOF'
import re, sys, pathlib
# encoding is explicit: Zig sources and test names are UTF-8, but Python
# defaults to the locale codec (cp1252 on Windows) and would die on them.
names = set(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8').splitlines())
count = 0
for f in sorted(pathlib.Path('src').rglob('*.zig')):
    text = f.read_text(encoding='utf-8')
    head = "\n".join(text.splitlines()[:5])
    if 'TEST-DISCOVERY-EXEMPT' in head:
        continue
    for m in re.finditer(r'^test "((?:\\.|[^"\\])*)"', text, re.M):
        name = m.group(1).replace('\\"', '"').replace('\\\\', '\\')
        if name not in names:
            print(f'DEAD-TEST: {f} — test "{name}" is NOT discovered by any test step', file=sys.stderr)
            count += 1
print(count)
PYEOF
)
rm -f "$listing.names"

if [ "$findings" -gt 0 ]; then
    echo >&2
    echo "[check_test_discovery] $findings dead named test block(s) — wire the file into the test-discovery graph ('_ = @import(\"<file>\");' in src/zwasm.zig's test block or a discovered sibling's), or mark the file TEST-DISCOVERY-EXEMPT with a reason" >&2
    [ "$MODE" = "--gate" ] && exit 1
fi
echo "[check_test_discovery] OK" >&2
exit 0
