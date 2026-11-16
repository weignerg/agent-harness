#
# install-windows.ps1
# Windows 11 (WSL2) one-command install bootstrap for agent-harness (v0.7.1).
#
# TLDR:
#   1) Download agent-harness-v0.7.1-source.tar.gz (the install bundle) from the v0.7.1
#      release (https://github.com/weignerg/agent-harness/releases/tag/v0.7.1), then extract:
#      tar -xzf agent-harness-v0.7.1-source.tar.gz
#      (tar.exe is built into Windows 11; "Extract All" in Explorer works too.)
#   2) One command, run from INSIDE the extracted tree:
#      powershell -NoProfile -ExecutionPolicy Bypass -File .\agent-harness-v0.7.1\windows\install-windows.ps1
#   The command self-elevates, sets up WSL + Ubuntu, asks for the one mandatory reboot,
#   then (same command after reboot, from the same extracted bundle) copies the bundle to
#   $env:USERPROFILE\agent-harness and runs the Linux ./install.sh inside WSL. Because the
#   repository is PRIVATE there is no anonymous install URL: the single bundled source
#   tarball is the install medium (no git clone / remote fetch anywhere).
#
# What it does (one paragraph):
#   This script bootstraps agent-harness on a fresh Windows 11 machine using the Windows
#   Subsystem for Linux. It elevates itself, provisions WSL and the Ubuntu distro (handling
#   the single mandatory reboot via a state marker on disk), installs git/curl/python inside
#   Ubuntu, creates a default user with an empty password and passwordless sudo so that WSL
#   can auto-login, copies this source bundle (already on disk because the script runs from
#   inside the extracted bundle) to a canonical install target, and finally runs the harness
#   ./install.sh inside WSL with the locked flags. Every artifact comes from the bundle the
#   script ships in; there is no remote fetch and no git clone because the repo is private.
#

param(
  [string]$InstallTarget = "$env:USERPROFILE\agent-harness",  # canonical harness source dir
  [string]$Dist          = "Ubuntu",                          # WSL distro
  [switch]$Refresh       # re-copy this bundle over an existing $InstallTarget (update flow)
)

$StateDir  = Join-Path $env:LOCALAPPDATA "agent-harness"
$StateFile = Join-Path $StateDir "wsl-install.state"

$ErrorActionPreference = "Stop"

function Write-Step($msg) { Write-Host ("  => " + [string]$msg) -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host ("  [OK] " + [string]$msg)  -ForegroundColor Green }
function Write-Warn($msg) { Write-Host ("  [WARN] " + [string]$msg) -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host ("  [ERR]  " + [string]$msg) -ForegroundColor Red }

# --- Pass 1 fix (must-fix): single-quote escaping for WSL paths embedded in bash.
# Wrap a value so it is safe inside a bash SINGLE-quoted string: each ' becomes '\''
# (close quote, escaped single quote, open quote). Compute it once and use it at EVERY
# single-quoted bash embedding of a WSL path.
function ConvertTo-BashSingleQuoted {
  param([Parameter(ValueFromPipeline)] [string]$Value)
  process { $Value.Replace("'","'\''") }
}

function Test-IsAdmin {
    return [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent().IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PendingReboot {
    # True if the Windows Session Manager has a pending reboot (used to annotate the WSL
    # feature state, e.g. "Enabled (Pending Reboot)").
    try {
        $pm = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingReboot' -ErrorAction Stop
        if ($pm) { return $true }
    } catch { }
    return $false
}

function Get-FeatureState($name) {
    try {
        $feat = Get-WindowsOptionalFeature -Online -FeatureName $name -ErrorAction Stop
        return [string]$feat.InstallState
    } catch {
        return "Disabled"
    }
}

function Get-WslFeatureState {
    # Returns one of: Disabled, Enabled, "Enabled (Pending Reboot)", "Disabled (Pending Reboot)".
    # The WSL pair (Microsoft-Windows-Subsystem-Linux + VirtualMachinePlatform) must BOTH be
    # enabled to be usable; if either is not, the pair is "not ready" and we surface it.
    $wslState = Get-FeatureState "Microsoft-Windows-Subsystem-Linux"
    $vmpState = Get-FeatureState "VirtualMachinePlatform"
    $pending  = Get-PendingReboot

    $wslUsable = ($wslState -eq "Enabled" -or $wslState -eq "Enabled (Pending Reboot)")
    $vmpUsable = ($vmpState -eq "Enabled" -or $vmpState -eq "Enabled (Pending Reboot)")

    if (-not ($wslUsable -and $vmpUsable)) {
        # A disabled / missing feature that still has a pending reboot -> ask for reboot.
        if ($pending) { return "Disabled (Pending Reboot)" }
        return "Disabled"
    }

    # At least one side is enabled; report the WSL side, annotated with a reboot note.
    if ($pending) { return "Enabled (Pending Reboot)" }
    return "Enabled"
}

function Get-InstalledDistro {
    # Returns $true if the configured $Dist distro is present. Distinguish the probe cases
    # by TEXT, not by exit code alone. Matching is case-insensitive on the distro name.
    $output = $null
    try {
        $output = wsl.exe -l -v 2>&1 | Out-String
    } catch {
        $output = [string]$_.Exception.Message
    }
    if ([string]::IsNullOrEmpty($output)) { return $false }

    # Case: WSL is installed but has no distros yet.
    if ($output -match 'no installed distributions') { return $false }

    # Case: WSL not ready (optional feature not enabled / hypervisor not running).
    if ($output -match '0x8007019e|0x80370102|Windows Subsystem for Linux has no installed distributions') {
        return $false
    }

    # Case: a row like "*? Ubuntu  Stopped  2" -> configured distro present.
    if ($output -match [regex]::Escape($Dist)) { return $true }
    return $false
}

function Convert-WindowsToWslPath($winPath) {
    # C:\Users\X\agent-harness -> /mnt/c/Users/X/agent-harness
    if ($winPath -notmatch '^[A-Za-z]:\\') { return $winPath }
    $drive = $winPath.Substring(0,1).ToLower()
    $rest  = $winPath.Substring(2).Replace('\','/')
    return "/mnt/$drive/$rest"
}

function Read-State {
    if (Test-Path $StateFile) {
        try { return (Get-Content -Path $StateFile -ErrorAction Stop | Select-Object -First 1).Trim() }
        catch { return "" }
    }
    return ""
}

function Write-State($token) {
    if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }
    Set-Content -Path $StateFile -Value [string]$token -NoNewline
}

# ---------------------------------------------------------------
# Bundle-root check: this script MUST run from INSIDE an extracted
# v0.7.1 source bundle. It is code, so it runs after param() and the
# function definitions, then before the install flow.
# ---------------------------------------------------------------
$BundleRoot = Split-Path -Parent $PSScriptRoot
if (-not $PSScriptRoot -or -not (Test-Path (Join-Path $BundleRoot "install.sh"))) {
    Write-Err "This script must be run from INSIDE an extracted v0.7.1 source bundle (the folder containing install.sh, i.e. agent-harness-v0.7.1\windows\install-windows.ps1)."
    Write-Err "  1) Download agent-harness-v0.7.1-source.tar.gz from the v0.7.1 release, then:"
    Write-Err "        tar -xzf agent-harness-v0.7.1-source.tar.gz"
    Write-Err "  2) Then run its copy of this script:"
    Write-Err "        powershell -NoProfile -ExecutionPolicy Bypass -File .\\agent-harness-v0.7.1\\windows\\install-windows.ps1"
    Write-Err "(If you only downloaded the standalone install-windows.ps1 asset, download the source bundle, extract it, and run ITS copy of this script.)"
    exit 1
}

# ---------------------------------------------------------------
# Banner
# ---------------------------------------------------------------
Write-Host "agent-harness Windows (WSL) install bootstrap - v0.7.1" -ForegroundColor Magenta
Write-Host "-------------------------------------------------------------"
Write-Host

# ---------------------------------------------------------------
# (1) Admin check / self-elevate
# ---------------------------------------------------------------
if (-not (Test-IsAdmin)) {
    Write-Warn "Admin rights required - relaunching elevated..."
    $scriptPath = $MyInvocation.MyCommand.Path
    if (-not $scriptPath) { $scriptPath = (Get-Location).Path + "\install-windows.ps1" }
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
    Start-Process -FilePath $env:windir\System32\WindowsPowerShell\v1.0\powershell.exe `
                  -Verb RunAs -ArgumentList $argList
    exit 0
}
Write-Ok "Running with administrator privileges."

# ---------------------------------------------------------------
# (2) Probe WSL state
# ---------------------------------------------------------------
$featState = Get-WslFeatureState
$hasDistro = Get-InstalledDistro
Write-Step ("WSL feature state: " + $featState + " ; " + $Dist + " present: " + $hasDistro + " ; state marker: '" + (Read-State) + "'")

if ($featState -eq "Disabled") {
    # CASE A - Fresh: enable WSL feature + install the distro; a reboot is required to finish.
    Write-Step "Installing WSL + $Dist (this enables features + downloads kernel + distro)..."
    $oldEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { wsl.exe --install -d $Dist; $rc = $LASTEXITCODE } catch { $rc = $LASTEXITCODE }
    $ErrorActionPreference = $oldEap
    if ($rc -ne 0) { Write-Warn "wsl.exe --install returned exit code $rc (continuing)"; }
    Write-State "PENDING_REBOOT"
    Write-Host ""
    Write-Err "WSL + $Dist are being installed. A REBOOT is required to finish."
    Write-Err "Please REBOOT your machine now."
    Write-Err "After the reboot, open PowerShell in the SAME extracted bundle and run the SAME command again (see the top-of-file TLDR) to continue the install."
    exit 0
}
elseif ($featState -eq "Enabled (Pending Reboot)" -or $featState -eq "Disabled (Pending Reboot)") {
    # CASE B - WSL is installed but not activated until the machine is rebooted.
    Write-Host ""
    Write-Err "WSL is installed but the machine still needs a REBOOT for it to activate."
    Write-Err "Please REBOOT, then run the SAME one-liner again."
    exit 0
}
else {
    # featState == "Enabled"
    if (-not $hasDistro) {
        # CASE C - WSL enabled, but the distro is not installed yet.
        Write-Step "WSL is enabled; installing the $Dist distro..."
        $oldEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        try { wsl.exe --install -d $Dist; $rc = $LASTEXITCODE } catch { $rc = $LASTEXITCODE }
        $ErrorActionPreference = $oldEap
        if ($rc -ne 0) { Write-Warn "wsl.exe --install returned exit code $rc"; }
        # Fall through to (3) First-run setup (no reboot needed on an already-enabled WSL).
    }
    # CASE D - WSL enabled AND the distro present -> fall through to (3).
}

# ---------------------------------------------------------------
# (3) First-run setup (idempotent), run as root inside WSL.
# ---------------------------------------------------------------
Write-Step "Installing WSL tooling (git, curl, python3, venv, build tools)..."
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
try {
    wsl.exe -d $Dist -u root -- bash -lc "export DEBIAN_FRONTEND=noninteractive; apt-get update -y && apt-get install -y git curl ca-certificates python3 python3-venv build-essential"
    $rc = $LASTEXITCODE
} catch { $rc = $LASTEXITCODE }
$ErrorActionPreference = $oldEap
if ($rc -ne 0) { Write-Err "WSL tooling install failed (exit code $rc)"; exit $rc }
Write-Ok "WSL tooling present."

# Create the default Linux user idempotently with an EMPTY password and passwordless sudo,
# and set it as the WSL default user.
#
# WHY EMPTY PASSWORD: WSL auto-login (wsl.conf [user] default=<user>) needs an account that
# WSL can log into without a prompt. A personal workstation box gets one-command convenience
# via an empty password + passwordless sudo. This is documented (and reversible) in
# docs/WINDOWS.md; run "passwd <user>" inside WSL to set a real password if desired.
#
# The payload is built so PowerShell does NOT expand the inner shell: the only PowerShell
# variable is $u, injected by concatenation. $u is sanitized (non-alphanumerics stripped,
# lowercased, fallback 'user') before embedding, so injection is impossible.
$u = ($env:USERNAME -replace '[^a-zA-Z0-9]','').ToLower(); if ([string]::IsNullOrEmpty($u)) { $u = "user" }
$inner = "set -e; " +
  "if ! id '$u' >/dev/null 2>&1; then useradd -m -s /bin/bash '$u'; fi; " +
  "echo '$u ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/agent-harness; chmod 440 /etc/sudoers.d/agent-harness; " +
  "usermod -p '' '$u'; " +
  "if ! grep -q '^\[user\]' /etc/wsl.conf 2>/dev/null; then printf '[user]\ndefault=$u\n' >> /etc/wsl.conf; fi"
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
try {
    wsl.exe -d $Dist -u root -- bash -lc $inner
    $rc = $LASTEXITCODE
} catch { $rc = $LASTEXITCODE }
$ErrorActionPreference = $oldEap
if ($rc -ne 0) { Write-Err "Default user setup failed (exit code $rc)"; exit $rc }
Write-Ok "Default WSL user '$u' ready (empty password, passwordless sudo)."

Write-State "READY"

# ---------------------------------------------------------------
# (4) Copy this source bundle to the canonical install target
#     (Windows side, PowerShell native Copy-Item). No tar extraction
#     inside WSL: the artifacts are already part of the bundle that
#     this script ships in. Idempotent - only the first run, or
#     -Refresh (from a NEW bundle), performs the copy.
# ---------------------------------------------------------------
$wslInstallTarget = Convert-WindowsToWslPath $InstallTarget
$bundleHasInstallSh = Test-Path (Join-Path $InstallTarget "install.sh")
if ($Refresh.IsPresent -or -not $bundleHasInstallSh) {
    New-Item -ItemType Directory -Force -Path $InstallTarget | Out-Null
    Write-Step "Copying bundle to $InstallTarget ..."
    $oldEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try {
        Copy-Item -Path (Join-Path $BundleRoot "*") -Destination $InstallTarget -Recurse -Force
        $rc = $LASTEXITCODE
    } catch { $rc = $LASTEXITCODE }
    $ErrorActionPreference = $oldEap
    if ($rc -ne 0) { Write-Err "Copy of bundle failed (exit code $rc)"; exit $rc }
    Write-Ok "Bundle copied to $InstallTarget."
} else {
    Write-Warn "Existing checkout at $InstallTarget detected; re-running the installer without re-copying."
    Write-Warn "Use -Refresh (from a NEW bundle) to update."
}

# ---------------------------------------------------------------
# (5) Run the installer inside WSL (stream + surface exit code).
#     The WSL target path is single-quoted inside bash, so it is
#     made apostrophe-safe via ConvertTo-BashSingleQuoted.
# ---------------------------------------------------------------
$wslInstallTargetSq = ConvertTo-BashSingleQuoted $wslInstallTarget

# Pre-flight: confirm the Linux view of the target exists (quote-safe path).
$preExists = $false
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
try {
    wsl.exe -d $Dist -- bash -lc "test -d '$wslInstallTargetSq'"
    $preExists = ($LASTEXITCODE -eq 0)
} catch { $preExists = $false }
$ErrorActionPreference = $oldEap
if (-not $preExists) {
    Write-Err "Install target not found inside WSL: $InstallTarget"
    exit 1
}

Write-Step "Running the harness installer inside WSL..."
$code = 0
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
try {
    wsl.exe -d $Dist -- bash -lc "cd '$wslInstallTargetSq' && ./install.sh --global --target all --with-backends --no-firewall --no-obsidian --no-healthcheck --skip-warmup -y"
    $code = $LASTEXITCODE
} catch {
    $code = -1
}
$ErrorActionPreference = $oldEap
Write-Host ""
if ($code -ne 0) {
    Write-Err "install.sh exited with code $code"
    exit $code
}
Write-Ok "install.sh completed successfully."

# ---------------------------------------------------------------
# (6) Final summary
# ---------------------------------------------------------------
Write-Host ""
Write-Host "agent-harness v0.7.1 install complete." -ForegroundColor Green
Write-Host ""
Write-Host "What was installed:" -ForegroundColor Cyan
Write-Host "  - Harness source from this bundle, copied to $InstallTarget (Windows side),"
Write-Host "    with harness state in the WSL Linux home."
Write-Host "  - WSL + $Dist, git/curl/python, and a default WSL user (empty password)."
Write-Host ""
Write-Host "How to enter WSL:" -ForegroundColor Cyan
Write-Host "  In a new PowerShell, type: wsl"
Write-Host ""
Write-Host "How to update:" -ForegroundColor Cyan
Write-Host "  Re-download the next release's source bundle, extract it, then run its"
Write-Host "    windows\install-windows.ps1 with -Refresh (re-copies over $InstallTarget)."
Write-Host ""
Write-Host "How to uninstall:" -ForegroundColor Cyan
Write-Host "  - Windows side: remove the checkout dir ($InstallTarget)."
Write-Host "  - WSL: remove ~/.config/opencode*, ~/.local/share/opencode-sglang-stack, ~/.orchestration"
Write-Host "  - Optional: wsl.exe --unregister $Dist (removes the distro and its data)."
Write-Host ""
Write-Host "One-command start (re-download the source bundle, extract it, then):" -ForegroundColor Cyan
Write-Host "    powershell -NoProfile -ExecutionPolicy Bypass -File .\\agent-harness-v0.7.1\\windows\\install-windows.ps1"
Write-Host ""
exit 0
