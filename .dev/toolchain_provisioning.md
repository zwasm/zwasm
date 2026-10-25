# Realworld-fixture toolchain provisioning

> **Doc-state**: ACTIVE

How zwasm v2 provisions the toolchains that compile real-world C / C++ /
Rust / Go sources to `.wasm` test fixtures, and how those fixtures are
handled across the 3-host gate. Introduced cyc220 (2026-05-30) at user
direction (「なければ導入していい / なるべくnix / 生成wasmをubuntuやwindowsで
どう扱うか効率的に / v1も参考にあるべき論で」).

## The cross-host model (the efficiency decision)

A generated `.wasm` is a **committed binary artifact** (like
`test/realworld/p10/clang_wasm64/wasm64_load_store.wasm`). The test
hosts run it through the **Zig-built edge-runner** (`runI32Export` /
`diff_runner`), which is compiled from source on each host. Therefore:

- The generation toolchains (emcc / tinygo / rustc / go / clang) are
  needed **only on the Mac generation host**, and only when fixtures are
  (re)generated — a rare maintenance task.
- **ubuntu / windows never need the *generation* toolchains.** They
  `git reset --hard` + `zig build test-all`, which runs the committed
  `.wasm` via the edge-runner. No generation toolchain install.
- **Carve-out (ADR-0162, 2026-06-05): native rust IS on the test hosts —
  for the §13.5 `rust_host` step ONLY.** ubuntunote via `nix develop
  .#rust-host` (pinned); windowsmini via native winget rust (rustc 1.96.0,
  no nix on Windows). This is the sole non-generation toolchain on the
  test hosts; `test-all`'s `devShells.default` stays toolchain-free.

This is why the heavy toolchains are kept **out of `devShells.default`**
(the shell the test hosts enter via SSH) and live in separate
`devShells.gen` (Mac generation) / `devShells.rust-host` (rust_host only).

## `devShells.gen` (flake.nix)

```sh
nix develop .#gen        # Mac host only; provides the generation toolchains
```

`flake.nix` defines three shells:

| Shell                 | Used by                             | Contents                                                                                      |
|-----------------------|-------------------------------------|-----------------------------------------------------------------------------------------------|
| `devShells.default`   | Mac + ubuntu (via `nix develop`)    | zig + wabt + wasmtime + wasm-tools + lldb + nasm (lightweight)                                |
| `devShells.gen`       | Mac generation host only            | + emscripten, tinygo, go, rustc (wasm32 targets via rust-overlay), clang + lld, wasm-tools    |
| `devShells.rust-host` | ubuntunote (§13.5 `run-rust-host`) | zig + native rustc (host target; ADR-0162). Windows uses native winget rust instead (no nix). |

### windowsmini native tools (no nix on Windows)

windowsmini does **not** run nix — `run_remote_windows.sh` invokes `zig build`
directly over SSH. The `devShells.default` tool set is mirrored by **native**
installs from [`scripts/windows/install_tools.ps1`](../scripts/windows/install_tools.ps1)
(the SSOT; pinned versions mirror `flake.nix`). Tools land in
`%LOCALAPPDATA%\zwasm-tools\<name>-<version>\` and are wired into the **User**
PATH. Current pins (2026-06-14, kept current per user directive): zig **0.17.0**
(PINNED — never bump), wasmtime **45.0.0**, wasm-tools **1.251.0**, wasmer
**7.1.0** (the §9.6 A3 second oracle), hyperfine **1.20.0** (latest), rustc
**1.96.0** (latest stable, winget/rustup). Update = bump the `$versions` pins +
`pwsh -File scripts\windows\install_tools.ps1 -OnlyTool <name> -Force`.

> **sshd PATH-cache gotcha** (verified 2026-06-14): the Windows OpenSSH service
> caches its environment, so a User-PATH change written by `install_tools.ps1`
> is **NOT visible to new ssh sessions** (incl. the gate) until **windowsmini
> reboots** (or `sshd` restarts). A naive `Restart-Service sshd` over ssh is
> unreliable — the restart process is a child of the session and is killed when
> sshd stops. So: after an `install_tools.ps1` update, the registry PATH is
> durably correct but a **reboot activates it**. The new binaries are verifiable
> meanwhile by absolute path (`%LOCALAPPDATA%\zwasm-tools\<name>-<ver>\...`).

`gen` uses a separate `genPkgs` binding (with the `rust-overlay`) so the
overlay never perturbs `default`. Rust wasm targets pinned:
`wasm32-unknown-unknown`, `wasm32-wasip1`. (wasm64 uses
`clang --target=wasm64`; rust's wasm64 is nightly-only, out of scope.)

`gen`'s `shellHook` sets `EM_CACHE` (emscripten needs a writable cache —
the nix store path is read-only) and clears `NIX_HARDENING_ENABLE` (the
nix-wrapped clang injects `-fzero-call-used-regs`, unsupported for wasm;
see `.dev/lessons/2026-05-30-clang-wasm-realworld-toolchain-recipe.md`).

This mirrors v1's flake-as-source-of-truth model (v1 pinned tinygo / go /
wasi-sdk in its single devShell + a `versions.lock`), but splits the
heavy toolchains into a second shell so the test hosts stay lean.

## Generation recipes

Run inside `nix develop .#gen`. Each fixture's `PROVENANCE.md` records the
exact command + the toolchain versions at generation time.

- **clang → wasm32** (e.g. tail-call):
  `clang --target=wasm32 -nostdlib -Wl,--no-entry -Wl,--export-all -O2 ...`
- **clang → wasm64** (memory64):
  `clang --target=wasm64 -nostdlib -Wl,--no-entry -Wl,--export-all -O2 ...`
- **rustc → wasm32**:
  `rustc --target wasm32-unknown-unknown -O --crate-type=cdylib ...`
  (`#![no_std]` + `#[no_mangle] pub extern "C" fn test() -> i32` + a
  `#[panic_handler]`; runnable through `runI32Export`).
- **emcc → wasm** (C/C++, incl. `-sMEMORY64=1`):
  `emcc -sMEMORY64=1 ... -o out.wasm`.
- **go → wasip1**: `GOOS=wasip1 GOARCH=wasm go build -o out.wasm ...`.
- **tinygo → wasip1**: `tinygo build -target=wasip1 -o out.wasm ...`.

## Wasm 3.0 GC / EH / tail-call producers (ADR-0128 §5)

Web-researched 2026-05-31. For realworld coverage of the Wasm-3.0
proposals (GC, EH, tail-call). The committed `.wasm` runs on the test
hosts through the edge-runner; some producers emit a JS-loader +
sidecar `.wasm` (commit the `.wasm`, drop the JS).

- **Lightest lever — hand-written `.wat` + `wat2wasm --enable-all`**
  (WABT, already pinned). Zero host imports, exact opcodes you choose;
  the right tool for per-opcode GC/EH/TC coverage no compiler reliably
  emits. `wat2wasm --enable-all foo.wat -o foo.wasm`. Prefer this for
  targeted fixtures; use the heavy toolchains below for *real programs*.
- **emcc → native Wasm EH** (`try_table`/`throw`, NOT legacy JS EH):
  `emcc -fwasm-exceptions -O1 -o throw.wasm throw.cpp` (pass
  `-fwasm-exceptions` at BOTH compile + link). nixpkgs `emscripten`;
  needs `EM_CACHE` writable (already set by the `gen` shellHook). A
  one-flag delta on the existing clang recipe.
- **`wasm_of_ocaml` → GC + EH + tail-call (triple crown)**: the only
  mainstream toolchain hitting all three. opam (in the gen shell):
  `opam install wasm_of_ocaml-compiler` (needs OCaml ≥4.14, dune ≥3.19,
  binaryen ≥119 via `pkgs.binaryen`). Build: `ocamlfind ocamlc -package
  js_of_ocaml -linkpkg -o prog.byte prog.ml && wasm_of_ocaml prog.byte`
  → `prog.js` + `prog.assets/*.wasm` (commit the `.wasm`). `--effects=cps`
  avoids the JSPI host import.
- **guile-hoot → GC + tail-call**: nixpkgs `guile-hoot` (aarch64-darwin
  OK). `hoot compile --output=foo.wasm foo.scm`; the main module imports
  `reflect.wasm` + `wtf8.wasm` (commit + link all three; `--bundle` emits
  them).
- **dart2wasm → GC (parse/validate-only)**: nixpkgs `dart`; `dart
  compile wasm main.dart -o main.wasm`. Heavy JS import surface → good
  as a parse/validate-stress GC fixture, NOT a runnable one.

## Provenance

Each `test/realworld/**/PROVENANCE.md` records: toolchain + version, the
exact build command, the result-check harness, and the fixture's expected
output. The committed `.wasm` + its `PROVENANCE.md` are the reproducibility
contract; re-generation requires re-entering `nix develop .#gen`.

## Stale-ness

- If a test host ever needs a generation toolchain (it shouldn't — the
  `.wasm` is committed), this model is wrong; revisit.
- If `nix develop .#gen` fails on a fresh Mac, the flake's pinned package
  set drifted; update `flake.nix` + re-pin.
