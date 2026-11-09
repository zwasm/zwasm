# Third-party components

zwasm is licensed under Apache-2.0 (see [`LICENSE`](LICENSE)). Every
third-party artifact vendored into this tree is **also Apache-2.0**, so the
whole tree is license-uniform. This file is the running inventory.

> Maintenance rule: when you add an Apache-2.0 third-party artifact, add one
> row here. Anything not under Apache-2.0 does not belong in the tree (e.g.
> the GPLv2-tainted `bz2` sightglass bench was dropped — see
> `bench/sightglass/PROVENANCE.txt`).

## Distributed with the package

These ship in the published artifact:

- `include/wasm.h` — WebAssembly/wasm-c-api, Apache-2.0, vendored at upstream
  commit `9d6b9376` (ADR-0004 pin).
- `src/engine/testdata/d291_ed25519.wasm` — Bytecode Alliance sightglass
  shootout `ed25519`, Apache-2.0.

## Test- and bench-only (not in the distributed package)

- `test/spec/**` — WebAssembly spec / proposals testsuite, Apache-2.0.
- `test/component/wasip3_official/**` — WebAssembly/wasi-testsuite prebuilt
  `wasm32-wasip3` conformance binaries + manifests (`prod/testsuite-base`
  branch, stripped; pin + regen in `scripts/vendor_wasip3_official.sh`),
  Apache-2.0 (ADR-0205 D3).
- `test/wasi/wasip1_official/**` — WebAssembly/wasi-testsuite prebuilt
  `wasm32-wasip1` conformance binaries + manifests + preopen trees, one
  subtree per source language (`prod/testsuite-base` branch, stripped; pin +
  regen in `scripts/vendor_wasip1_official.sh`), Apache-2.0 (ADR-0208 D1).
- `bench/sightglass/**` — Bytecode Alliance sightglass benchmarks,
  Apache-2.0 (provenance + selection in `bench/sightglass/PROVENANCE.txt`).
- `bench/shootout-src/**` — sightglass shootout sources, Apache-2.0.
- `bench/runners/wasm/**` — sightglass-derived runner `.wasm` corpus,
  Apache-2.0.
