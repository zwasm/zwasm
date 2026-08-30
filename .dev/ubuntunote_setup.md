# Linux SSH host setup (optional pre-flight)

> **Doc-state**: ACTIVE — optional maintainer tooling.

**Nothing here is required to contribute.** CI's `ci-required` check runs the
Linux leg on every pull request and is the authoritative gate (ADR-0076 D9).
This document describes an *optional* local pre-flight.

`ubuntunote` is the maintainer's own SSH alias and hostname, used here as a
worked example; substitute what you set in `ZWASM_UBUNTU_HOST`, with the clone
path in `ZWASM_REMOTE_DIR` (see
[`scripts/dev_hosts.env.example`](../scripts/dev_hosts.env.example), ADR-0206).

zwasm v2's Linux x86_64 verification host wants **native x86_64
hardware** (it replaces the OrbStack Rosetta-2 path that tripped
D-134 — see
[`.dev/lessons/2026-05-17-d134-rosetta-2-signal-translation-limit.md`](lessons/2026-05-17-d134-rosetta-2-signal-translation-limit.md)).

## Why a real x86_64 box instead of OrbStack

OrbStack's `my-ubuntu-amd64` machine runs x86_64 binaries
through Apple Rosetta 2 dynamic translation on an ARM64
kernel. Long-running JIT workloads exposed a Rosetta signal-
delivery race (D-134, root cause confirmed 2026-05-17) that
bypasses our guest-installed `sigaction(.SEGV, ...)` handler
non-deterministically. Native x86_64 Linux executes our
JIT-emitted instructions on real Intel/AMD silicon with
faithful signal-delivery semantics; no retry wrapper needed,
no Rosetta abstraction between the JIT and the CPU.

OrbStack is retained as a dev convenience host but is no
longer in the per-chunk gate.

## Mac-side prerequisites

`~/.ssh/config` block (mirror of `windowsmini`):

```
Host ubuntunote
    HostName ubuntunote.local
    User <user>
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    ServerAliveInterval 60
    ServerAliveCountMax 3
    TCPKeepAlive yes
```

Verification:

```bash
ssh ubuntunote 'echo ok && zig version'
```

Expected: `ok` + `0.16.0` (after Nix flake bootstrap, below).

## Ubuntu-side setup (one-time)

### 1. Hostname + mDNS

Apply the project-canonical hostname so `.local` resolution
works from any host on the same LAN:

```bash
sudo hostnamectl set-hostname ubuntunote
sudo apt update
sudo apt install -y avahi-daemon libnss-mdns openssh-server
systemctl status avahi-daemon --no-pager
grep ^hosts /etc/nsswitch.conf   # should contain mdns4
```

### 2. Minimal apt baseline

zwasm v2 prefers Nix for the toolchain (per `flake.nix`), so
the apt footprint stays small. Required apt packages:

```bash
sudo apt install -y \
    build-essential \
    git \
    curl \
    ca-certificates \
    xz-utils \
    sudo \
    openssh-server \
    avahi-daemon \
    libnss-mdns
```

- `build-essential` — Nix install bootstrap + (occasionally)
  C build for spike repros under `private/spikes/`.
- `xz-utils` — Nix installer dependency.
- The rest are baseline.

### 3. Nix install (Determinate Systems multi-user)

Determinate's installer is faster + safer than the legacy
single-user script and supports `nix develop` out of the box:

```bash
curl --proto '=https' --tlsv1.2 -sSf -L \
    https://install.determinate.systems/nix | sh -s -- install
```

Re-open shell (or `exec bash`) to pick up `/nix/var/nix/profiles/default/bin`
in `PATH`. Verify:

```bash
nix --version            # should be ≥ 2.30
nix flake --help | head -3
```

### 4. Clone + flake bootstrap

```bash
mkdir -p ~/Documents/MyProducts
cd ~/Documents/MyProducts
git clone -b main git@github.com:zwasm/zwasm.git zwasm
cd zwasm
nix develop --command zig version   # should print 0.16.0
```

The first `nix develop` fetches Zig 0.16.0 + project deps from
the flake's pinned inputs (~5 min, one-time per host). The clone path
must match `ZWASM_REMOTE_DIR` in `scripts/dev_hosts.env` (relative to
the remote `$HOME`) — that is what the runners `cd` into.

### 5. Per-chunk gate smoke

From Mac:

```bash
bash scripts/run_remote_ubuntu.sh build       # zig build
bash scripts/run_remote_ubuntu.sh test        # zig build test
bash scripts/run_remote_ubuntu.sh test-all    # full gate (per Phase 1+)
```

Expected: clean exit, no Rosetta-style SEGV (D-134 gone).

## What apt vs Nix decision look like

| Tool                              | apt | Nix flake | Rationale |
|-----------------------------------|:---:|:---------:|-----------|
| openssh-server, avahi, libnss-mdns | ✓ |           | system-level service; pre-Nix bootstrap |
| build-essential, xz-utils, curl   | ✓  |           | Nix installer + spike-repro C builds |
| sudo, ca-certificates, git        | ✓  |           | base bootstrap |
| Zig 0.16.0                        |     | ✓         | pinned via `flake.nix`; version-locked across hosts |
| zlinter (lint gate per ADR-0009)  |     | ✓         | project-pinned dev tool |
| gdb, strace, qemu-user (debug)    | ✓ (interactive) | ✓ (when reproducible repro needed) | debug-time tools; apt is convenient, Nix gives reproducibility |
| wasmtime, wasm-tools (diff runner) |    | ✓         | project-pinned spec-test tooling |

Rule of thumb:
- **apt**: anything required *before* Nix runs (network, ssh,
  shell, basic compilers for installer dependencies).
- **Nix flake**: everything else — especially anything that
  must agree across Mac aarch64 / Ubuntu x86_64 / windowsmini
  for the per-chunk 2-host gate to produce identical results.

## Lifecycle / sleep behavior

`ubuntunote` should ideally **stay up 24/7** to support
overnight autonomous loop runs. If suspend is unavoidable:

- Enable Wake-on-LAN: `sudo ethtool -s eth0 wol g` (per
  interface; persist via `/etc/systemd/system/wol.service` or
  NetworkManager dispatcher).
- Mac side: `wakeonlan <mac-addr>` before each remote run, or
  bundle into `run_remote_ubuntu.sh` (auto-WoL on `ssh: connection
  refused`).

For now treat sleep as out-of-scope; if it becomes an issue,
add a wake helper script under `scripts/`.

## Gate integration

Per `.claude/skills/continue/LOOP.md`, the per-chunk 2-host
gate fires:

- **Mac aarch64** (foreground): `zig build test-all`
- **Ubuntu x86_64** (background): `bash scripts/run_remote_ubuntu.sh test-all > /tmp/ubuntu.log 2>&1`

Phase-boundary reconciliation continues to include
`windowsmini` (the 3-host gate hasn't changed shape; only the
identity of the x86_64-Linux host has).

## Decommissioning OrbStack (post-Ubuntu-bring-up)

Once `ubuntunote` is verified green for the full corpus, the
OrbStack-side scaffolding becomes legacy:

- `scripts/orb_test_all_with_d134_retry.sh` — DELETED (ADR-0206 D5;
  git history retains the D-134 mitigation record).
- `.dev/orbstack_setup.md` — retain; OrbStack is still a
  useful dev-convenience host for interactive scratch.
- `.dev/debt.yaml` D-134 row — flip Status to `closed (root
  cause removed: OrbStack-Rosetta path retired from gate)`
  with reference to the ubuntunote pivot commit.
