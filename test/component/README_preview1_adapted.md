# preview1-adapted component fixtures

Components built from a wasi_snapshot_preview1 core module with the wasmtime
preview1 adapter (`wasm-tools component new --adapt`). The adapter is itself a
core module whose imports are the WASI 0.2 interfaces; every one of them must
be served by the P2 host or the component fails to link (`UnknownImport`).

| file | core | adapter |
|---|---|---|
| `preview1_adapted_reactor.wasm` | `preview1_adapted.wat`: imports `fd_write`, never calls it | reactor, wasmtime v50.0.0 |
| `preview1_fd_write_reactor.wasm` | `preview1_fd_write.wat`: `call` writes `P1-OK\n` to stdout via `fd_write` | reactor, wasmtime v50.0.0 |
| `preview1_command.wasm` | `preview1_command.wat`: same echo plus `_start` | command, wasmtime v50.0.0 |

`preview1_fd_write.wat` reserves 17 pages: the reactor adapter allocates its
State through the main module's `cabi_realloc` on the first preview1 call, and
the fixture's bump allocator never grows memory.

All three export `call: func(op: string, request: string) -> string` (WIT in
`preview1_adapted.wit`), which returns `request`.

The adapters are the wasmtime v50.0.0 release assets
(<https://github.com/bytecodealliance/wasmtime/releases/tag/v50.0.0>):

| asset | sha256 |
|---|---|
| [`wasi_snapshot_preview1.reactor.wasm`](https://github.com/bytecodealliance/wasmtime/releases/download/v50.0.0/wasi_snapshot_preview1.reactor.wasm) | `73b01f85e42e99c890efbbf619cd765e04e5809da36d976b87fc64abd87f5812` |
| [`wasi_snapshot_preview1.command.wasm`](https://github.com/bytecodealliance/wasmtime/releases/download/v50.0.0/wasi_snapshot_preview1.command.wasm) | `b3de00ac47528237211c6404b4a7e4235a67878665dc3e8853071908c3127a85` |

The recipe below with these two files rebuilds all three fixtures byte for
byte.

Rebuild (wasm-tools 1.262.0):

```sh
wasm-tools parse preview1_fd_write.wat -o core.wasm
mkdir -p wit && cp preview1_adapted.wit wit/
wasm-tools component embed wit core.wasm -o emb.wasm
wasm-tools component new emb.wasm \
  --adapt wasi_snapshot_preview1=wasi_snapshot_preview1.reactor.wasm \
  -o preview1_fd_write_reactor.wasm
```
