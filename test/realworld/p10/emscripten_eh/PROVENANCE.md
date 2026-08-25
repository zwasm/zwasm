# emscripten `-fwasm-exceptions` fixtures (Phase 10 / EH)

**Toolchain**: emscripten 5.0.7-git, pinned through `devShells.gen` in
`flake.nix`. The C++ Wasm 3.0 EH path — `try_table` / `throw` / `throw_ref` —
not the legacy JS-throw path and not the superseded `try` / `catch` opcodes.

**Fixture**: `cxx_throw_catch` — a `throw` across a function boundary caught by
type, plus a `try` that does not throw, so a miscompiled unwind shows up as a
wrong value rather than only as a crash. `test()` returns 42.

Follow-ons worth adding once the fixture runs: nested `try_table` (tag identity
by pointer equality, ADR-0114 D7), and a `throw` with no matching catch
(top-frame unwind).

## 2026-08-25 — the fixture now exists, and running it found a defect

Built with `emcc -fwasm-exceptions -sWASM_LEGACY_EXCEPTIONS=0 -O1
-sSTANDALONE_WASM -sEXPORTED_FUNCTIONS=_test --no-entry` over
`../../src/emscripten_eh/cxx_throw_catch.cpp`; the `.wasm` is committed beside
that source. The flag is load-bearing: emscripten still defaults to
`WASM_LEGACY_EXCEPTIONS=1`, whose output uses the superseded `try` / `catch`
opcodes that this runtime rejects with `NotImplemented`. Only `=0` produces the
`try_table` form zwasm implements.

The module is NOT wired in as a running fixture yet. wasmtime and the zwasm
interpreter both return the expected value; the JIT traps `oob_memory` (#280),
and this lane runs fixtures through the JIT. `../EXPECTED.txt` registers this
directory as an enumerated skip naming that issue, so the gap is announced
rather than invisible. When #280 closes, move the `.wasm` here with an
`i32: 42` sidecar and flip the entry to `expect=fixtures`.
