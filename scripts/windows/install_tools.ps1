<#
.SYNOPSIS
    Install zwasm v2's Windows-native toolchain.

.DESCRIPTION
    Idempotent, per-user installer. Mirrors flake.nix pin list so
    Mac / Linux / Windows share the same tool surface (per user
    guidance 2026-05-22 "Mac side と同じツールを使うべき"):
        zig, hyperfine, wasm-tools, wasmtime, wasmer,
        wabt (wat2wasm + wast2json), yq (yq-go), lldb (LLVM),
        sysinternals (Procmon + ProcExp + DebugView + Handle + ~70 tools).
    Tools land in %LOCALAPPDATA%\zwasm-tools\<name>-<version>\
    and are added to the user-scoped PATH.

    The sysinternals entry exists to give Windows-side JIT debugging
    the same "actively wired" status as the Mac and Linux hosts
    (per close-plan §0.2.1 + debug_jit_auto skill Windows recipes).
    Without these tools D-028 / D-136 / future Win64-specific JIT
    bugs are debuggable only via lldb, which lacks process / file
    / handle tracing.

    Background: v1 has scripts/windows/install-tools.ps1 but it
    does not include wabt / yq / lldb. v2's build.zig (Close-plan
    §6 (j), 2026-05-21) added a hard `wat2wasm` SystemCommand —
    this PS1 plugs the gap before §9.13-0 Cat IV reconcile.

    Idempotent: a versioned directory that already exists is
    skipped unless -Force is passed. PATH entries are not
    duplicated.

    Requires: Windows 10/11 with built-in tar.exe, PowerShell
    5.1 or PowerShell 7. Does not require administrator rights.

.PARAMETER Force
    Reinstall every tool even if the version-stamped directory
    already exists.

.PARAMETER OnlyTool
    Install just one tool. Default: all.

.EXAMPLE
    pwsh -NoLogo -File scripts\windows\install_tools.ps1

.EXAMPLE
    pwsh -NoLogo -File scripts\windows\install_tools.ps1 -OnlyTool wabt -Force
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [ValidateSet('zig', 'hyperfine', 'wasm-tools', 'wasmtime', 'wasmer', 'wabt', 'yq', 'lldb', 'sysinternals', 'all')]
    [string]$OnlyTool = 'all'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- Pinned versions (mirror flake.nix; bumped manually) ---

$versions = @{
    'zig'        = '0.17.0'      # PINNED — never bump; the whole project targets Zig 0.17.0
    'hyperfine'  = '1.20.0'
    'wasm-tools' = '1.251.0'
    'wasmtime'   = '45.0.0'
    'wasmer'     = '7.1.0'       # 2nd reference oracle (§9.6 A3); mirrors flake .#default Mac
    'wabt'       = '1.0.41'
    'yq'         = '4.53.2'
    'lldb'       = '22.1.6'      # via LLVM installer; lldb is bundled
    # Sysinternals Suite has no suite-level semver — Microsoft ships a
    # rolling zip at a fixed URL. The pin is a date-stamp marking when
    # we last verified the bundle. Bump manually + use -Force to refresh.
    'sysinternals' = '2026-05-22'
}

# --- Install layout ---

$installRoot = Join-Path $env:LOCALAPPDATA 'zwasm-tools'
$workDir     = Join-Path $installRoot '.work'
New-Item -ItemType Directory -Force -Path $installRoot | Out-Null
New-Item -ItemType Directory -Force -Path $workDir     | Out-Null

# --- Helpers ---

function Download-File {
    param([Parameter(Mandatory)][string]$Url,
          [Parameter(Mandatory)][string]$Dest)
    Write-Host "  download: $Url"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $oldProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing
    }
    finally {
        $ProgressPreference = $oldProgress
    }
}

function Extract-Zip {
    param([Parameter(Mandatory)][string]$Archive,
          [Parameter(Mandatory)][string]$Dest)
    if (Test-Path $Dest) { Remove-Item -Recurse -Force $Dest }
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    Expand-Archive -LiteralPath $Archive -DestinationPath $Dest -Force
}

function Extract-TarGz {
    param([Parameter(Mandatory)][string]$Archive,
          [Parameter(Mandatory)][string]$Dest)
    if (Test-Path $Dest) { Remove-Item -Recurse -Force $Dest }
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    & tar.exe -xzf $Archive -C $Dest
    if ($LASTEXITCODE -ne 0) {
        throw "tar.exe extraction failed for $Archive (exit $LASTEXITCODE)"
    }
}

function Resolve-SingleSubdir {
    param([Parameter(Mandatory)][string]$ParentDir)
    $children = @(Get-ChildItem -LiteralPath $ParentDir -Directory)
    if ($children.Count -eq 1) { return $children[0].FullName }
    return $ParentDir
}

function Install-Archive {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][ValidateSet('zip', 'tar.gz')][string]$Format
    )
    $stampedDir = Join-Path $installRoot ("{0}-{1}" -f $Name, $Version)
    if ((Test-Path $stampedDir) -and -not $Force) {
        Write-Host "[skip] $Name $Version (exists)"
        return $stampedDir
    }
    Write-Host "[install] $Name $Version"
    $ext = if ($Format -eq 'zip') { 'zip' } else { 'tar.gz' }
    $archive = Join-Path $workDir ("{0}-{1}.{2}" -f $Name, $Version, $ext)
    Download-File -Url $Url -Dest $archive
    $staging = Join-Path $workDir ("{0}-{1}-staging" -f $Name, $Version)
    if ($Format -eq 'zip') {
        Extract-Zip -Archive $archive -Dest $staging
    } else {
        Extract-TarGz -Archive $archive -Dest $staging
    }
    $unpacked = Resolve-SingleSubdir -ParentDir $staging
    if (Test-Path $stampedDir) { Remove-Item -Recurse -Force $stampedDir }
    Move-Item -LiteralPath $unpacked -Destination $stampedDir
    Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue
    Remove-Item -Force $archive -ErrorAction SilentlyContinue
    return $stampedDir
}

function Install-SingleFile {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$FileName
    )
    $stampedDir = Join-Path $installRoot ("{0}-{1}" -f $Name, $Version)
    $dest = Join-Path $stampedDir $FileName
    if ((Test-Path $dest) -and -not $Force) {
        Write-Host "[skip] $Name $Version (exists)"
        return $stampedDir
    }
    Write-Host "[install] $Name $Version"
    New-Item -ItemType Directory -Force -Path $stampedDir | Out-Null
    Download-File -Url $Url -Dest $dest
    return $stampedDir
}

function Install-Winget {
    param(
        [Parameter(Mandatory)][string]$Name,        # display name
        [Parameter(Mandatory)][string]$PackageId,   # winget package id
        [Parameter(Mandatory)][string]$Version,     # for the log
        [Parameter(Mandatory)][string]$VerifyExe    # absolute path of a file that proves install success
    )
    # LLVM's NSIS installer requires UAC elevation that an OpenSSH
    # session cannot provide; silent NSIS exits 0 without installing.
    # winget handles elevation cleanly via the user's session
    # (or fails loudly), so it is the reliable path for these
    # tools.  Machine-scope is forced for packages that don't
    # support --scope user (e.g. LLVM).
    if ((Test-Path $VerifyExe) -and -not $Force) {
        Write-Host "[skip] $Name $Version (exists at $VerifyExe)"
        return $VerifyExe
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "winget not available; install Microsoft App Installer or use the Microsoft Store route for $Name"
    }
    Write-Host "[install] $Name $Version (winget $PackageId)"
    & winget install $PackageId -e --silent `
        --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "$Name winget install failed (exit $LASTEXITCODE)"
    }
    if (-not (Test-Path $VerifyExe)) {
        throw "$Name winget reported success but $VerifyExe not found"
    }
    return $VerifyExe
}

function Install-WingetUser {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$VerifyExe
    )
    if ((Test-Path $VerifyExe) -and -not $Force) {
        Write-Host "[skip] $Name $Version (exists at $VerifyExe)"
        return $VerifyExe
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "winget not available for $Name"
    }
    Write-Host "[install] $Name $Version (winget $PackageId, user scope)"
    & winget install $PackageId -e --silent --scope user `
        --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "$Name winget install failed (exit $LASTEXITCODE)"
    }
    if (-not (Test-Path $VerifyExe)) {
        throw "$Name winget reported success but $VerifyExe not found"
    }
    return $VerifyExe
}

# --- Install plan ---

$paths = @{}

if ($OnlyTool -in @('all', 'zig')) {
    $v = $versions['zig']
    $url = "https://ziglang.org/download/$v/zig-x86_64-windows-$v.zip"
    $paths['zig'] = Install-Archive -Name 'zig' -Version $v -Url $url -Format 'zip'
}

if ($OnlyTool -in @('all', 'hyperfine')) {
    $v = $versions['hyperfine']
    $url = "https://github.com/sharkdp/hyperfine/releases/download/v$v/hyperfine-v$v-x86_64-pc-windows-msvc.zip"
    $paths['hyperfine'] = Install-Archive -Name 'hyperfine' -Version $v -Url $url -Format 'zip'
}

if ($OnlyTool -in @('all', 'wasm-tools')) {
    $v = $versions['wasm-tools']
    $url = "https://github.com/bytecodealliance/wasm-tools/releases/download/v$v/wasm-tools-$v-x86_64-windows.zip"
    $paths['wasm-tools'] = Install-Archive -Name 'wasm-tools' -Version $v -Url $url -Format 'zip'
}

if ($OnlyTool -in @('all', 'wasmtime')) {
    $v = $versions['wasmtime']
    $url = "https://github.com/bytecodealliance/wasmtime/releases/download/v$v/wasmtime-v$v-x86_64-windows.zip"
    $paths['wasmtime'] = Install-Archive -Name 'wasmtime' -Version $v -Url $url -Format 'zip'
}

if ($OnlyTool -in @('all', 'wasmer')) {
    $v = $versions['wasmer']
    # wasmer ships a flat tar.gz (bin/ lib/ include/, no top-level version dir);
    # Resolve-SingleSubdir falls through to the staging dir, so the stamped dir
    # holds bin\wasmer.exe (PATH points at the bin subdir, like wabt).
    $url = "https://github.com/wasmerio/wasmer/releases/download/v$v/wasmer-windows-amd64.tar.gz"
    $paths['wasmer'] = Install-Archive -Name 'wasmer' -Version $v -Url $url -Format 'tar.gz'
}

if ($OnlyTool -in @('all', 'wabt')) {
    $v = $versions['wabt']
    # wabt release naming: wabt-<v>-windows-x64.tar.gz (NO 'v' prefix on tag).
    $url = "https://github.com/WebAssembly/wabt/releases/download/$v/wabt-$v-windows-x64.tar.gz"
    $paths['wabt'] = Install-Archive -Name 'wabt' -Version $v -Url $url -Format 'tar.gz'
}

if ($OnlyTool -in @('all', 'yq')) {
    $v = $versions['yq']
    $url = "https://github.com/mikefarah/yq/releases/download/v$v/yq_windows_amd64.exe"
    # yq ships as a single .exe; stamped dir holds it as 'yq.exe' for
    # PATH-compatible invocation.
    $paths['yq'] = Install-SingleFile -Name 'yq' -Version $v -Url $url -FileName 'yq.exe'
}

if ($OnlyTool -in @('all', 'lldb')) {
    # LLVM bundles lldb (+ dsymutil + llvm-objdump + clang-format).
    # Installed via winget because NSIS silent install fails over
    # SSH without UAC; winget handles elevation cleanly.
    # LLVM does not support per-user scope -> machine install at
    # C:\Program Files\LLVM.
    $v = $versions['lldb']
    $llvmExe = Install-Winget -Name 'llvm' -PackageId 'LLVM.LLVM' `
        -Version $v `
        -VerifyExe 'C:\Program Files\LLVM\bin\lldb.exe'
    $paths['lldb'] = Split-Path $llvmExe -Parent

    # lldb on Windows is dynamically linked to Python 3.11 (python311.dll).
    # Without it: `lldb --version` exits with 'unable to find python311.dll'.
    # Install Python 3.11 in user scope so the DLL lands at a known
    # location and joins User PATH (winget Python.Python.3.11 -- scope user).
    $pyVer = '3.11'
    $pyVerify = Join-Path $env:LOCALAPPDATA 'Programs\Python\Python311\python311.dll'
    $pyDir = Install-WingetUser -Name 'python' -PackageId 'Python.Python.3.11' `
        -Version $pyVer `
        -VerifyExe $pyVerify
    $paths['python311'] = Split-Path $pyDir -Parent
}

if ($OnlyTool -in @('all', 'sysinternals')) {
    # Sysinternals Suite — Microsoft's debug toolkit bundle (~70 .exe).
    # Bundle URL is fixed (latest); the $versions pin is a date-stamp
    # marking when we last downloaded.
    # Tools used by zwasm v2 debug workflows:
    #   Procmon64.exe   — process / file / registry tracing (D-028 wedge)
    #   procexp64.exe   — live process state, fd / handle inspection
    #   DebugView.exe   — OutputDebugString capture
    #   handle64.exe    — fd / handle enumeration per process
    # The zip extracts flat (no nested top-dir) — Install-Archive's
    # Resolve-SingleSubdir falls through to return $staging as-is and
    # Move-Item renames staging → stampedDir. Tested 2026-05-22.
    $v = $versions['sysinternals']
    $url = 'https://download.sysinternals.com/files/SysinternalsSuite.zip'
    $paths['sysinternals'] = Install-Archive -Name 'sysinternals' -Version $v -Url $url -Format 'zip'
}

# --- PATH wiring (User scope, idempotent) ---

# Remove stale User-PATH entries for a tool being (re)installed at a new
# version. Without this, a version bump only APPENDS the new stamped dir while
# the old `<name>-<oldver>` entry keeps its earlier PATH position and wins the
# `where <tool>` lookup — so the update silently has no effect. Drops any User
# PATH entry under the install root whose stamped leaf is `<name>-*`, for each
# tool in $ToolNames; the matching new entry is re-added by Update-UserPath.
function Remove-StalePathEntries {
    param([Parameter(Mandatory)][string[]]$ToolNames)
    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $current) { return }
    $entries = @($current.Split(';') | Where-Object { $_ })
    $rootPrefix = $installRoot.TrimEnd('\') + '\'
    $kept = foreach ($e in $entries) {
        $drop = $false
        if ($e.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            $stamped = $e.Substring($rootPrefix.Length).Split('\')[0]   # <name>-<version>
            foreach ($t in $ToolNames) {
                if ($stamped.StartsWith($t + '-', [StringComparison]::OrdinalIgnoreCase)) { $drop = $true; break }
            }
        }
        if (-not $drop) { $e }
    }
    if (@($kept).Count -ne $entries.Count) {
        [Environment]::SetEnvironmentVariable('Path', (@($kept) -join ';'), 'User')
        Write-Host "[path] dropped stale entries for: $($ToolNames -join ', ')"
    }
}

function Update-UserPath {
    param([Parameter(Mandatory)][string[]]$Add)
    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $current) { $current = '' }
    $entries = @($current.Split(';') | Where-Object { $_ })
    $changed = $false
    foreach ($p in $Add) {
        if (-not $p) { continue }
        if ($entries -notcontains $p) {
            $entries += $p
            Write-Host "[path] +$p"
            $changed = $true
        }
    }
    if ($changed) {
        [Environment]::SetEnvironmentVariable('Path', ($entries -join ';'), 'User')
    }
}

# Per-tool PATH layout:
#   zig / wasm-tools / wasmtime / hyperfine — binaries directly in stamped dir
#   wabt        — bin/ subdir (wat2wasm, wast2json, wasm-strip, etc.)
#   yq          — yq.exe directly in stamped dir
#   llvm (lldb) — bin/ subdir (lldb.exe, dsymutil.exe, llvm-objdump.exe, ...)
$pathsToAdd = @()
if ($paths.ContainsKey('zig'))         { $pathsToAdd += $paths['zig'] }
if ($paths.ContainsKey('hyperfine'))   { $pathsToAdd += $paths['hyperfine'] }
if ($paths.ContainsKey('wasm-tools'))  { $pathsToAdd += $paths['wasm-tools'] }
if ($paths.ContainsKey('wasmtime'))    { $pathsToAdd += $paths['wasmtime'] }
if ($paths.ContainsKey('wasmer'))      { $pathsToAdd += (Join-Path $paths['wasmer'] 'bin') }
if ($paths.ContainsKey('wabt'))        { $pathsToAdd += (Join-Path $paths['wabt']  'bin') }
if ($paths.ContainsKey('yq'))          { $pathsToAdd += $paths['yq'] }
# lldb dir is already the LLVM bin dir (Split-Path of lldb.exe).
# OpenSSH bash sessions don't inherit Machine PATH changes that
# happen during the session, so we also add to User PATH which IS
# inherited at SSH login time.
if ($paths.ContainsKey('lldb'))        { $pathsToAdd += $paths['lldb'] }
if ($paths.ContainsKey('python311'))   { $pathsToAdd += $paths['python311'] }
# Sysinternals Suite: all .exe live flat in the stamped dir (Procmon64.exe,
# procexp64.exe, DebugView.exe, handle64.exe, ...).
if ($paths.ContainsKey('sysinternals')) { $pathsToAdd += $paths['sysinternals'] }

# Git for Windows bash (needed by `bash scripts/*.sh`).  Skip if absent.
$gitBin = 'C:\Program Files\Git\bin'
if (Test-Path (Join-Path $gitBin 'bash.exe')) {
    $pathsToAdd += $gitBin
}

# Drop stale prior-version entries for every tool we just installed BEFORE
# appending the current ones, so a version bump actually takes precedence.
Remove-StalePathEntries -ToolNames @($paths.Keys)
Update-UserPath -Add $pathsToAdd

Write-Host ""
Write-Host "Done. Open a new shell to pick up PATH changes."
Write-Host "Verify:"
Write-Host "  zig version"
Write-Host "  hyperfine --version"
Write-Host "  wasm-tools --version"
Write-Host "  wasmtime --version"
Write-Host "  wasmer --version"
Write-Host "  wat2wasm --version       # (wabt)"
Write-Host "  wast2json --version      # (wabt)"
Write-Host "  yq --version"
Write-Host "  lldb --version"
Write-Host "  Procmon64.exe /?         # (sysinternals) — file/process tracer"
Write-Host "  handle64.exe -h          # (sysinternals) — fd / handle enumeration"
