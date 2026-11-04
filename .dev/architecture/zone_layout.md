# Zone layout — full architecture reference

> **Doc-state**: ACTIVE

> **Status**: living reference. The auto-loaded discipline rule
> [`.claude/rules/zone_deps.md`](../../.claude/rules/zone_deps.md)
> is the concise version Claude sees during source edits; this
> document is the fuller reference for contributors orienting on
> the substrate. ROADMAP [§4.1 / §A1] is the source of truth — if
> anything here disagrees with ROADMAP, ROADMAP wins.
>
> Landed at §9.12-G as Phase 10 entry-substrate prep.

## Why four zones (motivation)

zwasm v1 grew a tangled call graph where Zone-3-style ABI concerns
(C ABI lifecycle, opaque-handle invariants) reached into Zone-1
parser internals across phases. Late-phase regalloc and ABI
refactors (the W54-class bug family) became expensive because the
implicit-contract sprawl made every cross-cutting change risk a
regression in an unrelated layer.

zwasm v2's four-zone layering is the **day-1 prevention**:

- The `@import` direction is checked mechanically by
  `scripts/zone_check.sh`.
- Cross-zone calls in the legitimate-but-inverted direction (lower
  zone needs to invoke a higher zone) go through the
  **VTable inversion pattern** — the call flow is preserved but
  the compile-time `@import` graph stays acyclic.
- Per-arch backends (arm64 / x86_64 / aot) are forbidden to
  import each other (the **A3 inter-zone-2 isolation rule**) so
  W54-class drift can't reappear silently.

The mechanical enforcement is intentionally cheap: every Zig
source edit re-runs `scripts/zone_check.sh` informationally
(post-§9.12-G it becomes a `--gate` enforcement in
`gate_commit.sh`).

## The four zones

```
Zone 3 — Public surface (ABI, CLI)
        src/cli/                     CLI entry (ADR-0024) + argparse + subcommand
        src/api/                     C ABI export (wasm.h / wasi.h / zwasm.h)
                                     ↓ may import any lower zone

Zone 2 — Execution + system surfaces
        src/interp/                  Interpreter (while-loop dispatch over ZIR)
        src/engine/                  Compile orchestrator + codegen/{shared, arm64, x86_64, aot}
        src/wasi/                    WASI 0.1 host implementation
                                     ↓ may import Zone 0+1; NEVER api/ or cli/

Zone 1 — Module representation + runtime state
        src/ir/                      ZIR + verifier + lower + analysis/
        src/runtime/                 Runtime + Module/Engine/Store/Value/Trap/Frame + instance/{...}
        src/parse/                   Wasm bytes → Module (sections / init_expr / leb128 consumers)
        src/validate/                Validator (type-stack + control-stack)
        src/instruction/             Per-spec-version opcode handlers (Wasm 1.0 / 2.0 / 3.0)
        src/feature/                 Per-VM-capability subsystems (SIMD, GC, EH, …)
        src/diagnostic/              Cross-cutting Ousterhout deep module (error reporting)
                                     ↓ may import Zone 0 only

Zone 0 — Primitives + platform
        src/support/                 LEB128 + dbg
        src/platform/                Linux / Darwin / Windows / POSIX abstractions
                                     ↑ imports nothing above
```

## Forbidden directions (machine-checked)

`scripts/zone_check.sh` parses every `@import("…/foo.zig")` and
rejects:

- `Zone 0 → Zone 1+`: support/ and platform/ MUST NOT import from
  ir/, runtime/, parse/, validate/, instruction/, feature/,
  diagnostic/, interp/, engine/, wasi/, api/, cli/.
- `Zone 1 → Zone 2+`: ir/, runtime/, parse/, validate/,
  instruction/, feature/, diagnostic/ MUST NOT import from
  interp/, engine/, wasi/, api/, cli/.
- `Zone 2 → Zone 3`: interp/, engine/, wasi/ MUST NOT import from
  api/, cli/.

Current baseline: **0 violations**. The Phase 10 prep migration
flips this from informational to gate-enforcing.

## Inter-zone-2 isolation (A3)

`src/engine/codegen/arm64/` and `src/engine/codegen/x86_64/` MUST
NOT import from each other. Both share via
`src/engine/codegen/shared/` only. This isolation is what makes
W54-class bugs surface in one arch without silently propagating
to the other; the discoverability of the bug is a direct
consequence of the import graph shape.

`scripts/zone_check.sh` flags cross-arch imports as a distinct
violation class.

## Feature module direction (A12)

`src/feature/<feature>/mod.zig` modules register handlers into
central dispatch tables (`src/ir/dispatch_table.zig`). The main
parser / validator / interp / emitter pipeline NEVER `@import`s
a specific feature module — they consult the dispatch table only.

This pattern is what enables ROADMAP §4.5 / §A12 (no pervasive
build-time `if`-branching for feature gating): each feature's
handlers compile in via build options (per-op DCE) and register
their entries comptime; the main pipeline reads the table at
runtime with zero feature-awareness.

## VTable inversion pattern

When a lower zone needs to call a higher zone (e.g. `runtime/`
needs to invoke `interp.exec` or `engine_codegen.compile`),
the lower zone declares the type and the higher zone injects
function pointers at startup:

```zig
// Layer 1 (runtime/) declares only the type
pub const VTable = struct {
    exec: *const fn (*Instance, FuncIdx, []const Value) anyerror![]Value,
    compile: *const fn (*Instance, FuncIdx) anyerror!void,
};

// Layer 2 (interp/ or engine/codegen/) installs at startup
runtime.vtable = .{
    .exec = interp.exec,
    .compile = engine_codegen.compile,
};
```

This inverts the **compile-time** dependency direction
(`runtime/` no longer `@import`s `interp/` or `engine/`) while
preserving the logical call flow. The zone-check parser is
keyed on `@import` declarations, so VTable-mediated calls are
zero-cost to the layering invariant.

## Test exemptions (D-017)

`scripts/zone_check.sh --gate` enforces only on `src/`. Two
layers of exemption keep the test infrastructure unconstrained:

1. **In-source `test "..." { ... }` blocks** — everything after
   the first `test "…"` line OR the first
   `const testing = std.testing` declaration in a file is
   skipped. Test code may legitimately cross zones (a
   parser test importing a runtime fixture loader).
2. **Files under `test/`** — not in the zone hierarchy at all.
   Runners under `test/runners/*.zig`, `test/spec/*.zig`,
   `test/realworld/*.zig`, `test/wasi/*.zig`,
   `test/edge_cases/*.zig` may import from any zone freely.
   They routinely consume the Zone 3 `cli_run.runWasmCaptured`
   surface and the Zone 2 engine pipeline.

The `test/` exemption is **structural**, not opt-in via in-file
marker — runner exe top-level code is intentional
Zone-3-from-test-context usage, not a violation.

## Auto-generated artefacts

Auto-generated source files (per `// AUTO-GENERATED FROM <source>`
marker on lines 1-3) are exempt from the file-size cap (ROADMAP
§A2) but participate in the zone-check normally. The generator
itself is responsible for emitting layer-correct `@import` lines.

## Enforcement modes

`scripts/zone_check.sh` operates in three modes:

| Mode | Command | Exit | Use |
|---|---|---|---|
| informational | `bash scripts/zone_check.sh` | 0 always | local audit; surfaces but doesn't block |
| strict | `bash scripts/zone_check.sh --strict` | 1 on any violation | CI on PR diff |
| gate | `bash scripts/zone_check.sh --gate` | 1 if violations > `BASELINE` (currently 0) | pre-commit (post-§9.12-G migration) |

Pre-§9.12-G, `gate_commit.sh --fast` skipped `zone_check`
(delegated to `audit_scaffolding` periodically) per ADR-0076 D4.
The §9.12-G migration changes the default gate-commit path to
include `zone_check --gate`; the `--fast` skip is preserved as
the autonomous-loop override.

## When the rule dissolves or amends

The four-zone layering is load-bearing for the entire project
lifetime. Amendments (adding a new zone, reorganising the
subdirectory list, changing the import direction rules) require:

1. An ADR per ROADMAP §18.2 (this is a §4.1 / §A1 deviation
   per §18.3).
2. A `scripts/zone_check.sh` update + new BASELINE if any
   existing violations are grandfathered.
3. An update to `.claude/rules/zone_deps.md` AND this document
   in the same commit.
4. A regeneration of `audit_scaffolding §G` anchor commands
   that grep for the layering.

The most likely future amendment is Phase 12+ adding a Zone for
WASI-preview-2 / Component Model integration (where the new
ABI's lifecycle straddles current Zone 2 wasi/ and Zone 3 api/
roles); that's an architectural ADR, not a routine update.

## References

- ROADMAP §4.1 Four-zone layered architecture (source of truth)
- ROADMAP §A1 (P3 layered-architecture principle)
- ROADMAP §A3 (inter-zone-2 isolation)
- ROADMAP §A12 (dispatch-table indirection for feature gating)
- ADR-0023 (post-zone-redesign refactor — origin of current shape)
- ADR-0024 (cli/ entry point layout)
- `.claude/rules/zone_deps.md` (auto-loaded discipline rule)
- `scripts/zone_check.sh` (mechanical enforcement)
- D-017 (test-tree exemption codification)
