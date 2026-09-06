#!/usr/bin/env bash
# Runner dbg-init guard (issue #329; the #268 incident class).
#
# `support/dbg` keeps its channel whitelist in process-global state that only
# `dbg.initFromEnv` fills. The two callers are `cli/main.zig` and
# `api/instance.zig:wasm_engine_new`; a `test/` runner that owns its own
# `pub fn main(init: std.process.Init)` and drives the engine in-process
# reaches neither, so every `ZWASM_DEBUG` channel is silently off in that
# lane. #328 put the one-line call at the top of 19 runners and nothing
# stopped a 20th from omitting it — `test/wasi/stdin_pipe_runner.zig` landed
# without it the next day (an exemption, as it turned out, but one nobody
# had been asked to decide).
#
# Unlike check_test_discovery.sh this asks no compiler: "does the file with an
# Init-taking main also call dbg.initFromEnv" is exact under grep, so it costs
# well under a second and sits in the core gate.
#
# A runner that cannot call it (no `zwasm` import — it spawns the CLI, which
# reads the env itself) or must not (its `main` never runs) carries
# `// DBG-INIT-EXEMPT: <reason>` on lines 1-5. The reasons live in the files,
# not here: a list in this script would outlive the file it names.
#
# Modes:
#   bash scripts/check_runner_dbg_init.sh          informational
#   bash scripts/check_runner_dbg_init.sh --gate   exit 1 on findings

set -euo pipefail
MODE="${1:-info}"
cd "$(dirname "$0")/.."

checked=0
exempt=0
findings=0
while IFS= read -r f; do
    checked=$((checked + 1))
    if head -n 5 "$f" | grep -qE 'DBG-INIT-EXEMPT: *[^[:space:]]'; then
        exempt=$((exempt + 1))
        continue
    fi
    # Anchored to the start of a statement line: a call inside a `//` comment
    # or a string literal is text, not a call, and must not satisfy the gate.
    # Zig has no block comments, so the line anchor is exact.
    if ! grep -qE '^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*\.)*dbg\.initFromEnv\(' "$f"; then
        echo "DARK-RUNNER: $f — owns pub fn main(init: std.process.Init) but never calls dbg.initFromEnv" >&2
        findings=$((findings + 1))
    fi
done < <(grep -rlE '^pub fn main\(init: std\.process\.Init\)' --include='*.zig' test/ | sort)

# An empty enumeration is the grep rotting, not a clean tree: the runners
# this guards are in test/ today and a green run over nothing proves nothing.
if [ "$checked" -eq 0 ]; then
    echo "[check_runner_dbg_init] FAIL — no test/ file with 'pub fn main(init: std.process.Init)' found; the pattern no longer matches the runners" >&2
    exit 1
fi

if [ "$findings" -gt 0 ]; then
    echo >&2
    echo "[check_runner_dbg_init] $findings runner(s) never call dbg.initFromEnv — add 'zwasm.support.dbg.initFromEnv(init.environ_map.get(\"ZWASM_DEBUG\"));' at the top of main, or mark the file '// DBG-INIT-EXEMPT: <reason>' on lines 1-5" >&2
    [ "$MODE" = "--gate" ] && exit 1
fi
echo "[check_runner_dbg_init] OK — $checked runner(s) checked, $exempt exempt, $findings dark" >&2
exit 0
