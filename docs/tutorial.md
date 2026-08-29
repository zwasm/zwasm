# Getting started

A short walkthrough: build the CLI, run + compile a module, then embed
zwasm as a library from Zig and C. Reference docs:
[`docs/reference/`](reference/).

## 1. Build

zwasm pins Zig 0.16.0 via Nix:

```sh
direnv allow          # loads the flake dev shell (Zig 0.16.0 + tools)
zig build             # builds the `zwasm` binary into zig-out/bin/
zig build test        # unit tests
```

(Without Nix, install Zig 0.16.0 and `wasm-tools` yourself — the build
generates `spectest.wasm` with the latter; versions are pinned in
`.github/versions.lock`. The toolchain for generating realworld `.wasm`
fixtures is Mac-only via `nix develop .#gen`.)

## 2. Run a module (CLI)

```sh
zwasm run hello.wasm                 # WASI _start / main; exits with proc_exit code
zwasm run --invoke add hello.wasm    # run a named export instead (zero-arg)
zwasm run --invoke 'add=2,3' math.wasm   # pass typed args; prints the result (→ 5)
zwasm run --dir .:/ guest.wasm       # preopen the cwd as the guest's /
```

The default engine is `auto` — it prefers the JIT and falls back to the
interpreter. `--engine interp` forces the interpreter; `--engine jit` forces the
JIT, which does full WASI too and additionally executes SIMD. Full flags:
[`reference/cli.md`](reference/cli.md).

## 3. Compile ahead-of-time

```sh
zwasm compile hello.wasm -o hello.cwasm   # produce an AOT artifact
zwasm run hello.cwasm                      # load + run it directly
```

## 4. Embed in Zig

Add zwasm to your `build.zig.zon` `.dependencies` (a `path`/`url` dep),
then in `build.zig`:

```zig
const zw = b.dependency("zwasm", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zwasm", zw.module("zwasm"));
```

Then drive it (Engine → compile → instantiate → call):

```zig
const std = @import("std");
const zwasm = @import("zwasm");

// `alloc`: your std.mem.Allocator (e.g. std.heap.page_allocator).
// `wasm_bytes`: the module's bytes (e.g. @embedFile("add.wasm") or read at runtime).
var eng = try zwasm.Engine.init(alloc, .{});
defer eng.deinit();
var mod = try eng.compile(&wasm_bytes);
defer mod.deinit();
var inst = try mod.instantiate(.{});
defer inst.deinit();

const add = inst.typedFunc(fn (i32, i32) i32, "add");
std.debug.print("{d}\n", .{try add.call(.{ 2, 40 })}); // 42
```

To provide **host imports**, build a `Linker` and `defineFunc` (the
Wasm signature is comptime-derived from your Zig fn; first param is
`*zwasm.Caller`):

```zig
fn hostAdd(_: *zwasm.Caller, a: i32, b: i32) i32 { return a + b; }
// ...
var lk = zwasm.Linker.init(&eng);
defer lk.deinit();
try lk.defineFunc("env", "add", fn (*zwasm.Caller, i32, i32) i32, hostAdd);
var inst = try lk.instantiate(&mod, .{});
```

Runnable: [`docs/examples/zig_dep/`](examples/zig_dep/) (external path-dep
consumer, exercises the full surface) and
[`docs/examples/zig_host/`](examples/zig_host/). Surface reference:
[`reference/zig_api.md`](reference/zig_api.md).

## 5. Embed in C

zwasm implements the standard wasm-c-api ([`include/wasm.h`](../include/wasm.h)).
A C host that drives any wasm-c-api runtime drives zwasm unchanged; WASI
is configured via [`include/wasi.h`](../include/wasi.h).

Build the library and the headers yourself — a release tarball holds the
`zwasm` executable and nothing else:

```sh
zig build static-lib -Doptimize=ReleaseSafe -Dcompiler-rt=true
# → zig-out/lib/libzwasm.a
#   zig-out/include/{wasm,wasi,zwasm}.h
```

Then compile a host against them (x86_64-linux shown):

```sh
cc -I zig-out/include docs/examples/c_host/hello.c zig-out/lib/libzwasm.a \
   -lm -Wl,-z,noexecstack -o c_host
./c_host      # → zwasm c_host: main() returned 42
```

The three extra flags are not decoration, and each has its own condition:

| Flag | Why it is there |
|---|---|
| `-Dcompiler-rt=true` | Bundles Zig's compiler-rt into the archive. Without it a `-Doptimize=ReleaseSafe` build fails to link with `undefined reference to __zig_probe_stack`; at the default `Debug` it happens to link, which is what makes the omission easy to miss. |
| `-lm` | zwasm calls `trunc` / `truncf`, which live in a separate library on glibc older than 2.34. |
| `-Wl,-z,noexecstack` | Linux only. Zig-emitted objects carry no `.note.GNU-stack` section, so GNU ld assumes an executable stack and prints a deprecation warning (D-312). The link succeeds without it. |

`zig build --help` describes the `static-lib` step and is authoritative for
the other targets. Cross-compiling the archive works the same way — add
`-Dtarget=<triple>`.

Runnable: [`docs/examples/c_host/`](examples/c_host/). Reference:
[`reference/c_api.md`](reference/c_api.md).

## 6. Coming from v1

v2 breaks v1's ABI by design (v1 is frozen at `v1.11.1`): re-embed against
the current C / Zig / CLI surfaces documented in
[`reference/`](reference/).
