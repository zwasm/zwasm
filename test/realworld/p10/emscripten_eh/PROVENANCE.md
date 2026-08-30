# emscripten `-fwasm-exceptions` fixtures (Phase 10 / EH)

**Toolchain**: emscripten 5.0.7-git, pinned through `devShells.gen` in
`flake.nix`. The C++ Wasm 3.0 EH path — `try_table` / `throw` / `throw_ref` —
not the legacy JS-throw path and not the superseded `try` / `catch` opcodes.

**Fixture**: `cxx_throw_catch` — a `throw` across a function boundary caught by
type, plus a `try` that does not throw, so a miscompiled unwind shows up as a
wrong value rather than only as a crash. `test()` returns 42.

Follow-ons worth adding: nested `try_table` (tag identity
by pointer equality, ADR-0114 D7), and a `throw` with no matching catch
(top-frame unwind).

**Build** (inside `nix develop .#gen`, from `../../src/emscripten_eh/`):
```sh
emcc -fwasm-exceptions -sWASM_LEGACY_EXCEPTIONS=0 -O1 -sSTANDALONE_WASM \
  -sEXPORTED_FUNCTIONS=_test --no-entry -o cxx_throw_catch.wasm cxx_throw_catch.cpp
```
The flag is load-bearing: emscripten still defaults to
`WASM_LEGACY_EXCEPTIONS=1`, whose output uses the superseded `try` / `catch`
opcodes that this runtime rejects with `NotImplemented`. Only `=0` produces the
`try_table` form zwasm implements.

**Result-check**: `zig build test-edge-cases` → `run_edge_realworld_p10` →
`runI32Export` `test` → `.expect` = `i32: 42`. **Status**: ACTIVE (the JIT
defects it surfaced were #280).
