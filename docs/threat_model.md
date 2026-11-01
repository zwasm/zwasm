# Threat model

This document states whom zwasm trusts, where its trust boundaries are, and what
we treat as a security vulnerability. To report one, follow
[SECURITY.md](../.github/SECURITY.md).

## Scope

In scope: the released `zwasm` CLI binaries, and `libzwasm` (the C API in
`include/` and the Zig API) built from a release tag with the default build
options, or with `-Dwasi=p2`, on the targets we publish. Out of scope: other
build options, and the development tooling under `.dev/` and `scripts/`.

## Maturity

As of October 2026, zwasm is maintained in practice by one person and has had
no external security audit. Fuzzing covers module loading and an
interpreter-versus-JIT execution differential over small committed corpora
(`test/fuzz/`); the WASI and component hosts are not fuzzed. Treat hostile
multi-tenant use — guests you do not trust, sharing one process — as beta.
Report what you find through [private vulnerability reporting](https://github.com/zwasm/zwasm/security/advisories/new);
published advisories are listed at
[security/advisories](https://github.com/zwasm/zwasm/security/advisories).

## Actors and trust

| Actor | Trust | Why |
| --- | --- | --- |
| Embedder, or the operator of a `zwasm run` | Trusted | Links the instances, grants the WASI resources and sets the limits. Anything an embedder can configure, CLI flags included, is not an attack. |
| Guest code | **Untrusted** | The adversary. We assume it is hostile from its first instruction, and that the module bytes are malformed on purpose. |
| Host functions | Trusted | Embedder code, called from the guest. |
| `.cwasm` artifacts | Trusted as native code | See [Trust boundaries](#5-artifact--runtime). |
| WASI host resources | Granted | Directories, environment variables, arguments and network access the embedder passed in. |
| Network peers | **Untrusted** | Whatever a guest's sockets talk to. |

## Trust boundaries

```
 embedder / CLI operator (trusted)
        │  links, grants, limits, .cwasm artifacts
        ▼
 ┌──────────────── host process (trusted) ───────────────────┐
 │  zwasm runtime + host functions + WASI host               │
 │                                                           │
 │   ┌─ instance A ─┐   ✗   ┌─ instance B ─┐                 │
 │   │ untrusted    │──────▶│ untrusted    │  only through   │
 │   └──────┬───────┘ links └──────────────┘  what was linked│
 └──────────┼────────────────────────────────────────────────┘
            │ granted WASI resources
        host files, environment, network peers
```

### 1. Guest ↔ runtime

The module's bytes and the guest's instructions cross here. The expected
outcomes are a refusal of a malformed module and a trap on a guest fault;
anything else is a breach of goal 1 or 2.

### 2. Guest ↔ WASI host

The guest's WASI calls cross here, to the resources the embedder granted:
standard I/O, preopened directories (`--dir`), environment variables (`--env`),
arguments and the network (`--allow-network`). Reaching anything else is a
breach of goal 4.

### 3. Instance ↔ instance

Only what the embedder linked crosses here. A function running on another
instance's state, on any engine, is a breach of goal 3.

### 4. Host function ↔ guest

Values the guest chose cross here. Validate them before acting on them, however
trusted the guest is.

### 5. Artifact ↔ runtime

A `.cwasm` is native code. The loader checks its format version and target, not
its origin or integrity. Load only artifacts you built yourself or trust as you
would a shared library; the same holds for the `--cache` directory.

## Security goals

These are not properties zwasm guarantees. Each names a breach that, with the
default settings, we treat as a vulnerability unless
[Known limitations](#known-limitations) names it.

1. **Sandbox.** A guest runs native code, or reads or writes memory outside its
   own memories and tables.
2. **Host integrity.** A guest triggers behaviour of the host process that the
   specification does not define: a crash that is not a trap, a read of
   undefined memory.
3. **Isolation.** A function runs on another instance's state, or an instance
   reaches something it was not linked with.
4. **Grants.** A guest reaches a host resource it was not granted.
5. **Limits.** A guest runs past a fuel budget, timeout, memory cap or table cap
   that was set.

## Settings that weaken a goal

| Setting | Goal | Effect |
| --- | --- | --- |
| `.unmetered` on an `InstantiateOpts` axis, or `null` to `Instance.setFuel` / `setMemoryPagesLimit` / `setTableElementsLimit` (Zig API) | 5 | That axis (fuel, memory or table) has no limit. The Zig API's defaults are finite. |
| A core-module `zwasm run` without `--fuel` / `--timeout` / `--max-memory` / `--max-table-elements` | 5 | The run is unbounded on every engine. A component run keeps the Zig API's finite defaults. |
| The C API, and `zwasm_instance_disable_fuel` / `zwasm_instance_clear_memory_pages_limit` | 5 | An instance starts unmetered until a `zwasm_instance_*` setter arms a limit; these two remove one. |
| `--max-memory` / `zwasm_instance_set_memory_pages_limit` | 5 | Caps `memory.grow`, not the memory a module declares at instantiation (#489). |
| `--dir`, `--env`, `zwasm_wasi_config_preopen_dir`, `zwasm_wasi_config_set_envs`, `zwasm_wasi_config_inherit_env` | 4 | Each is a grant: the guest reaches what it names. |
| `--allow-network`, `Host.allow_network` (Zig API) | 4 | A grant: a component reaches any address the host can route, and listens on any port the host can bind. |
| `--engine` / `zwasm_instance_new_ex` | 3 | The interpreter and the JIT have different known isolation gaps (#536, #578). |
| `--cache` | — | The cache directory holds native code (boundary 5). |

## What we treat as a vulnerability

A breach of a security goal that Known limitations does not name. A maintainer
sorts a report with three questions:

1. Does the attacker control only the untrusted side — the guest's bytes and
   what the embedder linked it with?
2. Does it breach a security goal?
3. Is the result something other than a trap or a refusal: a wrong answer the
   host acts on, undefined behaviour, a process abort, or a set limit that does
   not hold?

Three yeses make a vulnerability. One no makes it a bug. In particular:

- An uncaught out-of-bounds memory or table access, or a guest leaving the
  control flow its module declares.
- Memory unsafety in the host, at compile time or at run time.
- A crash, panic or abort while executing a guest, where the specification asks
  for a trap. [GHSA-wf5j-gpc8-4xvg](https://github.com/zwasm/zwasm/security/advisories/GHSA-wf5j-gpc8-4xvg)
  is the worked example: a guest-chosen list length overflowed the host's u32
  arithmetic and aborted the process.

## What we do not treat as a vulnerability

- **Behaviour confined to the sandbox.** A guest that computes a wrong value or
  traps when it should not harms only itself. We still fix these as bugs.
- **API misuse the documentation warns against**, such as calling the engine
  from a second thread.
- **Resource use in a run with no limit set**, and compile time: a module that
  crashes the compiler is a vulnerability, one that is slow to compile is not.
- **Side channels.** zwasm has no mitigation for speculative side channels, and
  guests of different trust in one process share them.

## Known limitations

- **Instance isolation, JIT (goal 3).** `call_indirect` of a funcref another
  instance returned runs it on the caller's state (#536).
- **Cross-instance funcref, interpreter (goal 2).** `call_indirect` on a
  funcref a JIT-backed instance minted dies with a fatal signal (#578).
- **Start function (goal 5).** No C entry point arms a limit before the start
  function runs (#465).

## Embedder responsibilities

- **Set limits for untrusted guests.** From the CLI, pass `--fuel` or
  `--timeout`, and `--max-memory`. From C, arm the `zwasm_instance_*` setters.
  From Zig, keep the finite defaults. See the
  [README](../README.md#embedding) and [the CLI reference](reference/cli.md#run).
- **Grant the least.** Preopen only the directories the guest needs, and pass
  only the environment it needs.
- **Give the runtime the stack it needs.** A thread under 1 MiB of stack can
  die before any wasm runs (#532, #534); on musl, see #533.
- **Treat `.cwasm` files and the cache directory as executables.**
- **Separate guests of different trust into different processes** where a side
  channel between them matters.
