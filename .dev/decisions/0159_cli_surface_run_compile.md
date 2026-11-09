# 0159 — CLI surface (§16.4): `run` + `compile` only; validate/inspect/features/wat/wasm deliberately dropped

- **Status**: Accepted (2026-06-05; autonomous §16.4 surface review per ADR-0156).
- **Date**: 2026-06-05
- **Author**: claude (Phase 16 完成形 CLI surface review)
- **Tags**: cli, surface, あるべき論, wasmtime-aligned, ROADMAP §10.1/§10.2/§10.3,
  Phase 16, ADR-0156, ADR-0023
- **Amends**: ROADMAP §10.1 (subcommand list), §10 dir-layout (`src/cli/`
  file list). **Retires** ADR-0023 §3's day-1 stub-file accommodation for the
  five dropped subcommands (the surface is now decided — there is no
  future-state to accommodate). **Applies ADR-0156** §1.2 ("the CLI does NOT
  owe v1 its validate/inspect/features/wat/wasm subcommands").

## Context

§16.4 is the 完成形 CLI surface review: decide + lock the truly-necessary,
simple, industry-standard `zwasm` CLI (breaking v1 allowed; v1 parity NOT a
goal — ADR-0156). The shipped CLI dispatches only `run` and `compile`
(`src/cli/main.zig`). Five aspirational placeholder files —
`validate.zig` / `inspect.zig` / `features.zig` / `wat.zig` / `wasm.zig`,
each 10 lines of doc-comment only — sat in `src/cli/` per ADR-0023 §3
("future-state accommodation; the subcommand directory shape is visible from
day 1"). They were never `@import`ed, never dispatched, never in the test
loader — pure dead aspiration. ROADMAP §10.1 still listed the full
seven-subcommand surface, contradicting §1.2's "not owed" framing.

## Survey (industry CLIs, live — verified 2026-06-05)

The reference clones (`~/Documents/OSS/`) were re-checked because this
ecosystem moves fast:

| Runtime    | CLI subcommands (top-level)                                   | validate? | wat/wasm conv? |
|------------|---------------------------------------------------------------|:---------:|:--------------:|
| wasmtime   | run · config · compile · explore · serve · settings · wast · objdump | no | no |
| wazero     | run · compile · version                                       | no        | no             |
| wasmer     | run · compile · validate · inspect · create-exe · …           | yes       | no             |

ROADMAP §10.2/§10.3 explicitly anchor the zwasm CLI on **wasmtime**
("mirrors wasmtime's CLI shape", "wasmtime-aligned naming"). wasmtime — and
the minimalist embeddable peer **wazero** — both ship `run` + `compile` and
delegate validation / conversion / introspection to dedicated tooling
(`wasm-tools`, `wabt`). Only wasmer (a heavier "platform" CLI) carries
`validate`/`inspect`.

## Decision

The `zwasm` CLI surface is **`run` + `compile`** (plus the implicit
no-subcommand `version` banner and `help`). The five v1-parity subcommands
are **deliberately dropped**:

- **`validate`** — validation is available *programmatically* (C-API
  `wasm_module_validate`, Zig `Engine.compile` → `error.ValidateFailed`);
  a standalone CLI verb is not wasmtime/wazero-standard. Standalone module
  linting is `wasm-tools validate`'s job.
- **`inspect` / `features`** — module introspection → `wasm-tools dump` /
  `wasm-tools print`. Build-time feature levels surface in the `zwasm`
  version banner already.
- **`wat` / `wasm`** — text↔binary conversion is squarely `wasm-tools`
  (`parse`/`print`) / `wabt` (`wat2wasm`/`wasm2wat`) territory; a *runtime*
  bundling a WAT printer is sprawl.

A runtime's CLI job is **run it** and **compile it (to a `.cwasm` cache)**.
Everything else is the surrounding ecosystem's. This keeps zwasm
lightweight-yet-fast + simple without losing capability (the richer C/Zig
APIs remain the full programmatic surface).

**No CLI-only vs API-only gap** exists at this surface: `run`/`compile` both
go through the public `engine`/`runner` paths (nothing CLI-exclusive), and
the C/Zig APIs are a strict superset (they additionally expose validation).
The reverse direction (CLI-only-vs-API-only) is re-checked under §16.5
dogfooding.

### Rejected alternatives

- **Ship `validate` anyway** (wasmer-style). Rejected: contradicts the
  wasmtime-alignment mandate (§10.2/§10.3) and §1.2 not-owed framing; the
  capability is not lost (C/Zig APIs + `wasm-tools`). Cheap to add later if
  §16.5 dogfooding surfaces a concrete need — recorded here so the door
  stays open.
- **Keep the dead stub files** for directory-shape signalling (ADR-0023 §3).
  Rejected: now that the surface is *decided*, dead files for subcommands we
  have chosen not to build are cruft that lies about intent.

## Consequences

- Remove `src/cli/{validate,inspect,features,wat,wasm}.zig` (dead).
- ROADMAP §10.1 + dir-layout reflect the `run`/`compile` surface.
- `src/cli/main.zig` header documents the settled surface (no "later phases"
  aspiration for the dropped verbs).
- Revisitable: a `validate` verb can be added later (the primitive
  `frontendValidate` + C-API exist); this ADR is the place that records why
  it is *currently* out.

## References

- ROADMAP §1.2 (not-owed sprawl), §10.1 (subcommands), §10.2/§10.3
  (wasmtime-aligned), Phase 16 §16.4.
- ADR-0156 (endgame: breaking-allowed industry-standard surfaces, no v1
  parity). ADR-0023 §3 (the retired day-1 stub accommodation). ADR-0039
  (`compile` → `.cwasm`). ADR-0136 (`run --engine`).
- Survey sources: `~/Documents/OSS/wasmtime/src/bin/wasmtime.rs`,
  `~/Documents/OSS/wazero/cmd/wazero/wazero.go`.
- **Validation (2026-06-05 C-API survey, lesson `2026-06-05-capi-survey-funcref-from-table`)**: a fresh
  wasmtime/wasmer/wazero sweep confirms `--invoke <fn> <args>` (wasmtime `src/commands/run.rs:51`, wasmer
  `lib/cli/src/commands/run/mod.rs:98`) + resource flags (`--fuel`/`--timeout`/`--epoch`
  `crates/cli-flags/src/lib.rs:342/345/389`, `--env` `run/wasi.rs:94`) are CLI *convenience over the embedder
  API*, not core needs — wazero (`cmd/wazero/wazero.go`) ships exactly `compile`+`run` with no `-invoke`. The
  run+compile scope is reaffirmed; `--invoke` (D-273) stays deferred until a real consumer need.

## Revision history

| Date       | Note |
|------------|------|
| 2026-11-09 | The surface gains `serve` (#688), wasmtime's verb for a `wasi:http/service` component, as ADR-0205 D4's demand-driven QoI entry. The run/compile reasoning above is unchanged: `serve` runs a component the way `run` runs a command. |
