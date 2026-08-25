# OrbStack Ubuntu x86_64 VM Setup (DEV-SCRATCH ONLY post-2026-05-17)

> **Doc-state**: ARCHIVED-IN-PLACE 2026-05-22 — OrbStack retired per ADR-0067 (ubuntunote pivot). Kept for historical reference + Mac-local scratch use. Do not edit.

> **STATUS**: Retired from the per-chunk autonomous gate per
> [ADR-0067](decisions/0067_ubuntunote_native_x86_64_gate_host.md).
> Root cause: Apple Rosetta 2 signal-translation race for
> long-running JIT workloads — see
> [`lessons/2026-05-17-d134-rosetta-2-signal-translation-limit.md`](lessons/2026-05-17-d134-rosetta-2-signal-translation-limit.md).
> The Linux x86_64 gate host is now `ubuntunote.local` (native);
> see [`ubuntunote_setup.md`](ubuntunote_setup.md).
>
> This document is retained for **Mac-local interactive dev
> scratch** (`orb run -m my-ubuntu-amd64 …` ad-hoc commands,
> quick experiments). Do NOT use OrbStack for any gate path
> (autonomous loop, A13 merge gate, phase-boundary
> reconciliation).

One-time setup for local Ubuntu x86_64 testing via OrbStack on
Apple Silicon. The VM runs x86_64 Ubuntu under Rosetta translation;
this catches most arch-asymmetric regressions (W54-class) at the
ELF / SystemV-ABI / x86 ISA level **for interactive dev scratch
only**. For per-chunk gate use, see `.dev/ubuntunote_setup.md`.

## VM Creation

```bash
orb create --arch amd64 ubuntu my-ubuntu-amd64
```

VM name: `my-ubuntu-amd64` (shared with the v1 setup; reuse the
existing VM if already present).

## Tool Installation

Run inside the VM:

```bash
orb run -m my-ubuntu-amd64 bash -lc "<commands>"
```

The minimum tool surface needed for Phase 0 is **Zig 0.16.0**.
Other tools are added when the corresponding Phase opens.

```bash
# System packages
sudo apt update && sudo apt install -y build-essential python3 xz-utils curl git rsync

# Zig 0.16.0
curl -L -o /tmp/zig.tar.xz https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz
sudo mkdir -p /opt/zig && sudo tar -xf /tmp/zig.tar.xz -C /opt/zig --strip-components=1
echo 'export PATH="/opt/zig:$PATH"' >> ~/.bashrc

# (Phase 1+) wasm-tools and wasm-c-api are pulled by scripts when needed.
# (Phase 4+) wasmtime, WASI SDK, Rust + wasm32-wasip1 — added on demand.
# (Phase 11+) hyperfine — added on demand.

# (Phase 7 / §9.7 / 7.10-l onward) JIT debug toolkit per
# `.claude/rules/debug_jit.md` — install when investigating
# realworld_run_jit run-stage SEGVs, JIT miscompiles, or
# any x86_64 byte-stream debug task. `rr` is omitted: OrbStack
# VMs don't expose perf counters (ptrace EIO on rr record).
sudo apt install -y gdb lldb nasm strace
```

## Build verification (§9.0 / 0.2)

From Mac, in `zwasm_from_scratch/`:

```bash
orb run -m my-ubuntu-amd64 bash -c '
  cd ~/Documents/MyProducts/zwasm_from_scratch &&
  zig build &&
  zig build test
'
```

(OrbStack mounts the Mac home directory inside the VM at the same
path; building from the Mac FS is slow but correct. For benchmarks
where build time matters, rsync to the VM's local storage.)

## Notes on Rosetta

OrbStack on Apple Silicon emulates x86_64 via Rosetta. Most
arch-asymmetric bugs that v1's W54 surfaced are caught here, but
Rosetta has its own quirks (FP rounding, signal-handler edge cases).
The ROADMAP §11.5 three-host gate (Mac native + OrbStack +
windowsmini) gives the deepest local coverage; CI matrix from
Phase 14 adds GitHub-hosted ubuntu-22.04 (true native x86_64).

## Future improvements

- Replace the manual `apt install` / `curl` recipe with Nix devshell
  + direnv inside the VM, mirroring the Mac-host setup.
- Pin tool versions via a `versions.lock` file once CI is wired (Phase 14+).
