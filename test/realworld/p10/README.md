# `test/realworld/p10/` — Wasm 3.0 realworld fixtures

Output from real toolchains, committed as `.wasm` and run on every host by the
edge runner. `EXPECTED.txt` beside this file states which directories are
supposed to yield fixtures and which are knowingly empty; the runner fails if
the corpus and that statement disagree, including for a directory the file does
not mention at all. Without it an empty directory and a fully-passing one are
the same verdict (#226).

| Directory | Proposal reached | Fixture |
|---|---|---|
| `moonbit/` | GC | MoonBit `--target wasm-gc` structs / nullable walk |
| `clang_musttail/` | tail calls | C continuation-passing style (`musttail`) |
| `clang_wasm64/` | memory64 | i64-indexed memory load / store |
| `clang_O0_arr_sum/`, `clang_O0_fp_sum/` | — | unoptimised C scalar / FP loops |
| `rust_fib/`, `rust_data/`, `rust_loop_sum/`, `rust_bubble_sort/` | — | rustc wasm32 |
| `emscripten_eh/` | EH | C++ `throw` across a call, caught by type (`try_table` / `throw` / `throw_ref`) |
| `wasm_of_ocaml/` | GC × EH × TC | not provisioned — see below |

## The one that does not run

`wasm_of_ocaml/` — the only fixture that would reach GC, EH and TC in one
module, which is the cross-check ADR-0117 asks for. The toolchain is not
provisioned; the implementation rows it used to wait on all shipped.

`dart/` and `hoot/` were removed rather than left as unfillable skips: GC is
reached by `moonbit/` and tail calls by `clang_musttail/`, so neither added
coverage the corpus lacks.

## Adding a fixture

Generate on the Mac host via `nix develop .#gen` (see
`.dev/toolchain_provisioning.md`), commit the `.wasm` with an `<name>.expect`
sidecar (`i32: <value>` or `trap:`), and add the directory to `EXPECTED.txt`.
A directory missing from that file fails the lane, which is the point.
