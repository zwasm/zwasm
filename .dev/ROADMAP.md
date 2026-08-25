# zwasm v2 — ROADMAP

> **Status of this document**
>
> The single authoritative plan for this project. It collapses the mission,
> principles, architecture, scope, phase plan, quality bar, and future
> decision points onto one page. The standard rule applies:
> **if anything elsewhere disagrees with this file, this file wins.**
>
> Detailed implementation discussions presuppose this document. Anything
> that contradicts it must go through an ADR (`.dev/decisions/`); ad-hoc
> deviations are not allowed. ADRs exist to record **deviations from this
> roadmap discovered during development**, not founding decisions —
> founding decisions live in §1–§14 below.
>
> History lives in git — see `git log -- .dev/ROADMAP.md` for diffs and
> `.dev/decisions/` for load-bearing later decisions. The amendment
> process itself is §18.

---

## 0. Table of contents

1. [Mission and differentiation](#1-mission-and-differentiation)
2. [Inviolable principles](#2-inviolable-principles)
3. [Scope: what we build, what we do not](#3-scope-what-we-build-what-we-do-not)
4. [Architecture](#4-architecture)
5. [Directory layout (final form)](#5-directory-layout-final-form)
6. [WebAssembly proposal tier system](#6-webassembly-proposal-tier-system)
7. [Concurrency design](#7-concurrency-design)
8. [WASI strategy](#8-wasi-strategy)
9. [Phase plan](#9-phase-plan)
10. [CLI / FFI design](#10-cli--ffi-design)
11. [Test strategy](#11-test-strategy)
12. [Performance and benchmarks](#12-performance-and-benchmarks)
13. [Commit discipline and work loop](#13-commit-discipline-and-work-loop)
14. [Forbidden actions (inviolable)](#14-forbidden-actions-inviolable)
15. [Future go/no-go decision points](#15-future-gono-go-decision-points)
16. [References](#16-references)
17. [Glossary](#17-glossary)
18. [Amendment policy](#18-amendment-policy)

---

## 1. Mission and differentiation

### 1.1 Mission

**A from-scratch redesign of zwasm: a standalone WebAssembly runtime
in Zig 0.16.0 that ships WebAssembly 3.0 conformance, wasm-c-api
ecosystem compatibility, and a dual-backend (interpreter + JIT-arm64
+ JIT-x86) single-pass JIT, with clean architecture from day 1.**

- **Wasm 3.0 first-class**: every Phase-5 proposal (multi-value, SIMD-128,
  memory64, reference types, exception handling, tail call, WasmGC,
  function references, extended-const, relaxed-simd) is in the
  architecture from day 1, not retrofitted.
- **wasm-c-api conformance**: `wasm.h` is the primary C ABI;
  `zwasm.h` extensions are subordinate.
- **Single-pass JIT for both ARM64 and x86_64** with a shared mid-IR
  (ZIR). Same compiler pipeline for in-memory JIT and on-disk AOT.
- **Three-OS first-class**: macOS aarch64, Linux x86_64 and Windows
  x86_64 are all gated. CI's `ci-required` check runs every leg on every
  pull request and is the authority (ADR-0076 D9; all three blocking per
  ADR-0211 D3). Running a leg locally over SSH is an optional pre-flight
  (§11.5).
- **Differential-tested**: interpreter ↔ JIT-arm64 ↔ JIT-x86
  three-way equivalence is the primary correctness gate.
- **No backwards compatibility with v1**: breaking the v1 ABI is
  intentional, and **breaking changes to the surfaces (C API / Zig API /
  CLI) are allowed in service of the right design** (ADR-0156). A v1→v2
  migration guide exists (`docs/migration_v1_to_v2.md`); **there is no
  release the loop controls** — see §1.2 + Phase 16.

### 1.2 Completion line — industry-standard surfaces, breaking-allowed (ADR-0156)

**The endgame is 完成形, not a version.** The bar is clean final design +
good design + lightweight-yet-fast + full-featured + 100% spec — across the
runtime **and all consumer surfaces (C API / Zig API / CLI)** — measured
against **あるべき論 + industry standards** (wasm-c-api,
wasmtime/wasmer/wazero, the Wasm/WASI specs), **not v1 feature-by-feature
parity**. Breaking v1 is allowed; v1's full surface (esp. its CLI subcommand
/ flag sprawl) is **explicitly not a requirement**.

The **correctness floor** below is the industry-standard bar (it happens to
match what v1 also shipped — but it is required because it is the spec/
ecosystem bar, not because v1 had it):

| Surface (correctness floor) | Requirement                                                                                            |
|-----------------------------|--------------------------------------------------------------------------------------------------------|
| Wasm 3.0 (9 proposals)      | Complete                                                                                               |
| Wide arithmetic             | Complete                                                                                               |
| Custom page sizes           | Complete                                                                                               |
| Atomics / relaxed-SIMD      | Complete (instruction sets; threaded EXECUTION stays §3.3)                                            |
| WASI 0.1                    | Complete                                                                                               |
| **Component Model**         | **wasmtime-equivalent — SHIPPED** (ADR-0170/0181/0182; default-ON via `-Dwasi>=p2`, `-Dwasi=p1` = lean opt-out per ADR-0193; campaign closed 2026-06-13, corpus 158/0/0) |
| **WASI 0.2 (preview2)**     | **wasmtime-equivalent native host** (ADR-0170/0180; CLI world + fs + sockets-TCP shipped)              |
| **WASI 0.3 (preview3)**     | **released 2026-06-11; CM-async-based** (async func / stream / future) — **FULL COVERAGE** of all six 0.3.0 proposals (cli/clocks/random/filesystem/sockets/http), official corpus 45/45 green (§9.0 Front D / **D-335** / **ADR-0205** phases A–E complete; opt-in `-Dwasi=p3`) |
| 4-platform JIT              | aarch64-darwin / aarch64-linux / x86_64-linux / x86_64-windows                                         |
| Spec testsuite              | 100 %, 0 skip                                                                                          |
| **wasm-c-api conformance**  | **Standard `wasm.h`** (the interface wasmtime/wasmer follow) + minimal `wasi.h` / `zwasm.h` extensions |

The **surfaces (C / Zig / CLI)** are designed to the あるべき論 minimal,
industry-standard shape — breaking v1 freely. The CLI does NOT owe v1 its
`validate`/`inspect`/`features`/`wat`/`wasm` subcommands or its capability-flag
set; it ships the truly-necessary, simple form.

> **完成形 is the line, never a release date (ADR-0153 + ADR-0156).** A
> *measured* design/completeness/performance deficiency (e.g. D-265: the
> single-pass deterministic-slot regalloc was ~2.3× slower than v1 on
> loop-locals — closed by the register-homing campaign) is **scheduled as a
> correctness-first rework**, never deferred to "after a release." There is
> **no autonomous release**: the loop improves toward 完成形 indefinitely;
> tagging / publishing / any main cutover is a **manual, user-only act** and
> does not exist as a loop construct (§Phase 16).

### 1.3 Capability backlog (no version lines — ADR-0181)

> Version lines ("v0.1.0 scope", "v0.2.0 line") are RETIRED as planning
> constructs (ADR-0156 + ADR-0181): the loop drives capabilities toward the
> 完成形 bar; versions exist only as the user's manual tagging vocabulary.
> Already-landed former "v0.2 line" items (atomics / wide-arith /
> custom-page-sizes / relaxed-SIMD instruction sets; Component Model +
> WASI 0.2 native host, campaign active) moved into §1.2's floor.

Still genuinely not built (demand-driven; see §3.3):

- **Threaded EXECUTION** (shared memory + real threads; the atomics
  instruction set itself is shipped with single-threaded semantics).
- **Stack switching / WASI 0.3** — Phase 3 proposal; gates async/streams.
- **RISC-V / s390x backends** — separate ADR each when demand appears.

(The optimising tier is NOT here: single-pass is permanent — §3.2,
ADR-0153/0181.)

### 1.4 Differentiation (3 axes)

| # | Axis                             | Edge over the field                                                                                                                                          |
|---|----------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 1 | **Single-binary CLI + library**  | wasmtime is heavier (~12 MB), wasm3 is too small for production WASI. zwasm sits in the lean-but-complete zone.                                              |
| 2 | **wasm-c-api drop-in**           | Hosts already targeting wasmtime can swap zwasm in by relinking. v1 had no such property.                                                                    |
| 3 | **Dual-backend single-pass JIT** | Most lean runtimes (wasm3, zware) are interpreter-only. Most JIT runtimes (wasmtime, wasmer) carry CLIF. zwasm pairs interp + single-pass JIT under one ZIR. |

### 1.5 Project name and branch

- **Project name** in all public docs and the published artifact: `zwasm`.
- Binary name: `zwasm`. Package name: `zwasm`.
- Working directory: `~/Documents/MyProducts/zwasm/`.
- Branch: `main` is the trunk. Work lands on a `develop/<slug>` branch
  and merges by PR; `main` is ruleset-protected and CI's `ci-required`
  is the gate.
- v1 reference: tag `v1.11.1` in this repository's own history (read as a
  textbook only — see P10).

---

## 2. Inviolable principles

These do not change between phases. Changing one requires an ADR.

| #   | Principle                                    | Effect                                                                                                                                                                                         |
|-----|----------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| P1  | **WebAssembly spec is ground truth**         | Spec test fail / skip is a release-blocker. If a test breaks, the design is wrong, not the test.                                                                                               |
| P2  | **Library and CLI in one binary**            | Single `zwasm` binary serves `run` + `compile` (ADR-0159; validate/inspect/wat↔wasm are the ecosystem's job — wasm-tools/wabt — not owed by the runtime CLI).                                  |
| P3  | **Cold-start is the primary metric**         | Compile pipeline is single-pass (no SSA optimisation passes). AOT mode (Phase 12) is the second answer.                                                                                        |
| P4  | **Zig 0.16 idioms**                          | `std.Io` DI, `*std.Io.Writer`, `packed struct`, `comptime`, `@branchHint`. No `std.Thread.Mutex`, no `std.io.AnyWriter`.                                                                       |
| P5  | **link_libc=false, host-side**               | All host math via Zig builtins (LLVM intrinsics). No libm. No MSVCRT.                                                                                                                          |
| P6  | **Single-pass compilation**                  | Decode → ZIR → regalloc → emit, four linear passes per function. No multi-pass IR optimisation.                                                                                             |
| P7  | **Both backends are equal**                  | Any feature that exists in `jit_arm64/` exists in `jit_x86/`. No "ARM64-only" or "x86-only" implementations.                                                                                   |
| P8  | **wasm-c-api is the C ABI primary**          | `zwasm.h` extensions are subordinate. ABI breakage requires an ADR (with deprecation window).                                                                                                  |
| P9  | **Knowledge compression by ROADMAP and ADR** | ROADMAP narrates the project; ADRs justify deviations from it. There is no per-task / per-concept chapter cadence.                                                                             |
| P10 | **v1 stays untouched, but is not copied**    | v1 is frozen at tag `v1.11.1`; v2 work lands on `main` through `develop/<slug>` PRs. v1 source may be **read** as a textbook; **never copy-and-paste** — re-design every line.                   |
| P11 | **Three OS first-class**                     | macOS aarch64, Linux x86_64 and Windows x86_64 are all gated, by CI's `ci-required` check on every PR (ADR-0076 D9; all three legs blocking per ADR-0211 D3).                                   |
| P12 | **Differential testing is the oracle**       | Every test that runs a wasm module asserts `interp == jit` on the host's native backend. The two-platform gate (and Phase 14's CI matrix) gives `interp == jit_arm64 == jit_x86` transitively. |
| P13 | **Day-one ZIR sized for the full target**    | All Wasm 3.0 ops + Phase 3-4 proposal ops + JIT pseudo-ops are reserved as `ZirOp` slots from day 1. Implementation is staged; the type is not.                                                |
| P14 | **Optimisation lands last in commit order**  | Phases 1-10 = simplest correct implementation; perf work comes after correctness. Phase 15 MEASURED the v1 W43/W44/W45 ports as ~0-headroom (v2 emit already efficient) and instead closed the D-265 register-homing rework (ADR-0153). Optimising tier stays permanently out (§3.2).         |

### 2.1 Architecture rules (verifiable)

| #   | Rule                                                                                                                                                                         | Verified by                                         |
|-----|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------|
| A1  | Lower zones do not import upper zones                                                                                                                                        | `scripts/zone_check.sh --gate`                      |
| A2  | One file ≤ 1,000 lines (soft) / ≤ 2,000 lines (hard)                                                                                                                       | `scripts/file_size_check.sh`                        |
| A3  | Cross-arch backends do not import each other (`engine/codegen/arm64` ↔ `engine/codegen/x86_64`) per ADR-0023                                                                | `scripts/zone_check.sh --gate`                      |
| A4  | `ZIR.verify()` runs after every analysis pass                                                                                                                                | Inline in `src/ir/verifier.zig`; called per pass    |
| A5  | Differential test gates every wasm-execution test (Phase 7+)                                                                                                                 | `zig build test-all`                                |
| A6  | ADR is required for: layer/contract change, ZIR shape change, C ABI surface change, phase order change, regression allowance, tier promotion                                 | Reviewer checklist; pre-merge audit                 |
| A7  | CI's `ci-required` check is the merge gate; the local SSH fan-out is an optional pre-flight (ADR-0076 D9)                                                                     | `.github/workflows/ci.yml`, `scripts/ci_gate.sh`    |
| A8  | Windows x86_64 is verified natively on every PR by the blocking CI leg (ADR-0211 D3); release stays user-only (ADR-0156)                                                     | `.github/workflows/ci.yml` gate matrix              |
| A9  | Bench history is append-only                                                                                                                                                 | `bench/history.yaml` reviewed at every merge        |
| A10 | Spec test fail=0 / skip=0 is a merge gate (Phase 2+)                                                                                                                         | `zig build test-spec`                               |
| A11 | All paths are `snake_case`; no hyphens in file or directory names                                                                                                            | Reviewer; convention                                |
| A12 | Feature opcodes are added through dispatch-table registration, not pervasive build-time `if` branches                                                                        | §4.5 design                                        |
| A13 | v1 regression suite (test/wasmtime_misc/wast/ + 50 realworld + ClojureWasm guest) stays green from Phase 6 onward (ADR-0008; renamed per ADR-0012 §6.B)                     | `zig build test-wasmtime-misc-basic` + Phase-6 gate |

---

## 3. Scope: what we build, what we do not

### 3.1 In scope (the 完成形 correctness floor — no version gate, ADR-0181)

- Full WebAssembly 3.0 (all Phase 5 proposals — see §6).
- Wide arithmetic + custom page sizes (matching v1's coverage).
- WASI 0.1 (preview1) full surface.
- `wasm.h` (wasm-c-api) full conformance.
- `wasi.h` (wasmtime-compatible) full surface.
- `zwasm.h` extensions: the SANDBOXING set (fuel, wall-clock timeout /
  cancel, memory cap, trap-kind introspection) **shipped** 2026-06-12 as
  instance-level setters (ADR-0179 #3a-4); allocator injection + the
  fast-path invoke remain **deferred / on-demand** post-v0.1.0. The shipped
  C surface is `wasm.h` + `wasi.h` + `zwasm.h`.
- Single-pass JIT for `aarch64-darwin`, `aarch64-linux`,
  `x86_64-linux`, `x86_64-pc-windows`.
- AOT compilation (`zwasm compile foo.wasm -o foo.cwasm`).
- Spec test runner driven by `zig build test-spec`.
- E2E test harness for realworld wasm samples.
- Fuzz infrastructure: corpus + edge-case generator + differential
  fuzz + overnight campaign.
- Bench harness with append-only `bench/history.yaml` — deliberate
  multi-arch recordings (Mac + Linux; Windows timing deferred per
  ADR-0137/D-249) plus the nightly `bench_watch.yml` gross-regression
  watch (ADR-0211 D2; the per-merge convention is retired).

### 3.2 Out of scope permanently

- **Backwards compatibility with zwasm v1's `zwasm_module_t` API.**
  The v1 ABI is dropped; `docs/migration_v1_to_v2.md` exists (the release
  itself is user-only, ADR-0156).
- **Multi-tier / optimising JIT** (V8 Liftoff + TurboFan style;
  copy-and-patch, SSA mid-IR, cranelift-as-backend). **Single-pass is
  the design, permanently** (ADR-0153 P3/P6 inviolable + ADR-0181;
  user-confirmed positioning 2026-06-13: fast-start/fast-exit workloads
  are the strength — losing to multi-tier optimisers on long-running
  throughput is accepted).
- **Dynamic Wasm code generation** at runtime by the host (security).
- **JS Promise Integration / Web CSP / ESM Integration** (web-only
  proposals).

### 3.3 Deferred (demand-driven; no version gate — ADR-0181)

> Component Model, WASI 0.2, and the atomics/relaxed-SIMD instruction
> sets graduated OUT of this list (shipped — §1.2 floor). **WASI 0.3 also
> graduated out** (ratified 2026-06-11; CM-async-based, builds on the shipped
> CM substrate → §9.0 Front D / D-335 — an actionable front, not deferred).
> The optimising tier moved to §3.2 (permanently out).

- **Threaded EXECUTION** (shared memory + spawning; the atomics
  instruction set is shipped single-threaded): after CM/P2 settles.
- **Stack switching (CORE continuations)**: core-wasm proposal, still
  pre-Phase-4 (format evolving 2026-06). Genuinely-future (D-300). NOTE: it does
  NOT gate WASI 0.3 — that was the old (wrong) assumption; WASI 0.3 async is
  CM-based, separable.
- **Shared-everything threads**: Phase 1 proposal; watch.
- **wasi:sockets listeners/UDP/name-lookup** (ADR-0180 Phases 2–3) +
  **fs `*-via-stream` minting**: typed not-supported today; on demand.
- **RISC-V / s390x backends**: separate ADR each.

---

## 4. Architecture

### 4.1 Four-zone layered (absolute dependency direction)

```
Zone 3: src/cli/                          -- CLI entry (cli/main.zig per ADR-0024) + subcommand
        src/api/                          -- C ABI export layer (wasm.h / wasi.h / zwasm.h impl)
                                          ↓ may import anything below

Zone 2: src/engine/                       -- runner + interp loop + codegen (shared / arm64 / x86_64 / aot)
        src/feature/                      -- VM-capability extensions: simd_128 / gc / exception_handling / tail_call / function_references / memory64 / threads (reserved) / stack_switching (reserved) / component (reserved)
        src/instruction/                  -- Stateless opcode impls grouped by Wasm version (wasm_1_0 / wasm_2_0 / wasm_3_0)
        src/wasi/                         -- WASI preview1 implementation
        src/diagnostic/                   -- Cross-cutting: Diagnostic + trace
                                          ↓ may import Zone 0+1

Zone 1: src/ir/                           -- ZIR + dispatch table type + lower + verifier + analysis (loop_info / liveness / const_prop)
        src/runtime/                      -- WASM Spec §4.2 Runtime Structure: Runtime / Engine / Store / Module / Value / Trap / Frame + instance/{instance, memory, table, global, func, element, data}
        src/parse/                        -- Parser + sections + ctx (wasm bytes → structured Module)
        src/validate/                     -- Validator (type stack + control stack)
                                          ↓ may import Zone 0 only

Zone 0: src/support/                      -- dbg, leb128 (minimal specific helpers)
        src/platform/                     -- jit_mem, signal, fs, time (OS abstractions)
                                          ↑ imports nothing above
```

Enforcement: `scripts/zone_check.sh --gate` parses every `@import`
and rejects upward-direction violations. Cross-arch
(`engine/codegen/arm64` ↔ `engine/codegen/x86_64`) imports are
also rejected (A3).

When Zone 0/1 needs to call Zone 2+ (rare), use the **VTable
pattern**: the lower zone declares the type, the upper zone installs
function pointers at startup.

### 4.2 ZIR (Zwasm Intermediate Representation) — full op catalogue

The architectural cornerstone (P13). Both the interpreter and the
JIT consume the same `ZirFunc`. Every op is reserved as a `ZirOp`
slot from day 1; implementation is staged across phases.

```zig
pub const ZirOp = enum(u16) {
    // ============================================================
    // Wasm 1.0 / MVP (the baseline)
    // ============================================================
    // control flow
    @"unreachable",
    @"nop",
    @"block",
    @"loop",
    @"if",
    @"else",
    @"end",
    @"br",
    @"br_if",
    @"br_table",
    @"return",
    @"call",
    @"call_indirect",

    // parametric
    @"drop",
    @"select",
    @"select_typed",   // ref-types-aware select

    // variable
    @"local.get",
    @"local.set",
    @"local.tee",
    @"global.get",
    @"global.set",

    // i32 const + arith + bit + cmp
    @"i32.const",
    @"i32.eqz", @"i32.eq", @"i32.ne",
    @"i32.lt_s", @"i32.lt_u", @"i32.gt_s", @"i32.gt_u",
    @"i32.le_s", @"i32.le_u", @"i32.ge_s", @"i32.ge_u",
    @"i32.clz", @"i32.ctz", @"i32.popcnt",
    @"i32.add", @"i32.sub", @"i32.mul",
    @"i32.div_s", @"i32.div_u", @"i32.rem_s", @"i32.rem_u",
    @"i32.and", @"i32.or", @"i32.xor",
    @"i32.shl", @"i32.shr_s", @"i32.shr_u", @"i32.rotl", @"i32.rotr",

    // i64 const + arith + bit + cmp
    @"i64.const",
    @"i64.eqz", @"i64.eq", @"i64.ne",
    @"i64.lt_s", @"i64.lt_u", @"i64.gt_s", @"i64.gt_u",
    @"i64.le_s", @"i64.le_u", @"i64.ge_s", @"i64.ge_u",
    @"i64.clz", @"i64.ctz", @"i64.popcnt",
    @"i64.add", @"i64.sub", @"i64.mul",
    @"i64.div_s", @"i64.div_u", @"i64.rem_s", @"i64.rem_u",
    @"i64.and", @"i64.or", @"i64.xor",
    @"i64.shl", @"i64.shr_s", @"i64.shr_u", @"i64.rotl", @"i64.rotr",

    // f32 const + arith + cmp
    @"f32.const",
    @"f32.eq", @"f32.ne", @"f32.lt", @"f32.gt", @"f32.le", @"f32.ge",
    @"f32.abs", @"f32.neg", @"f32.ceil", @"f32.floor", @"f32.trunc", @"f32.nearest", @"f32.sqrt",
    @"f32.add", @"f32.sub", @"f32.mul", @"f32.div", @"f32.min", @"f32.max", @"f32.copysign",

    // f64 const + arith + cmp
    @"f64.const",
    @"f64.eq", @"f64.ne", @"f64.lt", @"f64.gt", @"f64.le", @"f64.ge",
    @"f64.abs", @"f64.neg", @"f64.ceil", @"f64.floor", @"f64.trunc", @"f64.nearest", @"f64.sqrt",
    @"f64.add", @"f64.sub", @"f64.mul", @"f64.div", @"f64.min", @"f64.max", @"f64.copysign",

    // numeric conversion
    @"i32.wrap_i64",
    @"i32.trunc_f32_s", @"i32.trunc_f32_u",
    @"i32.trunc_f64_s", @"i32.trunc_f64_u",
    @"i64.extend_i32_s", @"i64.extend_i32_u",
    @"i64.trunc_f32_s", @"i64.trunc_f32_u",
    @"i64.trunc_f64_s", @"i64.trunc_f64_u",
    @"f32.convert_i32_s", @"f32.convert_i32_u",
    @"f32.convert_i64_s", @"f32.convert_i64_u",
    @"f32.demote_f64",
    @"f64.convert_i32_s", @"f64.convert_i32_u",
    @"f64.convert_i64_s", @"f64.convert_i64_u",
    @"f64.promote_f32",
    @"i32.reinterpret_f32",
    @"i64.reinterpret_f64",
    @"f32.reinterpret_i32",
    @"f64.reinterpret_i64",

    // memory load / store (i32 / i64 / f32 / f64)
    @"i32.load", @"i64.load", @"f32.load", @"f64.load",
    @"i32.load8_s", @"i32.load8_u", @"i32.load16_s", @"i32.load16_u",
    @"i64.load8_s", @"i64.load8_u", @"i64.load16_s", @"i64.load16_u",
    @"i64.load32_s", @"i64.load32_u",
    @"i32.store", @"i64.store", @"f32.store", @"f64.store",
    @"i32.store8", @"i32.store16",
    @"i64.store8", @"i64.store16", @"i64.store32",
    @"memory.size", @"memory.grow",

    // ============================================================
    // Wasm 2.0 additions (sign-extension, sat-trunc, bulk memory, ref types)
    // ============================================================
    // sign extension
    @"i32.extend8_s", @"i32.extend16_s",
    @"i64.extend8_s", @"i64.extend16_s", @"i64.extend32_s",

    // saturating truncation
    @"i32.trunc_sat_f32_s", @"i32.trunc_sat_f32_u",
    @"i32.trunc_sat_f64_s", @"i32.trunc_sat_f64_u",
    @"i64.trunc_sat_f32_s", @"i64.trunc_sat_f32_u",
    @"i64.trunc_sat_f64_s", @"i64.trunc_sat_f64_u",

    // bulk memory
    @"memory.copy", @"memory.fill", @"memory.init",
    @"data.drop",
    @"table.copy", @"table.init",
    @"elem.drop",

    // reference types
    @"ref.null", @"ref.is_null", @"ref.func",
    @"table.get", @"table.set", @"table.size", @"table.grow", @"table.fill",

    // ============================================================
    // Wasm 2.0: SIMD-128 (~236 ops total)
    // ============================================================
    // load / store
    @"v128.load", @"v128.store",
    @"v128.load8x8_s", @"v128.load8x8_u",
    @"v128.load16x4_s", @"v128.load16x4_u",
    @"v128.load32x2_s", @"v128.load32x2_u",
    @"v128.load8_splat", @"v128.load16_splat", @"v128.load32_splat", @"v128.load64_splat",
    @"v128.load32_zero", @"v128.load64_zero",
    @"v128.load8_lane", @"v128.load16_lane", @"v128.load32_lane", @"v128.load64_lane",
    @"v128.store8_lane", @"v128.store16_lane", @"v128.store32_lane", @"v128.store64_lane",

    // const / shuffle / lane
    @"v128.const",
    @"i8x16.shuffle", @"i8x16.swizzle",
    @"i8x16.splat", @"i16x8.splat", @"i32x4.splat", @"i64x2.splat",
    @"f32x4.splat", @"f64x2.splat",
    @"i8x16.extract_lane_s", @"i8x16.extract_lane_u", @"i8x16.replace_lane",
    @"i16x8.extract_lane_s", @"i16x8.extract_lane_u", @"i16x8.replace_lane",
    @"i32x4.extract_lane", @"i32x4.replace_lane",
    @"i64x2.extract_lane", @"i64x2.replace_lane",
    @"f32x4.extract_lane", @"f32x4.replace_lane",
    @"f64x2.extract_lane", @"f64x2.replace_lane",

    // i8x16 cmp + arith + bit
    @"i8x16.eq", @"i8x16.ne",
    @"i8x16.lt_s", @"i8x16.lt_u", @"i8x16.gt_s", @"i8x16.gt_u",
    @"i8x16.le_s", @"i8x16.le_u", @"i8x16.ge_s", @"i8x16.ge_u",
    @"i8x16.abs", @"i8x16.neg", @"i8x16.popcnt",
    @"i8x16.all_true", @"i8x16.bitmask",
    @"i8x16.narrow_i16x8_s", @"i8x16.narrow_i16x8_u",
    @"i8x16.shl", @"i8x16.shr_s", @"i8x16.shr_u",
    @"i8x16.add", @"i8x16.add_sat_s", @"i8x16.add_sat_u",
    @"i8x16.sub", @"i8x16.sub_sat_s", @"i8x16.sub_sat_u",
    @"i8x16.min_s", @"i8x16.min_u", @"i8x16.max_s", @"i8x16.max_u",
    @"i8x16.avgr_u",

    // i16x8 cmp + arith + bit
    @"i16x8.eq", @"i16x8.ne",
    @"i16x8.lt_s", @"i16x8.lt_u", @"i16x8.gt_s", @"i16x8.gt_u",
    @"i16x8.le_s", @"i16x8.le_u", @"i16x8.ge_s", @"i16x8.ge_u",
    @"i16x8.abs", @"i16x8.neg",
    @"i16x8.q15mulr_sat_s",
    @"i16x8.all_true", @"i16x8.bitmask",
    @"i16x8.narrow_i32x4_s", @"i16x8.narrow_i32x4_u",
    @"i16x8.extend_low_i8x16_s", @"i16x8.extend_high_i8x16_s",
    @"i16x8.extend_low_i8x16_u", @"i16x8.extend_high_i8x16_u",
    @"i16x8.shl", @"i16x8.shr_s", @"i16x8.shr_u",
    @"i16x8.add", @"i16x8.add_sat_s", @"i16x8.add_sat_u",
    @"i16x8.sub", @"i16x8.sub_sat_s", @"i16x8.sub_sat_u",
    @"i16x8.mul",
    @"i16x8.min_s", @"i16x8.min_u", @"i16x8.max_s", @"i16x8.max_u",
    @"i16x8.avgr_u",
    @"i16x8.extmul_low_i8x16_s", @"i16x8.extmul_high_i8x16_s",
    @"i16x8.extmul_low_i8x16_u", @"i16x8.extmul_high_i8x16_u",

    // i32x4 cmp + arith + bit
    @"i32x4.eq", @"i32x4.ne",
    @"i32x4.lt_s", @"i32x4.lt_u", @"i32x4.gt_s", @"i32x4.gt_u",
    @"i32x4.le_s", @"i32x4.le_u", @"i32x4.ge_s", @"i32x4.ge_u",
    @"i32x4.abs", @"i32x4.neg",
    @"i32x4.all_true", @"i32x4.bitmask",
    @"i32x4.extend_low_i16x8_s", @"i32x4.extend_high_i16x8_s",
    @"i32x4.extend_low_i16x8_u", @"i32x4.extend_high_i16x8_u",
    @"i32x4.shl", @"i32x4.shr_s", @"i32x4.shr_u",
    @"i32x4.add", @"i32x4.sub", @"i32x4.mul",
    @"i32x4.min_s", @"i32x4.min_u", @"i32x4.max_s", @"i32x4.max_u",
    @"i32x4.dot_i16x8_s",
    @"i32x4.extmul_low_i16x8_s", @"i32x4.extmul_high_i16x8_s",
    @"i32x4.extmul_low_i16x8_u", @"i32x4.extmul_high_i16x8_u",
    @"i32x4.trunc_sat_f32x4_s", @"i32x4.trunc_sat_f32x4_u",
    @"i32x4.trunc_sat_f64x2_s_zero", @"i32x4.trunc_sat_f64x2_u_zero",

    // i64x2 cmp + arith + bit
    @"i64x2.eq", @"i64x2.ne",
    @"i64x2.lt_s", @"i64x2.gt_s", @"i64x2.le_s", @"i64x2.ge_s",
    @"i64x2.abs", @"i64x2.neg",
    @"i64x2.all_true", @"i64x2.bitmask",
    @"i64x2.extend_low_i32x4_s", @"i64x2.extend_high_i32x4_s",
    @"i64x2.extend_low_i32x4_u", @"i64x2.extend_high_i32x4_u",
    @"i64x2.shl", @"i64x2.shr_s", @"i64x2.shr_u",
    @"i64x2.add", @"i64x2.sub", @"i64x2.mul",
    @"i64x2.extmul_low_i32x4_s", @"i64x2.extmul_high_i32x4_s",
    @"i64x2.extmul_low_i32x4_u", @"i64x2.extmul_high_i32x4_u",

    // f32x4 / f64x2 cmp + arith
    @"f32x4.eq", @"f32x4.ne", @"f32x4.lt", @"f32x4.gt", @"f32x4.le", @"f32x4.ge",
    @"f32x4.abs", @"f32x4.neg", @"f32x4.sqrt",
    @"f32x4.add", @"f32x4.sub", @"f32x4.mul", @"f32x4.div",
    @"f32x4.min", @"f32x4.max", @"f32x4.pmin", @"f32x4.pmax",
    @"f32x4.ceil", @"f32x4.floor", @"f32x4.trunc", @"f32x4.nearest",
    @"f32x4.convert_i32x4_s", @"f32x4.convert_i32x4_u",
    @"f32x4.demote_f64x2_zero",

    @"f64x2.eq", @"f64x2.ne", @"f64x2.lt", @"f64x2.gt", @"f64x2.le", @"f64x2.ge",
    @"f64x2.abs", @"f64x2.neg", @"f64x2.sqrt",
    @"f64x2.add", @"f64x2.sub", @"f64x2.mul", @"f64x2.div",
    @"f64x2.min", @"f64x2.max", @"f64x2.pmin", @"f64x2.pmax",
    @"f64x2.ceil", @"f64x2.floor", @"f64x2.trunc", @"f64x2.nearest",
    @"f64x2.convert_low_i32x4_s", @"f64x2.convert_low_i32x4_u",
    @"f64x2.promote_low_f32x4",

    // v128 bit / boolean
    @"v128.not", @"v128.and", @"v128.andnot", @"v128.or", @"v128.xor",
    @"v128.bitselect", @"v128.any_true",

    // ============================================================
    // Wasm 3.0 additions
    // ============================================================
    // memory64 — uses the same load/store ops with a memarg flag indicating 64-bit offset
    // (no new opcodes, but the memarg encoding carries `is_64`)
    @"memory.size_64",
    @"memory.grow_64",

    // exception handling
    @"try_table",
    @"throw",
    @"throw_ref",

    // tail call
    @"return_call",
    @"return_call_indirect",
    @"return_call_ref",

    // function references
    @"call_ref",
    @"ref.as_non_null",
    @"br_on_null",
    @"br_on_non_null",

    // GC: struct
    @"struct.new",
    @"struct.new_default",
    @"struct.get",
    @"struct.get_s",
    @"struct.get_u",
    @"struct.set",

    // GC: array
    @"array.new",
    @"array.new_default",
    @"array.new_fixed",
    @"array.new_data",
    @"array.new_elem",
    @"array.get",
    @"array.get_s",
    @"array.get_u",
    @"array.set",
    @"array.len",
    @"array.fill",
    @"array.copy",
    @"array.init_data",
    @"array.init_elem",

    // GC: ref / cast / extern conversion
    @"ref.test",
    @"ref.test_null",
    @"ref.cast",
    @"ref.cast_null",
    @"br_on_cast",
    @"br_on_cast_fail",
    @"any.convert_extern",
    @"extern.convert_any",

    // GC: i31
    @"ref.i31",
    @"i31.get_s",
    @"i31.get_u",

    // extended-const  (no new opcodes; const expression extension)

    // relaxed-simd
    @"i8x16.relaxed_swizzle",
    @"i32x4.relaxed_trunc_f32x4_s", @"i32x4.relaxed_trunc_f32x4_u",
    @"i32x4.relaxed_trunc_f64x2_s_zero", @"i32x4.relaxed_trunc_f64x2_u_zero",
    @"f32x4.relaxed_madd", @"f32x4.relaxed_nmadd",
    @"f64x2.relaxed_madd", @"f64x2.relaxed_nmadd",
    @"i8x16.relaxed_laneselect", @"i16x8.relaxed_laneselect",
    @"i32x4.relaxed_laneselect", @"i64x2.relaxed_laneselect",
    @"f32x4.relaxed_min", @"f32x4.relaxed_max",
    @"f64x2.relaxed_min", @"f64x2.relaxed_max",
    @"i16x8.relaxed_q15mulr_s",
    @"i16x8.relaxed_dot_i8x16_i7x16_s",
    @"i32x4.relaxed_dot_i8x16_i7x16_add_s",

    // wide arithmetic (matched to v1's coverage)
    @"i64.add128", @"i64.sub128",
    @"i64.mul_wide_s", @"i64.mul_wide_u",

    // custom page sizes (memory.discard + size variant tracked via memarg)
    @"memory.discard",

    // ============================================================
    // Phase 3-4 proposals — slots reserved, implementation deferred
    // ============================================================
    // threads / atomics
    @"memory.atomic.notify",
    @"memory.atomic.wait32", @"memory.atomic.wait64",
    @"atomic.fence",
    @"i32.atomic.load", @"i32.atomic.load8_u", @"i32.atomic.load16_u",
    @"i64.atomic.load", @"i64.atomic.load8_u", @"i64.atomic.load16_u", @"i64.atomic.load32_u",
    @"i32.atomic.store", @"i32.atomic.store8", @"i32.atomic.store16",
    @"i64.atomic.store", @"i64.atomic.store8", @"i64.atomic.store16", @"i64.atomic.store32",
    @"i32.atomic.rmw.add", @"i32.atomic.rmw.sub", @"i32.atomic.rmw.and", @"i32.atomic.rmw.or", @"i32.atomic.rmw.xor", @"i32.atomic.rmw.xchg", @"i32.atomic.rmw.cmpxchg",
    @"i64.atomic.rmw.add", @"i64.atomic.rmw.sub", @"i64.atomic.rmw.and", @"i64.atomic.rmw.or", @"i64.atomic.rmw.xor", @"i64.atomic.rmw.xchg", @"i64.atomic.rmw.cmpxchg",
    // (i32.atomic.rmw8.* / rmw16.* / i64.atomic.rmw8.* / rmw16.* / rmw32.* — also reserved when threads lands)
    @"i32.atomic.rmw8.add_u", @"i32.atomic.rmw8.sub_u", @"i32.atomic.rmw8.and_u", @"i32.atomic.rmw8.or_u", @"i32.atomic.rmw8.xor_u", @"i32.atomic.rmw8.xchg_u", @"i32.atomic.rmw8.cmpxchg_u",
    @"i32.atomic.rmw16.add_u", @"i32.atomic.rmw16.sub_u", @"i32.atomic.rmw16.and_u", @"i32.atomic.rmw16.or_u", @"i32.atomic.rmw16.xor_u", @"i32.atomic.rmw16.xchg_u", @"i32.atomic.rmw16.cmpxchg_u",
    @"i64.atomic.rmw8.add_u", @"i64.atomic.rmw8.sub_u", @"i64.atomic.rmw8.and_u", @"i64.atomic.rmw8.or_u", @"i64.atomic.rmw8.xor_u", @"i64.atomic.rmw8.xchg_u", @"i64.atomic.rmw8.cmpxchg_u",
    @"i64.atomic.rmw16.add_u", @"i64.atomic.rmw16.sub_u", @"i64.atomic.rmw16.and_u", @"i64.atomic.rmw16.or_u", @"i64.atomic.rmw16.xor_u", @"i64.atomic.rmw16.xchg_u", @"i64.atomic.rmw16.cmpxchg_u",
    @"i64.atomic.rmw32.add_u", @"i64.atomic.rmw32.sub_u", @"i64.atomic.rmw32.and_u", @"i64.atomic.rmw32.or_u", @"i64.atomic.rmw32.xor_u", @"i64.atomic.rmw32.xchg_u", @"i64.atomic.rmw32.cmpxchg_u",

    // stack switching (continuations)
    @"cont.new",
    @"cont.bind",
    @"resume",
    @"resume_throw",
    @"suspend",
    @"switch",

    // memory-control (additional to Wasm 3.0 memory.discard)
    @"memory.protect",

    // ============================================================
    // Pseudo opcodes — JIT-internal, populated Phase 7+ (when JIT v1 lands)
    // ============================================================
    @"__pseudo.const_in_reg",
    @"__pseudo.loop_header",
    @"__pseudo.loop_back_edge",
    @"__pseudo.loop_end",
    @"__pseudo.bounds_check_elided",
    @"__pseudo.phi_block_param",
    @"__pseudo.spill_to_slot",
    @"__pseudo.reload_from_slot",
    @"__pseudo.inst_ptr_cache_set",
    @"__pseudo.vm_ptr_cache_set",
    @"__pseudo.simd_base_cache_set",
    @"__pseudo.frame_setup",
    @"__pseudo.frame_teardown",

    _,  // open enum — future additions land here without renumbering
};
```

**`ZirFunc` shape — slots reserved day-1, populated per phase**:

```zig
pub const ZirFunc = struct {
    // Always present from Phase 1
    func_idx: u32,
    sig: FuncType,
    locals: []ValType,
    instrs: ArrayList(ZirInstr),
    blocks: ArrayList(BlockInfo),
    branch_targets: ArrayList(u32),

    // Populated Phase 5+ (analysis layer)
    loop_info: ?LoopInfo = null,
    liveness: ?Liveness = null,
    constant_pool: ?ConstantPool = null,

    // Populated Phase 7+ (JIT register allocator)
    reg_class_hints: ?[]RegClass = null,
    spill_slots: ?[]SpillSlot = null,
    inst_ptr_cache_layout: ?CacheLayout = null,
    vm_ptr_cache_layout: ?CacheLayout = null,
    simd_base_cache_layout: ?CacheLayout = null,

    // Populated Phase 9+ (SIMD additional state)
    simd_lane_routing: ?LaneRouting = null,

    // Populated Phase 10+ (GC / EH / tail call additional state)
    gc_root_map: ?GcRootMap = null,
    eh_landing_pads: ?[]LandingPad = null,
    tail_call_sites: ?[]TailCallSite = null,

    // Populated Phase 15+ (optimisation passes)
    hoisted_constants: ?[]HoistedConst = null,
    bounds_check_elision_map: ?[]ElisionRecord = null,
    coalesced_movs: ?[]CoalesceRecord = null,

    pub fn verify(self: *const ZirFunc, alloc: Allocator) Error!void { ... }
};
```

`ZIR.verify()` runs after every analysis pass. Each backend may
register arch-specific invariants (ARM64, x86) into the verifier.
CI runs `verify()` across the spec corpus.

### 4.3 Engine pipeline — interpreter / JIT / AOT share one path

```
[wasm bytes]
   │
   ▼  src/parse/  (parser → sections → ctx)
[Module]
   │
   ▼  src/validate/ (validator)
[validated Module]
   │
   ▼  src/ir/lower.zig
[ZIR]
   │
   ▼  src/ir/analysis/ (loop_info → liveness → const_prop) + ir/verifier
[ZIR (annotated)]
   │
   ▼  src/engine/runner.zig (dispatch via runtime.vtable)
   │
   ├── engine = interpreter ─┐
   │                          ▼
   │                   src/engine/interp/loop.zig (threaded-code dispatch)
   │                          │
   │                          ▼  execute (handlers from instruction/ + feature/)
   │
   └── engine = jit ──────────┐
                              ▼
                       src/engine/codegen/shared/  (regalloc + reg_class + linker + compile)
                              │
                              ▼  src/engine/codegen/arm64/  or  src/engine/codegen/x86_64/  (emit)
                       [machine code]
                              │
                              ├── JIT mode: in-memory pages (mprotect + jump)
                              │              ▼  execute
                              │
                              └── AOT mode: src/engine/codegen/aot/ (format + linker)
                                            │
                                            ▼  serialise to .cwasm
                                            │
                                            ▼  load (mmap) → execute
```

**Key invariant**: JIT and AOT share the **same compiler pipeline**.
The only difference is the output sink — in-memory pages versus a
serialised `.cwasm` file. This avoids two compilers, ensures
differential equivalence, and makes the optimisation work in Phase
14 land in one place.

### 4.4 wasm-c-api layered C ABI

```
include/wasm.h     # upstream wasm-c-api copy, fetched and pinned
include/wasi.h     # wasmtime-compatible WASI extension
include/zwasm.h    # zwasm extensions (allocator inj, fuel, cancel, fast invoke)
```

Implementation (per ADR-0023):

```
src/api/wasm.zig          # implements wasm.h (was c_api/wasm_c_api.zig)
src/api/wasi.zig          # implements wasi.h (was c_api/wasi_c_api.zig)
src/api/zwasm.zig         # implements zwasm.h (was c_api/zwasm_ext.zig)
src/api/vec.zig           # wasm_*_vec_t lifecycle helpers
src/api/trap_surface.zig  # Trap → wasm_trap_t marshal
src/api/cross_module.zig  # cross-module funcref dispatch
src/zwasm.zig             # library root + zone re-export hub (per ADR-0024;
                          # subsumes the former api/lib_export.zig role).
```

Mass-generation of vec-type lifecycle functions via `comptime`:
60 functions from one helper template.

`wasm.h` is fetched by `scripts/fetch_wasm_c_api.sh` from
`WebAssembly/wasm-c-api` at a pinned commit. CI runs the
wasm-c-api conformance suite.

### 4.5 Feature modules and dispatch-table registration (A12)

A core architectural decision: **per-spec-feature opcodes do not
appear as `if (build_options.gc)` branches sprinkled across the
parser, validator, lowerer, interpreter, and emitters.** Instead,
opcode implementations are registered into central dispatch tables
at module-load time.

Per ADR-0023, opcode-bearing code is split along **two axes**:

- **`src/instruction/wasm_X_Y/<category>.zig`** — stateless opcode
  families that add new instructions but do not change the VM's
  capability model. File axis follows WASM Spec §5.4 categories
  (numeric / parametric / variable / memory / control / ...) for
  Wasm 1.0, and proposal names (sign_extension / nontrap_conversion
  / bulk_memory / ...) for Wasm 2.0+. Each `.zig` file exposes
  `pub fn register(*DispatchTable)`.
- **`src/feature/<X>/`** — VM-capability extensions that introduce
  new runtime-state types, new type-system axes, ABI changes, or
  wholesale changes to JIT output shape. Each subtree is
  self-contained (register entry + ops + state files +
  per-arch emit).

```
src/instruction/
├── wasm_1_0/                                     # §5.4 categories
│   ├── numeric_int.zig
│   ├── numeric_float.zig
│   ├── numeric_conversion.zig
│   ├── parametric.zig
│   ├── variable.zig
│   ├── memory.zig
│   └── control.zig
├── wasm_2_0/                                     # proposal names
│   ├── sign_extension.zig
│   ├── nontrap_conversion.zig
│   ├── multi_value.zig
│   ├── bulk_memory.zig
│   └── reference_types.zig
└── wasm_3_0/
    ├── extended_const.zig                        # doc-comment-only file
    ├── wide_arith.zig
    └── custom_page_sizes.zig

src/feature/                                      # VM-capability extensions
├── simd_128/                                     # SIMD-128 + relaxed-simd
├── gc/                                           # WasmGC (managed heap)
├── exception_handling/
├── tail_call/
├── function_references/
├── memory64/
├── threads/                                      # README-only reserved
├── stack_switching/                              # README-only reserved
└── component/                                    # README-only reserved
```

Within each `feature/<X>/`, the standard layout is:

```
register.zig                                  # pub fn register(*DispatchTable)
ops.zig                                       # interp dispatch handlers
<subsystem>_state.zig (multiple)              # subsystem-private state
arm64.zig                                     # arm64 emit handlers
x86_64.zig                                    # x86_64 emit handlers
```

Each feature module exposes a `register` function:

```zig
// src/feature/ext_3_0/gc/mod.zig
pub fn register(table: *DispatchTable) void {
    table.parsers[@intFromEnum(ZirOp.@"struct.new")] = parseStructNew;
    table.interp [@intFromEnum(ZirOp.@"struct.new")] = interpStructNew;
    table.jit_arm64[@intFromEnum(ZirOp.@"struct.new")] = emitArm64StructNew;
    table.jit_x86 [@intFromEnum(ZirOp.@"struct.new")] = emitX86StructNew;
    // ...
}
```

At startup, each enabled feature module's `register` is invoked
once. The main parser / validator / interp / JIT consult the
dispatch table and do not branch on feature flags — the table is
simply populated or not.

**Feature build flags** (§4.6) control which feature modules are
included in the build, not pervasive `if` branches.

### 4.6 Build flags — coarse and orthogonal

```
-Dwasm=3.0|2.0|1.0          (default 3.0; 2.0 omits Phase-9 features; 1.0 omits SIMD too)
-Dwasi=preview1             (default preview1 at v0.1.0; preview2 lights up post-v0.1.0)
-Dengine=both|jit|interp    (default both; selects which engines are compiled in)
-Daot=true|false            (default false at v0.1.0; lights up Phase 8+)
-Denable=<feature>          (per-feature toggle within feature/; granular opt-out)
-Dapi=c|none                (default c; -Dapi=none drops api/ subtree for embed-only builds)
-Doptimize=Debug|ReleaseFast|ReleaseSafe|ReleaseSmall  (Zig standard)
-Dstrip=true|false          (default false; strips debug info from the CLI binary)
-Dtrace-ringbuffer=true|false (default false; compile in Diagnostic M3-a trace per ADR-0028)
```

Source-separation principle (A12): each feature module is its own
directory; the build system includes/excludes the directory based
on flags. There is **no `if (gc_enabled)`** in the parser /
validator / interp / emitter. The dispatch table is populated only
if `feature/gc/register.zig` was compiled in.

Zig's `comptime` makes this clean: the build system passes the set
of enabled feature modules to a comptime-generated `register_all`
function that inlines each feature's `register` call.

### 4.7 Runtime handle + std.Io DI

The Runtime struct lives at `src/runtime/runtime.zig` per ADR-0023:

```zig
pub const Runtime = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    engine: Engine,         // wasm-c-api primary handle (runtime/engine.zig)
    stores: ArrayList(*Store),
    config: Config,         // fuel limit, timeout, allocator injection
    vtable: VTable,         // backend dispatch (engine/runner.zig dispatches via vtable)
};
```

`std.Io` is DI'd through every layer — no global mutexes, no
ambient I/O. The CLI (Zone 3) creates a `Runtime` and passes it
down. Tests construct a mock Runtime.

### 4.8 Float and SIMD strategy

- `link_libc = false` host-side (P5); all math via Zig builtins
  (`@sqrt`, `@ceil`, `@trunc`, `@round`) → LLVM intrinsics → SSE4.1
  / NEON.
- `f32.nearest` / `f64.nearest` (banker's rounding) implemented in
  `src/runtime/float.zig` (Zig `@round` is away-from-zero).
- `f32.min` / `f32.max` Wasm-NaN-propagating semantics implemented
  in `src/runtime/float.zig`.
- SIMD baseline: SSE4.1 (x86_64) and NEON (aarch64). SSE2-only
  fallback is rejected.

### 4.9 Memory model

- Linear memory is `mmap`-backed on POSIX, `VirtualAlloc` on Windows.
- Bounds check via guard pages (Phase 7+) — out-of-range access
  triggers `SIGSEGV` (POSIX) / `EXCEPTION_ACCESS_VIOLATION`
  (Windows), caught by the JIT's signal handler and converted to a
  Wasm trap.
- Memory64 is part of the ZIR shape from day 1; the implementation
  lights up in Phase 10.

### 4.10 GC subsystem (Phase 10+)

WasmGC adds heap-allocated typed values (struct, array, i31). Per
ADR-0023 the GC subsystem is vertically aggregated under
`src/feature/gc/` (state-heavy VM-capability extension):

- `register.zig` — `pub fn register(*DispatchTable)`
- `ops.zig` — `struct.*` / `array.*` / `ref.test` / `ref.cast` / `ref.i31` / `i31.get_*` handlers
- `heap.zig` — HeapHeader + 8-byte aligned tagged pointer scheme
- `arena.zig` — phase-scoped arena (Phase 1+, infrastructure only)
- `mark_sweep.zig` — mark-sweep collector (Phase 10+)
- `roots.zig` — root tracking (operand stack + locals + globals + tables)
- `type_hierarchy.zig` — struct / array subtyping + recursive types
- `arm64.zig`, `x86_64.zig` — per-arch emit handlers

GC values use a tagged pointer scheme (low 3 bits = type tag, since
heap is 8-byte aligned). i31ref is unboxed in the tag.

---

## 5. Directory layout (final form)

```
zwasm/
├── README.md                   # 1-line intro + build/test
├── LICENSE                     # Apache-2.0
├── CHANGELOG.md                # release notes
├── .claude/CLAUDE.md           # AI operational instructions
├── .github/                    # CI, issue/PR templates, community health
├── docs/                       # user-facing docs + examples
├── legal/                      # THIRD_PARTY.md
├── .envrc                      # use flake
├── .gitignore                  # zig-out, .zig-cache, private/, etc.
├── flake.nix                   # Zig 0.16.0 + hyperfine + yq + wabt
├── flake.lock                  # nix lock
├── build.zig                   # build script with -Dwasm / -Dwasi / -Dengine flags
├── build.zig.zon               # package metadata (real fingerprint)
│
├── include/
│   ├── wasm.h                  # upstream wasm-c-api (fetched, Phase 3+)
│   ├── wasi.h                  # WASI extension (Phase 4+)
│   └── zwasm.h                 # zwasm extensions (allocator inj Phase 4+; fuel/cancel Phase 7+)
│
├── src/                        # Per ADR-0023 + ADR-0024; see those ADRs for full per-file annotations.
│   ├── zwasm.zig               # Library root + zone re-export hub + self-import surface (per ADR-0024 D-1/D-2)
│   ├── parse/                  # WASM Binary Format → structured Module
│   │   ├── parser.zig
│   │   ├── sections.zig
│   │   └── ctx.zig
│   ├── validate/
│   │   └── validator.zig
│   ├── ir/                     # ZIR + analysis passes (loop_info / liveness / const_prop / verifier)
│   │   ├── zir.zig
│   │   ├── dispatch.zig        # central DispatchTable type
│   │   ├── lower.zig           # wasm-op → ZirOp
│   │   ├── verifier.zig
│   │   └── analysis/
│   ├── runtime/                # WASM Spec §4.2 "Runtime Structure"
│   │   ├── runtime.zig         # central Runtime handle
│   │   ├── engine.zig
│   │   ├── store.zig
│   │   ├── module.zig
│   │   ├── value.zig
│   │   ├── trap.zig
│   │   ├── frame.zig
│   │   └── instance/           # WASM Spec §4.2 "Instances"
│   │       ├── instance.zig
│   │       ├── memory.zig
│   │       ├── table.zig
│   │       ├── global.zig
│   │       ├── func.zig        # FuncEntity per ADR-0014
│   │       ├── element.zig
│   │       └── data.zig
│   ├── instruction/            # WASM Spec §5.4 categories — stateless opcode impls
│   │   ├── wasm_1_0/           # numeric_int, numeric_float, numeric_conversion, parametric, variable, memory, control
│   │   ├── wasm_2_0/           # sign_extension, nontrap_conversion, multi_value, bulk_memory, reference_types
│   │   └── wasm_3_0/           # extended_const (doc-only), wide_arith, custom_page_sizes
│   ├── feature/                # VM-capability extensions; vertical subtrees
│   │   ├── simd_128/           # SIMD-128 + relaxed-simd folded in
│   │   ├── gc/                 # WasmGC (managed heap)
│   │   ├── exception_handling/
│   │   ├── tail_call/
│   │   ├── function_references/
│   │   ├── memory64/
│   │   ├── threads/            # README-only reserved slot (post-v0.2.0)
│   │   ├── stack_switching/    # README-only reserved slot (post-v0.2.0)
│   │   └── component/          # README-only reserved slot (Component Model)
│   ├── engine/                 # interp / codegen sibling parity
│   │   ├── runner.zig          # public entry: invoke ZirFunc via runtime.vtable
│   │   ├── interp/
│   │   │   ├── loop.zig        # threaded-code dispatch loop
│   │   │   └── trap_audit.zig
│   │   └── codegen/
│   │       ├── shared/         # regalloc, reg_class, linker, compile, entry, prologue, jit_abi
│   │       ├── arm64/          # emit (orchestrator) + op_const/alu/memory/control/call + bounds_check + inst + abi + prologue + label
│   │       ├── x86_64/         # mirrors arm64/ (Phase 7.6+)
│   │       └── aot/            # format + linker (Phase 8+ / Phase 12)
│   ├── wasi/
│   │   ├── preview1.zig        # preview1 entry + register
│   │   ├── host.zig            # capability table
│   │   ├── fd.zig
│   │   ├── clocks.zig
│   │   └── proc.zig
│   ├── api/                    # wasm-c-api compatible C ABI (was c_api/)
│   │   ├── wasm.zig            # wasm.h impl (was wasm_c_api.zig)
│   │   ├── wasi.zig
│   │   ├── zwasm.zig
│   │   ├── vec.zig
│   │   ├── trap_surface.zig
│   │   └── cross_module.zig
│   ├── cli/                    # CLI exe entry + subcommands (run + compile; ADR-0159)
│   │   ├── main.zig            # Juicy Main (CLI exe entry; per ADR-0024 D-4)
│   │   ├── run.zig
│   │   ├── compile.zig         # Phase 12
│   │   └── diag_print.zig
│   ├── platform/
│   │   ├── jit_mem.zig         # mmap (POSIX) / VirtualAlloc (Windows)
│   │   ├── signal.zig          # Phase 7+: SIGSEGV → trap
│   │   ├── fs.zig              # Phase 11: WASI fs adapter
│   │   └── time.zig
│   ├── diagnostic/             # cross-cutting (Ousterhout deep module)
│   │   ├── diagnostic.zig
│   │   └── trace.zig           # Phase 7+: trace ringbuffer per ADR-0016 M3
│   └── support/                # minimal specific helpers
│       ├── dbg.zig             # dev-only logger
│       └── leb128.zig          # encoding helper (parse + codegen/aot)
│
├── test/
│   ├── README.md
│   ├── unit/                   # mirrors src/
│   ├── spec/
│   │   ├── runner.zig
│   │   ├── wat/                # source .wat (committed)
│   │   └── json/               # wast2json output (gitignored, regenerated)
│   ├── e2e/
│   ├── realworld/
│   │   ├── src/                # C / Rust / Go sources (committed)
│   │   └── wasm/               # built artefacts (committed blobs)
│   ├── c_api_conformance/
│   └── fuzz/
│       ├── fuzz_loader.zig
│       ├── fuzz_gen.zig
│       └── corpus/             # gitignored
│
├── bench/
│   ├── README.md
│   ├── history.yaml            # append-only
│   ├── runners/                # bench wasm samples
│   └── fixtures/               # bench-specific data files
│
├── docs/examples/
│   ├── c_host/
│   ├── zig_host/
│   └── rust_host/
│
├── docs/                       # English public docs (Phase 15+)
│   ├── reference/
│   ├── tutorial/
│   └── migration_v1_to_v2.md   # written at Phase 15
│
├── scripts/
│   ├── zone_check.sh
│   ├── file_size_check.sh
│   ├── gate_commit.sh
│   ├── gate_merge.sh
│   ├── record_merge_bench.sh
│   ├── run_bench.sh
│   ├── run_spec.sh
│   ├── run_remote_windows.sh   # optional pre-flight — drives $ZWASM_WINDOWS_HOST
│   ├── regen_test_data.sh
│   ├── sync_versions.sh
│   ├── fetch_wasm_c_api.sh
│   └── check_md_tables.sh
│
├── .githooks/
│   ├── pre_commit
│   └── pre_push
│
├── .dev/
│   ├── README.md
│   ├── ROADMAP.md              # this file
│   ├── handover.md
│   ├── proposal_watch.md
│   ├── orbstack_setup.md
│   ├── windows_ssh_setup.md    # optional Windows SSH pre-flight setup
│   └── decisions/
│       ├── README.md
│       ├── 0000_template.md
│       └── NNNN_*.md           # written when ROADMAP deviations occur
│
├── .claude/
│   ├── settings.json
│   ├── output_styles/japanese.md
│   ├── skills/
│   │   ├── continue/SKILL.md
│   │   └── audit_scaffolding/{SKILL,CHECKS}.md
│   └── rules/
│       ├── zone_deps.md
│       ├── textbook_survey.md
│       ├── zig_tips.md
│       ├── no_workaround.md
│       ├── no_copy_from_v1.md
│       └── markdown_format.md
│
└── private/                    # gitignored agent scratch
```

**File-size discipline (A2)** (rubric finalised by ADR-0023;
reframed by ADR-0099):
- Soft cap 1,000 lines: WARN. **Smell detector, not metric.**
  Per ADR-0099 §D1, investigate first; extract only if a valid
  P1-P4 condition fires AND no N1-N4 condition rejects (§D2
  4+4 conditions). Default outcome when no valid extraction
  exists: `// FILE-SIZE-EXEMPT: <rationale> (per ADR-0099)` on
  lines 1-5.
- Hard cap 2,000 lines: gate fails; §A2 violation requires ADR.
- **Tests-split rubric**: production code ≤ 800 LOC requires
  inline `test "..."` blocks. Production code > 800 LOC and
  combined (production + tests) > 1,000 LOC permits a
  `<file>_tests.zig` companion file. Production code > 2,000
  LOC is the §A2 hard-cap violation regardless of test
  placement.
- Auto-generated files are exempt with `// AUTO-GENERATED FROM <source>`
  on lines 1-3.
- Split-quality is checked informationally by
  `scripts/check_split_smell.sh` (per ADR-0099 §D4).

**Naming (A11)**: all paths are `snake_case`. No hyphens in file or
directory names. Migrating from cw-v1-style hyphens (`gate-commit.sh`)
to snake_case happened during Phase 0 setup.

---

## 6. WebAssembly proposal tier system

The full live status is in `.dev/proposal_watch.md`. Summary:

| Tier        | Definition                    | zwasm intent                                     |
|-------------|-------------------------------|--------------------------------------------------|
| **Phase 5** | W3C Recommendation (Wasm 3.0) | **MUST** — implement in Phases 1–10 for v0.1.0 |
| **Phase 4** | Standardize                   | **Deferred to v0.2.0** for non-web items         |
| **Phase 3** | Implementation phase          | Per-feature judgement; mostly post-v0.1.0        |
| **Phase 2** | Proposed                      | Watch only                                       |
| **Phase 1** | Champion                      | Watch only                                       |

Tier promotions (Phase 4 → Phase 5) trigger a tier-promotion ADR
that updates `.dev/proposal_watch.md` and re-evaluates the phase
plan if the proposal hits Phase 5 during active development.

---

## 7. Concurrency design

- **Phases 0–10: single-threaded.** `Engine` is a process singleton;
  `Store` is host-thread-local.
- **Phase 11+:** multi-store, with `Engine` thread-safe (matches
  wasmtime convention). `wasm.h` allows shared modules; `zwasm.h`
  documents the safe sharing surface.
- **Atomics instruction set: SHIPPED** (single-threaded semantics,
  Phase 17). **Threaded execution (shared memory + spawning)** stays
  deferred (§3.3, demand-driven — ADR-0181). ZIR slots reserved (§4.2).
- **`std.Thread.Mutex` is forbidden** (Zig 0.16 removed it).
  Use `std.Io.Mutex` or `std.atomic.Mutex` only when concurrency
  actually arrives.
- **Cancellation** (`zwasm.h`'s `zwasm_module_cancel`): single
  atomic boolean checked at fuel-poll points. Phase 7+.

---

## 8. WASI strategy

- **WASI 0.1** (preview1): the realworld baseline. Phase 4 minimal
  subset; Phase 11 full surface. **Complete.**
- **WASI 0.2** (preview2): **native host SHIPPED / campaign active**
  (ADR-0170/0180/0181, Phase 17) — the component host implements the P2
  interfaces directly (cli/io/clocks/random/filesystem/poll +
  sockets-TCP), reusing the P1 facilities host-side; there is NO
  adapter guest module. Remaining P2 surface (sockets listeners/UDP,
  name-lookup, fs via-stream) = typed not-supported until demand (§3.3).
- **WASI 0.3**: async / streams. Requires stack-switching (§3.3).

---

## 9. Phase plan

### Phase status (the tracker)

This widget is the canonical answer to "which phase is the agent
working on right now". `continue` reads it on every resume; `0.7`
of each phase advances it.

| Phase | State       | First open `[ ]` task                                                                                                                                                                                                                                                                                                                                                                                                                              |
|-------|-------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 0     | DONE        | —                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| 1     | DONE        | —                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| 2     | DONE        | —                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| 3     | DONE        | —                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| 4     | DONE        | —                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| 5     | DONE        | —                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| 6     | DONE        | —                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| 7     | DONE        | —                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| 8     | DONE        | JIT optimisation foundation 🔒 (per ADR-0019)                                                                                                                                                                                                                                                                                                                                                                                                       |
| 9     | DONE        | Wasm 1.0 + 2.0 (incl. SIMD) **literal 100%** (skip-impl == 0 across spec + edge_cases + realworld + differential) on 3 hosts + Phase 10 substrate readiness (build-option DCE across all layers; per ADR-0056 + ADR-0065 + ADR-0071 + ADR-0073)                                                                                                                                                                                                    |
| 10    | DONE        | GC, EH, Tail call, memory64 (Wasm 3.0 completion) — both backends per ADR-0133 spec-corpus exit                                                                                                                                                                                                                                                                                                                                                   |
| 11    | DONE        | WASI 0.1 full + bench infra (incl. SIMD per-op gap analysis, moved from §9.10 per Track A)                                                                                                                                                                                                                                                                                                                                                        |
| 12    | DONE        | AOT compilation mode — `.cwasm` compile/run, JIT↔AOT differential, cross-compile, stateful-compute exec, cold-start ≥30% (stack-map §12.5 → P15 / ADR-0141; WASI imports → D-251)                                                                                                                                                                                                                                                            |
| 13    | DONE        | C API full (wasm-c-api conformance) — deliverables 3-host-green; §13.P re-scoped past D-245 win64 (ADR-0144)                                                                                                                                                                                                                                                                                                                                     |
| 14    | DONE        | CI matrix infrastructure — workflows + fuzz infra; §14.P re-scoped past D-245 win64 (ADR-0145)                                                                                                                                                                                                                                                                                                                                                   |
| 15    | DONE        | Performance parity with v1 (§15.P parity measured + D-265 register-homing rework closed; §15.6 ClojureWasm DEFERRED → D-264)                                                                                                                                                                                                                                                                                                                    |
| 16    | DONE        | Completion finalization (完成形) — surface audits (C/Zig/CLI) + memory-safety + docs + debt; dogfooding DONE (cw v1 succeeded, ADR-0168); **no autonomous release/tag** (ADR-0156, reconfirmed)                                                                                                                                                                                                                                                   |
| 17    | IN-PROGRESS | **Feature line** (ADR-0168/0181 — no version march, **no tag** per ADR-0156). DONE: atomics / wide-arith / custom-page-sizes / relaxed-SIMD (3-host) · **CM + WASI-P2 wasmtime-equivalent campaign CLOSED 2026-06-13** ([`component_model_plan.md`](component_model_plan.md) Retrospective: Tier 2 exceeded — typed API, sockets incl. windows AFD readiness, guest resources, corpus 158/0/0). **NOW: completion-refinement over the campaign-grown surfaces** (audit/simplify/file-size/docs sweeps + debt long-tail repayment per §1.2 完成形 bar); §1.3 capability backlog stays demand-driven |

State values: `IN-PROGRESS` (one phase at a time), `PENDING`,
`DONE`. Update this table whenever §9.<N>.7 closes a phase or when
a phase first opens.

### Cadence

- Each phase has a **Goal**, **Exit criterion** (machine-verifiable),
  and possibly a **🔒 platform gate**.
- The `§9.<N>` task table is **inline-expanded when the phase
  opens**.
- Phase order is fixed; a phase swap requires an ADR.
- **No calendar estimates** — phases are task-driven, not
  time-driven. Pace is what the agent and the user can sustain.

### 9.0 Completion-grade model — plateau + live fronts + future bucket (ADR-0186)

The project is at the **完成形 plateau**: Phases 0–16 are DONE and Phase 17
(the widget's feature/refinement line) is the steady state. The forward
phase-queue framing is retired — remaining work is **a few live fronts + a
genuinely-future bucket**, not a phase march. **Old Phase numbers stay as
stable section anchors** for existing citations (ADRs / debt / handover); the
**front** is the real unit. The goal-line is the **完成形 bar (§1.2)** — a
named state, never a version (release is user-only, ADR-0156; version lines
retired, ADR-0181). Modelled on ClojureWasm's ADR-0142 reframe.

**Posture — the loop drives everything; only tag-cut is user-reserved
(recalibrated 2026-06-15, user-directed; anti「先回しロック化」)**: `/continue`
tackles **all** of the below autonomously — live fronts, the future bucket, AND
the hard/parked items. NONE is user-locked. The **only** user-reserved act is the
release tag-cut (ADR-0156). "future bucket" = not-yet-started + priority-ordered
(promote the moment a proposal ratifies or demand appears — e.g. WASI 0.3 below),
**not** "do not touch"; "parked" = hard / multi-cycle research, **not** closed.
Hardness is a reason to *plan a campaign* (ADR-0153), never to defer-lock. The
loop self-selects the next unit by value and proceeds.

**Phase → status redirect** (so existing "Phase N" / §9.N citations resolve):

| Former phase       | Status                                                                                          |
|--------------------|-------------------------------------------------------------------------------------------------|
| Phase 0–16         | **DONE** — §1.2 correctness floor + all surfaces (C/Zig/CLI); detailed tables archived           |
| Phase 17 (widget)  | **Feature / refinement line** — completion-refinement over campaign-grown surfaces + debt long-tail; demand-driven (§1.3) |

**Live fronts** (the demand-driven hardening surface). Re-evaluate a front
before trusting one of its `blocked-by` rows, or during an
`audit_scaffolding` run; `scripts/audit_blocked_by_age.sh` names the rows
that are due:

- **Front A — surface/diagnostic finishing tail**: D-334 validator type-mismatch
  diag (popExpect + isRef done; further enrichment is cap-bounded at
  `validator.zig`'s 3400-line cap = principled stop), F6 per-section parse
  diagnostics (ADR-grade — decoders run in compile/instantiate, body-relative
  offsets), F4 trap-format (`@tagName` underscore; user-gated). Effectively
  drained → monitoring.
- **Front B — debt natural-discharge / steady-state hardening**: the
  external-blocked (upstream Zig / 3-host) + future-phase debt rows; a debt
  sweep re-walks the barrier and discharges what dissolved (the 2026-06-15
  ground-truth sweep reconciled D-082(b)/D-026 externref-segment).
- **Front C — dogfooding-driven**: cw consumer-side dogfooding is **DONE**
  (ADR-0168 — cw v1 succeeded against zwasm v2). A *further* v2-consumer signal
  arrives only if the cw-from-scratch redesign later adds an `@import("zwasm")`
  (**D-264**); that is a cw-side decision, not a zwasm blocker. Front C is
  effectively satisfied today.
- **Front D — WASI 0.3 (Preview 3) — NEW actionable feature front**: WASI 0.3.0
  was **ratified 2026-06-11** (Bytecode Alliance; Wasmtime 43+). It rebases WASI
  onto the **Component Model's async primitives** (`async` func, `stream<T>`,
  `future<T>`) — **not** the core stack-switching continuations proposal — so it
  builds directly on zwasm's already-shipped CM + WASI-0.2 substrate
  (`src/feature/component/`, `src/api/component_wasi_p2.zig`). This is an
  extension of done work, NOT a far-future item. Spec ref cloned at
  `~/Documents/OSS/WASI/`; reference impl `~/Documents/OSS/wasmtime/` (43+).
  Work units tracked as **D-335** (CM-async types + canon built-ins + async
  lift/lower + WASI-P3 host interfaces + corpus); the loop drives it as a
  campaign. **2026-08-10 — re-scoped to FULL 0.3 coverage (ADR-0205,
  user-directed)**: official 0.3.0 released 2026-06-11 (six proposals: cli /
  clocks / filesystem / http / random / sockets; 0.3.x release train every two
  months). Campaign phases A–E per ADR-0205 — **COMPLETE**: A substrate
  (generation-aware dispatch + timer waitable + official-testsuite harness +
  clocks `wait-until`/`wait-for` + `exit-with-code`), B filesystem-0.3
  via-stream, C sockets-0.3 (async TCP/UDP/name-lookup), D `wasi:http`
  (types + handler export + `client.send`), E claims sweep (this
  README/docs/ROADMAP flip + `check_wasi03_coverage_claims.sh` doc-truth
  guard). Conformance = vendored official `wasi-testsuite` wasip3 binaries
  (`prod/testsuite-base`, `=0.3.0`-pinned): **45/45 green on all three
  supported OSes** (the windows port composes its own NT/AFD socket control
  plane + NT hardlinks where the pinned stdlib has gaps).

**Genuinely-future bucket** (demand-driven, NO version gate — the §1.3 + §3.3
set; not a queue):

- Threaded EXECUTION (shared memory + spawn; the atomics *instruction set* is
  shipped single-threaded).
- **Core** stack-switching continuations (the core-wasm proposal — still
  pre-Phase-4, format evolving as of 2026-06; **D-300**). NOTE: WASI 0.3 does
  NOT need it — see Front D.
- RISC-V / s390x backends (separate ADR each).
  (`wasi:sockets` listeners/UDP/name-lookup + fs `*-via-stream` left this
  bucket 2026-08-10 → Front D phases B/C, ADR-0205.)
- The **optimising tier is permanently OUT** (single-pass is the design — §3.2).

> Already-shipped former "v0.2.0 line" items (Component Model + WASI 0.2,
> atomics / wide-arith / custom-page-sizes / relaxed-SIMD instruction sets)
> graduated into the §1.2 correctness floor — NOT future work.

### Phase 0 — Phase 8b — archived

Phase 0 through Phase 8b are all `DONE` per the §9 Phase Status widget
at the top of §9 (line ~1175). Their detailed task tables (Phase 0
through 8b.6, with row-level `[x]` SHA pointers and exit-criterion
prose) were extracted to
[`.dev/archive/roadmap_phase0_8.md`](archive/roadmap_phase0_8.md)
during scaffolding-compression chunk §9.12-A / A5c (master plan §9.12-A;
2026-05-19). The archive is **historical record only** — no row is
load-bearing for Phase 9 or later work.

Brief summary of what each phase delivered (full detail in the archive):

- **Phase 0** — Repo skeleton + 3-host bootstrap + git hooks
  + zone_check / file_size_check gates. 🔒 gate cleared.
- **Phase 1** — Frontend MVP: parse + validate + lower Wasm Core 1.0
  → ZIR; full ZirOp enum declared (P13).
- **Phase 2** — Interpreter MVP: threaded-code interpreter; Wasm 2.0
  spec corpus fail=0/skip=0; 5+ realworld samples run. 🔒 gate cleared.
- **Phase 3** — wasm-c-api C ABI: `wasm_module_new` / `_instance_new` /
  `_func_call` / `_global_set` exposed.
- **Phase 4** — WASI 0.1 minimal (fd_read/write, environ, exit,
  clock). 🔒 gate cleared.
- **Phase 5** — ZIR analysis layer: loop_info, liveness, const_prop
  passes; lower pass framework.
- **Phase 6** — v1 conformance baseline: full spec-test wiring +
  Phase 7 prep + skip_*.md discipline. 🔒 strict-close gate cleared
  (per ADR-0012 §6.J).
- **Phase 7** — JIT v1 ARM64 baseline: arm64 emit + regalloc + ABI;
  Wasm 2.0 SIMD-128 ARM64 implementation; 100% PASS on ARM64.
  Hard transition gate §7.13 cleared into Phase 8.
- **Phase 8** — JIT optimisation foundation: x86_64 emit parity +
  differential test; bench infra; coalesce/regalloc scaffolds +
  AOT skeleton (§9.8b). 🔒 8b.6 closed Phase 8.

The detailed task tables (Phase 0 task list / Phase 1 task list /
etc.) live in the archive; phase-internal sub-chunk records are in
[`.dev/phase_log/`](phase_log/) per ROADMAP §18.3 + ADR-0014.


### Phase 9 — Wasm 1.0 + 2.0 (incl. SIMD) completion on 3 hosts

**Goal** (per ADR-0056 + ADR-0065): Wasm 1.0 base spec
(including the Module / Instance / Store / linker layer +
`(register ...)` cross-module binding + host imports +
start-trap propagation) AND Wasm 2.0 (including SIMD-128
fixed-width ops on both backends) complete on Mac aarch64 +
ubuntunote Linux x86_64 + windowsmini Win x86_64 (per ADR-0067 ubuntunote pivot; OrbStack retired).

**Exit criterion** (per ADR-0056 2026-05-17 amend, 4-category
`skip-impl == 0` predicate):

- **Cat I** — validator / parser spec-rule enforcement at 0
  (already).
- **Cat II** — spec-test harness multi-result entry helpers
  at 0 (`entry.zig` `FuncRet_<types>` + `dispatchMultiResult
  <shape>` runner arms).
- **Cat III** — Wasm 1.0 runtime instance binding at 0
  (Store + Instance registry, cross-module import linker,
  cross-module call dispatch, host import binding spectest
  family, start-trap propagation, `(register ...)` runner
  directive) per ADR-0065.
- **Cat IV** — windowsmini Windows SEH bridge for
  `assert_trap` recovery (D-084 / D-136 / D-028 cohort);
  Phase 9 batch-end sweep per ADR-0049.
- JIT covers all Wasm 2.0 ops (no hidden-skip dispatch
  fallthroughs); `test-all` wires `test-edge-cases`,
  `test-realworld-run-jit`, `test-wasmtime-misc-runtime`;
  bench infra clean (no script bugs, no dead error paths,
  no schema drift); ADR-0029 Path B `skip-impl == 0`
  enforcement real (gates the runner, not just narrative).
- SSE4.1+SSE4.2 minimum baseline (per ADR-0041 §5 amend at
  9.7-m); runtime feature detection refuses to start on
  older x86 CPUs.
- SIMD smoke benches recorded against reference runtimes;
  no fixed numeric ratio target.

**🔒 gate**: no (Phase 9 itself); the post-Phase-9 substrate
audit at §9.12 IS a hard gate per ADR-0062.

#### §9.9 task list (initial expansion; refines as the phase progresses)

| #        | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | Status                        |
|----------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------|
| 9.0      | Open §9.9 inline + flip Phase Status widget (Phase 8 = DONE; Phase 9 = IN-PROGRESS).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | [x] `f0faf1d7`                |
| 9.1      | Step 0 survey: SIMD-128 op catalogue + ARM64 NEON / x86_64 SSE4.1 encoding strategy across wasmtime / wasmer / zware / v1 zwasm. Headlines: 415 op variants across 59 spec test files; cranelift ISLE-DSL-based (unsuitable for Zig); winch single-pass visitor (closer analog, but SIMD currently a no-op macro); wasmer singlepass minimal SIMD coverage; v1 zwasm's parallel `simd_xreg` cache flagged in W54 post-mortem as anti-pattern. Three divergences identified: (a) one ZirOp per operation (shape-as-variant), (b) reuse FP-class register pool, (c) spec-fidelity float ops. Survey lands at `private/notes/p9-9.1-simd-survey.md`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | [x] `ca58cfc5`                |
| 9.2      | ADR-0041 — SIMD-128 design framing: shape-as-variant ZirOp catalogue (171 variants pre-declared in zir.zig cover ~415 spec ops) + FP-class register pool reuse with shape-tag axis (per `single_slot_dual_meaning.md`) + feature-register pattern via `feature/simd_128/register.zig` (per ADR-0023 §4.5) + NEON IEEE-754 spec-fidelity strategy + SSE4.1 minimum baseline confirmed (PMULLD / PINSRB-W-D / PBLENDVB required). Spill-frame packing optimisation deferred to Phase 15 alongside ADR-0038 class-aware allocation.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | [x] `ba88328a`                |
| 9.3      | Validator extension: SIMD value type (`v128`) + per-op type signatures via the prefix-`0xFD` dispatch (mirrors prefix-`0xFC` shape). MVP catalogue covers v128.const + v128.load/store + splat (per shape) + extract/replace_lane (per shape) + binop/unop/relop ranges + any_true. Per ADR-0041 Revision 2: validator's static-dispatch reality (not central DispatchTable consultation) acknowledged; full dispatch-table-driven validator is a Phase 14+ structural refactor. 10 unit tests cover happy-path + type-mismatch + truncated-immediate + unknown-sub-opcode rejection.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | [x] `51da4b66`                |
| 9.4      | IR extension: SIMD ZirOp activation + lower paths via `emitPrefixFD` in `src/ir/lower.zig` (mirroring `emitPrefixFC` shape) — MVP catalogue covers v128.{const,load,store,load*x*_*,store,load*_splat,load*_zero,not} + i8x16.{shuffle,swizzle,splat,extract/replace_lane*} + i16x8/i32x4/i64x2/f32x4/f64x2 splats + extract/replace_lane variants + `i32x4.add` (representative binop). Adds `Allocation.shapeTag(vreg)` API + `ShapeTag` enum + `Allocation.shape_tags: ?[]const ShapeTag` field per ADR-0041 §"Decision" / 2 (separate-axis shape disambiguation per `single_slot_dual_meaning.md`). 9.4 MVP returns `.scalar` by default; 9.5+ ARM64 NEON emit populates `shape_tags` when the function contains v128 ops. 13 unit tests cover lower + ShapeTag round-trips + shuffle lane bound check + truncated immediate + unknown sub-opcode rejection.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | [x] `927364a6`                |
| 9.5      | ARM64 emit (NEON): SIMD load/store + lane access + integer arithmetic.. Sub-chunks 9.5-a..* recorded in [`.dev/phase_log/phase9.md`](phase_log/phase9.md#row-95--arm64-emit-neon--load-store--lane-access--int-arith) (extracted 2026-05-11; ROADMAP per §18 stays a now-snapshot).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | [x] `3969b16b`                |
| 9.6      | ARM64 emit (NEON): SIMD comparison + shuffle + float arithmetic + conversion.. Sub-chunks 9.6-a..* recorded in [`.dev/phase_log/phase9.md`](phase_log/phase9.md#row-96--arm64-emit-neon--cmp--shuffle--fp-arith--convert) (extracted 2026-05-11; ROADMAP per §18 stays a now-snapshot).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | [x] `d622e5da`                |
| 9.7      | x86_64 emit (SSE4.1+SSE4.2 baseline per ADR-0041 §5 amend at 9.7-m): SIMD load/store + lane access + integer arithmetic. Sub-chunks 9.7-a..* recorded in [`.dev/phase_log/phase9.md`](phase_log/phase9.md#row-97--x8664-emit-sse41sse42-baseline) (extracted 2026-05-11; ROADMAP per §18 stays a now-snapshot).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               | [x] `213e6946`                |
| 9.8      | x86_64 emit (SSE4.1): SIMD comparison + shuffle + float arithmetic + conversion. **Scope absorbed by §9.7 per ADR-0044** — these op families landed inside §9.7's progressive expansion (9.7-k..n compares; 9.7-o FP compares; 9.7-p..q FP arith; 9.7-ab..ae conversions; 9.7-ar shuffle; 9.7-aj..aq pairwise extadd; etc.). All 237 v128 ZirOps now have x86_64 handlers (verified by zir.zig:184-288 vs emit.zig grep). Closing as scope-merged routine status update.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | [x] `213e6946` (per ADR-0044) |
| 9.9      | **Wasm 1.0 + 2.0 (incl. SIMD) 100% PASS** per ADR-0056 (2026-05-17 + 2026-05-18 amends) + ADR-0065 (2026-05-18 amend): `skip-impl == 0` literally across **Cat I + Cat II + Cat III** on **Mac + ubuntunote**. Cat IV (windowsmini SEH bridge + reconcile) **moved to row §9.13-0** per ADR-0049 + ADR-0056 (2026-05-18 amendments) — the 3-host invariant is preserved, the windowsmini gate just shifts position to AFTER §9.12 substrate audit cleanup, BEFORE §9.13 Phase-10 entry gate. JIT covers all Wasm 2.0 ops (no hidden-skip dispatch fallthroughs); `test-all` wires `test-edge-cases`, `test-realworld-run-jit`, `test-wasmtime-misc-runtime`; bench infra clean; ADR-0029 Path B enforcement real. Discharge tracked across umbrella row + per-category rows 9.9-II / 9.9-III; sub-chunks recorded in [`.dev/phase_log/phase9.md`](phase_log/phase9.md#row-99--simdwast-spec-test-wiring) per ADR-0014 + §18.3. Execution playbook: [`.dev/phase9_close_master.md`](phase9_close_master.md) (current authoritative; archived predecessors at `.dev/archive/phase9/`).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | [x] `a8af42e3`                |
| 9.9-II   | **Cat II — Multi-result entry helpers** per ADR-0065. Drain ~1400 multi-result `skip-impl` directives (48 manifest-level lines spread across func / if / call / br / block / loop corpora) by adding `extern struct FuncRet_<types>` definitions in `entry.zig`, `callXX_yy() Error!FuncRet_<types>` helpers, `dispatchMultiResult<shape>(...)` arms in `spec_assert_runner_non_simd.zig`, and `(arg_kinds, result_kinds_tuple)` entries in the distiller's `supported` set. Highest-impact shapes first: `(i64,i64,i32)→(i64,i32)` add64_u_with_carry family (8 manifests), then `()→(i32,i32)` + `(i32)→(i32,i32)`, `()→(i32,i64)`, `()→(i32,f64)`, `(i32)→(i32,i32,i64)`, `()→(i32,i32,i32)`, long-tail. Sub-chunks 9.9-II-* recorded in `phase_log/phase9.md`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | [x] `fb063b09`                |
| 9.9-III  | **Cat III — Wasm 1.0 instance / store / linker / cross-module / host-imports / start-trap** per ADR-0065. Drain 144 directives (136 cross-module + 4 host imports + 2 start-trap + 2 link-typecheck) by implementing: Store + Instance registry (`Store.register(name, *Instance)`), cross-module import linker (resolve `(import "M" "f" ...)` at instantiation; verify import-type ≡ export-type for `link-typecheck` cases), cross-module call dispatch (funcref carries originating-instance pointer; `call_indirect` works through cross-module-populated table entries), host import binding (spectest `print_i32` family bound to runner-provided host function pointers), start-trap propagation (instantiation fails if start function traps), spec_assert runner `(register ...)` directive handler with per-session instance map. Step 0 surveys before any sub-chunk: v1 zwasm Store/Instance/linker (read-only; no copy per `no_copy_from_v1.md`), wasmtime `crates/runtime/`, zware `src/`, prior `~/zwasm/private/v2-investigation/`. Sub-chunks 9.9-III-* recorded in `phase_log/phase9.md`. Likely 1–2 sub-ADRs (`0066_*` / `0067_*`) for Store / Instance lifetime model.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     | [x] `2dbd3f15`                |
| 9.9-IV   | **Moved to §9.13-0** per ADR-0049 + ADR-0056 + ADR-0065 (2026-05-18 amendments). Originally read as "Cat IV windowsmini batch reconcile sweep AT §9.9 close"; user 2026-05-18 confirmation re-slots this to §9.13-0 (post-§9.12 substrate audit, pre-§9.13 Phase-10 entry). Row preserved for citation lineage; content moved to §9.13-0 below. No §9 renumber per ADR-0014.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | [~] moved to §9.13-0         |
| 9.10     | **Moved to Phase 11** per Phase 10 prep Track A Option (3) (see `.dev/phase10_prep/track_a_9.10_scope.md` §3.3 + §7 + ADR-0043 Revision history 2026-05-12 row). SIMD per-op gap analysis (3× threshold; v1 D122 ≈ 43× gap reference; AVX / MOVAPS-peephole / SIMD-coalescing candidate list) folds into Phase 11's bench-infra cohort alongside D-074's `-Dwith-bench-compare` flag + wazero/wasmer flake additions — the natural carrier per D-074 barrier statement. Row number preserved (no §9 renumber per ADR-0014).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | [~] moved to Phase 11         |
| 9.11     | Phase-9 boundary `audit_scaffolding` pass + SHA backfill.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | [x] `f06a3c9b`                |
| 9.12-pre | **ADR drafts + 3 Q3 spikes (autonomous prep for §9.12 collab gate)** per [`archive/phase9/phase9_completion_master_plan.md`](archive/phase9/phase9_completion_master_plan.md) §5.3. Drafts: ADR-0070 (libc dependency policy) / ADR-0071 (Phase 9 substrate audit resolution = Q2 P14 sharpening + Q3 adoption + Q4 boundary) / ADR-0072 (comment-as-invariant rule) / ADR-0073 (build-option DCE consistent substrate across all layers) + ADR-0050 amend (skip-impl one-way ratchet) + ADR-0023 §4.5 amend (per-op file pattern formal adoption). Spikes: `q3-zig-inline-switch/` (no compile-time wall at 581 tags; +1.9% .text vs plain) + `q3-interp-dispatch-bench/` (perf-null at production N=581; adoption proceeds on design-quality axes) + `q3-build-option-dce-poc/` (DCE substrate works literally per `nm` + `xxd` evidence). Exit: 6 ADRs landed with `Status: Proposed` + 3 spike measurement reports under `private/spikes/q3-*/`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | [x] `072d39cd`                |
| 9.12     | **Phase 9 completion substrate re-examination — CLEARED** ([`.dev/archive/phase9/phase9_completion_substrate_audit.md`](archive/phase9/phase9_completion_substrate_audit.md)). Collab review per ADR-0062 completed 2026-05-19: Q2 P13 = Accept (re-eval at §9.12-B if op gaps surface); Q2 P14 = Amend (sharpen + Structural cohesion caveat per ADR-0071); Q2 §4.5 = Amend (per-op file pattern; ADR-0023 §4.5 amend); Q2 §4.6 = Accept (4-layer DCE; ADR-0073); Q3 = **Hypothesis C** (per-op file + comptime collector + inline switch); Q4 = Decision + minimal PoC (i32.add in C pattern across 6 builds; §9.12-B for remaining ops); Q5 = 5 deliverables (ADR-0072 + new rules + lint + D-133 sweep) + **dedup sweep of existing rules/lints** in §9.12-C; Q6 = ADR-0070 (libc 3-category + 5 deliverables in §9.12-D; forward-looking management). ADRs 0070 / 0071 / 0072 / 0073 → Accepted; ADR-0023 §4.5 amend + ADR-0050 D-5/D-6 amend confirmed. ROADMAP §14 forbidden list amended (Unconscious libc fanout / skip-impl regression). Phase Status widget wording updated. Hard-gate cleared; §9.12-A self-resume.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     | [x] `43d82eb5`                |
| 9.12-A   | **Iteration-speed scaffolding compression + don't-give-up enforcement layer construction** per [`archive/phase9/phase9_completion_master_plan.md`](archive/phase9/phase9_completion_master_plan.md) §5.3 + §7. Compression: ROADMAP Phase 0-8 narrative archive (-800-1000 LOC); `continue/SKILL.md` compression (-300 LOC); archive closed phase gates / old audits / closed spikes. Enforcement (9 items): build-option DCE enforcement (`scripts/check_build_dce.sh` + `audit §K.1`); per-op file completeness (`dispatch_collector.zig` comptime check); skip-impl one-way ratchet (`scripts/check_skip_impl_ratchet.sh` + `skip_impl_history.yaml`); anti-fallback (`.claude/rules/no_fallback_on_failure.md` + grep script); spike lifecycle (rule + audit); chunk-close literal exit gate; Q3 C consistency audit (skill); progress tracker yaml; feature_level comptime verification. Reorganise + consolidate the existing 8 gates. Exit: cold-start load -40%; gate_commit average -20%; all 9 enforcements installed as pre-commit/pre-push hooks.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | [x] `8871f7ed`                |
| 9.12-B   | **Q3 C adoption completion + build-option DCE extension across all layers** per [`archive/phase9/phase9_completion_master_plan.md`](archive/phase9/phase9_completion_master_plan.md) §5.3. Per-op file migration for all ops (remaining 4 Wasm 1.0 placeholders + Wasm 2.0 `multi_value.zig` + SIMD-128 relocate); central collector + dispatcher (`dispatch_collector.zig` + rewrite 5 dispatchers to inline switch + collector consumption); build-option DCE extension across all layers (CLI args declarative form / C API `comptime @export` filter + `wasm.h` preprocessor gate / WASI syscall feature_level metadata). Exit: `test-all` green for all 6 build-option combinations (`-Dwasm={v1_0,v2_0,v3_0}` × `-Dwasi={p1,p2}`); `check_build_dce.sh` 0; per-op file completeness comptime check passes.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | [x] `b9a138f3`                |
| 9.12-C   | **Q5 hygiene landings** per [`archive/phase9/phase9_completion_master_plan.md`](archive/phase9/phase9_completion_master_plan.md) §5.3 + §3.5. `.claude/rules/comment_as_invariant.md` (new); extend `abi.zig` comptime disjointness check (convert table/memory emit scratch to named-constant arrays); D-133 sweep (route arm64 op_table/op_memory hardcoded X10/X11/X12 through named-constants); add stress axes section to `.claude/rules/edge_case_testing.md`; strengthen `audit §G` grep; strengthen `.claude/rules/bug_fix_survey.md` + inline `/continue` Step 4 checklist; new `.claude/rules/runtime_instance_layer.md` (Cat III code zone rule). **Dedup sweep**: in the same chunk, integrate existing `no_workaround.md` / `bug_fix_survey.md` / `audit_scaffolding §G` greps so they do not overlap or restate the new rules (per ADR-0071 §Q5 note + ADR-0072 Revision history). Exit: D-133 closed; comment_as_invariant rule auto-load functioning; audit grep detections 0; no rule-duplication remains.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | [x] `9558e5f7`                |
| 9.12-D   | **Q6 libc dependency boundary** per [`archive/phase9/phase9_completion_master_plan.md`](archive/phase9/phase9_completion_master_plan.md) §5.3 + §3.6. ADR-0070 Accepted (3 categories: necessary / replaceable / convenience); `.claude/rules/libc_boundary.md` auto-load; ROADMAP §14 amendment (forbid unconscious libc fanout); `scripts/check_libc_boundary.sh` + extend `audit §G.5`; sample migration `std.c.{write,_exit,getenv,munmap}` → `std.posix.*` (~5-10 sites). Exit: `bash scripts/check_libc_boundary.sh` 0; `test-all` green on all hosts.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               | [x] `b098a688`                |
| 9.12-E   | **★ Wasm 2.0 complete 100% (skip-impl 243 → 0 + 4 comprehensive test suites green)** — primary Phase 9 completion exit per [`archive/phase9/phase9_completion_master_plan.md`](archive/phase9/phase9_completion_master_plan.md) §5.3 + §2.2. SKIP-CROSS-MODULE-IMPORTS 100 (imports/elem/data/linking/table*/memory*/global) discharge via relaxed `hasUnbindableImports()` reject condition + per-shape resolver; SKIP-NO-LINK-TYPECHECK 26 via `Instance.checkImportType()` + `applyAssertUnlinkable` callback; SKIP-VALIDATOR-GAP SIMD 50 (simd_lane lane-index range + simd_align alignment immediate range); exports non-invoke-action 1 (action dispatcher `get`/`set`); D-079 v128 cross-module imports (ii) via ADR-0052 §3 globals extension. Comprehensive tests: spec (skip-impl == 0) + edge_cases + realworld (Wasm 2.0 scope; emcc family deferred to Phase 11) + differential vs wasmtime. Exit: `spec_assert_runner_non_simd: N passed, 0 failed, 495 skipped (= 0 skip-impl + 495 skip-adr)` Mac+ubuntunote bit-identical; `simd_assert_runner: 13301 passed, 0 failed, 390 skipped (= 0 skip-impl + 390 skip-adr)` Mac+ubuntunote bit-identical; 4 testsuites green; ratchet 0 maintained.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | [x] `ba203d91`                |
| 9.12-F   | **Phase-9-eligible debt cohort** per [`phase9_close_master.md`](phase9_close_master.md) §5 (current authoritative; archive predecessor `archive/phase9/phase9_completion_master_plan.md` superseded 2026-05-22 per ADR-0104). D-094 (x86_64 multi-result indirect-result-buffer; verify dissolution via D-140/D-148 chain or discharge); D-090 (lower.zig type-stack walker); D-062 (arm64 v128 9th+ stack overflow); D-141 (file_size_check WARN; mostly dissolved by Q3 C adoption, individual ADRs for the remainder); D-081 (emit.zig source split; verify dissolution by Q3 C); D-055 (emit_test_*.zig migration). Exit: per ADR-0102 per-row predicate (a)(b)(c)(d) + per ADR-0104 D1.5 — D-094 + D-062 closed via ADR-0106 implementations (workaround-masquerade reframe; "< 15" literal predicate REJECTED 2026-05-22 per ADR-0104).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | [x] `153e31d1`                |
| 9.12-G   | **Phase 10 prep substrate** per [`archive/phase9/phase9_completion_master_plan.md`](archive/phase9/phase9_completion_master_plan.md) §5.3. ZirOp Wasm 3.0 slot ↔ Wasm spec number mapping table `.dev/wasm_3_0_zirop_mapping.md` (collector machine-generate); extend `src/instruction/wasm_3_0/` placeholders to cover all Phase 10 features (GC/EH/tail-call/memory64/multi-memory/typed func refs); `src/api/instance.zig` (1431 LOC) health + helper extraction + minimal c_api Instance-path test coverage (D-139 pulled forward); add CLI `--invoke` mode (prerequisite for Phase 11 bench); `include/wasm.h` upstream diff check; `zone_check.sh --gate` migration (info → enforce); new `.dev/architecture/zone_layout.md`. Exit: all Phase 10 feature ZirOps reject with `Error.UnsupportedOpForBuildLevel` at `comptime`; `zone_check --gate` 0; c_api basic path tests landed.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | [x] `4bd62842`                |
| 9.12-H   | **Bench baseline (Mac-only Wasm 2.0 + wasmtime comparison)** per [`archive/phase9/phase9_completion_master_plan.md`](archive/phase9/phase9_completion_master_plan.md) §5.3. Extend `scripts/run_bench.sh --compare=wasmtime` + `--capture-rss`; on Mac aarch64 ReleaseSafe run 26 fixtures × hyperfine `--warmup 3 --runs 5`; add separate `runtime: zwasm` / `wasmtime` rows to `bench/results/history.yaml`; partial D-074 resolution (wazero/wasmer/bun/node + `-Dwith-bench-compare` flag deferred to Phase 11). Exit: "p9-close: Wasm-2.0 baseline (Mac aarch64)" row in history.yaml; zwasm vs wasmtime mean_ms ratio documented.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | [x] `600bd7cf`                |
| 9.12-I   | **ADR + lesson + private/ closure** per [`phase9_close_master.md`](phase9_close_master.md) §5.4 (current authoritative; archive predecessor superseded 2026-05-22 per ADR-0104). D-149 discharge (ADR Phase-9 cohort SHA backfill 75 → 0); ADR Status canonical pass (~22-25 entries from `Accepted` → `Closed (Phase X DONE)`); skip-ADR Status wording cleanup (skip_cross_module_register canonical, skip_cross_module_action close candidate); Lesson Citing backfill; scan for Lesson promotion candidates (decide ADR conversion for 3+ citations). Exit: `check_adr_history.sh --gate` 0; `check_lesson_citing.sh` 0; ADR `Accepted` count < 30.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | [x] `c5ec6889`                |
| 9.13-0   | **Cat IV — windowsmini reconcile sweep + cross-platform sweep (relocated from §9.9-IV per ADR-0049 + ADR-0056 + ADR-0065 2026-05-18 amends; scope expanded per [`phase9_close_master.md`](phase9_close_master.md) §5 (current authoritative; archive predecessor superseded 2026-05-22 per ADR-0104))**. Items: D-136 Win64 SEH bridge for `assert_trap` recovery (likely small C/asm shim alongside Zig); D-028 windowsmini SSH test-runner IPC flake re-evaluate; D-022 covered by `0c2474c2` F1 fix (`@panic("D-022")` for 3 Class B mixed helpers on Win64 else-branch). **D-084 (Win64 v128 marshal) was already closed pre-§9.13-0 at `7a7e387c` 2026-05-12 §9.9-i-1 per ADR-0055; original wording carried it as "residual" but no residual marshal failure exists per W0 survey post-F1** — see `.dev/archive/phase9/phase9_13_0_close_plan.md` §6 row 5 STRUCK note. any Windows-platform-specific issues surfacing from §9.9-III cross-module / host-import code OR §9.12 substrate audit cleanup. Sequence: inventory blocking items; pick implementation path per item; land in batch (single chunk if mechanical, multi-chunk if SEH bridge alone is substantial). Exit (per ADR-0104 D1.2-1.6 + Revision 2026-05-23 + master plan `.dev/phase9_close_master.md` §6 + §5.3a): windowsmini full `test-all` green with ZERO `SKIP-WIN64-EXHAUSTION` / `SKIP-WIN64-CALL-INDIRECT-TRAP` / `SKIP-WIN64-MULTI-RESULT` token emission (D-162 closed per ADR-0105 JIT-prologue stack-probe; D-163 closed `0de438a6` via R3 broader trap-path fix; D-164 closed per ADR-0106 multi-result ABI redesign). **Plus per ADR-0104 Revision 2026-05-23 Phase 9 真スコープ expansion**: D-157 (`SKIP-NO-LINK-TYPECHECK` 0 across 3 hosts via `instantiate.zig` non-func import-type checking), D-079 (ii) (c_api `wasm_instance_new` accepts v128-typed cross-module global imports), D-139 (c_api Instance lifecycle audit + coverage tests). The "bit-identical with Mac + ubuntunote" original wording REJECTED 2026-05-22 per ADR-0104 — workaround-disguising; replaced by zero-SKIP-WIN64-* gate via `scripts/check_phase9_close_invariants.sh` (deleted 2026-08-20, ADR-0212 D3) PLUS the §5.3a discharge conditions. windowsmini per-chunk gate stays deferred per ADR-0049 until this row opens. Sub-chunks recorded in `phase_log/phase9.md`. Runs autonomously by the `/continue` loop AFTER §9.12 substrate audit hard-gate clears (= §9.12 [x]); §9.13 Phase-10 entry hard-gate requires this row [x] for the 3-host invariant to hold. | [x] `add3da3d`                |
| 9.13-V   | **Value widen to 16-byte (terminal SIMD width) per ADR-0110 (Accepted 2026-05-24).** Six sub-phases per [`.dev/phase9_value_widen_plan.md`](phase9_value_widen_plan.md): (1) scope audit → (2) test coverage strengthening (Value semantics boundary fixtures, addresses cycle-37 user-flagged "テスト不足感") → (3) Value definition flip (`@sizeOf(Value) 8 → 16`) → (4) cascade impl (storage / JIT codegen `idx*8 → idx*16` + Q-reg/MOVUPS for v128 globals / extern struct field offsets / ZIR payload encoding / host-call marshal / spec runner unification / c_api Val passthrough simplification) → (5) cope-code removal (ADR-0052 `globals_offsets[]` + `globals_byte_storage` + per-valtype JIT switch + spec runner `GlobalsCtx` + ADR-0107 c_api propagation all removed) → (6) 3-host verify + ADR closure. Implements v128 first-class per industry 5/7 majority (per [`docs/runtime_deep_comparison.md`](../docs/runtime_deep_comparison.md)). cw v1 dogfooding-aware (ADR-0109 Value section simplifies in same cohort — no separate `V128` type). Parallel to §9.13-0; either order. Net code delta expected negative (~300-500 LOC cope removed vs ~50-100 LOC added). Exit: cope-code grep clean + Mac+ubuntu+windowsmini test-all green + bench delta within tolerance (per Phase 8b discipline) + ADR-0107 Withdrawn lineage + ADR-0052 cope-portion supersession confirmed.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | [x] `9204847a`                |
| 9.13     | 🔒 Phase 10 entry gate review ([`.dev/phase10_transition_gate.md`](phase10_transition_gate.md)) — collaborative review per Track D; runs **after** §9.13-0 windowsmini reconcile (which itself runs after the substrate audit 9.12 clears, since 9.12's outcome may amend Phase 10 scope AND windowsmini reconcile scope) **AND after §9.13-V Value widen (parallel cohort per ADR-0110 / ADR-0104 Revision 2026-05-24)**. **Phase 9 = DONE predicate** is in [`.dev/phase9_close_master.md`](phase9_close_master.md) §6; gate test is `bash scripts/check_phase9_close_invariants.sh --gate` (deleted 2026-08-20, ADR-0212 D3) (per ADR-0104). Includes user flip of ADR-0105 (JIT-prologue stack-probe) + ADR-0106 (multi-result ABI redesign) Proposed→Accepted as part of the collab review.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | [x] `36c494a3`                |

### Phase 10 — GC, EH, Tail call, memory64 (Wasm 3.0 completion)

**Goal**: WebAssembly 3.0 feature-complete.

**Exit criterion**:

- WasmGC: struct.new, array.new, ref.test, ref.cast, sub-typing.
- Exception Handling: try-table, throw, throw_ref. Stack frame
  unwinding.
- Tail Call: return_call, return_call_indirect, return_call_ref.
- memory64 lit up; existing load/store ops accept 64-bit offsets.
- All Phase-5 proposals' spec tests: **interp pass=fail=skip=0**; **JIT
  0-real-fail + every JIT skip on the forward-referenced deferred-allowlist**
  (re-scoped by ADR-0133 — see below).
- Bench: no unexplained regression vs Phase 9 baseline.

**Exit re-scope (ADR-0133, 2026-06-03; amends ADR-0128)**: raw "JIT skip=0" is
structurally unreachable in-phase (multi-memory's ~458 JIT skips are Phase-14
work; GC-on-JIT rooting's ~20 are Phase-11, per ADR-0128 §2 / ADR-0115). The
honest in-phase bar is **interp 100% (met) + JIT 0-REAL-fail + every JIT skip
forward-referenced to its true later phase** (no silent drop). Deferred-allowlist:
**multi-memory-on-JIT → Phase 14** (`compile.zig:125`); **GC-on-JIT rooting →
Phase 11**. In-phase JIT targets (NOT deferrable): the 17 module-compile rejects
(`UnsupportedEntrySignature`/`StackTypeMismatch`/`ElemSegmentTypeMismatch`/
`InvalidGlobalInitExpr` + `return_call_indirect`/`br_on_null` op emits) + the
`10.E-eh-on-jit` imported-tag fails + the D-234 runner-side fix (memory64
assert_trap mis-eval; codegen proven correct).

**100% plan (ADR-0128, 2026-05-31)**: "both backends" is made mechanically
true by a **spec-corpus JIT execution mode** (run the official testsuite
through the JIT, not just the interp); **GC-on-JIT** is emitted via the
non-moving op-emit path (rooting deferred — ADR-0128 §2, D-211); ADR-0127
PHASE C lands (assert_unlinkable 5→0); D-209 dissolved (payload u64).
Close-invariant SKIPs (I3/I5/I16/I20/I21) become real targets. The "close-
eligible" posture (8 SKIPs counted as deferred) is retracted (superseded by
the ADR-0133 deferred-allowlist, which forward-refs each deferred item).

**Design plan**: [`.dev/phase10_design_plan_ja.md`](phase10_design_plan_ja.md) (r3; 2026-05-24 user-reviewed). Sub-chunks recorded in `phase_log/phase10.md` per ADR-0014 + §18.3.

| #     | Item                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | Status |
|-------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------|
| 10.0  | Phase 9 → 10 transition: §9.13 hard gate clear; design plan + transition gate ja landed; widget 9→DONE; this §10 table inline 展開.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | [x]    |
| 10.C9 | Phase 9 close 後始末 — §9.11 audit_scaffolding Phase-boundary pass + §9.x SHA backfill + bench Phase 9 close baseline → `bench/results/history.yaml` + `phase9_close_master.md` Doc-state → ARCHIVED-IN-PLACE + `phase_log/phase10.md` 新規作成. Sub-chunks 10.C9-step1..step5 recorded in [`phase_log/phase10.md`](phase_log/phase10.md#row-10c9--phase-9-close-後始末).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | [x]    |
| 10.J  | **Native Zig API (ADR-0109 Accepted 2026-05-25; amended same day Revision row 3)** — `src/zwasm.zig` rewrite per `docs/zig_api_design.md` + execution plan [`phase10_zig_api_plan.md`](phase10_zig_api_plan.md) (7 sub-chunks J.2..J.close after J.1 withdrawal; ~7-11 cycles): Engine + Linker + TypedFunc + Memory slice view + Caller ctx + full Trap error set + allocator strict-pass, dropping the ADR-0025 c_api veneer. Internal `runtime.Runtime` (`src/runtime/runtime.zig:96`) stays unchanged — Zig 0.16 module-as-struct + `usingnamespace` removal ensures qualified namespace separation from the pre-existing `jit_abi.JitRuntime` (`src/engine/codegen/shared/jit_abi.zig:137`; born `JitRuntime` per ADR-0017 sub-2a to avoid collision); the originally-planned J.1 rename was retracted as the §1 rationale rested on a factual error about which struct JIT body reads (see ADR-0109 Revision row 3). Three-tier test architecture (in-source unit + integration runner + auto-leverage) ensures "other tests pass while Zig API is broken" cannot happen. Sub-chunks recorded in [`phase_log/phase10.md`](phase_log/phase10.md#row-10j--native-zig-api-adr-0109). Closes D-075 on impl complete (= ADR-0109 Status → `Closed (implemented)` per its Removal condition). | [x]    |
| 10.F  | c_api scalar accessors (D-171/172/173) — wasm-c-api spec 標準 global/table/memory accessors を `src/api/instance.zig` に追加 (Phase F per `phase9_close_master.md` §5.3a). Sub-chunks recorded in [`phase_log/phase10.md`](phase_log/phase10.md#row-10f--c_api-scalar-accessors). Runs in parallel with 10.J (separate file).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | [x]    |
| 10.Z  | ZirInstr 128-bit 拡張 (`payload: u32 → u64`) per design plan §3.1 / Z.1 chunk. 業界全社 (wasmtime/wasmer-LLVM/WAMR/spec ref) full u64 実態に追従; memory64 offset を spec full に carry。Phase 9 corpus 全 host 再 green + 既存 `emit_test_*.zig` byte-identical 確認。Spike なし; 失敗時 chunk revert。                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | [x]    |
| 10.D  | 設計ラウンド (ADR-0111-0117 + ROADMAP §12 amend) — 全 7 ADR を実装着手前に Accepted。memory64 (0111) / Tail Call (0112) / callsite_metadata + regalloc 3-axis (0113) / EH (0114) / GC heap+collector (0115) / GC roots+RTT+i31 (0116) / GC×EH×TC integration invariants (0117) + ROADMAP §12 (AOT) に "stack-map emission compatible with GC root walker" exit criterion 追加。                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | [x]    |
| 10.T  | テスト infra 整備 (実装陣前; design plan §4) — `scripts/import_proposal_corpus.sh` + `spec_assert_runner_wasm_3_0.zig` (5 sub-corpora) + `gc_stress_runner.zig` + `eh_frequency_runner.zig` skeleton + 既存 `emit_test_*.zig` Phase 9 baseline 採取 + `ZWASM_TEST_BLESS=1` bless workflow + `test/realworld/p10/` 9 fixture / 5 toolchain skeleton (Dart/wasm_of_ocaml/Hoot/emscripten EH/clang musttail/clang wasm64).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               | [x]    |
| 10.M  | memory64 実装 — `Memory.idx_type` 配線 + multi-memory enable (`memory: [*]u8` → `memories: []MemoryInstance`) + parse/validator + runtime mmap > 4 GiB + arm64/x86_64 codegen (wrap-check + offset materialise; i32 fast-path byte-identical 維持) + edge_cases + spec corpus + realworld/p10/clang_wasm64/ green。                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | [x]    |
| 10.R  | function-references prereq — `ref.as_non_null` / `br_on_null` / `br_on_non_null` / `call_ref` / `return_call_ref` + `(ref $sig)` typed function ref typing。`feature/function_references/` を起こす。GC 前 必須 (MVP.md:14-22 prereq)。                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | [x]    |
| 10.TC | Tail Call 実装 — regalloc terminator-class 拡張 (ADR-0113 §A) + `op_tail_call.zig` 新規 + `frame_teardown.zig` helper + `cross_module_tail_call.zig` (inline emit; ADR-0066 thunk 不再利用) + interp trampoline (v1 vm.zig pattern re-derive) + safepoint-free invariant comptime assert + spec corpus 95 wast + realworld (clang_musttail + wasm_of_ocaml) + EH × TC cross fixture。                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | [x]    |
| 10.E  | EH 実装 — regalloc N-successor callsite 拡張 (ADR-0113 §B; bounds_fixups を `callsite_metadata` 1-edge specialisation に refactor) + `feature/exception_handling/` (tag + exception) + `unwind.zig` FP-walk (SEH 流用しない) + `zwasm_throw` trampoline + `op_exception_handling.zig` landing pad emit + cross-module exception propagation + EH × TC integration test (`return_call_in_try_table.wat`) + c_api tag accessors + spec corpus 76 assertion + `eh_frequency_runner` 本実装 + realworld/p10/emscripten_eh/ green。                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        **訂正 2026-08-25**: 行末の `realworld/p10/emscripten_eh/ green` は成立していなかった。EH のコードは出荷済みだが `emscripten_eh/` は fixture を持たず、レーンは分母を持たないため 0 件を緑と報告していた (#226)。fixture を作って実際に走らせたところ JIT が miscompile することが判明 (#280)。 | [x]    |
| 10.G  | WasmGC 実装 — `Value.anyref` arm 追加 + `Module.needs_gc_heap` parse-time flag + `needs_heap_detector.zig` (type/import/table/global/function/element OR 走査) + `feature/gc/heap.zig` per-Store contiguous slab + `Collector` vtable + regalloc stack-map axis (ADR-0113 §C; per-Instance side-table) + `collector_null.zig` (α) + `delegation.zig` (Mode A 自前 + Mode B host root provider) + `i31.zig` + `type_hierarchy.zig` (RTT 8-deep) + `op_gc.zig` (struct/array/ref.test/ref.cast/br_on_cast family) + `op_i31.zig` (convert_extern/any) + `collector_mark_sweep.zig` (β; 必須 ship) + `gc_stress_runner` 本実装 + cross fixtures + spec corpus ~578 assertion + realworld (dart + wasm_of_ocaml + hoot) green。                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          **訂正 2026-08-25**: 行末の `realworld (dart + wasm_of_ocaml + hoot) green` は成立していなかった。3つとも fixture を持たず、レーンは 0 件を緑と報告していた (#226)。GC の realworld 到達は `p10/moonbit/` (#242) で別経路により達成済み。dart / hoot は GC 目的で moonbit と重複するため取り下げ、wasm_of_ocaml のみ GC×EH×TC の交差検証 (ADR-0117) として残す。 | [x]    |
| 10.P  | Phase 10 close — `scripts/check_phase10_close_invariants.sh` (deleted 2026-08-20, ADR-0212 D3) 整備 (23 件 invariant; design plan §8; `-Dwasm=v2_0` シンボル nm 不在 / Module.needs_gc_heap=false で GC infra 呼出ゼロ / `-Dgc=false` 完全 strip / safepoint-free invariant / SKIP-P10-{PARSER,EH,GC,MEM64,CROSS}-GAP=0 / realworld 9 fixture green 等) + **spec-corpus exit (ADR-0133): interp pass=fail=skip=0 + JIT 0-real-fail + 全 JIT skip が deferred-allowlist 上 (multi-memory→§14 / GC-rooting→§11, 各 forward-ref 必須)** + widget 10 IN-PROGRESS → DONE + Phase 11 inline 展開。                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | [x]    |

**Deferred-from-§10 JIT items (ADR-0133 allowlist — each forward-ref'd; no
silent drop).** These are the only JIT skips Phase 10 may close WITH (every
other JIT skip is an in-phase target). The 10.P close-invariant verifies the
live JIT skip set is a subset of this allowlist:

- **multi-memory-on-JIT** → **Phase 14** — JIT codegen for >1 memory. The JIT
  rejects `>1` memory at compile (`src/engine/compile.zig:125`
  `Error.MultipleMemories`); ~458 `multi-memory/` corpus skips. Multi-memory on
  the **interp** is Phase-10 (row 10.M); the JIT codegen follows in §14. (Wasm
  feature, not CI infra — parked in §14 as the JIT-completion carrier; revisit
  if a dedicated multi-memory-JIT phase is warranted.)
- **GC-on-JIT rooting** → **Phase 11** — non-moving GC-on-JIT emits in §10.G,
  but the moving/precise rooting + stack-map walker is deferred (ADR-0128 §2 /
  ADR-0115 / D-211); ~20 gc corpus skips ride this.

### Phase 11 — WASI 0.1 full + bench infra

**Goal**: production-ready WASI 0.1 + complete bench harness.

**Exit criterion**:

- All 50 realworld samples pass on Mac + Linux.
- Windows realworld subset (25 samples, C+C++ tier as v1) passes.
- `bench/history.yaml` gets per-merge automatic recording on Mac
  natively, Linux via ubuntunote (per ADR-0067), and Windows via `windowsmini` SSH
  (`scripts/run_remote_windows.sh`).
- `bash scripts/run_bench.sh --quick` works locally.
- **SIMD per-op gap analysis vs (wasmtime, wazero, wasmer)** —
  carried over from §9.10 per Track A Option (3) (see
  `.dev/phase10_prep/track_a_9.10_scope.md` + ADR-0043 Revision
  history 2026-05-12 row): identify ops where v2 lags by > 3× the
  median of (wasmtime, wazero, wasmer) and file Phase 15 debt
  entries naming the candidate optimisation (AVX path adoption
  gated on CPUID, MOVAPS preamble peephole at op_simd binop
  sites, SIMD-specific coalescing). v1 reached "adequate for
  embedded" but explicitly accepted ~43× gap to wasmtime (D122);
  v2 inherits this gap as starting point and Phase 11's gap
  analysis produces the profile that drives Phase 15
  SIMD-specific work scope beyond v1 W43/W44/W45 porting. Folds
  into the D-074 bench-infra cohort (`-Dwith-bench-compare` build
  flag, wazero/wasmer in `flake.nix`, per-op SIMD micro-bench
  corpus, gap-analysis script) — single design pass.

**🔒 gate**: no.

**§11 task table** (opened 2026-06-03 at Phase 10 close; rows expand as the phase
progresses):

| Task | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | Done                  |
|------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------|
| 11.0 | Open §11 inline + flip Phase Status widget (Phase 10 → DONE; Phase 11 → IN-PROGRESS).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     | [x]                   |
| 11.1 | WASI 0.1 (preview1) **syscall surface 46/46 (interp)** — completed 2026-06-05 under the **ADR-0161 WASI program**. This counts implemented syscalls, NOT conformance: the official wasi-testsuite scores 58/72 on the interpreter (ADR-0208, D-582/D-583) (the earlier "full" label was a 21/46-subset overclaim; ADR-0161 scheduled + this row records the 21→46 completion). All `std.Io.File`/`std.Io.Dir`-based; per-syscall TDD green Mac + x86_64 + Win64 cross-compile. `proc_raise`=notsup, sockets ×4=notsock (no socket fds in the preopen model — host socket-preopen = D-281). **All-engine WASI DONE**: JIT (D-244, `71cd3c85`) + AOT (D-251, `9750b064`) both do REAL WASI via the shared `jit_dispatch.zig` handlers. Per-syscall detail in D-278 + commits. | [x] `1d2cb8df`        |
| 11.2 | Bench infra — per-merge auto-recording into `bench/history.yaml` on **Mac native + ubuntunote** (`scripts/run_bench.sh --quick` local path). **Windows bench timing deferred per ADR-0137 / D-249** (hyperfine absent on `windowsmini`; not autonomously provisionable). 3-host *correctness* reconcile unaffected.                                                                                                                                                                                                                                                                                                         | [x]                   |
| 11.3 | SIMD per-op gap analysis vs (wasmtime, wazero, wasmer) — identify ops lagging > 3× the median; file Phase 15 debt entries (carried from §9.10 Track A). Profile: `bench/results/simd_gap_profile_p11_3.md` (0/12 ops > 3×; arm64 dot/extmul emit hole → D-246).                                                                                                                                                                                                                                                                                                                                                         | [x]                   |
| 11.4 | **Moved to Phase 15 (ADR-0135)**. GC-on-JIT precise rooting (D-211) is untestable without GC reclamation — a missed root can only UAF once objects are freed, and the Phase-10 collector is β no-reclaim (`collector_mark_sweep.zig:214`); ADR-0128 §2 = "rooting becomes load-bearing only when reclamation lands". Reclamation was unowned (not in §11.P exit, nor Phase 12/13/14). Re-sequenced: rooting + reclamation land together in Phase 15 (optimisation tier per P14; non-moving no-reclaim is correctness-safe to defer). Row preserved for citation lineage.                                                 | [~] moved to Phase 15 |
| 11.P | Phase 11 close — exit criteria met (50 realworld Mac+Linux + Windows realworld subset green on windowsmini `bbc4900b` + bench auto-record **Mac+Linux** (Windows bench deferred ADR-0137/D-249) + SIMD gap profile) + 3-host `test-all` reconcile GREEN (windowsmini run-2 `bbc4900b` restored post-Phase-10-EH/GC-on-JIT, Win64 arg-marshal + RSP-parity fixes) + widget 11 → DONE + Phase 12 inline expand.                                                                                                                                                                                                              | [x]                   |

### Phase 12 — AOT compilation mode

**Goal**: `zwasm compile` produces `.cwasm`; `zwasm run *.cwasm`
loads in fewer-than-startup-of-JIT time.

**Substrate inherited from §9.8b/8b.3** (per ADR-0040 migration):
the generator pipeline + `.cwasm` v0.1 format land in §9.8b
(ADR-0039); Phase 12 finalises the consumer side. The §9.8b
artefacts (`src/engine/codegen/aot/{format, serialise,
produce}.zig` + `src/cli/compile.zig`) are the loader's contract.

**Exit criterion**:

- `.cwasm` format defined: header + serialised regalloc + machine
  code + relocation table. **Loader reads against `format.zig`'s
  60-byte `CwasmHeader` + 12-byte `CwasmFuncMeta` + 9-byte
  `CwasmReloc` shapes** (ADR-0039 + Revision 2 numeric
  correction).
- AOT and JIT outputs are differential-test-equivalent.
- Cross-compile (`zig build -Dtarget=x86_64-linux`) works; cross-
  produced `.cwasm` runs on the target.
- **Cold-start bench-delta**: load + first-call time vs JIT
  first-invocation ≥30% improvement on at least 3 v1-class
  hyperfine fixtures (target derived from `private/notes/p8-8b3-
  aot-survey.md`'s 30-50% cold-start estimate; concrete
  threshold set when §9.12 task table expands). **This is the
  bench-delta obligation that §9.8b/8b.3 deferred per ADR-0040.**
- **Stack-map emission compatible with GC root walker** (per
  ADR-0117 invariant I4 + ADR-0115/0116 stack-map side-table):
  `.cwasm` format carries per-callsite stack-map entries
  serialised in the same shape as JIT-mode populates them, so
  the AOT-loaded image can be GC-root-walked identically.
  Required when `Module.needs_gc_heap == true`; for pure
  Wasm 1.0/2.0 `.cwasm` artefacts the stack-map section is
  empty (zero-overhead).

**🔒 gate**: no.

#### §12 task table

| Row   | Task                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               | Status                |
|-------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------|
| 12.0  | Open §12 inline + flip Phase Status widget (Phase 11 → DONE; Phase 12 → IN-PROGRESS).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | [x] `12dad700`        |
| 12.1  | `.cwasm` loader — `zwasm run *.cwasm` reads a §9.8b-produced artefact against `format.zig`'s `CwasmHeader` + 12-byte `CwasmFuncMeta` + 9-byte `CwasmReloc` (ADR-0039 Rev 2; header v0.2 = 68 B w/ exports section per ADR-0138); load + relocate + execute via a standalone runtime. Stateful `.cwasm` (memory/globals/imports) → §12.3b.                                                                                                                                                                                                                                                                                                                                                                                                      | [x]                   |
| 12.2  | AOT ↔ JIT differential-test equivalence (same fixtures, identical observable results both paths).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | [x]                   |
| 12.3  | Cross-compile (`zig build -Dtarget=x86_64-linux`) + cross-produced `.cwasm` runs on the target host (3-host per ADR-0067). Toolchain cross-compile via `scripts/check_aot_cross_compile.sh` (gate_merge); native per-host produce→run via `runCwasm`. Cross-ARCH *emission* stays deferred (ADR-0039 Alt D).                                                                                                                                                                                                                                                                                                                                                                                                                                      | [x]                   |
| 12.3b | **Stateful `.cwasm` execution (ADR-0139; promoted from D-250)** — serialise module state into `.cwasm` v0.3 + reconstruct a real runtime from the artefact alone. **DONE for the COMPUTE subset** (ADR-0140): globals (`797a7ef0`), memory + data segments (`58e97a09`), table 0 + element segments / `call_indirect` (`9b416428`) — real memory/globals/table compute modules run AOT (12/12 SIMD corpus fixtures `compile`+`run`). **WASI/host imports DONE** (D-251, `9750b064`): `.cwasm` v0.4 serialises import `(module,name,kind)`; `runEntryWasi` rebuilds `host_dispatch_base` via `jit_dispatch.lookup` + attaches a WASI Host — a WASI-importing `.cwasm` does REAL WASI (e.g. `proc_exit(42)`→exit 42), 2-host green (Mac+ubuntu). | [x]                   |
| 12.5  | **Moved to Phase 15 (ADR-0141)**. `.cwasm` stack-map section (per-callsite GC-root entries per ADR-0117 I4) co-defines with the JIT-side `zir.GcRootMap`, which is an empty placeholder until Phase-15 precise rooting (ADR-0135/0128, D-211) — serialising a non-existent shape now is premature. Lands WITH the Phase-15 rooting work (JIT + AOT halves together; mirrors §11.4→Phase 15). Row preserved for citation lineage.                                                                                                                                                                                                                                                                                                                | [~] moved to Phase 15 |
| 12.4  | Cold-start bench-delta: AOT load + first-call vs JIT compile + first-call **≥30%** on ≥3 **compute (zero-import) fixtures** (re-scoped from "v1-class" per ADR-0140 — WASI-importing fixtures run on neither path until JIT-WASI/D-244; the SIMD corpus + zero-import compute kernels run AOT today). The ADR-0040-deferred §9.8b/8b.3 bench obligation; threshold from `private/notes/p8-8b3-aot-survey.md`. **DONE** — `scripts/bench_aot_coldstart.sh`: 6/6 SIMD fixtures 33-37% faster (Mac; `bench/results/aot_coldstart.md`).                                                                                                                                                                                                           | [x]                   |
| 12.P  | Phase 12 close — AOT-core exit criteria met: loader (§12.1) + JIT↔AOT differential (§12.2) + cross-compile (§12.3) + stateful-compute exec (§12.3b) + cold-start ≥30% (§12.4). Stack-map (§12.5) → Phase 15 (ADR-0141); WASI imports → D-251 (ADR-0140). 3-host reconcile (windowsmini test-all + cross-compile gate; Phase-12 AOT exec skips Win64). Widget 12 → DONE; Phase 13 inline expand.                                                                                                                                                                                                                                                                                                                                        | [x]                   |

### Phase 13 — C API full (wasm-c-api conformance) 🔒

**Goal**: wasm-c-api conformance test passes.

**Exit criterion**:

- All ~130 functions in `wasm.h` implemented.
- `wasi.h` and `zwasm.h` ABI surface complete.
- `test/c_api_conformance/` (wasmtime example port + zwasm-specific
  tests) fail=0.
- `examples/{c_host, zig_host, rust_host}/` all build and run on all
  3 OS.

**🔒 gate**: yes (end-of-phase wasm-c-api conformance gate; NOT an entry
hard-gate — Phase 13 opens autonomously per the §12.P close, ADR-0141).

#### §13 task table

| Row  | Task                                                                                                                                                                                                                                                                                                                                                                                                                    | Status |
|------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------|
| 13.0 | Open §13 inline + flip Phase Status widget (Phase 12 → DONE; Phase 13 → IN-PROGRESS).                                                                                                                                                                                                                                                                                                                                | [x]    |
| 13.1 | `wasm.h` surface audit (Step 0) — inventory the ~135 `wasm.h` functions; map implemented vs missing; file the gap list by category. **DONE** → `.dev/phase13_capi_gap.md` (54/135 impl; absent: type constructors/queries, externtype/import-export types, frames, foreign, wasi builders). §13.2 work order: type constructors first (load-bearing).                                                                | [x]    |
| 13.2 | Implement the missing `wasm.h` surface (valtype / functype / globaltype / tabletype / memorytype / ref / global / table / memory / extern / trap / frame / foreign), grouped by category; each category red→green. **Load-bearing surface DONE; remainder (per-entity host_info + degenerate instance/extern as_ref) → D-253, §13.4-driven (ADR-0142).**                                                             | [x]    |
| 13.3 | `wasi.h` + `zwasm.h` ABI surface complete. v0.1 surface = `new`/`delete` + `set_args`/`set_envs`/`inherit_stdio` (`47298cd1`) + `set_wasi`. `inherit_argv`/`env`/`preopen_dir` **deferred post-v0.1** (one root cause: a C-library context has no Zig-0.16 `Init`/io token; decls removed) per ADR-0143 / D-255 → re-add with the C-API io infra (D-251 / Phase-14+). RESOLVED 2026-06-13: `preopen_dir`+`inherit_env` re-added via ADR-0184 engine-owned io (D-255 discharged; `inherit_argv` stays deferred).                                                  | [x]    |
| 13.4 | `test/c_api_conformance/` — wasmtime C-API example port + zwasm-specific tests, fail=0 (3-host). DONE: 5 examples via `zig build test-c-api-conformance` (in test-all), fail=0 Mac+ubuntu (windowsmini = §13.P boundary).                                                                                                                                                                                             | [x]    |
| 13.5 | `examples/{c_host, zig_host, rust_host}/` build + run on all 3 OS. c_host (`test-c-api`) + zig_host (`run-zig-host`) in test-all = 3-OS; rust_host (`run-rust-host`) Mac-only (test hosts rustc-free by design) → rust-3-OS sub-clause deferred to §13.P per ADR-0142 / D-254.                                                                                                                                        | [x]    |
| 13.P | Phase 13 close 🔒 — wasm-c-api conformance fail=0 ✓ + examples 3-host ✓ + audit_scaffolding 0-block ✓ + 3-host reconcile **re-scoped (ADR-0144)**: Phase-13 C-API deliverables 3-host-green (conformance + c_host + zig_host pass on windowsmini, Build Summary 61/63); sole win failure = D-245 win64 SIMD-JIT host→JIT flakiness (Phase-11, elevated+routed, NOT Phase-13). widget 13 → DONE; Phase 14 expanded. | [x]    |

### Phase 14 — CI matrix infrastructure

**Goal**: GitHub Actions matrix replaces ad-hoc local-only gating.

**Exit criterion**:

- `.github/workflows/pr.yml` runs the full test suite on
  `macos-15`, `ubuntu-22.04`, `windows-2022`.
- `.github/workflows/main.yml` records per-merge bench numbers on
  all 3 OS into `bench/history.yaml`.
- `.github/workflows/nightly.yml` runs fuzz + spec-bump + proposal-
  watch.
- `.github/workflows/bench_baseline.yml` (workflow_dispatch) records
  arch baselines on demand.
- The local `pre_push` hook still works; CI is a second line, not
  the first.

> **Revision 2026-08-19 (ADR-0211)**: this exit criterion is a Phase-14-era
> record. The premise it names (CI second-line) was reversed by ADR-0076 D9;
> `nightly.yml` is retired (revival hints in D-593), the per-merge recorder
> convention is retired in favor of the `bench_watch.yml` nightly
> gross-regression watch, and all three `ci.yml` legs are blocking.

**🔒 gate**: no.

#### §14 task table

| Row  | Task                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | Status |
|------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------|
| 14.0 | Open §14 inline + flip Phase Status widget (Phase 13 → DONE; Phase 14 → IN-PROGRESS).                                                                                                                                                                                                                                                                                                                                                                                                                | [x]    |
| 14.1 | `.github/workflows/pr.yml` — `zig build test-all` matrix on `macos-15` + `ubuntu-22.04` + `windows-2022` (mirrors the local 3-host gate; manual `workflow_dispatch` per §14.5 CI-second-line; reuses bench.yml's zig-0.16.0 install; actionlint-clean; win leg flaky on D-245).                                                                                                                                                                                                                       | [x]    |
| 14.2 | Per-merge bench recorder → `bench/results/history.yaml`. **Satisfied by existing `.github/workflows/bench.yml`** (workflow_dispatch; bench-mac + bench-linux → fragment artifacts → aggregate bot-commit). Scope is **2-host (Mac+Linux) per ADR-0137**; windows-timing leg deferred (**D-249**, hyperfine absent on windowsmini — perf-completeness, not a gate). No separate `main.yml` (would duplicate bench.yml; auto-on-merge trigger conflicts with the 2026-05-25 manual-CI decision). **Revision 2026-08-19 (ADR-0211 D2): the per-merge convention is retired; `bench_watch.yml` (nightly, commit-free, ≥2x/≥2-fixture alert) is the regression watch.** | [x]    |
| 14.3 | `.github/workflows/nightly.yml` — fuzz + spec-bump + proposal-watch. **DONE** (`17e3b6f1`+`1fc63016`): 3/3 legs — (1) fuzz campaign (`gen_fuzz_corpus.sh campaign` → `zig build fuzz-campaign`, ~2000 smith modules; harness `6c80c229`+`16584c1c` = parse/validate/instantiate crash-fuzz); (2) proposal-watch freshness (`check_proposal_watch.sh`, 90d); (3) spec-bump drift (`check_spec_bump.sh` vs `.dev/spec_pin.yaml` Wasm-3.0 baseline). workflow_dispatch; actionlint-clean. **Revision 2026-08-19 (ADR-0211 D1): nightly.yml retired — never scheduled in this tree and rotted around its legs; revival hints in D-593.** | [x]    |
| 14.4 | `.github/workflows/bench_baseline.yml` (`workflow_dispatch`) — record per-arch bench baselines on demand. **DONE**: runs `record_baseline_v1_regression.sh` on macos-15 + ubuntu-22.04 (2-host per ADR-0137; win deferred D-249), uploads `baseline_v1_regression.yaml` as a per-arch artifact (per-host floor, not committed). actionlint-clean.                                                                                                                                                      | [x]    |
| 14.5 | Confirm the local `pre_push` hook still works + document CI-as-second-line (not first); CI green ≠ skip local gate. **DONE**: `.githooks/pre-push` wired (`core.hooksPath=.githooks`), runs 4 audit gates every push (verified live this session); CI-second-line documented in the hook header + ADR-0076 D4 (merge gate is manual `gate_merge.sh`; CI workflows are `workflow_dispatch`).                                                                                                            | [x]    |
| 14.P | Phase 14 close (🔒 gate: no). **DONE** — re-scoped (ADR-0145): CI workflows (pr/bench/bench_baseline/nightly) authored + actionlint-clean (workflow_dispatch, §14.5 CI-second-line); the new `test-fuzz` test-all layer verified **3-host-green** (Mac+ubuntu+windowsmini reconcile, `29 processed, 0 crashes` each); audit_scaffolding 0-block. Sole windowsmini failure = D-245 win64 SIMD-JIT (the same elevated carry as §13.P; deferred to §11.3/Phase-15). widget 14→DONE; Phase 15 expanded. | [x]    |

### Phase 15 — Performance parity with v1 + ClojureWasm migration

**Goal**: zwasm v2 matches v1's bench performance and runs
ClojureWasm. **Per ADR-0043** (2026-05-12 Track A migration —
§9.10's gap-analysis carrier moved to Phase 11): Phase 15 SIMD
work absorbs (a) v1 W43/W44/W45 ports onto the v2 substrate as
documented below and (b) bench-driven SIMD-specific
optimisations surfaced by Phase 11's per-op gap analysis (AVX
path adoption gated on CPUID, MOVAPS preamble peephole at
op_simd binop sites, SIMD-specific coalescing — concrete
candidates filed as debt entries by Phase 11). The "v1 parity"
target is the floor, not the ceiling: exceeding v1's ~43× gap
to wasmtime (per v1 D122 self-assessment) is in scope where
Phase 11's gap profile + a feasibility-supported
debt entry name a candidate.

**GC reclamation + conservative rooting** (moved here per ADR-0135; ex-§11.4,
D-211; closed `be4357be`): the Phase-10 collector was non-moving + β no-reclaim
(mark-sweep wired, dead bytes leaked). §15.1 added actual reclamation (external
free-list reuse, ADR-0147) + a heap-pressure collection trigger (ADR-0146) +
an object-start-validated conservative native-stack scan (ADR-0128 §2) — the
rooting mechanism a NON-moving collector needs. ADR-0135's safety argument (a
missed root can only UAF once something frees) is satisfied by the conservative
scan landing WITH reclamation. **Re-scoped at close (ADR-0148 carve-out)**: the
precise `zir.GcRootMap` stack-map walker + §12.5 AOT GC-root serialization are
NOT required for a non-moving collector (ADR-0128 §2) and have no committed
consumer → deferred to **D-211** (barrier: a moving collector OR AOT GC-root
serialization). The JIT alloc trampoline's own collection trigger (separate
`*JitRuntime` root model) = **D-258**; interp reclamation reclaims JIT-allocated
dead objects whenever the interp path triggers. Zero codegen change.

**Substrate inherited from §9.8b/8b.1 + 8b.2** (per ADR-0040
migration):

- Coalescer scaffolding lands at §9.8b/8b.1 per ADR-0036 (pass
  module + `CoalesceRecord` types + `func.coalesced_movs` slot
  + `isCoalesceCandidate` predicate + `compile.zig` pipeline
  placement). Phase 15 layers concrete **detection logic**
  (operand-stack vreg-numbering simulation + same-slot-event
  subscription against the §9.8b/8b.2-c LIFO free-pool).
- LIFO free-pool allocator at §9.8b/8b.2-c per ADR-0037
  Revision 2 (busy-mask scan replaced with explicit free-pool;
  semantic equivalence). Phase 15 extends with **class-aware
  allocation** per D-036 §option-b + ADR-0038 (liveness type-
  tagging + dual-pool GPR/FP slots + tighter `spillBytes()`
  accounting).

**Exit criterion**:

- v1's optimisations (W43 SIMD addr cache, W44 reg class, W45 SIMD
  loop persistence, W54-class loop-invariant magic-constant hoist,
  D116-D135 line items as applicable) are ported as **clean
  additions** onto the v2 substrate (since the slots are already in
  `ZirFunc`). No retrofits.
- **Coalescer detection bench-delta**: ≥5% on loop-heavy
  fixtures with the §9.8b/8b.1 scaffolding's detection layer
  populated (target from `private/notes/p8-8b1-coalescer-
  survey.md`). **This is the runtime-bench obligation that
  §9.8b/8b.1 deferred per ADR-0036 + ADR-0040.**
- **Class-aware allocator bench-delta**: ≥3% on FP-heavy
  fixtures with the dual-pool allocator landed (per ADR-0038
  + ADR-0040). Combined coalescer + class-aware aggregate
  ≥10% on at least 3 v1-class fixtures.
- Bench shows no unexplained regression vs zwasm v1 main.
- ClojureWasm CI green when its `zwasm` dependency points to a local
  path of this repository (via `build.zig.zon` `path = ...`).
  No commits to ClojureWasm side are required for v2-experimental
  validation.

**🔒 gate**: no, but extensive bench validation.

#### §15 task table

| Row  | Task                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | Status |
|------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------|
| 15.0 | Open §15 inline + flip Phase Status widget (Phase 14 → DONE; Phase 15 → IN-PROGRESS).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | [x]    |
| 15.1 | **GC reclamation + conservative rooting** (non-moving; ADR-0128 §2 + ADR-0146/0147/0148): external free-list reuse (ADR-0147) + heap-pressure collection trigger (ADR-0146) + object-start-validated conservative native-stack scan (ADR-0128 §2). Bounded-cursor proof landed (`be4357be`). **Re-scoped (ADR-0148 carve-out)**: the precise `zir.GcRootMap` stack-map walker + §12.5 AOT GC-root serialization are NOT needed for a non-moving collector (ADR-0128 §2) → deferred to **D-211** (barrier: a moving collector OR AOT GC-root serialization). JIT-trampoline collection trigger = **D-258**. Mac-local.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | [x]    |
| 15.2 | **Mov-reduction perf — investigated, empirically unreachable → folded into §15.P** (ADR-0149 + 2026-06-04 Revision). Slot-alias coalescing = ~0 headroom (gpr helpers already elide reg-resident movs; no vreg-to-vreg movs). Re-targeted to redundant spill-reload elim, then MEASURED: total spill traffic is only 2.7–5.6% of emitted instructions, the adjacent-round-trip eliminable subset 1.4–2.2% → a ≥5% perf win is robustly unreachable in v2's deterministic-slot spill-everything emit. The residual store-then-reload peephole folds into §15.P (opportunistic). Perf parity shifts to §15.3 + §15.4 + §15.P aggregate.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | [x]    |
| 15.3 | **Class-aware allocator — measured FP-spill = 0%, ≥3% unreachable → folded** (ADR-0150). Measurement: FP-heavy fixtures (nbody/matrix) hit ZERO `fpLoadSpilled` (13 V-regs never overflow); resolution is already class-aware (D-036); a dual-pool allocator has no FP spills to eliminate → no FP-perf. Tighter `spillBytes()` is footprint-only (0 runtime instrs) → **D-259** cleanup, not perf. Regalloc-axis perf (§15.2+§15.3) both ~0 headroom — v2 emit already efficient. Perf lever shifts to §15.4 (SIMD/compute axis) + §15.P parity-vs-v1.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | [x]    |
| 15.4 | **SIMD: coverage (D-246 DONE) + perf ports (measure-first)**. ✅ **D-246 RESOLVED** (`078ffde5`→`1029e5b4`): arm64 JIT SIMD emit now at full coverage parity with x86_64 — 26 ops closed (dot + 12 extmul + 8 sat-arith + q15mulr + 4 extadd_pairwise), all clang-verified encoders + the missing lowering arms + JIT execution fixtures. Perf ports v1 W43/W44/W45 **MEASURED → folded to §15.P** (ADR-0151): W43 addr-cache + W45 loop-persistence redundancies are real but v2 already 0.5–0.8× the comparator median (0/12 ops lag >3×); W44 reg-class already done (D-036). W45 (v1's 78x→10x lever, a large allocator change) gets a §15.P loop-isolated measurement before any reconsideration.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | [x]    |
| 15.5 | **D-245 win64 host→JIT trampoline** — the cross-phase windows-CI/bench-green blocker (re-scoped past at §13.P/§14.P, ADR-0144/0145). Asm trampoline preserving the win64 callee-saved set (RBX/RBP/RDI/RSI/R12–R15 + XMM6–15) around the `entry.zig invokeAndCheck*` seam (return-value + arg'd + win64 variants); template = arm64 `8eca59e3` / x86_64-SysV `de576a76`. Verify windowsmini `test-all` deterministic-green. **Hard/remote — best as a deliberate session.** ✅ Closed: clobber-trampoline `510ffce9` (arch-uniform cohort save via non-inline `@call`); D-260 x86_64 SIMD bugs (q15mulr/extadd) surfaced by the win64 run + fixed `3a778080`; **test-all 3-host green** (Mac + ubuntu x86_64 + windowsmini win64). Root fix D-210 NOT taken (per-seam patch).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | [x]    |
| 15.6 | **ClojureWasm CI green** with its `zwasm` dep pointing at a local `build.zig.zon` `path = …` to this repository (no ClojureWasm-side commits needed for v2-experimental validation). **⏸ DEFERRED (ADR-0152 → D-264)**: `ClojureWasmFromScratch` is itself a from-scratch v1 redesign IN PROGRESS (branch `cw-from-scratch`, v0.0.0, deps=zlinter only, no `zwasm` dep, no CI); the stable cw is v0.5.0 on `main`. Its zwasm-v2 wasm-FFI consumer is cw's OWN future internal phase → nothing to validate today. Barrier dissolves when cw-v1 lands committed `@import("zwasm")` source. v2 package-consumability already proven by `examples/zig_host/` (ADR-0109).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | [ ]⏸   |
| 15.P | Phase 15 close — **parity-vs-v1 validation** (fixed combined-≥10% replaced per ADR-0149/0150: regalloc-axis §15.2+§15.3 measured ~0 headroom, v2 emit already efficient). **HARD gate (D-263, not optional)**: (1) an actual **v2-vs-v1 steady-state bench** on ≥3 loop-heavy + ≥1 SIMD-loop fixture (v1 from its clone / existing baseline) — no unexplained regression vs v1; (2) the **W45 loop-isolated measurement** (≥50M-iter v128-local-carrying loop / no-op-module baseline subtraction, per ADR-0151 — if v2's per-iteration v128-reload dominates a long loop, **re-open W45** with the data) + record the already-efficient finding (§15.2/15.3/15.4 all measured) + opportunistic D-259 spillBytes cleanup if a net win. 3-host reconcile = **DONE** (D-245 landed `510ffce9`, test-all 3-host green). **§15.6 DEFERRED (ADR-0152 → D-264)** — Phase 15 closes WITHOUT it. + widget 15 → DONE + Phase 16 inline expand. **✅ DONE**: (1) v2-vs-v1 bench done (`bench/results/s15p_parity_vs_v1.md`) — found a real 2.30× regression on loops reading a loop-carried local (D-265), NOT hand-waved; (2) W45 loop-isolated measurement done → v128-local loop 0.49× (v2 2× faster) → W45 stays folded (ADR-0151 re-open trigger NOT met). The D-265 regression was resolved by the **register-homing rework campaign** (ADR-0153, phases I–V; arm64 `a64c72a1`/`5d1dd221` + x86_64 `e8b7ad10`): loop-local reload penalty ELIMINATED on both backends (arm64 2.30×→0.97×; x86_64 reads-i/control differential 2.4×→1.0×; 3-host green incl. ubuntu test-all). ADR-0149/0150 Revision landed (the "~0 headroom" fold measured the wrong proxy). D-259 spillBytes = footprint-only, left open (no perf); native-x86_64 absolute ROI = D-266 note (confirmation-only). | [x]    |

### Phase 16 — Completion finalization (完成形); release is user-only (ADR-0156)

**Goal**: bring zwasm v2 to the 完成形 bar — clean final design + good design +
lightweight-yet-fast + full-featured + 100% spec — **across the runtime AND all
consumer surfaces (C API / Zig API / CLI)**, designed to あるべき論 + industry
standards (breaking v1 freely; v1 full-parity is NOT the goal — §1.2).

**There is NO release in this phase.** Tagging / publishing / any main cutover is
a **manual, user-only act** (ADR-0156); the loop has no autonomous path to a
release and **no release gate exists** as a loop construct. The loop works the
items below toward 完成形 indefinitely and pays debt down aggressively;
version / tag / cutover are a separate, explicit future user decision.

**Completion bar** (what "done" means — not a release trigger):

- All Phase 0–15 correctness floors hold (§1.2): Wasm 3.0 + WASI 0.1 + 4-platform
  JIT + spec testsuite 100%/0-skip + wasm-c-api conformance.
- The surfaces (C / Zig / CLI) are at their あるべき論 minimal industry-standard
  shape, audited and dogfooded; no "usable from CLI but unreachable from the API"
  gaps; the public docs match the settled surface.
- Memory-safety verified (the D-258 → D-261 GC-on-JIT rooting chain), debt ledger low.

#### §16 task table (reframed 2026-06-04 per ADR-0156)

Order: settle the **surfaces** (audit + dogfood) and the **safety** debt FIRST;
**docs come last** (no point finalising docs for a surface that is still being
designed). The §16.1 migration guide already exists and will be revised as the
surface audits land. Debt repayment + industry research (web search / reference
runtimes) are cross-cutting, not a single row.

**Root-cause discipline (user directive 2026-06-04):** the surface audits +
dogfooding WILL surface bugs, unimplemented paths, and test gaps/insufficiencies.
Each gets **root-cause investigation + a fundamental fix**, never a temporary
patch — per [`no_workaround.md`](../.claude/rules/no_workaround.md) +
[`investigation_discipline.md`](../.claude/rules/investigation_discipline.md) +
[`extended_challenge.md`](../.claude/rules/extended_challenge.md). A gap that
cannot be root-fixed in-cycle becomes a named `D-NNN` debt row with a clear
discharge predicate, not a silent workaround.

| #    | Task                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | Status         |
|------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------------|
| 16.0 | Open §16 inline + flip Phase Status widget (Phase 15 → DONE; Phase 16 → IN-PROGRESS). Reframed to completion-finalization per ADR-0156.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | [x]            |
| 16.1 | `docs/migration_v1_to_v2.md` — v1→v2 migration guide, grounded in the shipped+tested API (`src/zwasm.zig` facade). Surfaced D-267 (§10.A/ADR-0025 name `Runtime`, ships `Engine`). **Will be revised** as the §16.2–4 surface audits settle.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | [x] `58a483e8` |
| 16.2 | **C-API surface audit vs wasm-c-api** — audit `include/wasm.h` + `src/api/` against the upstream wasm-c-api standard wasmtime/wasmer follow; close any divergence; **fix the tests too** if they encoded a wrong shape. Industry-standard is the bar. **✅ DONE**: `wasm.h` byte-identical to upstream but **129/293 extern fns were unimplemented** (link errors); implemented ALL → **gap 0 (293/293)** (`scripts/capi_surface_gap.sh`). A type-accessors → B vec-ops → C config → D val → instance.zig split (ADR-0157) → host_info (27) → ref-cast same/as_ref/copy all 9 types (ADR-0158) → tagtype/EH → module serialize/share (byte-model). Residual semantic limits debt-tracked: standalone/instance/foreign `_copy`→null (D-253-D), val `of.ref`=raw-payload (D-269), serialize=source-bytes no-AOT-cache (D-271).                                                                                                                                                                                                                                                                     | [x] `e9367bb2` |
| 16.3 | **Zig-API surface review (あるべき論)** — confirm the `Engine`/`Module`/`Instance`/`Trap`/`Value`/`TypedFunc`/`Linker`/`Caller`/`Memory` surface is the minimal, clean, idiomatic shape; **reconcile D-267** (`Runtime`/`Module.parse` spec wording → shipped `Engine`/`compile`, or alias) — Revision on ADR-0025. Breaking-allowed. **✅ DONE**: surface confirmed minimal/clean/idiomatic (wasmtime/wasmer shape, 13 facade tests, code unchanged — no code edit needed). D-267 reconciled code-as-truth: `Runtime`/`Module.parse` were NEVER shipped (ADR-0025 superseded by ADR-0109 pre-impl); synced ROADMAP §10.A + ADR-0025 Revision note → shipped `Engine`/`compile`. Optional gap: Zig-level Global/Table accessors not exposed (D-272).                                                                                                                                                                                                                                                                                                                                                  | [x]            |
| 16.4 | **CLI surface review (あるべき論, breaking-allowed)** — design the truly-necessary, simple, industry-standard CLI; v1's `validate`/`inspect`/`features`/`wat`/`wasm` + capability-flag sprawl is NOT owed. Decide + implement the kept surface; close "CLI-only vs API-only" capability gaps surfaced by §16.5. **✅ DONE** (ADR-0159): live survey (wasmtime/wazero ship run+compile, no validate) → surface locked at **`run` + `compile`** + standard `--version`/`--help`/`help` + explicit unknown-subcommand error (testable `cli/dispatch.zig`). Removed 5 dead aspirational stubs (validate/inspect/features/wat/wasm — never dispatched); validation stays programmatic (C-API/Engine.compile), wat↔wasm/introspection → wasm-tools/wabt. Reconciled §10.1/§10.2/§10.3 to code-as-truth (`--engine` per ADR-0136, not the stale `--interpreter`; shipped `run` flags). Flag-parity gap vs wasmtime (`--invoke` args/result-print, `--env`/`--fuel`/`--timeout`) debt-tracked D-273 for §16.5 evaluation.                                                                                 | [x]            |
| 16.5 | **Minimal-wrapper dogfooding** — a local `build.zig.zon` path-dep consumer that uses zwasm v2 as a Zig library; verify it stands up cleanly, hunt ergonomic gaps + "usable from CLI but unreachable from the API" mismatches; reuse the existing test corpus where adaptation makes it serve double duty. (cw-v1 dogfooding stays deferred — D-264.) **✅ DONE**: stood up `examples/zig_dep/` (external path-dep consumer) + `scripts/check_zig_consumer.sh`. Found+fixed a real consumability bug — `build.zig` published no `b.addModule("zwasm")`, so external `dep.module("zwasm")` panicked (`zig_host` only shared the in-repo private module; ADR-0109's claim was never truly exercised) → now public (c1 `3bfa460a`). Proved the full facade externally: host imports (c2), Memory (c3); **closed D-272** with new Zig Global (c4) + Table (c5) accessors (`value_conv.zig` shared converter). c6 sweep: multi-result ✓ (T1.6), Engine config honestly-empty, no CLI-only-vs-API gap; minor `Module.instantiate` coarse-error noted **D-275**. Consume wart **D-274** (zlinter eager fetch). | [x]            |
| 16.6 | **Memory-safety completion** — D-258 (wire the JIT-trampoline GC collection trigger) → D-261 (the GC-on-JIT conservative-rooting **adversarial** test that D-258 unblocks). Close the latent-UAF gap before calling the GC-on-JIT path 完成形. **✅ DONE** (ADR-0160): **D-258** wired `root_scope.maybeCollectJit` (conservative-native-stack-scan-only — pure-JIT means all live GcRefs are on the native stack at the trampoline CALL) into both JIT GC-alloc trampolines; **D-261** adversarial test — a JIT fn holds struct A (field=42) across a collect-forcing `struct.new` B; A survives (=42) vs swept-and-slot-reused (=0), deterministically proving the rooting. Green Mac + ubuntu `test-all` (x86_64 native-stack scan verified). Residual **D-276** (callee-saved-register-resident worst case not independently forced; common case safe).                                                                                                                                                                                                                                             | [x]            |
| 16.7 | **Docs finalization (AFTER §16.2–6 settle)** — `README.md` (install, 3-line happy paths, Wasm proposal/tier table §11, 3-OS matrix), `docs/reference/` (API ref for the settled surface), `docs/tutorial/`, `CHANGELOG.md`. Match the finalised surface, not a moving target. **✅ DONE**: rewrote `README.md` (stale Phase-9 → settled state + Embedding happy-paths) + new `CHANGELOG.md` (Keep-a-Changelog [Unreleased]; no tag, ADR-0156) (`12390815`); curated `docs/reference/{zig_api,c_api,cli}.md` + `docs/tutorial.md` (`3a5e8ba0`). Writing the C ref surfaced **D-277** (`include/zwasm.h` is an empty placeholder — §10.4 extensions never shipped; WASI-from-C is `wasi.h`).                                                                                                                                                                                                                                                                                                                                                                                                           | [x]            |

> **No 🔒 release gate row.** Per ADR-0156 the release is user-only and outside
> the loop; the loop never prepares-then-tags. When every item above hits 完成形,
> the loop keeps refining / paying debt — it does not surface "ready to release."

### Post-completion — see §9.0 future bucket (no version line, ADR-0181/0186)

The old "v0.2.0 line" queue is retired. Component Model + WASI 0.2 **shipped**
(§1.2 floor); the remaining demand-driven items (threaded EXECUTION, stack-
switching / WASI 0.3, tier promotions) live in **§9.0's genuinely-future
bucket** + §3.3. The optimising tier is permanently out (§3.2).

---

## 10. Consumer surface design

zwasm v2 has three independent consumer surfaces. They share
internal core types (Runtime / Trap / Value) but each has its
own ergonomic shape and stability boundary.

### 10.A Zig library surface (per ADR-0109; §16.3 reviewed, D-267 reconciled)

Zig hosts that import zwasm as a Zig package see the native API
defined by `src/zwasm.zig` per **ADR-0109** (which superseded the
ADR-0025 c_api-veneer shape — `Runtime`/`Module.parse` were never
shipped; the surface is **`Engine`/`compile`**, matching wasmtime/
wasmer). The happy path:

```zig
const zwasm = @import("zwasm");
var eng = try zwasm.Engine.init(alloc, .{});
defer eng.deinit();
var module = try eng.compile(wasm_bytes);
defer module.deinit();
var instance = try module.instantiate(.{});
defer instance.deinit();
try instance.invoke("fib", &args, &results);          // untyped (Value slice)
const fib = instance.typedFunc(fn (i32) i32, "fib");  // typed
```

**Stable surface** (per ADR-0109): `Engine`, `Module`, `Instance`,
`Trap`, `Value`, `TypedFunc`, `Memory`, `Linker`, `Caller`. Host
imports via `Linker` (`defineFunc` / `defineMemory` / `defineWasi`).
Other re-exports under `zwasm.parse / .ir / .engine / ...` exist for
the build system + test runners and are **not** stability-committed.
Breaking changes allowed pre-v1.0; SemVer compatibility starts at v1.0.

§16.3 surface review (2026-06-05): the Engine/Linker/TypedFunc/Memory
set is the minimal, clean, idiomatic wasmtime/wasmer-shaped surface;
v128 access is Zig-native via `Value.v128` (C-API is scalar-only per
D-171). Exported Global/Table accessors at the Zig level are not
exposed (functions + memory cover the 95% host use; C-API has them) —
optional 完成形 enhancement tracked as D-272. ClojureWasm v1 migration
deferred (D-264).

### 10.B CLI surface

(continues below — original §10 content)

### 10.1 Subcommands

Decided + locked by **ADR-0159** (§16.4 surface review, 2026-06-05): the
wasmtime/wazero-aligned あるべき論 shape is `run` + `compile` plus standard
`--version` / `--help`.

```
zwasm run        <wasm-or-cwasm-file> [args...]
zwasm compile    <wasm-file> [-o output.cwasm]
zwasm --version | -V
zwasm --help | -h | help
zwasm            (no subcommand)         # version + build-options banner
```

No bare-file `zwasm <file>` shortcut: the surface is explicit (an
unrecognised first token is a typo → exit 2), avoiding subcommand/file
ambiguity. `run` is always spelled.

`zwasm validate`/`inspect`/`features`/`wat`/`wasm` are **deliberately not
shipped** (ADR-0159): validation is programmatic (C-API
`wasm_module_validate` / Zig `Engine.compile`); introspection + wat↔wasm
conversion are `wasm-tools` / `wabt`'s job. A runtime's CLI is run-it +
compile-it; the surrounding sprawl belongs to the ecosystem.

### 10.2 Engine selection (shipped — ADR-0136, flipped by ADR-0200 / D-496)

- `.cwasm` input → **AOT-loaded** directly (the `CWAS` magic dictates; no
  parse/compile).
- `.wasm` input, no `--engine` → **`auto`** (ADR-0200 §"API shape", flipped in
  D-496 ch6): the JIT on an arch with a backend, transparent interpreter
  fallback otherwise.
- `--engine interp` / `--engine jit` (or `--engine=<k>`) → force one. **Both do
  the full WASI command set** (D-244 closed the JIT-WASI gap, `--dir` preopens
  included); `jit` additionally executes SIMD-128, which the interpreter does
  not.

There is no `--aot` flag (the `.cwasm` extension dictates). The explicit
`--engine <interp|jit>` (rather than wasmtime's interpreter-less
`--interpreter`) reflects zwasm's reality of two real engines.

### 10.3 `run` flags

**Shipped:**

- `--invoke <name>[=arg1,arg2,...]` — run the named export instead of
  `_start` / `main`. With `=args` (comma-separated, parsed by the export's
  param types: i32/i64/f32/f64), the typed results print bare (one per line)
  on stdout. Zero-arg `--invoke <name>` keeps exit-code semantics. Interp
  engine only (JIT/.cwasm entry is zero-arg compute-only).
- `--engine <interp|jit>` — engine selection (§10.2).
- `--dir <host>[:<guest>]` — preopen a host directory for WASI (colon
  separator; guest path mirrors host when omitted).

**Not shipped (deliberately minimal; D-273 tracks the wasmtime-parity gap):**
`--invoke NAME=ARGS` arg marshalling + typed-result printing, `--env KEY=VAL`,
`--fuel N`, `--timeout DURATION`, `--wasi`/`--no-wasi`. These are evaluated
against real need under §16.5 dogfooding — not pre-built.

### 10.4 wasm-c-api layered ABI

`include/wasm.h` is upstream wasm-c-api (complete — gap 0, 293/293);
`include/wasi.h` is the hand-authored WASI host-setup extension
(`zwasm_wasi_config_*`, ADR-0005). `include/zwasm.h` ships the
**instance-level sandboxing extensions** (ADR-0179 #3a-4, 2026-06-12):
fuel, cooperative interruption (cancel/timeout), the host memory cap, and
`zwasm_trap_kind`. The extensions once sketched but still NOT shipped —
allocator injection and the kind-less fast-path `zwasm_func_call_fast` —
remain post-v0.1.0 / evaluated-on-demand, consistent with the lightweight
design (the C-API surface today is `wasm.h` + `wasi.h` + `zwasm.h`).

---

## 11. Test strategy

### 11.1 Unified runner: `zig build test-all`

Test layers are exposed as Zig build steps. There is **no
`bash test/run_all.sh`** — the unified entry point is `zig build`.

| Step                       | Phase intro | What                                               |
|----------------------------|-------------|----------------------------------------------------|
| `zig build test`           | 0           | Unit tests inline in `src/**/*.zig`                |
| `zig build test-spec`      | 1           | WebAssembly spec testsuite (Zig-native runner)     |
| `zig build test-e2e`       | 4           | End-to-end CLI invocations                         |
| `zig build test-realworld` | 4           | 50 known-good wasm samples (matches v1)            |
| `zig build test-c-api`     | 3           | wasm-c-api conformance                             |
| `zig build test-fuzz`      | 5           | Quick fuzz smoke (campaign automation: D-593)      |
| `zig build test-diff`      | 6           | `interp == jit_native` differential                |
| `zig build test-all`       | 0           | All of the above (skips not-yet-implemented steps) |

External tools (`wast2json`, `hyperfine`, `wat2wasm`) are pinned by
`flake.nix`. Build steps `addSystemCommand` them and emit a helpful
error if absent.

### 11.2 Test data policy (uniform across CI / local / OS)

Single rule: **source-of-truth committed; derivatives rebuilt on
demand** — with one exception (heavyweight toolchain outputs).

| Category                                        | source-of-truth (committed)                                                                         | derivative (handling)                                                                                                                                                          |
|-------------------------------------------------|-----------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Self-authored `.wat`                            | `test/spec/wat/*.wat`                                                                               | `.wasm` regenerated by `zig build test-spec`                                                                                                                                   |
| Self-authored `.wast`                           | `test/spec/wast/*.wast`                                                                             | `.json` regenerated via `wast2json`                                                                                                                                            |
| Wasm spec testsuite                             | local copy under `~/Documents/OSS/WebAssembly/testsuite/` (pinned via `scripts/regen_test_data.sh`) | `.json` regenerated                                                                                                                                                            |
| WASI testsuite                                  | upstream `prod/testsuite-base` prebuilt binaries at a pinned SHA                                    | **`.wasm` + manifests + preopen trees committed** under `test/wasi/wasip1_official/` and `test/component/wasip3_official/` (three guest toolchains to rebuild — the heavyweight-toolchain exception; `wasm-tools strip`ped, 96.5 MiB → 5.5 MiB for p1) + `scripts/vendor_wasip{1,3}_official.sh` pin + regen (ADR-0208 D1, ADR-0205 D3) |
| Realworld samples (TinyGo / Rust / emcc / etc.) | C / Rust / Go source under `test/realworld/src/` (committed)                                        | **`.wasm` also committed** under `test/realworld/wasm/` (toolchain reproducibility is heavy; the binary is a snapshot) + `scripts/regen_test_data.sh` documents how to rebuild |
| Bench wasm                                      | source under `bench/runners/src/` or `~/Documents/OSS/sightglass/`                                  | `.wasm` committed under `bench/runners/`                                                                                                                                       |
| Fuzz corpus                                     | none (generated by `wasm-tools smith`)                                                              | gitignored, regenerated locally                                                                                                                                                |

A single script — `scripts/regen_test_data.sh` — re-derives everything
and is identical across Mac / Linux / Windows. CI delegates to the
same script. There is **no per-OS divergence** in test data prep.

`.gitignore` reflects this: `test/spec/json/`, `test/e2e/wast/`,
`test/e2e/json/`, `test/fuzz/corpus/` are gitignored. Realworld
`.wasm` is committed.

### 11.3 Differential testing (Phase 7+)

```zig
test "differential: <name>" {
    const wasm = @embedFile("./testdata/<name>.wasm");
    const ref = try runWith(.interpret, wasm);
    const jit = try runWith(.jit, wasm);
    try expectDeepEqual(ref, jit);
}
```

Combined with the three-platform gate (Mac aarch64 + ubuntunote
Ubuntu x86_64 [per ADR-0067; OrbStack retired] + windowsmini SSH),
the three-way invariant
`interp == jit_arm64 == jit_x86` is enforced without needing a
single host that runs both JITs.

### 11.4 Fuzz strategy

- Corpus: ~1800 wasm modules from `wasm-tools smith` (9 categories:
  mvp, simd, gc, eh, threads, mem64, tailcall, all, invalid).
- Edge cases: hand-crafted (truncated, bad magic, oversized LEB).
- Differential fuzz: random input → both `interp` and `jit_native`,
  assert equal.
- Overnight campaign: automation retired with nightly.yml (ADR-0211
  D1); run on demand, revival hints in D-593. Duration still
  unmeasured.
- Crash files saved to `test/fuzz/corpus/crash_*`. (The "uploaded to
  GitHub Release on failure" leg was aspirational — no workflow ever
  carried it; a rebuilt campaign runner owns that decision, D-593.)

### 11.5 Three-OS verification

CI's `ci-required` runs the 3-OS gate on every PR and is the authority
(ADR-0076 D9). The local fan-out below is an **optional pre-flight**:

- Mac aarch64 native — `bash scripts/gate_merge.sh`.
- Linux x86_64 native — `bash scripts/run_remote_ubuntu.sh test-all` (drives
  the host named by `ZWASM_UBUNTU_HOST`; native hardware, not emulation —
  ADR-0067 retired the OrbStack Rosetta-2 path).
- Windows x86_64 native — `bash scripts/run_remote_windows.sh` (drives the
  Windows SSH host named by `ZWASM_WINDOWS_HOST`; pulls the branch under test
  on the remote clone at `ZWASM_REMOTE_DIR`, then runs the requested
  `zig build` step — see `scripts/dev_hosts.env.example`, ADR-0206).


---

## 12. Performance and benchmarks

### 12.1 No fixed numeric targets

Per-phase numeric ratios (e.g. "within 1.5× of wasmtime") are
**deliberately not set**. Goodhart's law: a numeric target distorts
behaviour toward the number, not the underlying goal.

Instead:

- `bench/history.yaml` records deliberate measurements (§12.4 cadence;
  the per-merge convention is retired, ADR-0211 D2), and
  `bench_watch.yml` watches for gross regressions nightly.
- A regression in any bench triggers investigation, not an automatic
  block.
- Comparison against reference runtimes (wasm3, wasmtime baseline,
  wasmtime cranelift, wasmer singlepass) is recorded but not gated.
- completion requires "no unexplained regression vs v1 baseline" (the
  eventual release is user-only, ADR-0156).

### 12.2 σ stability

- σ < 5% per measurement (5 runs + 3 warmup, hyperfine).
- Outliers (single run σ > 10%) → automatic re-measure.
- Linux CI: `taskset -c 0` for CPU pinning.
- macOS: `nice -19 hyperfine --warmup 5 --runs 10 --shell=none`.

### 12.3 history.yaml schema

```yaml
- date: 2026-XX-XXTHH:MM:SSZ
  commit: <full SHA>
  arch: aarch64-darwin | x86_64-linux | x86_64-windows
  reason: "Record benchmark for <subject>"
  runs: 5
  warmup: 3
  benches:
    - name: coremark
      median_ms: 12.34
      stddev_ms: 0.45
```

### 12.4 Cadence

- **Deliberate recordings only** (ADR-0211 D2, 2026-08-19; the
  per-merge convention is retired — it assumed merges were local
  events and went unused once the merge gate moved to CI):
  `history.yaml` rows come from a local
  `bash scripts/record_merge_bench.sh --phase-record --reason=...`
  run or a `bench.yml` dispatch, at phase boundaries or when a
  change is performance-relevant.
- **Gross-regression watch**: `bench_watch.yml` (nightly) runs
  `scripts/bench_watch.sh` — same-run A/B of HEAD vs the latest
  release tag, alert at ≥2x slower on ≥2 canary fixtures via the
  scheduled run failing. Commits nothing, gates nothing (§12.1
  investigation-trigger discipline unchanged).
- **Manual baselines**: `bash scripts/record_merge_bench.sh
  --arch=...` records on demand.

### 12.5 Binary size

No fixed numeric target either. The eventual release (user-only, ADR-0156)
records the actual size; v1's range (1.20–1.60 MB stripped) is the informal sanity
check — if v2 is much larger, that's an investigation trigger, not
a build-time error.

---

## 13. Commit discipline and work loop

### 13.1 Granularity

- One commit = one logical change. TDD red-then-green is two commits
  (the red test commit and the green code commit) only when the red
  test is large enough to stand alone; otherwise one commit.
- Never commit when tests are red.
- Source commits and ADR commits may co-occur (an ADR documenting
  the source change in the same commit is encouraged).

### 13.2 Commit message format

`<type>(<scope>): <subject>` where type ∈ {feat, fix, docs, refactor,
chore, test, bench, ci, build}, scope ∈ {p0, p1, ..., p16, all,
infra, ...}.

Example: `feat(p1): parser handles multi-value block params`.

Body explains *why* when non-trivial; the diff explains *what*.

### 13.3 Branch discipline

- `main` is the trunk and is ruleset-protected: no direct push, PR
  required, `ci-required` must be green.
- Work lands on a `develop/<slug>` branch cut from `main`, merged by PR.

### 13.4 The TDD loop (driven by `continue` skill)

See `.claude/skills/continue/SKILL.md` for the canonical procedure.

### 13.5 No copy from v1

zwasm v1 is read as a textbook (Step 0 Survey, see
`.claude/rules/textbook_survey.md`). **Copy-and-paste is forbidden**
(see `.claude/rules/no_copy_from_v1.md`). Every line of v2 is
re-designed; if the result happens to look identical to a v1 line,
that's fine, but the act of typing it is the act of re-deciding.

---

## 14. Forbidden actions (inviolable)

```
❌ Pushing directly to main (PR-only; ruleset-protected)
❌ git push --force / --force-with-lease to any branch
❌ git reset --hard discarding committed work
❌ git commit --no-verify
❌ git rebase -i (interactive, unsupported in CI)
❌ Single file > 2000 lines (hard cap A2)
❌ Bypassing zone_check.sh (A1)
❌ Cross-arch JIT imports (jit_arm64 ↔ jit_x86)
❌ pub var as a vtable (use a struct field)
❌ std.Thread.Mutex (use std.Io.Mutex or std.atomic.Mutex)
❌ std.io.AnyWriter (use *std.Io.Writer)
❌ ARM64-only or x86-only feature (P7)
❌ Running one backend after Phase 8 without differential check
❌ Adding to wasm.h without an ADR
❌ Per-task / per-concept Japanese chapter cadence (P9)
❌ Skipping Step 5 (test gate) on commit
❌ Skipping Step 0 (Survey) when introducing a new public API
❌ Copy-paste from zwasm v1 (P10; see rules/no_copy_from_v1.md)
❌ Hyphens in file or directory names (A11)
❌ Runtime feature-flag branching (Wasmer / Cranelift-style toggle)
   in main code paths; `if (comptime build_options.<feature>)` and
   `inline for + continue` DCE idioms are permitted per ADR-0071 §Q2
   P14 sharpening + ADR-0073, but must follow the structural-cohesion
   caveat (prefer block / module-level over inline scatter; see
   ADR-0071 §"Structural cohesion caveat")
❌ Unconscious libc fanout (new `std.c.*` / `@extern("c")` /
   `pthread_*` call sites outside ADR-0070's `necessary` set without
   ADR amendment; see ADR-0070, rules/libc_boundary.md)
❌ Changes increasing skip-impl counts without an `exempt: <ADR-NNNN>`
   row in `bench/results/skip_impl_history.yaml` (see ADR-0050 D-5/D-6
   amend; the ratchet substrate gates pre-push)
❌ Numeric performance ratio targets baked into ROADMAP / CI gate
   (see §12.1)
❌ Single field serving two distinct semantic axes (e.g. one
   `arity` slot used by both `end` and `br`); split per axis from
   day 1 (see rules/single_slot_dual_meaning.md, ADR-0014 §6.K.5)
❌ Workaround / SKIP-X-MISSING fallback without paired root-cause
   investigation OR a debt-ledger row naming the structural
   barrier (see rules/extended_challenge.md, .dev/debt.yaml
   discipline; the §9.6 / 6.F windowsmini wasmtime stub case is
   the worked example)
```

---

## 15. Future go/no-go decision points

- **End of Phase 5** — re-evaluate ZIR design: are the slot-based
  growth assumptions holding, or is a redesign needed before Phase
  7 JIT lands?
- **End of Phase 6** — does the v1 regression suite (carry-over
  tests + 50 realworld + ClojureWasm guest) actually pass under v2
  interp? If gaps remain (missing ops, semantic divergences),
  Phase 7 (JIT) does not open until they close (A13).
- **End of Phase 7** — does the interpreter v1-surface readiness
  (WASI 0.1 full = Phase 11; wasm-c-api full = Phase 13) merit
  pulling forward before Phase 8 JIT optimisation? Re-evaluate
  with realworld JIT data from §9.7 / 7.9 (ARM64 realworld) and
  7.10 (x86_64 realworld), not speculation. Surfaced by the
  2026-05-04 design dialogue (regret triage); ADR-0021 documents
  the deferral. If reorder is justified, file an ADR amending
  Phase 8/11/13 ordering at that point.
- **End of Phase 8** — is the differential test pass rate stable?
  If frequent diff failures persist, the JIT design is wrong, not
  the test.
- **End of Phase 10** — is the Wasm 3.0 feature-complete claim
  defensible? If the spec test corpus has unimplemented opcodes,
  Phase 11+ does not open.
- **End of Phase 15** — ClojureWasm dogfooding is DEFERRED (§15.6 →
  D-264: cw-v1 has no v2 consumer yet). When it lands, "works with no
  measurable user-visible regression" is a 完成形 quality bar — there is
  no release to "block" (release is user-only, ADR-0156).
- **Post-v0.1.0** — does the ecosystem (other hosts adopting
  wasm-c-api against zwasm) materialise to justify v0.2.0 work
  (Component Model + WASI 0.2)? If only ClojureWasm consumes zwasm,
  v0.2.0 priorities can shift toward smaller wins.
  **RESOLVED 2026-06-07 (ADR-0170, user-directed) — in CM's favour.** Not on
  consumer-count: "Component Model works" is a rare capability (only
  wasmtime-class; wasmer/wazero/WAMR lack a CM host) and thus a strategic
  differentiator for the ClojureWasm story, valuable independent of a current
  consumer. Full wasmtime-equivalent CM + WASI-P2 is now the active campaign
  (`.dev/component_model_plan.md`).

---

## 16. References

- v1 charter: `~/Documents/MyProducts/zwasm/.dev/zwasm-v2-charter.md`
- v1 D100-D138: `~/Documents/MyProducts/zwasm/.dev/decisions.md`
- v1 W54 post-mortem: `~/Documents/MyProducts/zwasm/.dev/archive/w54-redesign-postmortem.md`
- Pre-skeleton investigation: `~/zwasm/private/v2-investigation/CONCLUSION.md`
- ClojureWasm v1 ROADMAP: `~/Documents/MyProducts/ClojureWasmFromScratch/.dev/ROADMAP.md`
- WebAssembly Core 3.0 spec: `~/Documents/OSS/WebAssembly/spec/`
- wasm-c-api: `~/Documents/OSS/wasm-c-api/include/wasm.h`
- wasmtime cranelift / winch: `~/Documents/OSS/wasmtime/`
- regalloc2: `~/Documents/OSS/regalloc2/`
- sightglass (bench reference): `~/Documents/OSS/sightglass/`

---

## 17. Glossary

- **ZIR** — Zwasm Intermediate Representation (this project's mid-IR;
  §4.2).
- **VCode** — wasmtime cranelift's machine-IR (post-isel,
  pre-regalloc). Reference for ZIR's shape.
- **regalloc2** — wasmtime's register allocator (linear-scan + graph
  coloring). Reference for `src/jit/regalloc.zig`.
- **wasm-c-api** — `WebAssembly/wasm-c-api`; the de-facto standard
  C ABI (§4.4).
- **WASI** — WebAssembly System Interface; `wasi_snapshot_preview1`
  (0.1), Component Model wit (0.2 / 0.3).
- **🔒 gate** — phases marked require Mac native + ubuntunote
  Ubuntu native (per ADR-0067; OrbStack retired) + windowsmini
  build to pass before proceeding.
- **Differential test** — running the same wasm through interp and
  JIT, asserting identical output (§4.2 / Phase 7+).
- **Three-OS** — macOS aarch64, Linux x86_64, Windows x86_64; all
  first-class (P11).
- **Single-pass** — decode → ZIR → regalloc → emit, four linear
  passes per function. Not "no IR" (the cranelift winch sense).
- **Dispatch table** — central registry mapping `ZirOp` to handler
  function pointers; the mechanism by which feature modules add
  ops without pervasive `if`-branching (§4.5).
- **`windowsmini`** — local SSH-accessible Windows x86_64 host used
  for build / test / bench. See `.dev/windows_ssh_setup.md`.

---

## 18. Amendment policy

This document is a "now" snapshot. Early-phase planning will
inevitably miss dependencies that only become visible when later
phases are implemented. **Correcting such mismatches IS the
maintenance work, not an ad-hoc patch.** This section governs how
to do that without eroding the document's role as the single source
of truth.

### 18.1 When to amend ROADMAP itself (vs. add an ADR-only deviation)

Amend in place when the document already disagrees with reality:

- An exit criterion, scope row, or task description references a
  feature whose implementation is scoped to a later phase.
- A directory / file name in §5 has been superseded.
- A principle in §2 needs sharpening because a later phase exposed
  an edge case the principle did not anticipate.

Add an ADR **instead** of amending when:

- A genuinely new design decision is being made (not a correction
  of an unobserved pre-existing inconsistency).
- A deviation from a §2 principle is justified as a one-time
  trade-off and should not generalise into the document.

### 18.2 The four-step amendment

When amending, do all four — none of them are optional:

1. **Edit ROADMAP in place.** Write the corrected text as if it had
   always been so. The document is a "now" snapshot; consistency
   matters more than preserving past wording. Do not add inline
   change-bars, dated comments, or `~~strikethrough~~`.
2. **Open an ADR** (`.dev/decisions/NNNN_<slug>.md`) recording the
   original wording, the new wording, and *why the mismatch existed*.
   The ADR is the changelog; ROADMAP is not.
3. **Sync any live doc that cited the amended text** (`.dev/handover.md`
   is frozen — never sync it; open PRs and issues carry current state).
4. **Reference the ADR in the commit message** that lands the
   ROADMAP edit so `git log -- .dev/ROADMAP.md` is browseable for
   cause.

### 18.3 Forbidden

- Editing ROADMAP without an accompanying ADR for load-bearing
  changes — defined narrowly as **scope or exit-criterion changes
  in §1, §2, §4, §5, §9 phase rows, §11 layers, §14 forbidden
  list**. "Load-bearing" means another file's behaviour, a
  phase's gate criterion, or what closes a §9 row changes
  because of the edit.
- Accumulating sub-chunk prose into a §9 row's description or
  status cell. The row text records *scope* (what closes the
  row) and the close-out marker (`[x]` / `[ ]` / SHA); per-sub-
  chunk records belong in **commit messages** and, if grouping
  by row helps cold-resume readers, in
  **`.dev/phase_log/<phase>.md`** referenced from the row. Rows
  that already accumulated log prose are migrated lazily as
  encountered. Canonical example: §9.9 row 9.7 + 9.9 →
  `phase_log/phase9.md` (extracted 2026-05-11; ROADMAP rows now
  carry just scope + pointer).
- Adding a "revision history" section back to this document — the
  trail is git log + ADRs.
- Editing principle text in §2 without an ADR (always load-bearing).
- "Quiet" renumbering of `§N` headings; if a renumber is unavoidable,
  it gets its own ADR and a sweep of every `§N.M` reference under
  `.claude/`, `.dev/`, and source comments.

### 18.3a What counts as routine (no ADR required)

These edits proceed without an ADR because they don't change any
load-bearing claim:

- `[ ]` → `[x]` flip on a row whose **scope text is unchanged**.
- Backfilling a SHA pointer on an `[x]` row.
- Advancing the Phase Status widget (`PENDING` → `IN-PROGRESS` →
  `DONE`).
- Inline-expanding the **next** phase's task table when its
  phase first opens (one-time per phase).
- Pointing a row at a `phase_log/<phase>.md` entry that already
  exists (migration of accumulated log prose into the phase log).

The trigger for "load-bearing per §18.3" is whether the edit
changes *what closes the row*, not whether the row is currently
open or closed.

### 18.4 Why this exists

Without 18.1–18.3 the project drifts in one of two failure modes:

- ROADMAP turns into an aspirational document that nobody updates
  because every change "feels like ad-hoc" and is delayed indefinitely.
- ROADMAP becomes a free-form scratchpad with edits scattered across
  history, and the "single source of truth" claim quietly dies.

The four-step amendment keeps the ROADMAP correct as a present-
tense plan while preserving full traceability through ADRs and git
log.

---

> **Note on history**: this document is a "now" snapshot, not a
> changelog. What changed and why lives in
> `git log -- .dev/ROADMAP.md` and `.dev/decisions/NNNN_*.md` ADRs
> (load-bearing rationale). The amendment process itself is §18.
