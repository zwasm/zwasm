# Contributing to zwasm

Thanks for your interest in zwasm.

## How to contribute

zwasm v2 is on its stable release line and welcomes contributions.
This is a small, resource-limited project, so please keep the following in mind
to make review sustainable:

- **Bugs / feature requests** — open an
  [Issue](https://github.com/zwasm/zwasm/issues/new/choose) using the
  templates. A minimal `.wasm` / `.wat` reproducer helps enormously.
- **Questions & ideas** — start a thread in
  [Discussions](https://github.com/zwasm/zwasm/discussions).
- **Pull requests** — welcome. For anything non-trivial, please open an issue
  or discussion first so we can agree on the approach before you invest time.
  Keep PRs focused; make sure `zig build test-all` and `zig fmt src/` are clean.
- **Security** — do **not** post exploit details publicly; follow
  [`SECURITY.md`](SECURITY.md) (private vulnerability reporting).

Response times may vary since this is maintained in spare time — thanks for
your patience.

## Branch & merge model

`main` is the trunk and is protected — there are **no direct pushes**. Every
change lands the same way:

1. Branch off `main` (maintainers use `develop/<slug>`; external contributors
   fork). Never commit straight to `main`.
2. Open a pull request. Opening it runs **CI** — a 3-OS gate (macOS aarch64 +
   Linux x86_64 + Windows x86_64) that runs the exact `scripts/ci_gate.sh` the
   maintainer runs locally.
3. The required **`ci-required`** check must be green before the PR can merge.
   Doc-only changes (Markdown, `docs/`, `.dev/`, `.claude/`, `LICENSE`) skip the
   heavy 3-OS build/test automatically, so a docs PR goes green in seconds — but
   still merges through the same gate.
4. Merge when it is green; the branch is auto-deleted.

Releases (tags / published artifacts) are cut manually by the maintainer only.

## Building and testing (for trying it locally / forking)

zwasm targets **Zig 0.16.0** and
[`wasm-tools`](https://github.com/bytecodealliance/wasm-tools), both pinned in
[`versions.lock`](versions.lock). `zig build` generates `spectest.wasm` from
`test/spec/spectest.wat` by invoking `wasm-tools`, so even a plain build fails
when `wasm-tools` is not on your `PATH`. With both installed:

```sh
zig build              # compile the zwasm CLI + library
zig build test         # unit tests
zig build test-all     # all enabled test layers
zig fmt src/           # format
```

**[`docs/development.md`](../docs/development.md) is the full development
reference** — test layers, optional tools (wasmtime oracle, Nix shells,
`yq`), git-hook activation, and an explicit list of the optional tooling
you do NOT need (remote pre-flight scripts, fixture-regeneration
toolchains). CI runs the complete 3-OS gate on every PR, so a single
machine of any supported OS is enough to contribute.

See [`docs/tutorial.md`](../docs/tutorial.md) to build, run, and embed zwasm.

## License

By contributing you agree that your contributions are licensed under the
project's license, **Apache-2.0** (see [`../LICENSE`](../LICENSE)). Note that v2 is
Apache-2.0; the frozen v1 line was MIT.
