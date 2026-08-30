# JIT / runtime debug toolkit — recipes catalogue

> Sibling of [`SKILL.md`](SKILL.md); contains the copy-paste-ready
> recipe bodies (1-17) + the SA_SIGINFO fault-address poison-pattern
> cheatsheet. `SKILL.md` keeps the procedure shell (tool inventory,
> decision tree, lessons, edit-this-file meta) so the on-demand load
> stays under the 500-line skill-readability threshold.
>
> Every recipe is copy-paste-ready: swap in the binary / argv / manifest,
> capture stderr/stdout to `/tmp/`,
> grep for the signature. No human-in-loop debugger steering needed.

## Autonomous recipe 1 — `lldb -b` first triage

For "where exactly does the SEGV happen" — fastest path:

```bash
lldb -b \
  -o "settings set target.x86-disassembly-flavor intel" \
  -o "process launch -- <argv>" \
  -o "register read" \
  -o "disassemble --pc --count 20" \
  -o "memory read --size 1 --count 256 \$pc" \
  -o "thread backtrace" \
  -o "quit" \
  ./path/to/binary 2>&1 | tee /tmp/lldb-segv.log
```

**Key flags**:
- `-b` = batch mode (auto-quit when commands finish)
- `-o "cmd"` = lldb command to execute in order
- `process launch -- <argv>` = pass argv to the process
- After SEGV, `register read` + `disassemble --pc` show the faulting site

**Reading the output**:
- `RIP` (x86_64) / `PC` (arm64) = faulting instruction address
- Subtract from `block.bytes.ptr` (printed by emit-pass diag) →
  byte offset within the JIT block
- Use `objdump -d -b binary -m i386:x86-64 -M intel` (or
  `ndisasm -b 64 -o <base>`) to disasm that byte range from the
  hex dump

## Autonomous recipe 2 — `ndisasm` for raw JIT byte stream

When the spike has dumped JIT block hex and we need to know
"what x86_64 instructions does this byte sequence decode to":

```bash
# Hex dump from spike code: write block.bytes to /tmp/jit.bin
ndisasm -b 64 /tmp/jit.bin | head -40
# Or with arbitrary base address (matches lldb's $pc display):
ndisasm -b 64 -o 0x1000 /tmp/jit.bin

# objdump alternative:
objdump -D -b binary -m i386:x86-64 -M intel /tmp/jit.bin | head -40
```

Both work; `ndisasm` is a single line of output per insn (easier
to grep). `objdump` matches lldb's display style.

## Autonomous recipe 3 — `strace` for mmap / mprotect inspection

When suspecting JIT block protection (e.g. RWX → RX transition
not happening, or `PROT_EXEC` not applied):

```bash
# ubuntunote only (Mac uses dtruss):
ssh ubuntunote 'cd ~/Documents/MyProducts/zwasm &&
    strace -f -e trace=mmap,mprotect,munmap \
        ./<binary> 2>&1' | grep -E "^mmap|^mprotect" | tail -20
```

Look for:
- `mmap(NULL, size, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0)`
- `mprotect(addr, size, PROT_READ|PROT_EXEC)` — JIT block flip
- A `mprotect` with `PROT_EXEC = 4` flag is the executable transition

Mac equivalent (root-required):
```bash
sudo dtruss -f -t mprotect ./binary 2>&1 | tail -20
```

## Autonomous recipe 4 — SIGSEGV handler (no debugger)

When neither lldb nor gdb is available (or the segfault happens
before main reaches a debuggable state), install a Zig signal
handler in the spike code:

```zig
// In private/spikes/jit_segv/main.zig
const std = @import("std");

fn segvHandler(sig: c_int, info: *const std.posix.siginfo_t, ctx: ?*const anyopaque) callconv(.c) noreturn {
    _ = sig;
    _ = ctx;
    const fault_addr = info.fields.sigfault.addr;
    std.debug.print("\nSEGV at fault_addr={*} (siginfo)\n", .{fault_addr});
    // Print extracted RIP from the ucontext (platform-specific)
    // ... (see std.os.linux.ucontext for layout)
    std.process.exit(139);
}

pub fn main() !void {
    var act: std.posix.Sigaction = .{
        .handler = .{ .sigaction = &segvHandler },
        .mask = std.posix.empty_sigset,
        .flags = std.posix.SA.SIGINFO,
    };
    try std.posix.sigaction(std.posix.SIG.SEGV, &act, null);

    // ... reproduce the SEGV here ...
}
```

This buys the autonomous loop fault-address visibility WITHOUT
shelling out to a debugger. `siginfo_t.fields.sigfault.addr` is
the faulting memory address; the exact offset within the JIT
block is `(fault_addr - block.bytes.ptr)`.

## Autonomous recipe 5 — `private/spikes/jit_segv/` skeleton

When the realworld_run_jit runner segfaults but it's hard to
isolate which fixture / which op, build a minimal in-process
spike:

```
private/spikes/jit_segv/
├── README.md            ← what we're testing + findings
├── minimal.wasm.hex     ← hand-crafted 1-function wasm bytes
├── main.zig             ← compileWasm + dump bytes + invoke
└── build.zig            ← Zig build harness (maybe `zig build-exe`)
```

`extended_challenge.md` Step 4 grants spikes ≤ 1 day; outcomes
land as ADR (if rejected) / lesson (if observational) /
production code (if the fix). The `private/spikes/` directory
is gitignored — only the lessons / ADRs persist.

## Recipe 6 — bisection by Wasm op

Hand-craft a series of progressively-larger wasm modules to
binary-search the SEGV-triggering op family:

1. `(func)` — empty
2. `(func) (i32.const 0) (drop)` — i32.const + drop
3. `(func) (i32.const 0) (i32.const 0) (i32.add) (drop)` — i32.add
4. `(func (param i32)) (local.get 0) (drop)` — local.get
5. ... continue until SEGV reproduces.

Each step → compile → invoke → check exit code. The op family
that flips from "exit 0" to "SIGSEGV" is the regression source.
Bisection cost: log₂(N) compiles to localise to ≤ 1 op family.

## Recipe 7 — crash-time JIT context dump (async-signal-safe)

When a SEGV reproduces inside the JIT body and you want fault
context (faulting address, surrounding bytes, RIP) WITHOUT a
debugger attached, install a `SA.SIGINFO` handler that writes
raw bytes via async-signal-safe primitives only. Reference
implementation: `test/spec/spec_assert_runner_base.zig`
(`sigsegvHandler` + `installSigsegvHandler`). The pattern:

```zig
const std = @import("std");

fn handler(sig: c_int, info: *const std.posix.siginfo_t, _: ?*const anyopaque) callconv(.c) noreturn {
    _ = sig;
    // siginfo.fields.sigfault.addr is the faulting address.
    // Async-signal-safe: only raw writes; no allocator, no
    // formatted std.debug.print (which acquires a mutex).
    const fault_addr = @intFromPtr(info.fields.sigfault.addr);
    var buf: [128]u8 = undefined;
    const n = std.fmt.bufPrint(&buf, "SEGV at 0x{x}\n", .{fault_addr}) catch buf[0..0];
    _ = std.posix.write(std.posix.STDERR_FILENO, n) catch {};
    std.c._exit(142);  // 142 distinct from 139 to disambiguate
                       // "our handler ran" vs "kernel killed us".
}

// In main, before invoking the JIT:
const SS = 1 << 18;  // 256 KB altstack — required for stack-
                     // exhaustion SEGV cases (assert_exhaustion).
var stack: [SS]u8 align(std.heap.page_size_max) = undefined;
std.posix.sigaltstack(&.{ .sp = &stack, .flags = 0, .size = SS }, null) catch {};
var act: std.posix.Sigaction = .{
    .handler = .{ .sigaction = &handler },
    .mask = std.posix.sigemptyset(),
    .flags = std.posix.SA.ONSTACK | std.posix.SA.SIGINFO,
};
std.posix.sigaction(.SEGV, &act, null);
// Optionally also SIGBUS for Mach-side mis-aligned access:
std.posix.sigaction(.BUS, &act, null);
```

**Don't do** in a signal handler:
- `std.debug.print` (acquires a mutex, deadlocks if interrupted
  thread held it).
- Allocator calls (likewise re-entrant).
- `std.fs` / `std.Io` non-raw paths.
- Any libc function not in the POSIX async-signal-safe list
  (`man 7 signal-safety`).

**Do**:
- `std.posix.write` to a fixed-size stack buffer.
- `std.c._exit` (not `exit` — atexit handlers may not be
  async-signal-safe).
- `siglongjmp` to a previously-set `sigsetjmp` recovery point
  (use only when the saved frame is provably alive).

**Exit-code disambiguation** (d-71 lesson): pick an exit code
DIFFERENT from `139` (= 128 + SIGSEGV, the kernel's default
exit code when no handler installed). Otherwise a
`zig build` report of "exited with code 139" is ambiguous
between "your handler ran and chose 139" and "the kernel
killed the process before your handler installed". The
spec_assert runner uses `142` for this reason.

**When to factor out**: while only one site uses this pattern
today, the second site (e.g. a JIT-execution sentinel runner
for cross-host differential diagnosis per ADR-0034) should
extract a `src/diagnostic/jit_dump.zig` module rather than
duplicate. Until then, copy the pattern from spec_assert and
adapt the recovery target.

## Recipe 8 — fault-address poison-pattern decoding (FIRST step on every SEGV)

Per D-142 cycle 6 (2026-05-17): **the very first action on any
SEGV is to capture the fault address from `siginfo_t.addr`
via SA_SIGINFO and decode its pattern**. The pattern usually
identifies the bug class in seconds, narrowing which recipe
above to invoke next.

The infrastructure is already in place at
`test/spec/spec_assert_runner_base.zig::sigsegvHandler`
(SA_SIGINFO upgrade landed in commit `dd0cd332`); the
unarmed-branch trace emits
`(handler-entry=N last-armed=M fault-addr=0xNNNN...)`
automatically. For new SEGV-prone code paths, install the same
sa_sigaction + `siginfo.addr` emission pattern.

### Pattern cheatsheet

| Fault address pattern | Likely cause | Decode example |
|---|---|---|
| `0xAA...AA` ± small offset | Zig `undefined` poison (Debug only) — uninitialised memory dereferenced. The low byte reveals the offset from the poison base: `0xB2 = 0xAA + 8`, `0xCC = 0xAA + 0x22`, etc. | `0xaaaaaaaaaaaaaab2` ⇒ uninit pointer deref at `+8`. Trace back: which field is at offset 8 of an extern struct that was constructed with `.foo = undefined`? See `.claude/rules/zig_tips.md` `undefined in extern struct` entry. |
| `0xCC...CC` ± small offset | x86 INT3 / Zig safety-stub remnant. Often inside a freed or de-init'd region. | grep for `@memset(buf, 0xCC)` or look for use-after-free. |
| `0xDEADBEEF` / `0xDEAD_DEAD` | Sentinel value. Check `linker.IMPORT_SENTINEL_OFFSET` (`0xFFFF_FFFF`), `@ptrFromInt(0xDEADBEEF)` patterns. | grep `0xDEAD` / `IMPORT_SENTINEL`. |
| `0xFFFF_FFFF` / `0xFFFF_FFFF_FFFF_FFFF` | sentinel "no value"; for slices, `len = maxInt(u32)` etc. | check the slice's len/cap fields. |
| Near current SP (within 8 KB of `mov sp, sp`) | Stack-guard hit (stack overflow). | compare against pthread stack info via `pthread_attr_getstack`; check for deep recursion. |
| Mac aarch64 `0x1xx_xxxxxx` | `.text` or MAP_JIT region. Cross-check `otool -tv <binary>` (Recipe 1 / 2). | likely a code-address fault (bad function pointer load or RX page that wasn't mapped X). |
| Linux x86_64 `0x40_xxxx_xxxx` / `0x55_xxxx_xxxx` | `.text` or MAP_JIT region. | `/proc/self/maps` cross-check. |
| `0x0` or low (< 0x1000) | NULL deref. | trivially `*null`; check optional unwrap sites. |
| Large random-looking address (e.g. `0x7fff_xxxx_xxxx`) | Likely valid stack / heap area but wrong contents. | use Recipe 1 to capture register state + check pointer provenance. |

### Why first-step

Without the fault address, every SEGV investigation starts by
guessing the bug class from the symptom. The address narrows
the search **before** committing to a specific recipe. D-142
spent 5 cycles rejecting hypotheses (PAC, siglongjmp re-entry,
altstack, layout, MAP_JIT-flip) before the fault-address
emission landed; cycle 6 identified the poison pattern in
under a minute.

### When the pattern doesn't match the cheatsheet

Capture the address anyway and add a row to this table in
the same commit that closes the bug. The cheatsheet's
value is cumulative.

## Windows recipes (windowsmini-specific, added 2026-05-22)

The POSIX-signal-model recipes (1, 4, 7) DON'T apply cleanly on
Win64 — Windows uses Vectored Exception Handling (VEH) +
Structured Exception Handling (SEH) instead of `sigaction` /
`sigsetjmp`. Until D-136 / W3.b lands the VEH bridge (per
ADR-0103), Windows-side trap recovery is **not present** — any
SEGV / OOB / illegal-instruction in JIT code terminates the
process outright. These recipes work around that.

Common SSH invocation pattern for all Windows recipes:

```bash
# From Mac: drop into windowsmini's PowerShell or Git-Bash
ssh windowsmini "powershell -NoLogo -NoProfile -Command \"<cmd>\""
ssh windowsmini "bash -lc '<cmd>'"
```

### Recipe 9 — `lldb -b` first triage on windowsmini (SSH)

Mirror of Recipe 1, adapted for Win64 PE/COFF:

```bash
ssh windowsmini "bash -lc '
  cd ~/Documents/MyProducts/zwasm
  lldb -b \
    -o \"settings set target.x86-disassembly-flavor intel\" \
    -o \"process launch -- <argv>\" \
    -o \"register read\" \
    -o \"disassemble --pc --count 20\" \
    -o \"memory read --size 1 --count 256 \\\$pc\" \
    -o \"thread backtrace\" \
    -o \"quit\" \
    ./zig-out/bin/<exe>.exe 2>&1
'"
```

**Differences from POSIX**:
- Register names: `RIP` / `RSP` / `RBP` same as Linux x86_64
- Symbol resolution uses PE/COFF + .pdb (Zig emits both for
  debug builds); lldb auto-discovers .pdb files next to .exe
- `EXCEPTION_ACCESS_VIOLATION` is the Win64 equivalent of
  SIGSEGV — lldb on Windows prints "stop reason = Exception
  Access violation".

### Recipe 10 — `Procmon64.exe` for process spawn / file access trace (D-028 primary)

Procmon captures every file / process / registry / network
event with timestamp. Killer tool for D-028 wedge: see exactly
which child-process spawn hangs and what files are being
scanned at that moment.

```bash
# Manual interactive (from windowsmini desktop):
#   1. Procmon64.exe → start capture
#   2. Filter: Process Name contains "zwasm" OR contains "zig"
#   3. Run: zig build test-all in another shell
#   4. After wedge: File → Save → CSV or PML
#   5. Look for: Process Create events + the millisecond gap
#      before/after suspect runner transition (wast_runner exit →
#      spec_assert_runner start)

# Headless (SSH-driven) capture via /BackingFile + /Quiet:
ssh windowsmini "powershell -NoLogo -NoProfile -Command \"
  Start-Process -FilePath 'C:\Users\shota\AppData\Local\zwasm-tools\sysinternals-2026-05-22\Procmon64.exe' \
    -ArgumentList '/Quiet','/Minimized','/BackingFile','C:\Users\shota\procmon-trace.pml','/AcceptEula'
\""
# Run test-all in another SSH session
# Then:
ssh windowsmini "powershell -NoLogo -NoProfile -Command \"
  & 'C:\Users\shota\AppData\Local\zwasm-tools\sysinternals-2026-05-22\Procmon64.exe' /Terminate
\""
# Then SCP procmon-trace.pml back to Mac and open with Procmon GUI
# (Procmon native PML format is not text-readable; export to CSV via GUI for grep)
```

**What to look for in the trace** (D-028 wedge specifically):
- Long gaps (>10 s) between `Process Create` for one runner
  and its first `File Read` event → image scan delay
- `CreateFile` events on `.exe` files from `MsMpEng.exe`
  (Defender process) interleaved with zwasm process spawn →
  confirms Defender hypothesis (#5 in D-028)
- Sudden burst of handle / file events at runner transition →
  hypothesis #3 evidence

### Recipe 11 — `handle64.exe` for fd / handle count (D-028 #3 probe)

D-028 hypothesis #3 says "fd-table fullness at runner
transition". Test directly:

```bash
# Snapshot of all open handles for a specific process:
ssh windowsmini "powershell -NoLogo -NoProfile -Command \"
  & 'C:\Users\shota\AppData\Local\zwasm-tools\sysinternals-2026-05-22\handle64.exe' \
    -p zwasm-spec-runner.exe -accepteula
\""

# Per-process count (rough):
ssh windowsmini "powershell -NoLogo -NoProfile -Command \"
  & 'C:\Users\shota\AppData\Local\zwasm-tools\sysinternals-2026-05-22\handle64.exe' \
    -p zwasm-spec-runner.exe -accepteula 2>\\\$null | Measure-Object -Line
\""

# All processes with high handle count:
ssh windowsmini "powershell -NoLogo -NoProfile -Command \"
  Get-Process | Sort-Object -Property HandleCount -Descending | Select-Object -First 10 Name, HandleCount, Id
\""
```

**Expected baseline**: zwasm test runners typically hold
50-200 handles. If a wedged process shows >5000 handles,
hypothesis #3 is confirmed.

### Recipe 12 — `llvm-objdump` PE/COFF JIT byte disasm

Mirror of Recipe 2, adapted for Win64. Since the JIT-emitted
bytes are NOT in a PE/COFF file (they live at mmap'd memory),
the same `--disassemble -b binary` form works:

```bash
ssh windowsmini "bash -lc '
  # Hex dump from spike code: write block.bytes to /tmp/jit.bin (via lldb memory write -outfile)
  llvm-objdump --disassemble -b binary -m x86_64 --x86-asm-syntax=intel /tmp/jit.bin
'"

# To inspect an actual PE/COFF binary (test exe symbols, sections):
ssh windowsmini "bash -lc '
  llvm-readobj --headers --sections --symbols ./zig-out/bin/zwasm-spec-runner.exe
'"

# To dump only the .text section disasm:
ssh windowsmini "bash -lc '
  llvm-objdump --disassemble --section=.text ./zig-out/bin/zwasm-spec-runner.exe | head -200
'"
```

### Recipe 13 — `Dbgview.exe` + `OutputDebugStringA` for VEH handler verification (W3.b post-land)

**Placeholder until W3.b SEH bridge implementation lands.**

When `src/platform/windows_traphandler.zig` is implemented per
ADR-0103, instrument the `vehHandler` entry point with
`OutputDebugStringA("[veh] hit RIP=...")` calls. Capture with:

```bash
# Manual: launch Dbgview.exe on windowsmini desktop, "Capture Win32" + "Capture Events"
# Then run the test that triggers VEH

# Programmatic launch:
ssh windowsmini "powershell -NoLogo -NoProfile -Command \"
  Start-Process -FilePath 'C:\Users\shota\AppData\Local\zwasm-tools\sysinternals-2026-05-22\Dbgview.exe' \
    -ArgumentList '/g','/t','/k','/l','C:\Users\shota\veh-trace.log'
\""
```

`OutputDebugStringA` is the most reliable async-signal-safe-ish
escape hatch on Windows for VEH handler observation; printf is
not safe in VEH context (loader lock, etc.).

### Recipe 14 — Crash dump (WER `.dmp`) post-mortem with lldb

When a Win64 test crashes outright (no recovery, process kill),
Windows Error Reporting auto-drops a `.dmp` file to
`%LOCALAPPDATA%\CrashDumps\` (path is in ExclusionPath per
2026-05-22 setup). lldb on Windows can read these:

```bash
ssh windowsmini "bash -lc '
  ls -la ~/AppData/Local/CrashDumps/
  lldb -c ~/AppData/Local/CrashDumps/zwasm-spec-runner.exe.<pid>.dmp \
    -o \"thread backtrace all\" \
    -o \"register read\" \
    -o \"quit\"
'"
```

**Enabling WER dump collection** (one-time, requires admin —
or PowerShell ssh if user has admin):

```powershell
# Set per-app dump config for zwasm runners (DumpType 2 = full mini-dump):
$reg = "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps"
New-Item -Path "$reg\zwasm-spec-runner.exe" -Force
Set-ItemProperty -Path "$reg\zwasm-spec-runner.exe" -Name DumpType -Value 2
Set-ItemProperty -Path "$reg\zwasm-spec-runner.exe" -Name DumpFolder -Value 'C:\Users\shota\AppData\Local\CrashDumps'
Set-ItemProperty -Path "$reg\zwasm-spec-runner.exe" -Name DumpCount -Value 10
```

(Not yet applied on windowsmini as of 2026-05-22 — add when
first Win64 crash needs post-mortem analysis.)

### Recipe 15 — `ssh windowsmini cmd /c '...'` stable orchestration (HANG / interactive debug)

Codifies the 8-trap learning from D-165 cycle 9
(`.dev/lessons/2026-05-23-windowsmini-ssh-quoting-traps.md`).
The default OpenSSH shell on windowsmini is PowerShell 7;
nesting `bash -lc` re-enters Git-Bash with MSYS path
conversion. Both layers introduce quoting traps that bite
hard at exactly the wrong moment (during root-cause hunts).

**Stable form** — bypasses PowerShell + Git-Bash + MSYS:

```bash
ssh windowsmini cmd /c "<windows-cmd-with-windows-paths>"
```

Inside the double-quoted string, `cmd /c` interprets
Windows-native switches (`/F`, `/FI`, `/T`, `/NOBREAK`, etc.)
without path conversion. Chain commands with cmd `&&`:

```bash
ssh windowsmini 'cmd /c "cd /d C:\Users\shota\Documents\MyProducts\zwasm && git fetch origin main && git reset --hard origin/main && zig build install"'
```

Note: `cd /d <path>` forces drive change too — required when
the SSH-default shell starts on a different drive.

**8 specific traps + fixes** (see lesson file for full
detail):

1. PowerShell parses bash `$var` → use `bash -lc "'...'"` OR `cmd /c '...'`.
2. PowerShell parses `(...)` / `foreach($p in ...)` → `cmd /c` or `.ps1` file.
3. MSYS path-converts `/F` `/FI` args → `cmd /c` bypass (preferred).
4. `tasklist /FI` filter quoting → `cmd /c 'tasklist /FI "..." /NH /FO CSV'`.
5. Cygwin PID ≠ Win-native PID → re-fetch via tasklist.
6. SSH background `&` doesn't auto-detach → `< /dev/null` + redirect logs.
7. tasklist header row → `/NH /FO CSV`.
8. lldb attach works without admin — verified.

**Log file locations**:
- `%USERPROFILE%\d165-win.log` is a friendly Windows path.
- `C:\tmp\` does NOT exist by default (don't write there).
- For pulling back to Mac: `scp -q windowsmini:d165-win.log /tmp/d165-win.log`.

### Recipe 16 — JIT bytes dump via runner instrumentation (HANG-friendly, no debugger)

When you suspect a JIT-emitted body has bad bytes (and the
runtime hangs / corrupts / loops infinitely so `lldb -b -o
"process launch"` can't reach the bug site without manual
interrupt), instrument the runner to dump the bytes BEFORE
execution. Pre-execution dump bypasses the hang.

**CODIFIED 2026-06-15 (`db3109d8`)** — permanent, env-gated, in
`src/engine/compile.zig` (the per-func link loop). No more ad-hoc
re-introduction:

```sh
ZWASM_DEBUG=jit.dump zig-out/bin/zwasm run --engine jit <file.wasm> 2> /tmp/dump.log
# each line: [jit.dump] func=<wasm_idx> len=<L> hex=<machine bytes>
```

Gated by `dbg.on("jit.dump")` (Zone-0 whitelist plumbed from Zone 3;
release-stripped, zero cost when unset). Bytes are body-relative
(pre-link → call/branch targets not yet fixed up).

Disassemble (arm64). **NOTE: llvm-21's `llvm-objdump` dropped GNU
`-b binary`, and Apple's `/usr/bin/objdump` rejects `-b` too. Use
`llvm-mc --disassemble`:**

```bash
HEX=$(grep -oE "func=4 .* hex=[0-9a-f]+" /tmp/dump.log | sed -E 's/.*hex=//')
echo "$HEX" | sed -E 's/(..)/0x\1 /g' \
  | /nix/store/*llvm-21*/bin/llvm-mc --disassemble --triple=aarch64 > /tmp/func4.asm
# x86_64: --triple=x86_64  (add --output-asm-variant=1 for Intel syntax)
```

Map an asm line back to a runtime address for an lldb value-trace:
`code_map.zig` Entry carries the func's `start_addr`; the i-th asm
line (1-based) is at `start_addr + (i-1)*4` on arm64. First use:
D-330 c_sha256 `\n` residual (func 4 putc/`__overflow` region).

Win64 legacy variant — dump to file, scp back to Mac:

```bash
ssh windowsmini 'cmd /c "cd /d <repo> && set ZWASM_DEBUG=jit.dump&& start /B zig-out\bin\zwasm.exe run --engine jit <file.wasm> > %USERPROFILE%\dump.log 2>&1"'
scp -q windowsmini:dump.log /tmp/dump.log
```

The original D-165 use (ad-hoc `if(true)` in the spec runner, now
superseded by the env gate) dumped fac-ssa's 390-byte body on the
critical path to the pick0/pick1 MEMORY-class + cap=1 bugs.

### Recipe 17 — manifest-bisect via `test/private/d-165/` scratch dir

To isolate which directive triggers a JIT-runtime bug:

1. `cp test/spec/wasm-2.0-assert/<feature>/fac.0.wasm
   test/private/d-165/fac/` — copies the upstream wasm.
2. Write a custom `test/private/d-165/fac/manifest.txt` with
   progressively-narrowed directives.
3. Run `zig-out/bin/zwasm-spec-wasm-2-0-assert test/private/d-165`.
4. Iterate: bisect by adding/removing directives until you
   isolate the minimal trigger (Recipe 17a — 1 cycle ≈ 5-15
   seconds round-trip via scp + cmd /c).

`test/private/` is gitignored — no commit pressure for the
scratch fixture. Reverts to base state by `rm -rf test/private/d-165/fac/*; cp ... fac.0.wasm fac/`.

`installArtifact(non_simd_assert_runner_exe)` in `build.zig`
ensures `zig-out/bin/<runner>` is the stable canonical path
(landed cycle 9 / `12fb9e4f`). Without this you'd hunt for
the latest `.zig-cache/o/HASH/<runner>.exe` per build.

### Recipe 18 — lldb VALUE-trace inside JIT code (`scripts/jit_value_trace.sh`)

For a miscompile that produces WRONG OUTPUT but does NOT crash (the
crash recipes 1/4/7 don't apply). JIT bodies have no symbols and live
in runtime-mmap'd W^X pages, so a raw-address bp set before `run` is
resolved but NEVER inserted. The harness automates the fix; full
rationale in lesson `2026-06-15-lldb-value-trace-on-jit-code`.

```bash
# 1. find the suspect instruction
bash scripts/jit_value_trace.sh disasm <file.wasm> <func_idx>   # → /tmp/jit_func<idx>.asm
#    (asm line N is at byte offset (N-1)*4 on arm64)

# 2. value-trace it (post_cmds_file = lldb -o commands, one per line)
printf 'register read x28 x16\nthread step-inst\nregister read w14\n' > /tmp/post.lldb
bash scripts/jit_value_trace.sh trace <file.wasm> <func_idx> <asm_line> fdWrite /tmp/post.lldb
```

Key facts the harness encodes (so you don't re-pay the ~9-attempt cost):
- `settings set target.disable-aslr true` → JIT addresses stable across runs.
- Arm the JIT-address bp ONLY after the page maps: stop first at a host
  symbol (`fdWrite` default — the WASI write, always hit on output), then
  `br set -H -a <addr>`. **`-H` (hardware) bp is REQUIRED** (W^X JIT pages
  can't take a software BRK patch). VALIDATED to fire (func 11 entry).
- WASI guest→host: JIT guest → `jit_dispatch.fd_write` (Zig; `rt.vm_base`
  = guest mem base) → `fdWrite`. Break PAST the prologue (a body line, not
  the function entry) for Zig locals to resolve.
- **Buffering gotcha**: piped/redirected stdout = musl FULL buffering →
  the stream flushes ONCE at exit, so the first `fdWrite` is AFTER all
  `putc`. To trace `putc`-path guest code, stop EARLIER than `fdWrite`.

### Recipe 19 — attribute a spec-lane fail BEFORE reading any codegen

The `spec_assert_runner_*` detail lines print the **func name only** —
`JITfail [gc/type-subtyping] run err=Trap`. Corpora where every module
exports `run` (all the `gc/*` sub-corpora) therefore do not tell you which
module failed, and eyeballing the manifest for the "interesting-looking"
directive is how D-590 spent a cycle inside `invokeMulti` for a
`table.get` bug. Cost of doing it properly: ~2 minutes.

```bash
S=private/spikes/<slug>                       # gitignored scratch
mkdir -p $S/corpus/{gc,memory64,tail-call,exception-handling,function-references,multi-memory}
cp -r test/spec/wasm-3.0-assert/gc/<sub-corpus> $S/corpus/gc/   # COPY, not symlink — the
                                                                # walk is `if (entry.kind
                                                                # != .directory) continue`
                                                                # (runner :513), and a
                                                                # symlink is .sym_link, so
                                                                # you get `manifests=0`
cp $S/corpus/gc/<sub-corpus>/manifest.txt $S/manifest.full.txt  # keep a pristine copy
zig build --prefix $S/out                                       # runner binary
```

Then drive the runner on the one-manifest corpus and shrink the manifest.
The empty sibling proposal dirs only exist to silence `PROPOSAL-DIR-FAIL`;
`manifest_errors` there does not affect the JIT tallies.

```bash
ZWASM_SPEC_ENGINE=jit ZWASM_SPEC_DETAIL=1 $S/out/bin/zwasm-spec-wasm-3-0-assert $S/corpus
```

**If the runner dies instead of tallying** (`exit 70`, one
`caught a fatal signal` line, no per-proposal rows): stdout is flushed at
exit, so a crash destroys the entire run's output, including every proposal
that already finished. You get no attribution at all — not even "which
proposal". Split first, then bisect:

```bash
# one real proposal per corpus root, the other five empty
for p in memory64 tail-call exception-handling gc function-references multi-memory; do
  d=$S/percorpus/$p; rm -rf $d
  for q in memory64 tail-call exception-handling gc function-references multi-memory; do mkdir -p $d/$q; done
  cp -al test/spec/wasm-3.0-assert/$p/. $d/$p/      # hard links — the runner only reads
  ZWASM_SPEC_ENGINE=jit $S/out/bin/zwasm-spec-wasm-3-0-assert $d >/dev/null 2>&1
  printf '%-22s rc=%s\n' "$p" "$?"
done
```

then binary-search the manifest **prefix** inside the guilty sub-corpus
(`sed -n "1,${mid}p"`), and take the backtrace with the fault handler still
installed — gdb stops before it:

```bash
gdb -q -batch -ex 'handle SIGSEGV stop nopass' -ex run -ex 'bt 25' \
    -ex 'info registers rip rsp rax rdx r10 r11' --args <runner> $S/corpus
```

`RIP = 0x0` with a `jitTrampoline (f=0x0, …)` frame = the JIT jumped through
a **null function pointer**, not a miscompiled body — go look at what
populates the funcptr table, not at the emit pass.

Bisect by manifest **window**, not by deletion — a bare `assert_*` with no
preceding `module` line lands in the skip column instead of running, so a
window that starts on an assert is not the experiment you think it is (it
looks like a clean pass):

```bash
sed -n "${START},${END}p" $S/manifest.full.txt > $S/corpus/gc/<sub>/manifest.txt
```

Then the decisive step: run the suspect `module` + **its own** assert with
nothing else in the manifest. If that alone reproduces `fail=1`, the
directive you originally blamed is innocent — check it in isolation too and
confirm it passes. Restore with `cp $S/manifest.full.txt …` when done.

Once you have the module, drop the runner entirely — most lane fails
reproduce on the plain CLI, which gives a precise trap kind for free:

```bash
$S/out/bin/zwasm run --engine jit    --invoke <name> <module.wasm>   # trap kind=…
$S/out/bin/zwasm run --engine interp --invoke <name> <module.wasm>   # oracle
```

### Recipe 20 — operand-stack-pressure sweep (spill-dependent miscompiles)

For a JIT-only wrong-result/wrong-trap where the individual ops all pass in
isolation. The engine's x86_64 GPR pool is small (R10/R11 are reserved as
`abi.spill_stage_gprs`, R15 as the runtime ptr), so vregs start spilling at a
**low** operand-stack depth — D-590's `table.get` bug needed only **4** live
values. Sweep the depth; the threshold IS the diagnosis.

```bash
for n in $(seq 0 9); do
  body=""; for i in $(seq 1 $n); do body="$body    ref.null func
"; done
  cat > n$n.wat <<EOF
(module
  (type \$v (func))
  (table 3 3 funcref)
  (func \$run (type \$v)
$body    i32.const 0
    table.get 0
    br 0)
  (export "run" (func \$run)))
EOF
  wasm-tools parse n$n.wat -o n$n.wasm
  printf 'live=%s jit: %s\n' "$n" "$(zwasm run --engine jit --invoke run n$n.wasm 2>&1)"
done
```

`br 0` at the end discards the whole stack, so the padding values need no
matching consumers and the function stays `()->()`. Use `ref.null func`
(or `i32.const`) for padding — an op with a host callout (`ref.cast` →
`jitGcRefCast`) spills across the call and *relieves* the pressure, which
will hide the bug.

A clean "passes at N-1, fails at N" boundary means a **spilled operand**, so
go straight to the emit site's `gpr.gprLoadSpilled` / `gprDefSpilled` calls
and check the `stage_idx` argument against every register the surrounding
code has already loaded — `spill_stage_gprs[stage_idx]` is a *physical*
register, and reloading a spilled vreg into it silently clobbers whatever
was there. Compare against the same op's arm64 twin and against the sibling
op in the same file: in D-590, `emitTableSet` and arm64 `emitTableGet` both
snapshot operands *before* the descriptor loads and say so in a comment,
and only x86_64 `emitTableGet` had the order inverted.

The threshold is a property of the **ABI, not of the module**:
`abi.allocatable_gprs` is 4 wide on SysV x86_64, 6 on Win64, 8 on arm64, so
the same `.wasm` crosses the spill boundary at a different `live=` on each
host — a green sweep on the wrong one proves nothing.

Deciding whether a candidate emit site is really this bug needs the **stage
index**, not just the register: the collision requires the live value and
the reload to land on the SAME `spill_stage_gprs[i]`. Most GC op handlers
keep their scratch in stage 1 (`slab` = R11) and take stage 0 for the
result, which is disjoint and safe — a scan that ignores the index reports
every one of them. Two things a literal-`.r10` grep also misses:
`codegen/{arm64,x86_64}/ops/**` binds the stage regs to named consts
(`slab` / `call_scratch` / `len_scratch`), and `scripts/spill_aware_check.sh`
never reads that subtree (`find … -maxdepth 2`, 37 of 469 x86_64 files) —
nor would it fire here, since it checks that a handler *uses* the
spill-aware helpers, never *where* it calls them.

## Recipe 21 — differential probe of a real-world guest by re-exporting its internals

**Trigger.** A toolchain-built `.wasm` (AssemblyScript / TinyGo / Rust /
emcc) aborts under `--engine jit` but completes under `--engine interp`,
and the module is far too big to read. Works for both "engine diverges"
and "guest detects its own corruption" shapes.

### 21a — is it a host-call boundary at all?

```bash
for e in interp jit; do ZWASM_DEBUG=mem.cksum zig-out/bin/zwasm run --engine $e F.wasm; done
```

Read the **import names**, not just the checksums. If the JIT's first
`[dbg mem.cksum]` line names a *different* import than the interp's first
line, the guest already took a different branch **before any host call** —
so it is a plain miscompile, not host-boundary memory corruption. (This
inverted the AssemblyScript-TLSF hypothesis in one command: interp's first
line was `interp 2` = `random_get`; the JIT's was `jit fd_write`, which is
the abort message itself.)

### 21b — which guest function diverges

```bash
for e in interp jit; do ZWASM_DEBUG=jit.callcount zig-out/bin/zwasm run --engine $e F.wasm; done
```

Diff the **sets** of called indices, not the counts — interp bumps at the
call site, the JIT in the prologue, so magnitudes are not comparable.
Indices present on one engine only bracket the divergent branch. Pair with
a call graph so an index maps to a role:

```bash
wasm-tools print F.wasm > /tmp/f.wat   # then: for each `(func (;N;)`, collect its `call K`
```

The function that calls both `fd_write` and `proc_exit` is the guest's
`abort`; its callers carry the assertion's file:line as `i32.const`
literals, which names the failing source line in the guest's own runtime.

### 21c — drive an internal function directly

`zwasm run` has `--invoke <name>[=a,b,...]`, so add probe exports to a
scratch copy of the guest and call them:

```bash
wasm-tools print F.wasm > probe.wat   # append probe funcs, then:
wasm-tools parse probe.wat -o probe.wasm
```

```wat
;; run the guest's own initializer, then read one word of its heap
(func $p_peek (export "p_peek") (param i32) (result i32)
  call 22          ;; the guest's initializeRoot
  global.get 1     ;; its root pointer
  local.get 0 i32.add i32.load)
;; …and a prefix hash, for binary search
(func $p_cksum (export "p_cksum") (param i32) (result i32) ...)
```

Binary-search `p_cksum=N` interp-vs-jit for the **first differing byte** —
~11 round trips instead of a full word sweep. In the TLSF case this landed
on a single word (`slMap[7]`: interp `0x4000`, JIT `0x4001`).

### 21d — prove which instruction writes the bad value

Replace the suspect `i32.store` with `drop drop` in the scratch copy,
keeping the address/value computation intact. If the divergence vanishes,
that store's *value operand* is wrong; if it survives, look elsewhere.

### 21e — WARNING: probes inside the suspect function hide regalloc bugs

Inserting `global.set` / `global.get` captures **into** the function under
test changes its register pressure and made this bug disappear (every
captured value read correct, and the final store became correct too).
That is itself the diagnosis — a Heisenbug under added pressure means
**regalloc / liveness**, not arithmetic. Probe from *outside* the function,
then go to `ZWASM_DEBUG=jit.dump` + Recipe 2 for the real answer.

### 21f — shrink to hand-written `.wat`

Once the wat pattern is known, retype it by hand and sweep variants
(with/without the `br`, `br` vs `br_if`, `block` vs `loop`, an extra
operand below the block). The AssemblyScript TLSF abort reduced to:

```wat
(module (func (export "f") (param $p i32) (result i32)
  block (result i32) i32.const 7 br 0 end   ;; fall-through is DEAD
  i32.const 1 local.get $p i32.shl i32.or))
```

`f(3)`: interp 15, JIT 9. The 54-byte body disassembles to `mov ebx,0x7` /
`jmp` / `mov ebx,0x1` — one physical register for two live operands.

## Recipe 22 — liveness's operand-stack sim must mirror emit's `pushed_vregs`

**Symptom.** The JIT reads a stale value for an operand that a `block` /
`if` produced, and `ZWASM_DEBUG=regverify` reports **no** overlap: the
allocation is consistent with the liveness it was given, and the liveness
is what is wrong.

**Check.** `src/ir/analysis/liveness.zig` simulates the operand stack
independently of `codegen/{arm64,x86_64}/op_control.zig`. Every place the
emit adjusts `pushed_vregs`, liveness must make the *same* adjustment to
`sim_stack` / `sim_len`, or the two models drift by a slot and every vreg
after that point is mis-scoped. When auditing a control op, diff the two
files side by side — the emit is authoritative, because it decides which
register a value is actually read from.

Concrete drift found this way: `emitEndIntra` splits a block's `.end` into
three shapes ((a) live fall-through, (b) dead fall-through, (c) stack
emptied below `entry + arity`), while liveness's `.end` had only shape (a)/(b)
behind an **absolute** `sim_len >= result_arity` guard. A block whose only
exit is `br` hits shape (c): the `br` handler drains `sim_stack` to the
block's entry depth, the guard fails, and the captured merge vreg is never
restored — it dies at the branch and the next push inherits its register.
With one operand already on the stack the absolute guard is worse than
useless: it passes, reaches *below* the block's base, and overwrites the
enclosing frame's vreg.

**Grep-able tell.** In liveness, any guard of the form
`sim_len >= <arity>` that should be `sim_len >= entry_depth + <arity>`, and
any `Frame` field the emit's `Label` has but liveness pins to a constant
(`param_arity = 0` was pinned for block/loop frames).

## Recipe 23 — Debug-passes / optimised-fails in a host→JIT thunk

**Trigger.** A lane is green at the default optimize level and fails at
`-Doptimize=Release*`. `ci_gate.sh` runs `test-all` at the default optimize
level; the unit tests also run ReleaseSafe on every PR's Linux leg (#347), so
check that leg's log first — it names the failing test. The integration
runners have no optimized lane on a PR: `check_jit_releasesafe.sh` sits in the
`ZWASM_CI_EXTENDED` leg, which fires on the push to `main`, so a runner-only
instance of this class still reaches `main` before any lane sees it.

**First: settle whether it is the optimizer or the mode.** Run all four.
Debug-only-green with every Release mode failing identically points at the
host↔JIT boundary, not at a Release-specific miscompile.

```sh
for m in Debug ReleaseSafe ReleaseFast ReleaseSmall; do
  zig build install ${m:+-Doptimize=$m} >/dev/null 2>&1
  ./zig-out/bin/<runner> <corpus> >/dev/null 2>&1; echo "$m exit=$?"
done
```

**Then bisect the manifest, not the code.** Truncating a manifest is far
cheaper than reading codegen, and lands on the directive:

```sh
lo=1; hi=$(wc -l < full.txt)
while [ $lo -lt $hi ]; do
  mid=$(( (lo + hi) / 2 )); head -$mid full.txt > manifest.txt
  ./zig-out/bin/<runner> <corpus> >/dev/null 2>&1
  if [ $? -ne 0 ]; then hi=$mid; else lo=$((mid+1)); fi
done
```

**Two failure modes live at this boundary.** Both were found together in the
mixed multi-result thunks (`entry.zig` `callI32f64NoArgs` and siblings):

1. **An operand named as both input and output of one `asm`.** `"{x0}"` in and
   `"={x0}"` out are untied, so the allocator may place the output's def before
   the input's use. Debug happened to allocate elsewhere. Symptom: the callee
   runs with a garbage first argument, faulting at a small constant address (a
   field offset off that garbage). Fix: take the value in a different register
   and `mov` it into place inside the asm; pin every operand to a named
   register — `"r"` is free to pick the one a neighbouring line just wrote.

2. **The JIT's register cohort not saved.** The JIT allocates from the host's
   callee-saved registers and its prologue saves only one, so every host→JIT
   call must bracket the branch. `invokeAndCheckVoid` carries the save for
   aarch64 and SysV; it has no Windows branch and falls through to
   `jitTrampolineVoid`. A thunk added later can silently omit the save. Symptom: a
   result comes back holding a pointer, or the host faults after returning.

**Verify a new gate leg is a guard, not a passing command.** Revert the fix,
rebuild at the optimised level, confirm the leg fails, restore, confirm it
passes. Check the restore by content (`git status --porcelain`, or an md5), not
by trusting that the revert command did what was asked — a `git stash` that
silently matched nothing once produced a confident "the guard does not work".

**Do not trust an inline-asm comment about the ABI without checking it.** The
first explanation written for this bug claimed x0 held an sret pointer for a
16-byte struct return. The callee was declared to return `void`, so there was
no struct return in the call at all; and AAPCS64 returns a 16-byte non-HFA
composite in x0+x1 directly, putting the indirect-return pointer in x8 when it
uses one — cross-checked against cranelift's aarch64 ABI lowering
(`cranelift/codegen/src/isa/aarch64/abi.rs` in `bytecodealliance/wasmtime`).
Read the callee's declared type first, then the ABI, then the disassembly.
