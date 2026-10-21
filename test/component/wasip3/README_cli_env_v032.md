# `cli-env-v032.wasm` — a guest bound to the WASI 0.3.2 names

WASI 0.3.1 and 0.3.2 change only the version strings of the 0.3.0 WIT. This
is the official `wasip3_official/cli-env.wasm` with its `@0.3.0` names
rewritten in place to `@0.3.2`; no other byte differs. Regenerate with
`bash scripts/gen_wasip3_v032.sh` after a bump of `wasip3_official`.

`cli-env-v032.json` is the upstream `cli-env.json`. The guest asserts its
argv[0] is `cli-env.wasm`, the upstream name, not this file's.

Apache-2.0 (derived from WebAssembly/wasi-testsuite; see `legal/THIRD_PARTY.md`).
