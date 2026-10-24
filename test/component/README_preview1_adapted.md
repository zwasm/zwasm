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

Rebuild (wasm-tools 1.262.0):

```sh
wasm-tools parse preview1_fd_write.wat -o core.wasm
mkdir -p wit && cp preview1_adapted.wit wit/
wasm-tools component embed wit core.wasm -o emb.wasm
wasm-tools component new emb.wasm \
  --adapt wasi_snapshot_preview1=wasi_snapshot_preview1.reactor.wasm \
  -o preview1_fd_write_reactor.wasm
```
