# Zone Dependency Rules — full detail

> **Doc-state**: ACTIVE. Reference (no `paths:` frontmatter → read on demand only). Stub: [`../rules/zone_deps.md`](../rules/zone_deps.md).

Auto-loaded when editing Zig source. Authoritative version of the
layering contract in ROADMAP §4.1 / §A1.

## Zone architecture (post-ADR-0023)

```
Zone 3: src/cli/                       -- CLI entry (cli/main.zig per ADR-0024) + argparse, subcommand
        src/api/                        -- C ABI export layer (wasm.h / wasi.h / zwasm.h)
                                        ↓ may import anything below

Zone 2: src/interp/                     -- Interpreter (while-loop dispatch over ZIR)
        src/engine/                     -- runner + codegen/{shared, arm64, x86_64, aot}
        src/wasi/                       -- WASI 0.1 implementation
                                        ↓ may import Zone 0+1

Zone 1: src/ir/                         -- ZIR + verifier + lower + analysis/
        src/runtime/                    -- Runtime + Module / Engine / Store / Value / Trap / Frame
                                           + instance/{instance, table, memory, global, func, element, data}
        src/parse/                      -- Parser / sections / ctx (wasm bytes → Module)
        src/validate/                   -- Validator (static type-stack + control-stack)
        src/instruction/                -- per-spec-version opcode handlers (registered into dispatch tables)
        src/feature/                    -- Per-VM-capability subsystems (SIMD, GC, EH, …)
        src/diagnostic/                 -- Cross-cutting Ousterhout deep module
                                        ↓ may import Zone 0 only

Zone 0: src/support/                    -- LEB128, dbg
        src/platform/                   -- Linux / Darwin / Windows / POSIX abstractions
                                        ↑ imports nothing above
```

## NEVER: upward imports

```
support/ + platform/  must NOT import from ir/, runtime/, parse/, validate/, instruction/, feature/, diagnostic/, interp/, engine/, wasi/, api/, cli/
Zone 1 (ir/, runtime/, parse/, validate/, instruction/, feature/, diagnostic/)
                       must NOT import from interp/, engine/, wasi/, api/, cli/
interp/ + engine/ + wasi/  must NOT import from api/, cli/
```

## Inter-zone-2 isolation

`engine/codegen/arm64/` and `engine/codegen/x86_64/` must NOT
import from each other (A3). Both share via `engine/codegen/shared/`
only. This keeps the per-arch backend independent and discoverable;
cross-arch dependency would defeat the W54-class bug detection
design.

## Feature module direction

`src/feature/<feature>/mod.zig` registers handlers into central
dispatch tables (`src/ir/dispatch_table.zig`). The main parser /
validator / interp / emitter NEVER `@import` a specific feature
module — they consult the dispatch table only. This is what enables
ROADMAP §4.5 / A12 (no pervasive build-time `if`-branching).

## When a lower zone needs to call a higher zone

Use the **VTable pattern**: the lower zone declares the type, the
higher zone injects function pointers at startup.

```zig
// Layer 0 (runtime/) declares only the type
pub const VTable = struct {
    exec: *const fn(*Instance, FuncIdx, []const Value) anyerror![]Value,
    compile: *const fn(*Instance, FuncIdx) anyerror!void,
};

// Layer 2 (interp/ or engine/codegen/) installs at startup
runtime.vtable = .{
    .exec = interp.exec,
    .compile = engine_codegen.compile,
};
```

This inverts the *compile-time* dependency direction while
preserving the logical call flow.

## Enforcement

`scripts/zone_check.sh` parses every `@import("…/foo.zig")` in the
source tree and flags upward-direction violations and cross-arch
imports (A3).

- `bash scripts/zone_check.sh` — informational; always exits 0.
- `bash scripts/zone_check.sh --strict` — exit 1 on any violation.
- `bash scripts/zone_check.sh --gate` — exit 1 if violation count
  exceeds the in-script BASELINE (currently 0).

Tests are exempt at two levels (D-017 codification):

1. **In-source test blocks**: everything after the first
   `test "…"` line OR the first `const testing = std.testing`
   declaration in a file is skipped (test code may legitimately
   cross zones; per Zig idiom the testing alias + per-test
   sibling/parent imports are usually declared in the
   test-helper section above the first `test "…"` block, so
   the earlier marker captures that region too).
2. **Files under `test/`**: not in the zone hierarchy at all.
   Test infrastructure (runners under `test/runners/*.zig`,
   `test/spec/*.zig`, `test/realworld/*.zig`, `test/wasi/*.zig`,
   `test/edge_cases/*.zig`) may import from any Zone freely —
   they routinely consume the Zone 3 `cli_run.runWasmCaptured`
   surface and the Zone 2 engine pipeline. `scripts/zone_check.sh
   --gate` only scans `src/`, enforcing this by tool-level
   exclusion. The `test/` exemption is **not opt-in via in-file
   marker**; it's structural — runner exe top-level code is
   intentional Zone-3-from-test-context usage, not a violation.
