# §9.13-0 Cat IV — execution plan

> **Doc-state**: ARCHIVED 2026-05-22 — superseded by [`.dev/phase9_close_master.md`](../../phase9_close_master.md). Kept for ADR / ROADMAP citation lineage; do not edit.

> Close-plan-style doc. `.dev/handover.md` Cold-start procedure
> step 1 points here, so the `/continue` skill's Step 1a override
> activates and §6 Work sequence below is the **authoritative
> work source** for the next session.

## §0 Preflight — environment health check (run FIRST)

windowsmini was provisioned 2026-05-22 by
`scripts/windows/install_tools.ps1` (commits `cfbd3b16` /
`711bdcce` sysinternals add). Tool inventory verified:
zig 0.16.0 / hyperfine 1.20.0 / wasm-tools 1.246.1 /
wasmtime 42.0.1 / wabt 1.0.41 (wat2wasm + wast2json) /
yq 4.53.2 / lldb 22.1.6 (LLVM, with Python 3.11 DLL) /
sysinternals 2026-05-22 (Procmon64 / procexp64 / handle64 /
Dbgview / +160 files at `%LOCALAPPDATA%\zwasm-tools\
sysinternals-2026-05-22\`).

### §0.1 Tool inventory check (each resume)

```sh
ssh windowsmini "bash -lc '
for t in zig hyperfine wasm-tools wasmtime wat2wasm wast2json yq lldb handle64 Procmon64; do
  command -v \$t >/dev/null && echo OK \$t || echo MISS \$t
done'"
```

Expected: 10 × `OK` lines (8 original + 2 sysinternals canaries:
handle64 / Procmon64; full Sysinternals bundle has ~70 tools at
the same install path).

### §0.2 If any tool missing: re-run installer

```sh
ssh windowsmini "powershell -NoLogo -NoProfile -ExecutionPolicy Bypass \
    -File %USERPROFILE%\\Documents\\MyProducts\\zwasm_from_scratch\\scripts\\windows\\install_tools.ps1"
```

The PS1 is idempotent — tools already at the pinned version
are skipped. PATH wiring re-applied at the end. After running,
open a new SSH session for PATH to propagate.

`-OnlyTool <name>` (zig / hyperfine / wasm-tools / wasmtime /
wabt / yq / lldb / sysinternals) targets a single tool;
`-Force` reinstalls even if present.

### §0.2.1 Win64 iteration workflow — 4 tiers

The naive cycle (Mac edit → commit gate → push → windowsmini
pull → `test-all`) takes ~9 min. Use the layered loop:

| Layer | Command | Measured time (2026-05-22) | Catches |
|---|---|---|---|
| **L0 (inner)** | `zig build -Dtarget=x86_64-windows-gnu` (Mac, MinGW ABI) | **3.2s** warm | ~90% — Win64 compile errors, exhaustive-switch, inferred-error-set issues, comptime branch mistakes |
| **L1 (mid)** | `tar cf - src/ test/ build.zig \| ssh windowsmini "cd ~/Documents/MyProducts/zwasm_from_scratch && tar xf -"` + `ssh windowsmini "bash -lc 'cd ~/.../zwasm_from_scratch && zig build'"` | **3.9s** sync + ~13s warm build | MSVC ABI compile differences vs MinGW |
| **L2 (outer)** | sync + `ssh windowsmini "...zig build test"` | ~40s warm | Unit test regressions |
| **L3 (final)** | commit → push → windowsmini pull → `zig build test-all` | ~10 min | Full gate, spec runners, edge cases |

**Discipline**:
- Inner loop = L0 (Mac cross-compile). Iterate freely.
- Promote to L1 only when L0 is clean.
- L3 is the **chunk close**, not the iteration tool. Each
  L3 cycle incurs ~25s commit-gate (file_size_check,
  libc_boundary, fallback_patterns, etc.) + ~5s push +
  ~5s windowsmini pull, before the ~8min test-all itself.
  **Do not commit during iteration** — batch into one L3
  at chunk close.

**MSVC vs MinGW ABI gap**: Mac cross-compile uses
`x86_64-windows-gnu` (MinGW); windowsmini native is MSVC.
~90% of compile-time issues are identical (Zig stdlib API
usage, type inference, comptime branches). Differences
surface in runtime ABI (SEH semantics, struct passing
conventions) — these need L2/L3 on windowsmini.

**SSH multiplexing** (active per 2026-05-22 ~/.ssh/config):
```
Host windowsmini
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 10m
```
First `ssh windowsmini` opens a shared socket; subsequent
calls reuse it. Saves ~250ms per call; verify via
`ssh -O check windowsmini`.

**`tar | ssh tar` pattern** (NOT rsync — windowsmini lacks
rsync; tar is stock both sides):
```sh
tar cf - --exclude=.zig-cache --exclude=zig-out --exclude=.git \
    src/ test/ build.zig | \
    ssh windowsmini "cd ~/Documents/MyProducts/zwasm_from_scratch && tar xf -"
```
Use during L1/L2 iteration; **commit to git for L3**.
Full src/ tree resync is ~4s — acceptable for sync-on-every
-iteration. For more frequent edits, narrow the tar tree to
just changed files.

### §0.3 HEAD drift check

```sh
ssh windowsmini "bash -lc 'cd ~/Documents/MyProducts/zwasm_from_scratch && git rev-parse HEAD'"
```

If output differs from `git rev-parse origin/zwasm-from-scratch`:
`scripts/run_remote_windows.sh` does `git fetch + reset --hard`
automatically on each run, so a stale clone self-repairs at
W0. No separate pull needed.

Preflight is a single bash call. **Not a separate cycle**;
runs at the head of the first resume that opens §9.13-0.

## §1 Goal

Close §9.13-0 (Cat IV windowsmini reconcile). Exit per
`.dev/ROADMAP.md` §9.13-0:

- windowsmini `zig build test-all` green incl.
  `spec_assert_runner_non_simd`.
- Bit-identical with Mac aarch64 + ubuntunote x86_64.
- 3 Cat IV debts closed: D-022 / D-028 / D-136 (D-084 already
  closed pre-§9.13-0 at `7a7e387c` 2026-05-12 §9.9-i-1 per
  ADR-0055; original §9.13-0 framing carried it forward as
  "residual" but no residual Win64 v128 marshal failure exists
  per W0 survey post-F1 — see §6 row 5 STRUCK note).

Parallel track: WA (`.dev/decisions/0102_phase9_debt_exit_
reframe.md`) — DRAFT LANDED `4196b385` (Status: Proposed).
ADR-flip Proposed → Accepted is the only user touchpoint.

## §2 Parallel-track model

Two independent tracks; the loop drives both:

| Track | Where | Type | User touchpoint |
|---|---|---|---|
| **WA** — §9.12-F exit ADR draft | main session | `architectural` (ADR draft only; no src/ change) | ADR-flip Proposed → Accepted |
| **W0–W6** — §9.13-0 Cat IV chunks | mostly main; W0+W1 may use background subagent | `survey` then `emit` / `infrastructure` then `architectural` (W3 SEH only) | None for W0–W2 / W4–W6; W3 SEH bridge surfaces shim-design ADR at draft |

Anti-pattern guard: this doc lists pure work descriptors,
ordered.  Surrender framing is forbidden per
`handover_framing.md`.

## §3 Subagent delegation policy (this plan only)

**Delegable (data-collection, no commit authority):**

- **W0** — windowsmini `test-all` foreground run + survey
  note generation. Pure IO + log analysis. Output:
  `private/notes/p9-9.13-0-survey.md` (gitignored).
- **W1** — `run_remote_windows.sh test-all` × 10 + flake-rate
  measurement. Output:
  `private/notes/p9-d028-flake-rate.md` (gitignored).

**Non-delegable (main session only):**

- WA ADR draft (text work that benefits from §18 + framing
  discipline applied in main).
- W2–W6 (code/architectural changes; require diff review +
  ubuntu defer chain per ADR-0076 D2/D3).

**Subagent prompt template** (for the resume cycle that
dispatches W0): see §7 below.

## §4 Hosts + scripts (pre-flight)

- **windowsmini**: `ssh windowsmini` (mDNS). Clone at
  `~/Documents/MyProducts/zwasm_from_scratch`.
- **`scripts/run_remote_windows.sh`**: wrapper. Does
  `git fetch + reset --hard origin/zwasm-from-scratch` on
  windowsmini, then `zig build <step>`. Log to `/tmp/win.log`
  (overwrite).
- **`scripts/should_gate_windows.sh --record`**: phase-boundary
  gate result recorder (run after W4 green).

## §5 Work item details

### W0 — survey (subagent-eligible)

**Status (2026-05-22)**: partial coverage from `zig build
test` smoke run on windowsmini (HEAD `9218f91e`):

- **1744/1775 unit tests passed, 29 skipped, 2 crashed**.
- Both crashes in `spec_assert_runner_base.zig`:
  - `sigsegv guard: handler siglongjmps back to caller frame
    on raised SIGSEGV` (exit 3 = Windows access violation)
  - `sigsegv guard: armed=false after recovery so subsequent
    SEGV is unexpected`
- Both map to **D-136 (Win64 SEH bridge)** — planned W3
  work. No surprises; landscape matches pre-survey hypothesis.
- `zig build test-all` triggered in background; result
  appended to handover at completion (Bash task `bwapumur8`).

**Remaining**: full test-all FAIL enumeration confirms
D-022 / D-028 / D-084 mapping (smoke run covered `test`
only; `test-all` adds `test-spec*`, `test-edge-cases`,
`test-realworld*`, `test-wasmtime-misc-runtime`).

- Command: `bash scripts/run_remote_windows.sh test-all > /tmp/win.log 2>&1`
  (Bash timeout ≥ 1800000 ms; cold build is slow).
- Read log tail (last 400 lines via `tail -n 400 /tmp/win.log`).
- Produce `private/notes/p9-9.13-0-survey.md`:
  - For each FAIL beyond the 2 known D-136 crashes: test
    name, error class, file:line if available, mapping to
    D-022 / D-028 / D-084 (or "NEW — file new debt row").
  - Pass/skip counts pasted as-is.
  - Recommended W1–W6 priority order based on evidence.
- Commit: NONE (gitignored notes). Handover update at chunk
  close per main-session Step 7.

### W1 — D-028 flake rate measurement (subagent-eligible)

- Loop: `for i in 1..10; do bash scripts/run_remote_windows.sh test-all > /tmp/win-$i.log 2>&1; echo "run $i exit=$?"; done`
- Aggregate: count `error: test runner failed to respond` per
  run; record exit codes.
- Produce `private/notes/p9-d028-flake-rate.md`: rate / 10,
  named hypothesis if pattern visible (timing? specific test?
  cold-cache only?).
- Commit: NONE (gitignored notes). If rate is 0 over 10 runs,
  W1 close commit may discharge D-028 with rate-reduction
  rationale + ADR.

### ~~W2 — D-084 Win64 v128 marshal residual~~ STRUCK

D-084 is **not a §9.13-0 task** — already discharged
pre-§9.13-0 at commit `7a7e387c` (2026-05-12) under
§9.9-i-1 per ADR-0055 (Status: Accepted). D-084 is NOT
in active `.dev/debt.md`.

Verification walked 2026-05-22 (this resume):

- `marshalCallArgs` Win64 v128 hidden-pointer path exists
  at `src/engine/codegen/x86_64/op_call.zig:642-664`
  (per-call scratch via `win64V128ScratchBase`; LEA scratch
  addr → int-arg-reg slot or stack overflow).
- `captureCallResult` non-MEMORY-class v128 capture exists
  at `:842-853` (XMM0/XMM1 cap per Win64 §3.2.4 §"≤1 per
  class"; MOVAPS to result vreg).
- `captureCallResult` MEMORY-class v128 returns
  `Error.UnsupportedOp` at `:765` — but MEMORY-class is
  SysV-only (`results.len > 2 and abi.current_cc == .sysv`,
  see `:169`), so the v128 line is unreachable on Win64.
  The SysV MEMORY-class v128 gap is **D-094 territory**
  (active `blocked-by:` row), not D-084.
- W0 survey (`private/notes/p9-9.13-0-survey.md`) at HEAD
  `9218f91e` enumerated **only D-136 SEH crashes** as the
  windowsmini-specific residual; the F1 `entry.zig`
  compile error was the only other gap and closed at
  `0c2474c2`.

The W2 framing was carried forward from the original
§9.9-IV → §9.13-0 relocation (ADR-0049 + ADR-0056 +
ADR-0065 2026-05-18 amends) without re-checking the
discharge log. ROADMAP §9.13-0 items list also carries
D-084 forward; refreshed alongside this amendment.

### W3 — D-136 Win64 SEH bridge

**Architectural-typed**. ADR draft FIRST per
`.claude/rules/architectural_spike.md`:

- `.dev/decisions/NNNN_win64_seh_bridge.md`:
  - Context: `installSigsegvHandler` is no-op on Windows;
    `sigsetjmp` / `siglongjmp` unavailable; assert_trap
    fixtures cause OS-level process kill.
  - Decision: small C/asm shim (`src/runtime/platform/
    windows_seh_bridge.c` or `.zig` via inline asm)
    wrapping `__try` / `__except` blocks; expose
    `seh_arm()` / `seh_disarm()` / `seh_recover()` Zig-
    callable boundary; semantically equivalent to POSIX
    `sigsetjmp` / `siglongjmp` pair.
  - Alternatives: AddVectoredExceptionHandler (rejected:
    process-wide global state); manual SEH frame walking
    (rejected: undocumented frame layout in Zig).
  - Consequences: D-136 close; `spec_assert_runner_non_simd`
    on windowsmini matches Mac/ubuntu behaviour; 3-host
    bit-identical for assert_trap fixtures.
- After ADR Proposed: implement shim → wire to
  `spec_assert_runner` non-simd runner → windowsmini gate.
- Test gate: same as W2. windowsmini verified at W4.
- Exit: D-136 row removed; `spec_assert_runner_non_simd`
  green on windowsmini.

### W4 — cross-module Windows compat verification

- Run windowsmini `test-all` again after W3 lands.
- For any new FAIL not in W0 survey: file as new debt row OR
  fix inline if mechanical (≤ 5 min). D-022 (Win64 cross-
  platform residual) is the umbrella row for fallout here.
- Exit: D-022 closed; windowsmini `test-all` exit 0.

### ~~W5 — Q6 std.posix.* Windows availability~~ STRUCK

W5's actionable work was discharged at §9.12-D / B132
(`b098a688` 2026-05-20) before §9.13-0 opened: `std.c.kill` /
`std.c.pid_t` migrated to `std.posix.*`, and the single
remaining `std.c.getenv` site (`api/instance.zig:213`
`wasm_engine_new`) was reclassified Replaceable → Necessary
in ADR-0070 with the rationale that c_api exports do not
receive `std.process.Init` (no Juicy Main mechanism in
C-ABI-callable code). Verified this resume (2026-05-22):

- `bash scripts/check_libc_boundary.sh --gate` →
  31 necessary, 0 replaceable, 0 unclassified. Exit 0.
- `zig build -Dtarget=x86_64-windows-gnu` → exit 0
  (Mac → Win64-gnu cross-compile clean).

The close-plan W5 framing was carried forward from the
original §9.9-IV → §9.13-0 relocation (ADR-0049 + ADR-0056 +
ADR-0065 2026-05-18 amends) without re-checking the
§9.12-D discharge log. Same pattern as W2 STRUCK.

### W6 — build-option DCE 6 combos × Windows

**Mac-side DONE** (2026-05-22 this resume):

- `bash scripts/check_build_dce.sh --report` → all 6 combos
  green; text bytes monotone (v1_0=1039856 < v2_0=v3_0=1085784);
  forbidden-symbol grep clean. Exit 0.

**Windows-side deferred to W4** (windowsmini reconcile after
W3.b SEH bridge impl lands):

- `ssh windowsmini` `bash scripts/check_build_dce.sh --gate` —
  runs the same 6-combo matrix on Windows native MSVC ABI;
  `nm` / `objdump --syms` confirm excluded ops are absent
  from PE/COFF binaries (per ADR-0073 DCE substrate).
- Exit: 6 combos green AND `check_build_dce.sh` exit 0 on
  windowsmini.

The Mac-side check was originally framed as "Run on
windowsmini"; in practice the matrix builds with
`-Dtarget=x86_64-windows-gnu` cross-compile would catch any
MinGW-vs-MSVC structural divergence at L0. Windows native
MSVC verification stays at W4.

### WA — §9.12-F exit re-framing ADR (parallel, main only)

- File: `.dev/decisions/NNNN_phase9_debt_exit_reframe.md`
  (assign next NNNN per `.dev/decisions/README.md`).
- Status: `Proposed`.
- Context: §9.12-F current exit "debt active rows < 15";
  current count 19; 13 are deferred to Phase 10+ (structural,
  not closable in Phase 9 scope); 4 are §9.13-0 Cat IV
  (covered by W0–W6 above); 2 are trigger-not-fired
  (D-094 / D-062).
- Decision: re-frame exit to "phase-9-eligible debt cohort
  substantially addressed" — defined as:
  (a) all §9.13-0 Cat IV closed (= W0–W6 done);
  (b) trigger-not-fired debts left with `Status: blocked-by:
       <specific external event>` (testable barrier);
  (c) deferred-to-Phase-N debts left with explicit Phase
       target row.
- Alternatives: hold the numeric bar (rejected: forces
  premature Phase 10+ work); drop the criterion (rejected:
  loses Phase-close hygiene).
- ROADMAP §9.12-F amendment text: included in ADR.
- Surface to user at flip time.

## §6 Work sequence (authoritative — `/continue` reads this)

Each row is one autonomous resume cycle (or close to one).
Step 0–7 of `/continue` per-task TDD loop applies. The
subagent-eligible rows note dispatch protocol; non-delegable
rows proceed in main session.

| # | Item | Type | Subagent? | Output |
|---|---|---|---|---|
| 1 | ~~**W0** survey~~ DONE 2026-05-22 | — | — | `private/notes/p9-9.13-0-survey.md` (gitignored) |
| 2 | ~~**WA** ADR draft~~ DONE `4196b385` (Status: Proposed; ADR-flip is the only user touchpoint) | — | — | `.dev/decisions/0102_phase9_debt_exit_reframe.md` Status: Proposed |
| 3 | ~~**F1-fix** `entry.zig` Win64 build~~ DONE `0c2474c2` (`@panic("D-022")` in 3 Class B mixed helpers' else-branch; shared `Error = error{Trap}` preserved; cascade-free) | — | — | windowsmini `zig build` exit 0; test 1744/1775; test-all 37/39 |
| 4 | ~~**W1** D-028 flake measurement~~ PARTIAL (2/10 runs; run 2 wedged > 120 min mid-corpus, killed exit 137). Note at `private/notes/p9-d028-flake-rate.md` (gitignored, 5.7 KB). **New evidence**: failure signature diverges from D-028's "test runner failed to respond for 1m4ms" — observed exit 3 (binary failure) + indefinite hang at runner transition. Suggests Windows resource exhaustion / SSH buffering stall, not IPC timeout. Re-frames D-028's blocked-by barrier. | `survey` | — | `private/notes/p9-d028-flake-rate.md` |
| 5 | ~~**W2** D-084 v128 marshal~~ **STRUCK** — already closed `7a7e387c` (2026-05-12 §9.9-i-1) per ADR-0055 (Accepted); D-084 not in active `.dev/debt.md`; `marshalCallArgs` Win64 v128 hidden-pointer path lives at `op_call.zig:642-664` + `captureCallResult` non-MEMORY-class v128 at `:842-853`; W0 survey post-F1 enumerates only D-136 SEH crashes as residual Win64 failure — no v128 marshal failure present. | — | — | — |
| 6 | ~~**W3.a** SEH bridge ADR draft~~ DONE `8334bc44` (Status: Proposed; **diverges from §5/W3 Option A**: adopts `AddVectoredExceptionHandler` + threadlocal `RecoveryInfo` per v1/Wasmtime/Wasmer precedent, not `__try`/`__except` C shim) | — | — | `.dev/decisions/0103_win64_seh_bridge.md` Status: Proposed |
| 7 | **W3.b-1** SEH shim impl: module + install() wiring | `emit` (post-ADR) | NO | `src/platform/windows_traphandler.zig` (165 LOC; install/uninstall/arm/disarm/RecoveryInfo/vehHandler) + `installSigsegvHandler` Windows arm calls `windows_traphandler.install()`; Mac cross-compile (`-Dtarget=x86_64-windows-gnu`) clean; Mac test-all green; lint clean |
| 7' | ~~**W3.b-2** callJitOrTrap helper + 2 simple callsites~~ PARTIAL `72d8a0e8` (`callJitOrTrap` helper added; 2 production sites + 2 unittest skips wired; spec_assert_runner_non_simd dispatch ladder at `:1498` deferred to W3.b-2b) | `emit` | NO | helper + 2/3 production sites; Mac cross-compile + test-all + lint clean |
| 7'' | ~~**W3.b-2b** dispatch-ladder callsite~~ DONE `af4eff55` (assert_trap dispatch ladder refactored to local `Dispatch` struct; Win64 routes via `callJitOrTrap`; POSIX path unchanged; Mac cross-compile + test-all + lint clean) | `emit` | NO | 124 ins / 121 del refactor; closes the last sigsetjmp callsite on Windows arm |
| 8 | **W4** windowsmini reconcile run (final post-W3 verification) | verification | NO | `bash scripts/run_remote_windows.sh test-all` exit 0; D-022 / D-136 / D-028 all closed (D-084 already closed pre-§9.13-0) |
| 9 | ~~**W5** posix.* Windows availability~~ DONE (autonomous: `check_libc_boundary --gate` reports 0 replaceable + 0 unclassified; ADR-0070 amended `b098a688` 2026-05-20 §9.12-D / B132 reclassified `std.c.getenv` in `wasm_engine_new` Replaceable → Necessary; `zig build -Dtarget=x86_64-windows-gnu` exit 0). Original framing assumed open replaceable sites; the §9.12-D sweep already discharged. | — | — | gate exit 0; Win64 cross-compile exit 0 |
| 10 | **W6** build-option DCE × Windows — Mac-side DONE (`check_build_dce.sh --report`: 6/6 combos green; text bytes monotone v1_0 < v2_0 == v3_0; forbidden-symbol grep clean). Windows-side `nm`/`objdump` symbol verification gated on W4 reconcile (post-W3.b). | verification | NO | Mac: 6 combos green; windowsmini: deferred to W4 |
| 11 | §9.13-0 close + Phase 9 boundary | phase-boundary | NO | §9.13-0 [x]; `should_gate_windows.sh --record`; §9.12-I batch ADR Status flip; SHA backfill |

## §7 Subagent prompt template — W0 / W1 dispatch

The resume cycle that dispatches W0 uses this brief
verbatim (Agent tool, `subagent_type: Explore`, with
`run_in_background: true`):

```
zwasm v2 project (~/Documents/MyProducts/zwasm_from_scratch/).
Run windowsmini test-all and produce a survey note.

1. Foreground bash:
   bash scripts/run_remote_windows.sh test-all > /tmp/win.log 2>&1
   (Bash timeout 1200000 ms; cold build is slow)
2. Check exit code from /tmp/win.log tail. Read last 400 lines.
3. Produce private/notes/p9-9.13-0-survey.md (markdown):
   - Test run metadata: HEAD sha, host, exit code, pass/fail/skip counts
   - Per-FAIL: test name, error class, file:line if available,
     mapping to one of D-022/D-028/D-084/D-136 (or "NEW")
   - Recommended W1-W6 priority order from evidence
4. DO NOT commit. Notes are gitignored; main session
   captures the artifact reference at next resume.
5. Return a 200-word summary of what was found.

Constraints:
- No source code changes.
- No git commits or pushes.
- Single bash invocation for the test run.
- If windowsmini SSH fails, return with that as the result;
  do not retry beyond once.
```

W1 dispatch uses the same shape with the loop `for i in
1..10; do ...; done` instead of single run, output to
`private/notes/p9-d028-flake-rate.md`.

## §8 Termination criteria

This plan closes when:

- All §6 rows 1–10 complete.
- §9.13-0 row in ROADMAP is `[x]`.
- handover.md retargets to §9.13 (Phase 10 entry hard gate;
  user touchpoint per `/continue` hard-gate detection).

At that point, this file is **archived** (delete or move to
`.dev/archive/` per `.claude/rules/lessons_vs_adr.md`'s
demotion path — this is a plan-doc, not an ADR, so deletion
is the canonical close).

## §9 Subagent monitoring across resumes

Background subagents launched in one resume cycle may
complete in a later one (notification arrives mid-Step). The
main session's next resume:

- Checks `.task-notification` / `BashOutput` arrivals via
  the standard task-tool flow.
- If W0 / W1 subagent has completed → read its output file
  reference + the produced `private/notes/p9-*.md` →
  proceed to row 4 (W2) per §6.
- If W0 still running → fire WA ADR draft (row 2) instead,
  re-arm at end. Both tracks make progress.
- If W0 errored (windowsmini unreachable, etc.) →
  `extended_challenge.md` 3-step procedure on the surfaced
  error.

This avoids the failure mode where main session blocks on
subagent completion or polls — the resume cycle simply
picks whichever row in §6 is unblocked next.

## §10 References

- `.dev/handover.md` — Cold-start pointer.
- `.dev/ROADMAP.md` §9.13-0 (line ~1316) — exit criterion.
- `.dev/debt.md` — D-022, D-028, D-084, D-136 rows.
- `.dev/decisions/0049_*.md` — windowsmini gate deferral.
- `.dev/decisions/0067_*.md` — ubuntunote-x86_64 pivot
  (Rosetta race; informs Win64 expectations).
- `.dev/decisions/0076_*.md` — single-push commit pair;
  ubuntu defer chain.
- `.claude/rules/architectural_spike.md` — W3 ADR-first.
- `.claude/rules/handover_framing.md` — framing discipline.
- `.claude/skills/continue/SKILL.md` Step 1a — close-plan
  override mechanic.
