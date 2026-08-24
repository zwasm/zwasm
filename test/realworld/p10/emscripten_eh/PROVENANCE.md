# emscripten `-fwasm-exceptions` fixtures (Phase 10 / EH)

**Toolchain**: emscripten 3.x with `-fwasm-exceptions` flag —
the C++ Wasm 3.0 EH path (vs the legacy JS-throw path).

**Planned fixtures** (per design plan §4.3):
- `cxx_throw_catch.cpp.wasm` — basic `throw std::runtime_error`
  with matching `catch` handler (verifies try_table emit + FP-walk
  unwind per ADR-0114)
- `cxx_nested_try.cpp.wasm` — nested try_table; verifies tag
  identity via pointer equality (ADR-0114 D7)
- `cxx_uncaught.cpp.wasm` — `throw` with no matching catch
  → propagates to runtime abort (verifies EH × top-frame
  unwind invariant)

**Build command (when impl ships)**:
```sh
emcc -fwasm-exceptions <src>.cpp -o <name>.cpp.wasm
```

**Status (2026-05-28)**: Core 10.E EH codegen has SHIPPED across
the 10.E-payload-prop bundle + D-181/D-182/D-183/D-184 cycles
(single-frame + cross-frame + multi-frame + payload + multi-catch
all green on Mac aarch64 + Linux x86_64 SysV per
`src/engine/runner.zig` regression tests). What remains for these
fixtures is:

- **Toolchain bake** (D-179 wabt 1.0.41+ pin, OR emscripten build
  on a separate host) — generate the `.cpp.wasm` artefacts from
  the planned `.cpp` sources.
- **Cross-module exception propagation** — exceptions thrown in a
  callee instance that propagate to a caller instance's
  try_table. The current single-instance walker covers same-
  instance multi-frame; cross-instance requires per-Instance
  CodeMap chaining at the unwinder (deferred to v0.2 or later
  Phase 11+ work).
- **emcc runtime shim** — emscripten EH may depend on JS-side
  thunks for some C++ ABI features (typeinfo, dynamic_cast in
  catch); audit the emcc-generated module imports against
  `src/api/wasi.zig` host surface to identify gaps.

Tracked as **SKIP-P10-EH-EMSCRIPTEN-GAP** in test-realworld
runners (renamed from the legacy SKIP-P10-EH-GAP which conflated
"core EH not implemented" with these emscripten-specific gaps).
The legacy token reference in `.dev/phase10_design_plan_ja.md`
§400 ("SKIP-P10-EH-GAP = 0" exit criterion for core EH ops +
landing pad emit) is now SATISFIED.

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
