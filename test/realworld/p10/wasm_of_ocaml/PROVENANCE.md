# wasm_of_ocaml toolchain fixtures (Phase 10 / GC + EH + TC; triple crown)

**Toolchain**: `wasm_of_ocaml` 6.0.1+ — the OCaml-to-Wasm compiler.
Exercises all 3 Phase 10 proposals simultaneously (GC for OCaml
heap objects, EH for `raise`, TC for proper tail calls).

**Planned fixtures** (per design plan §4.3):
- `list_fold.ml.wasm` — `List.fold_left` with deep recursion
  (verifies tail-call disposition; ADR-0112 invariant)
- `exception_raise.ml.wasm` — `raise (Failure "oops")` with
  `try-with` handler (EH via try_table)
- `record_alloc.ml.wasm` — record construction + field
  access (struct.new + struct.get)

**Build command (when impl ships)**:
```sh
ocaml-wasm <src>.ml -o <name>.ml.wasm
```

**Status (2026-08-25)**: the premise of the old line — "until all 3 impl rows
land" — is stale: 10.G / 10.E / 10.TC are all `[x]`. What is missing is the
toolchain, not the implementation. This directory is registered in
`../EXPECTED.txt` as an enumerated skip, so the lane announces the gap on
every run instead of reporting an empty directory as green (#226).

It stays named rather than deleted because no other fixture reaches GC, EH
and TC in one module — GC is covered by `../moonbit/`, TC by
`../clang_musttail/`, and EH by `../../src/emscripten_eh/`, but only
separately. The cross-check ADR-0117 asks for needs all three at once.
This toolchain is the **cross-subsystem integration anchor** per
ADR-0117 (gc_x_eh_thrown_ref_rooted + gc_x_tail_call invariants
all fire from realworld OCaml).
