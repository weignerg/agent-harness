#
# install-windows.ps1
# Windows 11 (WSL2) one-command install bootstrap for agent-harness (v0.7.1).
#
# TLDR:
#   1) Download the v0.7.1 release assets into ONE folder on Windows (this script,
#      agent-harness-v0.7.1-source.tar.gz, and the python sdist/wheel live there flat).
#   2) From that folder, run ONE command:
#       powershell -NoProfile -ExecutionPolicy Bypass -File .\install-windows.ps1
#   The command self-elevates, sets up WSL + Ubuntu, asks for the one mandatory reboot,
#   then (same command after reboot) extracts the pinned v0.7.1 source tarball from the
#   local bundle and runs the Linux ./install.sh inside WSL. Because the repository is
#   PRIVATE there is no anonymous install URL: the release bundle is the install medium.
#
# What it does (one paragraph):
#   This script bootstraps agent-harness on a fresh Windows 11 machine using the Windows
#   Subsystem for Linux. It elevates itself, provisions WSL and the Ubuntu distro (handling
#   the single mandatory reboot via a state marker on disk), installs git/curl/python inside
#   Ubuntu, creates a default user with an empty password and passwordless sudo so that WSL
#   can auto-login, extracts the pinned v0.7.1 source tarball from the LOCAL release bundle
#   (no git clone, because the repo is private), and finally runs the harness ./install.sh
#   inside WSL. The python sdist/wheel assets in the bundle are alternative install paths and
#   are not used by this script; the source tarball is the only code artifact consumed here.
#

param(
  [string]$BundleDir     = $PSScriptRoot,            # folder holding the downloaded release assets
  [string]$InstallTarget = "$env:USERPROFILE\agent-harness",  # Windows-side checkout dir
  [string]$Dist          = "Ubuntu",
  [switch]$Refresh       # re-extract the source tarball over an existing $InstallTarget
)

$RepoRef        = "v0.7.1"
$SourceTarballName = "agent-harness-$RepoRef-source.tar.gz"   # agent-harness-v0.7.1-source.tar.gz
$StateDir       = Join-Path $env:LOCALAPPDATA "agent-harness"
$StateFile      = Join-Path $StateDir "wsl-install.state"

$ErrorActionPreference = "Stop"

function Write-Step($msg) { Write-Host ("  => " + [string]$msg) -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host ("  [OK] " + [string]$msg)  -ForegroundColor Green }
function Write-Warn($msg) { Write-Host ("  [WARN] " + [string]$msg) -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host ("  [ERR]  " + [string]$msg) -ForegroundColor Red }

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
    # Returns $true if an Ubuntu distro is present. Distinguish the probe cases by TEXT, not
    # by exit code alone.
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

    # Case: a row like "*? Ubuntu  Stopped  2" -> Ubuntu present.
    if ($output -match '(?i)ubuntu') { return $true }
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
# Banner
# ---------------------------------------------------------------
Write-Host "agent-harness Windows (WSL) install bootstrap - v$RepoRef" -ForegroundColor Magenta
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
Write-Step ("WSL feature state: " + $featState + " ; Ubuntu present: " + $hasDistro + " ; state marker: '" + (Read-State) + "'")

if ($featState -eq "Disabled") {
    # CASE A - Fresh: enable WSL feature + install Ubuntu; a reboot is required to finish.
    Write-Step "Installing WSL + Ubuntu (this enables features + downloads kernel + distro)..."
    $oldEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { wsl.exe --install -d Ubuntu; $rc = $LASTEXITCODE } catch { $rc = $LASTEXITCODE }
    $ErrorActionPreference = $oldEap
    if ($rc -ne 0) { Write-Warn "wsl.exe --install returned exit code $rc (continuing)"; }
    Write-State "PENDING_REBOOT"
    Write-Host ""
    Write-Err "WSL + Ubuntu are being installed. A REBOOT is required to finish."
    Write-Err "Please REBOOT your machine now."
    Write-Err "After the reboot, open PowerShell in the SAME bundle folder and run the SAME command again (see the top-of-file TLDR) to continue the install."
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
        # CASE C - WSL enabled, but no Ubuntu distro yet.
        Write-Step "WSL is enabled; installing the Ubuntu distro..."
        $oldEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        try { wsl.exe --install -d Ubuntu; $rc = $LASTEXITCODE } catch { $rc = $LASTEXITCODE }
        $ErrorActionPreference = $oldEap
        if ($rc -ne 0) { Write-Warn "wsl.exe --install returned exit code $rc"; }
        # Fall through to (3) First-run setup (no reboot needed on an already-enabled WSL).
    }
    # CASE D - WSL enabled AND Ubuntu present -> fall through to (3).
}

# ---------------------------------------------------------------
# (3) First-run setup (idempotent), run as root inside WSL.
# ---------------------------------------------------------------
Write-Step "Installing WSL tooling (git, curl, python3, venv, build tools)..."
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
try {
    wsl.exe -d Ubuntu -u root -- bash -lc "export DEBIAN_FRONTEND=noninteractive; apt-get update -y && apt-get install -y git curl ca-certificates python3 python3-venv build-essential"
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
# variable is $u, injected by concatenation. There are no deliberately bash-expanded vars.
$u = ($env:USERNAME -replace '[^a-zA-Z0-9]','').ToLower(); if ([string]::IsNullOrEmpty($u)) { $u = "user" }
$inner = "set -e; " +
  "if ! id '$u' >/dev/null 2>&1; then useradd -m -s /bin/bash '$u'; fi; " +
  "echo '$u ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/agent-harness; chmod 440 /etc/sudoers.d/agent-harness; " +
  "usermod -p '' '$u'; " +
  "if ! grep -q '^\[user\]' /etc/wsl.conf 2>/dev/null; then printf '[user]\ndefault=$u\n' >> /etc/wsl.conf; fi"
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
try {
    wsl.exe -d Ubuntu -u root -- bash -lc $inner
    $rc = $LASTEXITCODE
} catch { $rc = $LASTEXITCODE }
$ErrorActionPreference = $oldEap
if ($rc -ne 0) { Write-Err "Default user setup failed (exit code $rc)"; exit $rc }
Write-Ok "Default WSL user '$u' ready (empty password, passwordless sudo)."

Write-State "READY"

# ---------------------------------------------------------------
# (4) Extract the pinned release from the LOCAL bundle inside WSL
#     (idempotent; NO git clone - the repo is private).
# ---------------------------------------------------------------
$srcTar = Join-Path $BundleDir $SourceTarballName
if (-not (Test-Path $srcTar)) {
    Write-Err "Source artifact not found: '$srcTar'."
    Write-Err "Run this installer from the folder where you downloaded the v0.7.1 release assets"
    Write-Err "(which must include agent-harness-v0.7.1-source.tar.gz), or pass -BundleDir <that-folder>."
    Write-Host ""
    Write-Host "Bundle directory contents:" -ForegroundColor Cyan
    try {
        Get-ChildItem -Path $BundleDir -ErrorAction Continue | ForEach-Object { Write-Host ("    " + $_.Name) }
    } catch {
        Write-Warn "Could not list the bundle directory."
    }
    exit 1
}

$wslTarget = Convert-WindowsToWslPath $InstallTarget
$wslSrcTar = Convert-WindowsToWslPath $srcTar

# Extract only when forced (-Refresh) or when the checkout does not exist yet. An existing,
# user-modified checkout is left intact; re-extraction requires -Refresh.
$exists = $false
if (-not $Refresh.IsPresent) {
    $oldEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { wsl.exe -d Ubuntu -- bash -lc "test -d '$wslTarget'"; $exists = ($LASTEXITCODE -eq 0) }
    catch { $exists = $false }
    $ErrorActionPreference = $oldEap
}

if ($Refresh.IsPresent -or -not $exists) {
    Write-Step "Extracting $SourceTarballName into $wslTarget (strip-components=1)..."
    $oldEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try {
        wsl.exe -d Ubuntu -- bash -lc "mkdir -p '$wslTarget' && tar -xzf '$wslSrcTar' --strip-components=1 -C '$wslTarget'"
        $rc = $LASTEXITCODE
    } catch { $rc = $LASTEXITCODE }
    $ErrorActionPreference = $oldEap
    if ($rc -ne 0) { Write-Err "Extraction failed (exit code $rc)"; exit $rc }
    Write-Ok "Source extracted into $wslTarget."
}
else {
    Write-Warn "Checkout already present at $wslTarget; skipping extraction."
    Write-Warn "Re-run with -Refresh to re-extract the pinned source."
}

# ---------------------------------------------------------------
# (5) Run the installer inside WSL (stream + surface exit code).
# ---------------------------------------------------------------
Write-Step "Running the harness installer inside WSL..."
$code = 0
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
try {
    wsl.exe -d Ubuntu -- bash -lc "cd '$wslTarget' && ./install.sh --global --target all --with-backends --no-firewall --no-obsidian --no-healthcheck --skip-warmup -y"
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
Write-Host "agent-harness v$RepoRef install complete." -ForegroundColor Green
Write-Host ""
Write-Host "What was installed:" -ForegroundColor Cyan
Write-Host "  - Harness v$RepoRef, extracted from the local bundle's $SourceTarballName"
Write-Host "    into $InstallTarget (Windows side), with harness state in the WSL Linux home."
Write-Host "  - WSL + Ubuntu, git/curl/python, and a default WSL user (empty password)."
Write-Host ""
Write-Host "How to enter WSL:" -ForegroundColor Cyan
Write-Host "  In a new PowerShell, type: wsl"
Write-Host ""
Write-Host "How to update:" -ForegroundColor Cyan
Write-Host "  Download the next release's assets into a fresh folder and run, from that folder:"
Write-Host "    powershell -NoProfile -ExecutionPolicy Bypass -File .\install-windows.ps1 -Refresh"
Write-Host ""
Write-Host "How to uninstall:" -ForegroundColor Cyan
Write-Host "  - Windows side: remove the checkout dir ($InstallTarget)."
Write-Host "  - WSL: remove ~/.config/opencode*, ~/.local/share/opencode-sglang-stack, ~/.orchestration"
Write-Host "  - Optional: wsl.exe --unregister Ubuntu (removes the Ubuntu distro and its data)."
Write-Host ""
Write-Host "The release bundle (sdist + wheel) also offers pure-Python install paths; this script"
Write-Host "uses the source tarball so the private repo never needs a git clone."
Write-Host ""
Write-Host "One-command start (re-download the bundle, then):" -ForegroundColor Cyan
Write-Host "    powershell -NoProfile -ExecutionPolicy Bypass -File .\install-windows.ps1"
Write-Host ""
exit 0
