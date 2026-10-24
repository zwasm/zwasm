# Security Policy

zwasm is a WebAssembly runtime: it loads and executes **untrusted `.wasm`
bytecode** in the same process as the host. Memory safety and sandbox
integrity are therefore first-class concerns, and we take reports seriously.

## Supported versions

zwasm v2's first stable release is **`v2.0.0`**. Security fixes land on the
`main` branch and the latest `v2.x` release. Older `v1.x` tags are frozen and no
longer receive updates.

| Version         | Supported |
|-----------------|-----------|
| `v2.x` / `main` | ✅ |
| `v1.x` (frozen) | ❌ |

## Reporting a vulnerability

**Please do not open a public issue or Discussion for security problems.**

Report privately via GitHub's **[Private Vulnerability Reporting](https://github.com/zwasm/zwasm/security/advisories/new)**
(the "Report a vulnerability" button under the repository's *Security* tab).
If that is unavailable to you, open a minimal public Discussion asking a
maintainer to reach out — **without any exploit detail** — and mention
`@chaploud` and `@jtakakura`.

Please include, where possible:

- affected version / commit and target (`aarch64-macos`, `x86_64-linux`,
  `aarch64-linux`, or `x86_64-windows`) and execution mode (interpreter / JIT / AOT);
- a minimal `.wasm` (or `.wat`) reproducer and the exact CLI / embedding call;
- the observed impact (host memory corruption, sandbox escape, WASI capability
  bypass, denial of service, etc.).

We aim to acknowledge a report within a few days. Because this is a
small, resource-limited project, please allow reasonable time for a fix
before any public disclosure.

## Scope

In scope: host memory corruption or an abort of the host process from a
malformed or adversarial module, sandbox / WASI-capability escapes, JIT
code-generation bugs with a security impact, and unbounded resource use that
the documented limits (fuel, timeout, memory ceiling) fail to contain.

Out of scope: behaviour of untrusted guest code that stays *within* the
sandbox, and misuse of the embedding API in ways the documentation warns
against.

For the trust boundaries, the settings that relax them, and how a report is
classified, see [the threat model](../docs/threat_model.md).

## Hardening the host

zwasm ships deny-by-default WASI capabilities, fuel metering, a wall-clock
timeout, a memory ceiling, W^X JIT pages, and signal-handled traps. See
[the README](../README.md#embedding) and
[the CLI reference](../docs/reference/cli.md#run) for how to configure these
limits.
