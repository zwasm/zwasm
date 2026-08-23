---
name: debug_jit_auto
description: JIT runtime debug toolkit (lldb/ndisasm/strace/SIGSEGV recipes for SEGV / miscompile investigation). Invoke when investigating SEGV, signal 11, exit code 139, mprotect issues, JIT byte stream disassembly, or any runtime crash in zwasm v2 codegen / interpreter.
---

# JIT / runtime debug toolkit — autonomous SEGV / miscompile recipes

> **Living document.** When you discover new tools, recipes, or
> workflow patterns during a debug session, **edit this file in
> the same commit as the fix** (or in a follow-up `chore(debug):`
> commit). Don't let the knowledge evaporate into chat history —
> the next debug session needs to find it via this skill's
> on-demand load. Adding a new recipe is cheap; re-deriving it from
> scratch is expensive.

Invoked when investigating SEGV / miscompile / runtime crash in JIT
codegen, interpreter, runtime, realworld runners, edge-case fixtures,
or anything under `private/spikes/`. Codifies the toolchain
established during §9.7 / 7.10-l (run-stage SEGV chunk-m investigation):
which tools live where, and copy-paste-ready batch-mode recipes that
the autonomous `/continue` loop can invoke without human-in-loop
debugger steering.

`extended_challenge.md` Step 4 explicitly authorises spikes +
WebFetch + reference-repo deep reads in autonomous scope. This file
is the **how** for runtime-debug spikes — the catalogue of tools that
already exist locally + the recipe shapes that fit the autonomous
loop.

## Tool inventory (post-7.10-l, ubuntunote-updated 2026-05-17, windowsmini-added 2026-05-22)

| Tool | Mac (nix `flake.nix`) | ubuntunote (`apt` / `nix profile`) | windowsmini (`install_tools.ps1`) | Purpose |
|---|---|---|---|---|
| `lldb` | `pkgs.lldb` (21.x) | Nix dev-shell via `flake.nix` (21.x) | LLVM bundle 22.1.6 at `C:\Program Files\LLVM\bin\lldb.exe` | batch-mode debugger; primary autonomous tool |
| `gdb` | not in flake (darwin gdb is finicky — codesign required) | `apt install gdb` (15.x) | n/a (use lldb) | Linux-side alternative to lldb |
| `ndisasm` / `nasm` | `pkgs.nasm` (3.x) | `apt install nasm` (2.16.x) | n/a (use llvm-objdump --disassemble -b binary) | raw byte stream → x86_64 disasm |
| `objdump` / `llvm-objdump` | clang's (in nix shell) | `apt install binutils` (default) | `llvm-objdump.exe` (LLVM bundle) | ELF / Mach-O / PE/COFF disasm |
| `llvm-readobj` | clang's | binutils default | LLVM bundle | PE/COFF / ELF inspection (symbols, sections, headers) |
| `llvm-symbolizer` | clang's | binutils default | LLVM bundle | backtrace symbolication |
| `strace` | not on Mac (use `dtruss` Apple-native) | `apt install strace` (6.8) | n/a (use **Procmon64.exe** — Sysinternals — for file/process/registry trace) | syscall / OS event trace (catches RWX page issues, file access timing) |
| `ltrace` | n/a | `apt install ltrace` (0.7.3) | n/a (lib call trace not first-class on Win) | libc / dynamic library call trace |
| `valgrind` | `pkgs.valgrind` (Linux only at flake level) | `apt install valgrind` (3.22) | n/a | heap analysis when DebugAllocator isn't enough |
| `bpftrace` | n/a (macOS lacks eBPF) | `apt install bpftrace` (0.20) + `bpfcc-tools` | n/a (ETW / WPR is the Win analog; not wired yet) | kernel-level dynamic tracing |
| `perf` | n/a | `apt install linux-tools-generic` | n/a (PerfView is the Win analog; not installed yet) | CPU profiling, branch / cache analysis |
| `qemu-x86_64` | n/a | `apt install qemu-user-static` | n/a (windowsmini is native x86_64) | cross-arch verification |
| `readelf` / `nm` | clang's | binutils default | `llvm-nm.exe` (LLVM bundle) | ELF / PE/COFF symbol inspection |
| `xxd` | available | available | `bash -c "xxd ..."` via Git-Bash; or PowerShell `Format-Hex` | hex dump / patch |
| `file` | available | `apt install file` | `bash -c "file ..."` via Git-Bash | quick arch / format identification |
| **`Procmon64.exe`** | n/a | n/a | Sysinternals bundle (`install_tools.ps1 -OnlyTool sysinternals`) — `%LOCALAPPDATA%\zwasm-tools\sysinternals-<date>\` | Process / file / registry trace. **D-028 wedge investigation primary tool**. Filter on Process Name → see exactly what zwasm-spec-runner.exe's spawn does (parent process wait, image scan delay, etc.) |
| **`procexp64.exe`** | n/a | n/a | Sysinternals bundle | Live process state, fd / handle count. **D-028 hypothesis #3 (fd-table fullness)** directly observable here — open Process Explorer → Find Handle → see handle count per process |
| **`handle64.exe`** | n/a | n/a | Sysinternals bundle | CLI fd/handle enumeration. `handle64.exe -p zwasm-spec-runner.exe` lists open handles of a specific process |
| **`Dbgview.exe`** | n/a | n/a | Sysinternals bundle | Capture `OutputDebugStringA/W` from any process. Useful when adding W3.b VEH-handler debug prints |
| **`tcpview64.exe`** | n/a | n/a | Sysinternals bundle | TCP/UDP connection viewer. Not core for JIT debug; included with bundle |

**Not viable / out of scope**: `rr` (record-and-replay) — needs
perf counters that virtualised hosts often don't expose
correctly; not yet installed on ubuntunote. If true record-
replay is needed on the native x86_64 host, run on bare metal
with `rr record` directly. **D-134's investigation** (LD_PRELOAD
sigaction shim + handler-entry probe + dmesg
`print-fatal-signals` + vanilla C reproducer) is documented in
the canonical pattern at
[`.dev/lessons/2026-05-17-d134-rosetta-2-signal-translation-limit.md`](../../../.dev/lessons/2026-05-17-d134-rosetta-2-signal-translation-limit.md);
the same shape applies to future SIGSEGV / signal-handling
oddities.

The `.dev/ubuntunote_setup.md` document carries the canonical
apt-vs-nix decision table (system-level vs project-pinned).
`.dev/orbstack_setup.md` is retained but reflects OrbStack's
**dev-scratch-only** role per ADR-0067 — debug tools listed
there are duplicates of the ubuntunote inventory at a slightly
older version.

## Recipes catalogue → [`RECIPES.md`](RECIPES.md)

Recipe bodies live in the sibling `RECIPES.md`. Load on demand —
this skill's on-demand load returns the procedure shell only
(tool inventory + decision tree + meta). When the decision tree
below points at a numbered recipe, open `RECIPES.md` and jump
to the heading.

| # | Recipe | Host | First-use trigger |
|---|---|---|---|
| 1 | `lldb -b` first triage | Mac / ubuntunote | Read fault RIP / register state |
| 2 | `ndisasm` raw JIT byte disasm | Mac / ubuntunote | Disassemble byte range from JIT block |
| 3 | `strace` mmap / mprotect inspection | ubuntunote | Suspect JIT-page protection issue |
| 4 | SIGSEGV handler (no debugger) | Mac / ubuntunote | lldb/gdb unavailable or crash pre-main |
| 5 | `private/spikes/jit_segv/` skeleton | any | Isolate which fixture/op triggers SEGV |
| 6 | Bisection by Wasm op | any | Op family unknown; hand-craft progressively-larger wasm |
| 7 | Crash-time JIT context dump (async-signal-safe) | Mac / ubuntunote | Fault context without debugger |
| 8 | **Fault-address poison-pattern decoding** | any | **FIRST step on every SEGV** (cheatsheet in `RECIPES.md`) |
| 9 | `lldb -b` first triage on windowsmini (SSH) | windowsmini | Mirror of #1 for Win64 PE/COFF |
| 10 | `Procmon64.exe` process spawn / file trace | windowsmini | D-028 wedge primary tool |
| 11 | `handle64.exe` fd / handle count | windowsmini | D-028 hypothesis #3 probe |
| 12 | `llvm-objdump` PE/COFF JIT byte disasm | windowsmini | Win64 mirror of #2 |
| 13 | `Dbgview.exe` + `OutputDebugStringA` VEH trace | windowsmini | W3.b post-land VEH handler verification |
| 14 | Crash dump (WER `.dmp`) post-mortem with lldb | windowsmini | Win64 outright crash post-mortem |
| 15 | `ssh windowsmini cmd /c '...'` stable orchestration | windowsmini | HANG / interactive debug with quoting traps |
| 16 | JIT bytes dump via runner instrumentation (`ZWASM_DEBUG=jit.dump`, codified) | any | Disassemble a JIT body |
| 17 | Manifest-bisect via `test/private/d-165/` scratch | any | Isolate which directive triggers the bug |
| 18 | **lldb VALUE-trace inside JIT code (`scripts/jit_value_trace.sh`)** | Mac/ubuntu | **Miscompile = wrong output, NO crash** — read regs/mem at a JIT instruction |
| 19 | **Attribute a spec-lane fail before reading any codegen** | any | **FIRST step on every `ZWASM_SPEC_ENGINE=jit` fail** — the detail line names the func, not the module |
| 20 | **Operand-stack-pressure sweep** | any | JIT-only wrong result/trap where each op passes in isolation → spilled operand |
| 21 | **Differential probe by re-exporting a guest's internals** | any | **A toolchain-built `.wasm` aborts under `--engine jit` only** — too big to read |
| 22 | **liveness sim vs emit `pushed_vregs` drift** | any | Stale block/if result AND `regverify` reports no overlap |


## When to invoke each recipe (decision tree)

```
Fail came from a spec-assert runner lane (ZWASM_SPEC_ENGINE=jit)?
└── Recipe 19 FIRST — the detail line prints the func name only, so in a
    corpus where every module exports `run` it does not say which module
    failed. Bisect the manifest to the module, then reproduce on the CLI
    (`zwasm run --engine jit/--engine interp`) for a precise trap kind.
    Only then enter the tree below. (D-590: a `table.get` regalloc bug
    spent a cycle inside `invokeMulti` for want of this step.)

A whole toolchain-built guest (AssemblyScript / TinyGo / Rust / emcc)
aborts or misbehaves under `--engine jit` but not `--engine interp`?
└── Recipe 21 FIRST — 21a settles in ONE command whether a host-call
    boundary is involved at all (compare WHICH import each engine reaches
    first under `ZWASM_DEBUG=mem.cksum`, not just the checksums), then 21b/21c
    localize to a guest function and a single heap word without reading the
    module. 21f ends at a hand-written `.wat`. If a probe inserted INTO the
    suspect function makes the bug vanish (21e), it is regalloc/liveness —
    continue at Recipe 22, then Recipe 2 on the `jit.dump` bytes.

Host = Mac / ubuntunote?
├── JIT-only wrong result / wrong trap, but each op passes in isolation?
│   └── Recipe 20 (operand-stack-pressure sweep): find the live-value
│       count where it flips. A clean boundary = a spilled operand →
│       audit the emit site's `gprLoadSpilled` `stage_idx` against the
│       physical registers already live there.
├── Wrong OUTPUT but NO crash (value miscompile — e.g. diff-jit mismatch)?
│   └── Recipe 18 (`scripts/jit_value_trace.sh`): disasm the suspect func,
│       then VALUE-trace the instruction (regs/mem) interp-vs-jit. This is
│       the lens IR/vreg-level analysis (liveness/regalloc) cannot give.
├── SEGV reproduces in test-realworld-diff-jit?
│   (test-realworld-run-jit only COMPILES — it stopped executing fixtures
│    when its null-WASI-host run stage was removed; a SEGV during execution
│    reproduces in the diff lane, or via `zwasm run --engine jit <fixture>`)
│   ├── YES → Recipe 1 (lldb -b) for first triage. Read fault RIP.
│   │        ├── RIP inside JIT block (block.bytes.ptr ≤ RIP < ptr+len)?
│   │        │   ├── YES → Recipe 2 (ndisasm) on the byte range.
│   │        │   │        Identify the faulting x86 insn → trace back
│   │        │   │        to the emit-pass site that produced it.
│   │        │   │        → Likely candidates: prologue stack
│   │        │   │          alignment, spill region overflow, trap
│   │        │   │          stub address calc.
│   │        │   └── NO → not in JIT body. Check entry shim
│   │        │            (entry.zig), runtime ptr passing, or
│   │        │            JitRuntime layout (Recipe 3).
│   │        └── Crash before lldb attaches?
│   │            └── Recipe 4 (SIGSEGV handler) instead.
│   │
│   ├── NO but suspect mprotect issue?
│   │   └── Recipe 3 (strace) for mmap/mprotect timeline.
│   │
│   └── Hard to localise to one fixture?
│       └── Recipe 5 (spike) + Recipe 6 (bisection).
│
└── Host = windowsmini?
    ├── Process wedges / hangs at runner transition (D-028 shape)?
    │   ├── First: Recipe 11 (handle64 fd count) — hypothesis #3 probe
    │   └── Then: Recipe 10 (Procmon trace) — see what spawn does
    │
    ├── Crash / EXCEPTION_ACCESS_VIOLATION?
    │   ├── If WER dump available: Recipe 14 (post-mortem)
    │   ├── If reproducible under lldb: Recipe 9 (lldb -b, SSH form)
    │   └── If JIT bytes need disasm: Recipe 12 (llvm-objdump PE)
    │
    └── W3.b VEH bridge work (D-136 impl)?
        └── Recipe 13 (Dbgview + OutputDebugString) for VEH entry trace
```

## Lessons / ADR landing

Per `.claude/rules/lessons_vs_adr.md`:
- Spike outcome that's observational ("we tried X, learned Y") →
  lesson at `.dev/lessons/<date>-<slug>.md`
- Spike outcome that's load-bearing decision ("X is rejected
  because Y") → ADR at `.dev/decisions/NNNN_<slug>.md`
- Production fix → normal source commit

Always cite the concrete `lldb -b` output / `ndisasm` line / etc.
in the commit body — the recipe + finding lineage matters for
future-you debugging similar SEGVs.

## How this file evolves (meta — read on every load)

This file is a **living toolkit**, not a frozen reference. The
autonomous loop is expected to extend it whenever new ground is
covered. Concretely:

- **New tool installed** (Mac via `flake.nix` / `pkgs.X` or
  Ubuntu via `apt install Y`)? Add it to the **Tool inventory**
  table with one-line purpose. Mention which platform.
- **New recipe figured out** (e.g. a specific `gdb -ex` chain
  that auto-extracts JIT bytes around a crash, or a `strace`
  filter that catches a particular runtime quirk)? Add it as
  a numbered Recipe with a copy-paste block.
- **Tried-and-rejected tool** (e.g. `rr` requires perf counters
  that aren't exposed everywhere)? Note it in **Not viable** /
  **Not in scope** so the next session doesn't re-pay the trial
  cost.
- **Tool installation gap discovered** (e.g. ndisasm missing
  on a host)? Update `.dev/ubuntunote_setup.md` / `flake.nix`
  AND the inventory table here in the same commit.

**Edit triggers** (when this skill is loaded, scan for these):
- Are you about to debug a SEGV / miscompile / runtime crash?
  → Apply the decision tree at the bottom.
- Did you just finish such a debug session?
  → Did you use a tool / recipe NOT documented here? Add it.
- Did you install a new tool to the dev environment? → Inventory
  table.

**Don't be precious about edits.** A new recipe with rough
copy-paste output is more valuable than a polished prose entry.
Aim for "future-me can grep this file and find the exact
incantation" not "this reads like documentation".

## Cross-references

- `extended_challenge.md` — autonomous self-resolution discipline
  (spikes, WebFetch, reference-repo deep reads). This skill is
  the toolkit; that rule is the policy.
- `lessons_vs_adr.md` — where to land the FINDINGS (lesson vs
  ADR vs production code).
- `bug_fix_survey.md` — once root-caused, grep for siblings.
- `.dev/ubuntunote_setup.md` — canonical apt/Nix install lines
  for the native x86_64 Linux gate host (post-ADR-0067).
- `.dev/orbstack_setup.md` — retained for dev-scratch use only
  (no longer the per-chunk gate host per ADR-0067).
- `.dev/windows_ssh_setup.md` — windowsmini setup; see its
  "Interactive JIT debug session" section for canonical SSH-
  side workflow (lldb-attach, Procmon launch, WER dump
  collection). Recipes 9-14 above are the toolkit; setup.md
  is the host-side prerequisite list.
