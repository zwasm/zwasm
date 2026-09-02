#!/usr/bin/env bash
# scripts/run_remote_ubuntu.sh — drive build/test on the configured
# Linux x86_64 SSH gate host (`ZWASM_UBUNTU_HOST`; native hardware).
#
# Replacement for the OrbStack `my-ubuntu-amd64` path
# (Rosetta-translated x86_64; tripped D-134 SIGSEGV race —
# closed per ADR-0067). Mirrors `run_remote_windows.sh`:
# `git fetch + reset --hard` the remote clone to the
# latest pushed `origin/main`, then run the
# requested `zig build` step. (`main` is the merged trunk — reached only via
# PR now; CI runs this same gate on each PR head. Pass `--branch develop/<slug>`
# to verify a feature branch on this host before opening the PR.)
#
# Usage:
#   bash scripts/run_remote_ubuntu.sh                          # default: zig build test-all on main
#   bash scripts/run_remote_ubuntu.sh build                    # zig build
#   bash scripts/run_remote_ubuntu.sh test                     # zig build test
#   bash scripts/run_remote_ubuntu.sh test-spec                # zig build test-spec
#   bash scripts/run_remote_ubuntu.sh --branch NAME [STEP]     # test arbitrary branch (feature branch verification)
#
# Per-chunk /continue gate: ALWAYS `test-all` (ADR-0076 D6). The
# narrow steps above are for manual/feature-branch (`--branch`) use;
# the autonomous loop kicks the no-arg default (= test-all) so the
# background x86_64-RUN gate never under-scopes (the D-260 foot-gun).
#
# The `--branch` form is used by §9.13-V Phase A.6 to verify
# feature branches (e.g. `develop/value16`) before
# merging to the trunk. Default branch is
# `main`; the per-chunk `/continue` loop never
# passes `--branch` (it expects to verify the just-pushed
# origin HEAD of the main dev branch per ADR-0076 D3).
#
# Prerequisites (all per-machine, none baked into the repo — see
# `scripts/dev_hosts.env.example`): `ZWASM_UBUNTU_HOST` naming an SSH
# alias that resolves without a prompt; Zig 0.16.0 available remotely
# via the project's flake.nix dev shell; this repo cloned at
# `$ZWASM_REMOTE_DIR` (relative to the remote `$HOME`) with `origin`
# pointing at `zwasm/zwasm`. Provisioning notes in
# `.dev/ubuntunote_setup.md`.
#
# Failure attribution: each remote step (preflight / sync /
# build) emits a labelled `[run_remote_ubuntu] FAIL: <step>`
# line on stderr before exiting, so the autonomous loop's log
# scan localises which phase broke without re-running.

# Per-machine host config FIRST (see dev_hosts.env.example) — resolved
# via an absolute script dir so any invocation cwd works, and before the
# orphan guard so the guard reaps SSH clients of the CONFIGURED host.
_sd="$(cd "$(dirname "$0")" && pwd)"
[ -f "$_sd/dev_hosts.env" ] && source "$_sd/dev_hosts.env"

# The host is per-machine and has no in-repo default. Resolving it before
# the orphan guard also keeps the guard's `pgrep -f "ssh <host>"` reap
# anchored to a real alias instead of matching every ssh client.
HOST="${ZWASM_UBUNTU_HOST:-}"
if [ -z "$HOST" ]; then
    echo "[run_remote_ubuntu] FAIL: config — ZWASM_UBUNTU_HOST is unset." >&2
    echo "  cp scripts/dev_hosts.env.example scripts/dev_hosts.env and set your own SSH alias (ADR-0206)." >&2
    echo "  This local fan-out is OPTIONAL — CI's ci-required check is the authoritative 3-OS gate." >&2
    exit 2
fi

# Orphan guard — reap prior orphans + self-bound under timeout before
# any work (see scripts/orphan_guard.sh + orphan_prevention.md). Must
# run before `set -e` so the reap's empty-pgrep exits don't abort.
_og="$_sd/orphan_guard.sh"
[ -f "$_og" ] && source "$_og" && orphan_guard "$0" "$HOST" "$@"

set -euo pipefail
cd "$_sd/.."

# SSH keepalive: a dead local client (parent-session kill / timeout)
# makes the remote sshd drop the channel — and the remote `zig build` —
# within ~2 min, so a reaped/timed-out gate doesn't leave a build
# running on the gate host (the "timeout does NOT propagate" caveat).
SSH_OPTS="-o ServerAliveInterval=30 -o ServerAliveCountMax=4"

REMOTE_DIR="${ZWASM_REMOTE_DIR:-zwasm}"
REMOTE_BRANCH="main"
if [ "${1:-}" = "--branch" ]; then
    if [ -z "${2:-}" ]; then
        echo "[run_remote_ubuntu] FAIL: --branch requires a branch name" >&2
        exit 2
    fi
    REMOTE_BRANCH="$2"
    shift 2
fi
STEP="${1:-test-all}"
shift 2>/dev/null || true   # remaining positionals forward to the `bench` step

die_step() {
    echo "[run_remote_ubuntu] FAIL: $1" >&2
    exit 1
}

# 1. Preflight — clone exists, ssh + nix reachable. `bash -lc`
#    sources `/etc/profile.d/nix*.sh` (Determinate installer
#    injects the daemon profile there + into /etc/bash.bashrc),
#    so the remote `nix` command resolves from a non-interactive
#    SSH session without relying on user .bashrc.
echo "[run_remote_ubuntu] preflight (clone + nix reachable) ..."
ssh $SSH_OPTS "$HOST" bash -lc "'
    test -d $REMOTE_DIR || exit 11
    command -v nix >/dev/null 2>&1 || exit 12
'" || {
    rc=$?
    case "$rc" in
        11) die_step "preflight — remote clone $REMOTE_DIR missing (see .dev/ubuntunote_setup.md)" ;;
        12) die_step "preflight — nix not in remote PATH (Determinate Nix install / profile missing)" ;;
        *)  die_step "preflight — ssh exit $rc reaching '$HOST' (host unreachable, key auth, …). NOTE: this local fan-out is OPTIONAL (CI runs the 3-OS gate on every PR); to use your own host, configure scripts/dev_hosts.env (see dev_hosts.env.example)" ;;
    esac
}

# 2. Sync — fetch + reset + echo the landed SHA so logs record
#    what was actually tested. `git fetch` failure (network) vs
#    `reset --hard` failure (concurrent mod) are distinguished
#    by exit code below.
echo "[run_remote_ubuntu] sync $HOST:~/$REMOTE_DIR to origin/$REMOTE_BRANCH ..."
remote_sha="$(ssh $SSH_OPTS "$HOST" bash -lc "'
    cd $REMOTE_DIR || exit 21
    git fetch origin $REMOTE_BRANCH >&2 || exit 22
    git checkout $REMOTE_BRANCH >&2 || exit 23
    git reset --hard origin/$REMOTE_BRANCH >&2 || exit 24
    git rev-parse --short HEAD
'")" || {
    rc=$?
    case "$rc" in
        21) die_step "sync — cd $REMOTE_DIR failed" ;;
        22) die_step "sync — git fetch origin failed (network / auth)" ;;
        23) die_step "sync — git checkout $REMOTE_BRANCH failed" ;;
        24) die_step "sync — git reset --hard origin/$REMOTE_BRANCH failed" ;;
        *)  die_step "sync — ssh exit $rc" ;;
    esac
}
echo "[run_remote_ubuntu] remote HEAD: $remote_sha"

# 3. Build / test / bench. `build` is the implicit (default) step in
#    build.zig — invoking `zig build build` errors, so map it to no
#    step. `bench` is NOT a zig build step: it runs the §12.4 manual
#    bench recorder (record_merge_bench.sh → run_bench.sh hyperfine,
#    pinned via flake.nix) to produce the x86_64-linux row. Extra args
#    after `bench` forward, e.g. `… bench --quick --phase-record` or
#    `… bench --quick --bench=tinygo/arith`; default = full --quick.
# The ZWASM_SPEC_ENGINE passthrough that used to live here is gone: the only
# reader is the wasm-3.0 assert runner, and `test-spec-wasm-3.0-assert` now
# runs both engines with each lane's selector pinned in build.zig. Forwarding
# the variable could no longer change what the remote ran.
case "$STEP" in
    build) REMOTE_CMD="zig build" ;;
    bench) REMOTE_CMD="bash scripts/record_merge_bench.sh ${*:---quick}" ;;
    *)     REMOTE_CMD="zig build $STEP" ;;
esac

# `nix develop --command` pins Zig 0.16.0 + project deps via
# `flake.nix`, guaranteeing bit-identical toolchain with Mac
# and any other host.
echo "[run_remote_ubuntu] $REMOTE_CMD ..."
ssh $SSH_OPTS "$HOST" bash -lc "'
    cd $REMOTE_DIR && nix develop --command bash -c \"$REMOTE_CMD\"
'" || die_step "build — '$REMOTE_CMD' failed on $HOST (HEAD=$remote_sha)"

echo "[run_remote_ubuntu] OK (HEAD=$remote_sha)."
