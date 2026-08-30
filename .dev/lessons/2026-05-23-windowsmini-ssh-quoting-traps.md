# windowsmini SSH quoting / orchestration trap inventory

**Citing**: D-165 cycle 9 interactive debug session, 2026-05-23.
Captured as scratch memo — promote to `debug_jit_auto/SKILL.md`
Recipe 15+ once workflow is fully proven and patterns are
stable. Until then this is the cross-reference for "I tried X
and it broke for reason Y on windowsmini" so we don't pay the
cost again.

## Layer cake of shells

`ssh windowsmini <cmd>` lands in **OpenSSH server → PowerShell
7** by default. From PowerShell, scripts often re-enter
**Git-Bash** (`bash -lc`) which itself depends on **MSYS** path
conversion. Three shells, three sets of quoting rules.

## Traps observed (with fix)

### 1. PowerShell mis-interprets bash syntax

Symptom: `ssh windowsmini "command with $var"` → PowerShell tries
to expand `$var`, fails with "The term '...' is not recognized".

Fix: wrap with `bash -lc "'...'"` (single-quotes around the body
so bash receives the literal, not PowerShell).

```bash
# WORKS
ssh windowsmini bash -lc "'
  cd ~/Documents/MyProducts/zwasm_from_scratch
  echo \$HOME
'"
```

### 2. PowerShell parses `(...)` and `foreach($p in ...)` early

Symptom: `Stop-Process -Id $p.Id` inside `foreach` errored
"Unexpected token 'in'".

Fix: use `cmd /c '<cmd>'` for any non-trivial PowerShell-like
construct, OR write a `.ps1` script and SCP-then-invoke.

### 3. MSYS path conversion mangles `/F` `/FI` etc.

Symptom: `taskkill /F /IM x.exe` via Git-Bash → "C:/Program
Files/Git/F" passed as literal argument.

Fix A: `cmd /c 'taskkill /F /IM x.exe'` (most reliable).
Fix B: `MSYS_NO_PATHCONV=1 taskkill ...` — sometimes works.
Fix C: `taskkill //F //IM ...` (double-slash escape) — **does
not work** for taskkill; passed as `//F` literal.

Conclusion: **use `cmd /c '...'` for any Windows-native CLI tool
invocation with `/X` switches** (taskkill, tasklist, sc, reg,
schtasks, ...).

### 4. `tasklist /FI "..."` filter quoting hell

Symptom: `tasklist /FI "IMAGENAME eq x.exe"` via bash → filter
arg path-mangled.

Fix: `cmd /c 'tasklist /FI "IMAGENAME eq x.exe" /NH /FO CSV'`.

### 5. Cygwin/Git-Bash PID ≠ Windows native PID

Symptom: `lldb -p <bash $!>` → "The parameter is incorrect."

Fix: re-fetch via `cmd /c 'tasklist /FI "IMAGENAME eq x.exe" /NH
/FO CSV'` and parse second column. That's the Win-native PID
lldb expects.

### 6. SSH background `&` doesn't auto-detach

Symptom: `ssh windowsmini bash -lc "... &"` → ssh session waits
indefinitely even after the remote backgrounded process is
running.

Cause: ssh attaches stdio to the remote process; bash `&` keeps
the stdio inherited.

Fix: redirect remote process stdio to a file AND `< /dev/null`
on the ssh side. Or use `setsid <cmd> < /dev/null > /tmp/x.log
2>&1 &`.

### 7. lldb attach works without admin

Confirmed via attaching to a spawned `pwsh.exe`. No
SE_DEBUG_NAME requirement on the windowsmini standard `<user>`
user. `process interrupt` works, `process detach` works,
register/backtrace read clean.

### 8. tasklist by name returns header row by default

Symptom: parsing tasklist output picks up "Image Name PID..."
header line.

Fix: `/NH /FO CSV` flags — no header, CSV format. Parse with
awk-F, or simpler: just grep for the .exe name.

## Robust-enough orchestration shape

```bash
# 1. scp manifest (local → remote)
scp -q -r ./local/dir windowsmini:Documents/.../remote/dir/

# 2. start runner detached (stdio redirected, < /dev/null)
ssh windowsmini cmd /c 'start /B "" .zig-cache\\o\\HASH\\runner.exe args > C:\\tmp\\run.log 2>&1'

# 3. wait, then get Win-native PID
WPID=$(ssh windowsmini cmd /c 'tasklist /FI "IMAGENAME eq runner.exe" /NH /FO CSV' \
  | awk -F, 'NR==1 { gsub(/"/, ""); print $2 }')

# 4. lldb attach (works directly)
ssh windowsmini cmd /c "\"C:\\Program Files\\LLVM\\bin\\lldb.exe\" -b -p $WPID -o \"process interrupt\" -o \"register read\" -o \"thread backtrace\" -o \"process detach\" -o \"quit\""

# 5. cleanup
ssh windowsmini cmd /c "taskkill /F /PID $WPID"
ssh windowsmini cmd /c 'type C:\\tmp\\run.log'
```

Notably: **all step is `ssh windowsmini cmd /c '...'`**. No
nested `bash -lc`. No PowerShell. CMD handles `/F` `/FI` natively
and `start /B "" exe` properly detaches.

## When this lesson promotes to skill recipe

Once we've actually run this orchestration successfully (lldb
attached + state dumped from a real hang + matched the bug),
promote to `.claude/skills/debug_jit_auto/SKILL.md` as Recipe 15
"running-process attach + state dump on windowsmini (HANG
debug)" with a checked-in `scripts/win64_debug/attach_dump.sh`
that codifies the shape.

Until then, this scratch memo stays.

## Related

- `.dev/windows_ssh_setup.md` — generic windowsmini setup.
- `.claude/skills/debug_jit_auto/SKILL.md` Recipe 9-14 — existing
  windowsmini debug recipes (process launch, not attach).
