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
  [switch]$Refresh,                                            # re-copy this bundle over an existing $InstallTarget (update flow)
  [string]$Profile   = "quick",   # quick | full | manual  (recorded feature set; install.sh has no profile flag)
  [string]$LinuxUser = "user",    # Linux login name; defaults to sanitized $env:USERNAME
  [switch]$SetPassword,           # if set, prompt for + apply a Linux password (else empty-password convenience)
  [switch]$NoSudo,                # if set, skip passwordless sudo (account still created)
  [switch]$Quiet                  # non-interactive: never prompt, use all defaults
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
    param(
        # When supplied, parse this directly instead of invoking wsl.exe. Tests use this to
        # feed representative `wsl.exe -l` output so the detection logic is unit-testable on
        # non-Windows hosts. $null => query the live system.
        [string]$RawOutput = $null
    )

    # Returns a hashtable: { present=$false missing=$false status="<text>" code="<0x..>" }.
    #  present = case-insensitive match of $Dist in the *exact* instance-name list.
    #  missing = !(present); $true => it is safe to recommend `wsl.exe --install -d $Dist`.
    #  code    = a WSL 0x80070xxx code surfaced VERBATIM, or "" if none.
    $present = $false
    $errHex  = ""

    if (-not [string]::IsNullOrEmpty($RawOutput)) {
        $blob = $RawOutput
    }
    else {
        $listTxt  = $null; $listCode  = 0
        $statusTxt = $null; $statusC  = 0
        try { $listTxt  = wsl.exe -l --list  2>&1 | Out-String; $listCode  = $LASTEXITCODE }
        catch { $listCode  = [UInt32]$_.Exception.HResult }
        try { $statusTxt = wsl.exe --status  2>&1 | Out-String; $statusC  = $LASTEXITCODE }
        catch { $statusC  = [UInt32]$_.Exception.HResult }
        $blob = ($listTxt + "`r`n" + $statusTxt)
        if ($listCode  -ne 0 -or $statusC  -ne 0) {
            $rc = if ($listCode  -ne 0) { $listCode } else { $statusC }
            $errHex = ('0x{0:X8}' -f ([UInt32]$rc))
        }
    }

    # Surface any 0x80070xxx WSL error code from the output VERBATIM.
    if ($errHex -eq "" -and ($blob -match '(0x80[0-9a-fA-F]{6})')) { $errHex = $Matches[0] }

    # WSL not ready / no distros  => "missing", recommend install, surface any hex code.
    if ($blob -match '0x8007019e|0x80370102|Windows Subsystem for Linux has no installed distributions') {
        return @{ present=$false; missing=$true; status="WSL not ready"; code=$errHex }
    }
    if ([string]::IsNullOrWhiteSpace($blob.Trim())) {
        return @{ present=$false; missing=$true; status="WSL not installed"; code=$errHex }
    }
    if ($blob -match 'no installed distributions') {
        return @{ present=$false; missing=$true; status="WSL installed; no distros"; code=$errHex }
    }

    # Normalise instance names: drop header rows, leading "*"/"*?" status markers, and a
    # trailing "?". Then match against $Dist (case-insensitive).
    $names = ($blob -split "`r?`n") | ForEach-Object { $_.Trim() } `
                  | ForEach-Object { $_ -replace '^\*[?]?\s+','' }   # drop "*?"/"*" marker prefix
                  | ForEach-Object { $_ -replace '\?\s*$','' }          # ignore trailing "?"
                  | Where-Object { $_ -and $_ -notmatch '^(NAME|Version|version|Downloading|Installing|---|—|)$' }

    # Pass 1: exact (case-insensitive) instance-name match.
    foreach ($n in $names) { if ($n -ieq $Dist) { $present = $true; break } }
    # Pass 2: case-insensitive substring match is AUTHORITATIVE (kickoff), only if no exact hit.
    if (-not $present) {
        foreach ($n in $names) {
            if ($n.IndexOf($Dist, [StringComparison]::InvariantCultureIgnoreCase) -ge 0) { $present = $true; break }
        }
    }

    return @{ present=$present; missing=(-$present);
              status = if ($present) { "$Dist present" } else { "$Dist absent (recommend install)" };
              code   = $errHex }
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
# Auto-resume after reboot: register an "at logon" Task Scheduler task
# that re-invokes THIS script (idempotent; ReRegister overwrites any
# existing task of the same name). Registered in CASE A before the
# mandatory reboot; removed once the install reaches READY.
# ---------------------------------------------------------------
function Register-WslInstallResume {
    try {
        $name = "agent-harness-wsl-install-resume"
        $psBin = Join-Path $env:windir "System32\WindowsPowerShell\v1.0\powershell.exe"
        $arg   = "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`""
        $act   = New-ScheduledTaskAction  -Execute $psBin -Argument $arg -WorkingDirectory $BundleRoot
        $trig  = New-ScheduledTaskTrigger  -AtLogOn
        $user  = ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
        $princ = New-ScheduledTaskPrincipal -UserId $user -RunLevel Highest -RequirePrivilege $false
        Register-ScheduledTask -TaskName $name -Action $act -Trigger $trig `
                               -Principal $princ -Description "Resume agent-harness WSL install after login." `
                               -Force | Out-Null
        Write-Ok "Auto-resume registered: after reboot, on your next log-in this setup continues automatically."
    } catch {
        Write-Warn "Auto-resume registration skipped: $($_.Exception.Message)"
    }
}

function Unregister-WslInstallResume {
    $name = "agent-harness-wsl-install-resume"
    try {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop | Out-Null
        Write-Ok "Auto-resume task removed (install finished)."
    } catch {
        # Not an error if the task was never registered / already gone.
    }
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
    Register-WslInstallResume
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
# ---------------------------------------------------------------
# (3b) First-run identity. INTERACTIVE, and DECOUPLED from the Windows
#      login ($env:USERNAME): the Linux user can differ from the Windows
#      account. Prompts only when the target Linux user does NOT already
#      exist, so (a) a fresh box is asked (typically on the post-reboot
#      resume run, immediately before the user is created) and (b) later
#      re-runs are SILENT (user already present) -> non-interactive resume.
#      "-Quiet" never prompts. The Profile choice is recorded to the state
#      dir (install.sh has no profile flag). Password is staged in a 0600
#      temp file so it never appears on a command line.
# ---------------------------------------------------------------
$profile = if ($Quiet) { "quick" } else { ($Profile.ToLower()) }
if ($profile -notin @("quick", "full", "manual")) { $profile = "quick" }

# Preferred Linux login: explicit -LinuxUser, else sanitized $env:USERNAME, else 'user'.
if ($Quiet) {
    $linuxUser = $LinuxUser
} else {
    $prompted = Read-Host "Linux username [$($LinuxUser)]"
    $linuxUser = if ($prompted) { $prompted } else { $LinuxUser }
}
$safeUser = ($linuxUser -replace '[^a-zA-Z0-9]', '').ToLower()
if ([string]::IsNullOrEmpty($safeUser)) { $safeUser = "user" }

# Does the Linux user already exist? (Skip prompting / creation-work if so.)
$pwFile = ""
$pwInject = ""
$userExists = $false
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
try {
    wsl.exe -d $Dist -- bash -lc "id '$safeUser' >/dev/null 2>&1"
    $userExists = ($LASTEXITCODE -eq 0)
} catch { $userExists = $false }
$ErrorActionPreference = $oldEap

if (-not $userExists -and (-not $Quiet)) {
    $ans = Read-Host "Set a Linux password? [Enter = leave empty (convenience)]"
    if ($ans) {
        $ss = Read-Host -AsSecureString "Type the Linux password, then Enter"
        $b  = [System.Runtime.InteropServices.Marshal]::SecureStringToBString($ss)
        try {
            $pwFile = Join-Path $env:TEMP ("agent-harness-pw-" + [Guid]::NewGuid().ToString("N"))
            [File]::WriteAllText($pwFile, [System.Runtime.InteropServices.Marshal]::PtrToStringBString($b))
        } finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBString($b) }
        $pwInject = "; [ -f '$pwFile' ] && chmod 600 '$pwFile' && chpasswd < '$pwFile'; rm -f '$pwFile'; "
    }
    $s = Read-Host "Give '$safeUser' passwordless sudo? [y/N]"
    $sudoOK = (-not [bool]$NoSudo) -and ($s -and $s.Trim().ToLower() -eq 'y')
} else {
    $sudoOK = -not [bool]$NoSudo
}

# Record the chosen profile for later reference (does not affect resume token logic).
try {
    if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }
    Set-Content -Path (Join-Path $StateDir "profile") -Value $profile -Force -ErrorAction SilentlyContinue
} catch { }

$sudoFlag = if ($sudoOK) { "1" } else { "0" }   # PowerShell substitutes literal 1/0 (injection-safe)

$inner = "set -e; " +
  "if ! id '$safeUser' >/dev/null 2>&1; then useradd -m -s /bin/bash '$safeUser'; fi; " +
  "usermod -aG sudo '$safeUser'; " +
  "if [ $sudoFlag ] = 1; then echo '$safeUser ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/agent-harness; chmod 440 /etc/sudoers.d/agent-harness; fi; " +
  "usermod -p '' '$safeUser'; " +               # empty password is the default convenience
  $pwInject +
  "if [ ! -f /etc/wsl.conf ]; then : > /etc/wsl.conf; fi; " +
  "grep -q '^\\[boot\\]' /etc/wsl.conf 2>/dev/null || printf '[boot]\nsystemd=true\n'  >> /etc/wsl.conf; " +
  "grep -q '^\\[user\\]' /etc/wsl.conf 2>/dev/null || printf '[user]\ndefault=$safeUser\n' >> /etc/wsl.conf"

# Backwards-compatible alias for the downstream success message.
$u = $safeUser
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
try {
    wsl.exe -d $Dist -u root -- bash -lc $inner
    $rc = $LASTEXITCODE
} catch { $rc = $LASTEXITCODE }
$ErrorActionPreference = $oldEap
if ($rc -ne 0) { Write-Err "Default user setup failed (exit code $rc)"; exit $rc }
Write-Ok "Default WSL user '$u' ready (empty password, passwordless sudo)."

# Force WSL up fresh so the new /etc/wsl.conf [boot] systemd=true takes effect on the
# next launch (the running distro otherwise keeps its stale boot config). --shutdown is
# idempotent and safe when WSL is already down.
wsl.exe --shutdown

Write-State "READY"
# Install reached READY: the post-reboot auto-resume task is no longer needed.
Unregister-WslInstallResume

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
    wsl.exe -d $Dist -- bash -lc "cd '$wslInstallTargetSq' && ./install.sh --global --target all --with-backends --no-firewall --no-obsidian --skip-warmup -y"
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
