# WebAssembly Proposal Phase Watch

> Reviewed quarterly. zwasm v2 implements all Phase 5 (= W3C
> Recommendation) proposals for v0.1.0; lower phases are watched and
> re-evaluated when they advance. Phase 4 non-web proposals are the
> v0.2.0 line.

Last reviewed: **2026-10-21**. Next WASI release train (ADR-0205 D6): **0.3.3, 2026-12-08**.

> **WASI 0.3.0 RATIFIED 2026-06-11** (Bytecode Alliance; Wasmtime 43+). It
> rebases WASI onto the **Component Model async primitives** (`async` func,
> `stream<T>`, `future<T>`) — **NOT** the core stack-switching continuations
> proposal — so it builds on zwasm's already-shipped CM + WASI-0.2 substrate. It
> is now an **actionable feature front** (ROADMAP §9.0 Front D / **D-335**), not
> a deferred item. Spec cloned at `~/Documents/OSS/WASI/` +
> `~/Documents/OSS/WebAssembly/component-model/`; reference impl
> `~/Documents/OSS/wasmtime/` (43+). The CORE stack-switching proposal stays
> pre-Phase-4 (D-300) — separable, not on the WASI-0.3 path.

## Phase 5 — W3C Recommendation (zwasm v2 v0.1.0 MUST implement)

WebAssembly 3.0 (W3C Recommendation 2025-09):

| Proposal                                      | zwasm v2 phase | ZirOp prefix         |
|-----------------------------------------------|----------------|----------------------|
| MVP (i32/i64/f32/f64, control, memory)        | 1–2           | core                 |
| Multi-value (block params, multi-return)      | 1–2           | (sig-driven)         |
| Sign extension ops                            | 1–2           | core                 |
| Saturating float-to-int                       | 1–2           | core                 |
| Bulk memory                                   | 1–2           | core                 |
| Reference types                               | 1–2           | core                 |
| SIMD-128 (fixed-width)                        | 8              | `*x*.*` /  `v128.*`  |
| Memory64                                      | 9              | core (64-bit memarg) |
| Exception Handling (try-table, throw_ref)     | 9              | `eh_*`               |
| Tail Call (return_call, return_call_indirect) | 9              | `tail_*`             |
| WasmGC (struct/array/i31)                     | 9              | `gc_*`               |
| Function references                           | 9              | core                 |
| Extended const                                | 1–2           | (const-expr)         |
| Relaxed-SIMD                                  | 8              | `*.relaxed_*`        |

Plus v1 parity items at Phase 5:

- Wide arithmetic (i64x2 multiply, add-with-carry)
- Custom page sizes (memory.discard + memarg page-size variants)

## Phase 4 — Standardize (deferred to v0.2.0 for non-web items)

| Proposal                    | Status  | zwasm intent            |
|-----------------------------|---------|-------------------------|
| Threads (atomics, smem)     | Phase 4 | v0.2.0 (after WASI 0.2) |
| JS Promise Integration      | Phase 4 | **SKIP** (web-only)     |
| Web Content Security Policy | Phase 4 | **SKIP** (web-only)     |

## Phase 3 — Implementation (per-feature judgement)

| Proposal                         | Note                  | zwasm intent                    |
|----------------------------------|-----------------------|---------------------------------|
| ESM Integration                  | JS modules            | **SKIP**                        |
| Wide arithmetic (i64x2 mul, ADC) | BigInt-relevant       | Phase 9 alongside SIMD (v0.1.0) |
| Stack switching (continuations)  | core proposal, still pre-Phase-4 (format evolving 2026-06) | **DEFER the CORE proposal** (D-300). NOTE: WASI 0.3 does NOT depend on it — 0.3 async is Component-Model-based (async func/stream/future), separable → see the WASI-0.3 callout at top + §9.0 Front D / D-335 |
| Compact import section           | Size opt              | v0.2.0+                         |
| Custom page sizes                | memory tuning         | Phase 10 (v0.1.0)               |
| Custom Descriptors / JS Interop  | JS-only               | **SKIP**                        |

## Phase 2 — Proposed (watch only)

`Profiles`, `Relaxed Dead Code Validation`, `Numeric Values in WAT
Data Segments`, `Extended Name Section`, `Rounding Variants`,
`Compilation Hints`, `JS Primitive Builtins`. Re-evaluate quarterly.

## Phase 1 — Champion (watch only)

`Type Imports`, `Component Model` (v0.2.0 entry point),
`WebAssembly C and C++ API` (already adopted as ABI; ROADMAP §4.4),
`Flexible Vectors`, `Memory Control` (memory.discard), `Reference-
Typed Strings`, `Profiles` (Rossberg variant), `Shared-Everything
Threads`, `Frozen Values`, `Half Precision (FP16)`, `More Array
Constructors`, `JIT Interface` (interesting for self-JIT),
`Multibyte Array Access`, `Type Reflection` (likely demoted), `JS
Text Encoding Builtins` (skip).

## WASI roadmap

| WASI version   | zwasm phase   | Notes                                   |
|----------------|---------------|-----------------------------------------|
| 0.1 (preview1) | ✅ COMPLETE   | de-facto baseline; complete since Phase 11 |
| 0.2 (preview2) | ✅ COMPLETE (default-ON) | Component Model campaign done 2026-06-13 (ADR-0170); official corpus 158/0/0 |
| 0.3            | ✅ 0.3.0 COMPLETE (opt-in `-Dwasi=p3`) | 0.3.0 **released 2026-06-11**; rebases WASI on CM async (async func / `stream<T>` / `future<T>` — NOT core stack-switching, see callout). Full-coverage campaign done (ADR-0205 Accepted); official corpus 45/45 on all three OSes. 0.3.1 / 0.3.2 rename only, but their CM `map` / `implements` are refused (#611, #612; 2026-10-21 entry below) |

- **2026-10-21** — **WASI 0.3.1 (08-11) and 0.3.2 (10-13)**: the `.wit` diff
  from `v0.3.0` is the version strings plus one doc comment in
  `http/types.wit`. 0.3.1 adopted the CM `map<K, V>` type and the
  `implements` annotation (`docs/ComponentModelFeatures.md`): a 0.3.1+ runtime
  must accept both, though no 0.3.2 WIT uses either; zwasm refuses both at
  decode (#611, #612). Next train: 0.3.3 on 2026-12-08.
- **2026-08-10** — **WASI 0.3 full-coverage campaign kickoff (ADR-0205,
  user-directed)**. Reference clones re-pulled / re-cloned (WASI monorepo →
  HEAD `a72eb09`; wasmtime / wasm-tools / WebAssembly{spec wg-3.0, testsuite,
  component-model} re-cloned into `~/Documents/OSS/`; wasi-testsuite +
  wit-bindgen + wasi-rs pulled). New upstream facts: (1) `docs/Release.md`
  formalizes the **0.3.x release train** — 0.3.1 lands 2026-08-11, then every
  second Tuesday bi-monthly; (2) `specifications/wasi-0.3.0/` = six proposals
  (cli / clocks / filesystem / http / random / sockets) published as OCI
  packages; WIT diff `v0.3.0`→HEAD is 3 doc-comment lines in `http/types.wit`
  (0.3.0 ≈ 0.3.1); (3) official wasi-testsuite carries **45 wasm32-wasip3
  guest tests** (wkg.lock `=0.3.0`-pinned) prebuilt on `prod/testsuite-base`
  — measured: the binaries are dual-world (0.2.x + 0.3.0 imports both
  present), so the host serves both generations simultaneously. Per-release
  tracking discipline = ADR-0205 D6 (record `v0.3.x` tag + WIT diff at each
  quarterly review; deliberate testsuite-binary bumps only).
- **2026-07-17** — **WASI-0.3.0-official diff inventory** (reference clones
  pulled: WASI monorepo → 2026-07-15 HEAD incl. the `v0.3.0` release of
  2026-06-11; wasmtime v48; wasm-tools v1.252; the per-interface
  `WebAssembly/wasi-*` repos were ARCHIVED upstream 2025-11-25 — living WIT =
  `WASI/proposals/*/wit/`). Deltas between the official 0.3.0 WIT and zwasm's
  draft-era P3 surface: (1) `wasi:clocks/wall-clock` was RENAMED
  `system-clock`, `datetime{u64,u32}` → `instant{seconds: s64, ns: u32}`, +
  `get-resolution`; (2) `wasi:clocks/monotonic-clock` gains `get-resolution` +
  `wait-until`/`wait-for` **async funcs**; (3) `wasi:cli` stdio via-stream
  shapes match zwasm's ADR-0190 impl (stdout/stderr `write-via-stream(stream<u8>)
  -> future<result<_,error-code>>`); (4) `wasi:io` is deleted upstream (CM
  builtins replace it) — zwasm's P2 wasi:io host stays for 0.2 guests. ALSO
  measured: the committed `test/component/wasip3/*.wasm` fixtures import
  **wasi 0.2.6 interfaces** — root cause is the borrowed wasip2 wasi-libc in
  the link recipe, NOT the nightly pin (nightly-bump hypothesis refuted by a
  regen on nightly-2026-06-24, which compiles std's `wasip3 0.6.0
  +wasi-0.3.0-rc` crate yet still emits all-0.2.6; details in D-523).
  Host-side `system-clock` support added this sweep.
- **2026-07-03** — **post-v2.0.0 maintenance sweep** (reference clones refreshed
  ff-only: wasmtime / WAMR / wasm-tools / component-model to upstream HEAD; spec +
  testsuite left at their `wg-3.0` / `spec_pin.yaml` pins). **No proposal phase
  advances since 2026-06-15**: Threads = Phase 4; stack-switching / custom-page-sizes /
  wide-arithmetic = Phase 3; WASI 0.3.0 stays ratified-only (Wasmtime 46 flips CM-async
  on by default — runtime maturation, not a spec move; already post-v0.2.0 for zwasm).
  Testsuite `main` is one benign commit past the pin (`193e551` — custom-page-sizes
  proposal wast reformatted to `(module definition …)`; **zero `test/core/` change**),
  so the frozen 3.0 conformance corpora are unaffected → no re-distil, no spec-pin bump.

## Toolchain proposals (non-Wasm; trigger zwasm scaffolding changes)

| Proposal                                     | Status                                | Trigger                                                                                                                                       |
|----------------------------------------------|---------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------|
| Zig `@deprecated()` builtin + `-fdeprecated` | ziglang/zig#22822 — accepted, urgent | When this lands (likely 0.17+), revisit ADR-0009 — native compiler enforcement may obsolete the zlinter `no_deprecated` dependency entirely. |

## Review log

- **2026-04-30** — initial table seeded from zwasm v1's
  `.dev/proposal-watch.md` and the pre-skeleton survey at
  `~/zwasm/private/v2-investigation/surveys/wasm-proposal-status.md`.
- **2026-05-03** — added "Toolchain proposals" section tracking
  ziglang/zig#22822 as the ADR-0009 sunset trigger.
- **2026-06-07** — **Component Model + WASI-P2**: the ROADMAP §15 ecosystem-gate
  is RESOLVED in CM's favour (ADR-0170, user-directed) — CM-as-capability is a
  rare differentiator (only wasmtime-class), not consumer-count-gated. Now the
  active Phase-17 campaign; full wasmtime-equivalent target; driver
  `component_model_plan.md`. Supersedes the prior "deferred to post-v0.1.0" framing.
- **2026-06-07** — **branch-hinting** (`metadata.code.branch_hint` custom
  section): v1 advertised COMPLETE; the proposal is an advisory QoI hint with
  NO conformance effect. v2 accepts it via the generic custom-section skip
  (verified @dcc8d71c, fixture `edge_cases/p17/branch_hint`, hints ignored) —
  this satisfies "a conformant runtime may ignore it." OPTIONAL future QoI:
  consume the hints to bias JIT branch layout (likely/unlikely). Not scheduled
  (no behaviour/conformance gain); revisit only if a perf campaign wants it.
- **2026-06-13** — **WASI 0.3.0 released** (2026-06-11): rebases WASI on the
  Component Model's async primitives — first-class streams/futures replace the
  0.2 poll/`pollable` pattern; breaking vs 0.2. Stays **post-v0.1.0 (post-v0.2.0)**:
  its async core is gated on CM-async + stack-switching (D-300, still DEFER —
  format unstable per the 2026-06-07 survey). v0.1.0 scope = Wasm 3.0 + WASI 0.2
  (Phase 17) UNCHANGED; no current-scope drift. Reference-clone note: local
  `WebAssembly/{spec,testsuite,WASI}` clones trail `.dev/spec_pin.yaml` (pinned
  2026-06-04, NEWER than the clones) — the tested/vendored corpus is current for
  the targeted scope; refresh the clones for manual lookups when convenient.
- **2026-06-14** — **wg-3.0 currency re-verification (the debt's "multi-value-runner
  ceiling" was STALE, refuted)**: empirically compared committed corpus assert
  counts vs the frozen `wg-3.0` tag for every proposal — ALL current: EH try_table
  34=34, gc all files (array 24 / struct 17 / i31 55 / type-subtyping 17 / ref_cast
  11 / ref_test 68), tail-call (un-reverted `21959b5f`). 0 skip-impl; multi-value-
  result asserts (`type-f64-i64-to-i32-f32`, `get_globals`) PRESENT + passing via
  `invokeMulti`. **Alpha conformance condition (100% latest 3.0 spec) MET.** Spec
  pin bumped 21b053f→f3d3448 (`.dev/spec_pin.yaml`): the drift was PURELY `[spectec]`
  formal-spec tooling + editorial/typing-rule fixes (PRs #2180-2186), `test/core/
  *.wast` ZERO changes → corpora unaffected. Also: JIT exnref completeness done
  (D-327 reify + throw_ref / D-328 multi-value catch result-vreg; conformance-
  neutral but user-directed "ideal form"; bundle `3234f7a9`).
