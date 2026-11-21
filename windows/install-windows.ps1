#
# install-windows.ps1
# Windows 10/11 (WSL2) self-extracting install bootstrap for agent-harness (v0.7.2).
#
# TLDR:
#   1) Download install-agent-harness-v0.7.2-windows10-11.ps1 from the release page
#      (https://github.com/weignerg/agent-harness/releases).
#   2) Run ONE command:
#      powershell -NoProfile -ExecutionPolicy Bypass -File .\install-agent-harness-v0.7.2-windows10-11.ps1
#   The command self-elevates, provisions WSL2 + Ubuntu (with systemd persistence and
#   Task Scheduler auto-resume across the one mandatory reboot), decodes and checksum-
#   verifies its embedded base64(tar.gz) runtime payload, extracts it into
#   $env:USERPROFILE\agent-harness via WSL, and runs the embedded Linux ./install.sh.
#   Because the repository is PRIVATE there is no anonymous install URL: this single
#   self-extracting script IS the install medium (no git clone / remote fetch anywhere).
#
# What it does (one paragraph):
#   This script is the Windows/WSL2 bootstrap wrapped by release-build/make_windows_installer.ps1
#   into the self-extracting install-agent-harness-v0.7.2-windows10-11.ps1 artifact. It
#   elevates itself, provisions WSL2 and the Ubuntu distro (handling the single mandatory
#   reboot via a state marker and logon auto-resume task), installs git/curl/python inside
#   Ubuntu, configures a default Linux user and [boot] systemd=true in /etc/wsl.conf,
#   decodes + SHA-256 verifies its embedded base64(tar.gz) payload with .NET, extracts it
#   into $InstallTarget inside WSL, and finally runs the embedded ./install.sh inside WSL.
#   Every runtime file comes from the embedded payload; there is no remote fetch or git clone.
#

param(
  [string]$InstallTarget = "$env:USERPROFILE\agent-harness",  # canonical harness runtime dir
  [string]$Dist          = "Ubuntu",                          # WSL distro
  [switch]$Refresh,                                            # re-extract embedded payload over an existing $InstallTarget (update flow)
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
        $prevWslUtf8 = $env:WSL_UTF8
        try {
            $env:WSL_UTF8 = "1"
            try { $listTxt  = wsl.exe -l -v     2>&1 | Out-String; $listCode  = $LASTEXITCODE }
            catch { $listCode  = [int]$_.Exception.HResult }
            try { $statusTxt = wsl.exe --status 2>&1 | Out-String; $statusC  = $LASTEXITCODE }
            catch { $statusC  = [int]$_.Exception.HResult }
        } finally {
            if ($null -eq $prevWslUtf8) { Remove-Item Env:WSL_UTF8 -ErrorAction SilentlyContinue }
            else { $env:WSL_UTF8 = $prevWslUtf8 }
        }
        $blob = ($listTxt + "`r`n" + $statusTxt)
        if ($listCode  -ne 0 -or $statusC  -ne 0) {
            $rc = [int](if ($listCode -ne 0) { $listCode } else { $statusC })
            $rcUnsigned = [BitConverter]::ToUInt32([BitConverter]::GetBytes($rc), 0)
            $errHex = ('0x{0:X8}' -f $rcUnsigned)
        }
    }

    # Strip embedded NUL bytes emitted when Windows PowerShell 5.1 captures UTF-16LE wsl.exe output.
    $blob = $blob -replace "`0", ""

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

    # Match each row's instance NAME = the first whitespace-delimited token (the distro
    # column), stripping surrounding double quotes from a quoted/renamed instance. Exact
    # token match wins; a case-insensitive substring match is kept only as a lenient
    # fallback so a distro name that the user configured is never missed (no false
    # negative). NOTE: this means "Ubuntu" still matches a renamed "Ubuntu-22.04"; that is
    # the intentional lenient behavior called for by the kickoff.
    $tokens = foreach ($n in $names) {
        $tok = ($n -split '\s+', 2)[0]               # instance name = first column token
        if ($tok -match '^"(.*)"$') { $tok = $Matches[1] }  # strip surrounding quotes
        $tok
    }
    # Pass 1: exact (case-insensitive) instance-name match.
    foreach ($t in $tokens) { if ($t -ieq $Dist) { $present = $true; break } }
    # Pass 2: lenient case-insensitive substring fallback, only if no exact hit.
    if (-not $present) {
        foreach ($t in $tokens) {
            if ($t.IndexOf($Dist, [StringComparison]::InvariantCultureIgnoreCase) -ge 0) { $present = $true; break }
        }
    }

    return @{ present=$present; missing=(-not $present);
              status = if ($present) { "$Dist present" } else { "$Dist absent (recommend install)" };
              code   = $errHex }
}

function Convert-WindowsToWslPath($winPath) {
    # C:\Users\X\agent-harness -> /mnt/c/Users/X/agent-harness
    if ($winPath -notmatch '^[A-Za-z]:\\') { return $winPath }
    $drive = $winPath.Substring(0,1).ToLower()
    $rest  = $winPath.Substring(2).Replace('\','/').TrimStart('/')
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
function Format-SelfInvocationArgs {
    param(
        [string]$ScriptPath,
        [hashtable]$BoundParams = @{}
    )
    $quoteWinArg = {
        param([string]$s)
        # Double backslashes immediately before quotes or end-of-string (CommandLineToArgvW).
        $escaped = [regex]::Replace($s, '(\\*)"', '$1$1\"')
        $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
        return ('"' + $escaped + '"')
    }
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add("-NoProfile")
    $parts.Add("-ExecutionPolicy")
    $parts.Add("Bypass")
    $parts.Add("-File")
    $parts.Add((& $quoteWinArg $ScriptPath))
    foreach ($key in ($BoundParams.Keys | Sort-Object)) {
        $val = $BoundParams[$key]
        if ($val -is [System.Management.Automation.SwitchParameter]) {
            if ($val.IsPresent) {
                $parts.Add("-$key")
            }
        } elseif ($null -ne $val) {
            $parts.Add("-$key")
            $parts.Add((& $quoteWinArg ([string]$val)))
        }
    }
    return ($parts -join " ")
}

function Register-WslInstallResume {
    try {
        $name = "agent-harness-wsl-install-resume"
        $psBin = Join-Path $env:windir "System32\WindowsPowerShell\v1.0\powershell.exe"
        $selfPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
        $workDir  = if ($selfPath) { Split-Path -Parent $selfPath } else { (Get-Location).Path }
        $arg   = Format-SelfInvocationArgs -ScriptPath $selfPath -BoundParams $script:InitialBoundParams
        $act   = New-ScheduledTaskAction  -Execute $psBin -Argument $arg -WorkingDirectory $workDir
        $trig  = New-ScheduledTaskTrigger  -AtLogOn
        $user  = ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
        # -RunLevel Highest is the canonical privilege; New-ScheduledTaskPrincipal has no
        # -RequirePrivilege parameter, so omit it (passing it threw and silently skipped
        # registration, defeating the post-reboot auto-resume feature).
        $princ = New-ScheduledTaskPrincipal -UserId $user -RunLevel Highest
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

function Get-EmbeddedPayload {
    param([string]$ScriptPath)
    if ([string]::IsNullOrWhiteSpace($ScriptPath) -or -not (Test-Path -LiteralPath $ScriptPath)) {
        return @{ found = $false; payloadB64 = ""; expectedSha = "" }
    }
    $lines = [System.IO.File]::ReadAllLines($ScriptPath)
    $marker = "#" + "__HARNESS_PKG_EOF__"
    $expectedSha = ""
    $markerIdx = -1
    for ($k = 0; $k -lt $lines.Count; $k++) {
        if ($lines[$k] -match '^# HARNESS_PAYLOAD_SHA256=([0-9a-fA-F]{64})$') {
            $expectedSha = $Matches[1].ToLowerInvariant()
        }
        if ($lines[$k] -ceq $marker) {
            $markerIdx = $k
            break
        }
    }
    if ($markerIdx -lt 0) {
        return @{ found = $false; payloadB64 = ""; expectedSha = $expectedSha }
    }
    $b64Lines = New-Object System.Collections.Generic.List[string]
    for ($j = $markerIdx + 1; $j -lt $lines.Count; $j++) {
        if ($lines[$j] -ceq "#>") { break }
        if (-not [string]::IsNullOrWhiteSpace($lines[$j])) {
            $b64Lines.Add($lines[$j].Trim())
        }
    }
    if ($b64Lines.Count -eq 0) {
        return @{ found = $false; payloadB64 = ""; expectedSha = $expectedSha }
    }
    return @{
        found       = $true
        payloadB64  = ($b64Lines -join "`n")
        expectedSha = $expectedSha
    }
}

function Resolve-VerifiedEmbeddedPayload {
    param([string]$ScriptPath)
    $info = Get-EmbeddedPayload -ScriptPath $ScriptPath
    if (-not $info.found) {
        throw "No embedded runtime payload found in this script (missing '#__HARNESS_PKG_EOF__' sentinel)."
    }
    if ([string]::IsNullOrWhiteSpace($info.expectedSha) -or ($info.expectedSha -notmatch '^[0-9a-f]{64}$')) {
        throw "Missing or malformed embedded '# HARNESS_PAYLOAD_SHA256=<64-hex>' header; refusing to proceed."
    }
    $bytes = [Convert]::FromBase64String($info.payloadB64)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $actualSha = -join (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }))
    } finally {
        $sha.Dispose()
    }
    if ($actualSha -ne $info.expectedSha) {
        throw ("Embedded payload SHA-256 mismatch (expected=$($info.expectedSha) actual=$actualSha); refusing to proceed.")
    }
    return @{
        bytes  = $bytes
        sha256 = $actualSha
    }
}

# Capture top-level CLI parameters so self-elevation and post-reboot resume preserve flags (e.g. -Refresh).
$script:InitialBoundParams = @{}
foreach ($kv in $PSBoundParameters.GetEnumerator()) {
    $script:InitialBoundParams[$kv.Key] = $kv.Value
}

# ---------------------------------------------------------------
# Embedded payload pre-check & SHA-256 verification (FAIL-CLOSED):
# Runs BEFORE UAC elevation, WSL mutations, or extraction so a
# corrupted/unbuilt script fails fast without mutating the host.
# ---------------------------------------------------------------
$ScriptSelfPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
try {
    $VerifiedPayload = Resolve-VerifiedEmbeddedPayload -ScriptPath $ScriptSelfPath
} catch {
    Write-Err $_.Exception.Message
    Write-Err "  1) Download install-agent-harness-v0.7.2-windows10-11.ps1 from the release page, or"
    Write-Err "     build it from a checkout with: pwsh -NoProfile -File release-build/make_windows_installer.ps1"
    Write-Err "  2) Then run:"
    Write-Err "        powershell -NoProfile -ExecutionPolicy Bypass -File .\install-agent-harness-v0.7.2-windows10-11.ps1"
    exit 1
}

# ---------------------------------------------------------------
# Banner
# ---------------------------------------------------------------
Write-Host "agent-harness Windows (WSL2) self-extracting install bootstrap - v0.7.2" -ForegroundColor Magenta
Write-Host "-------------------------------------------------------------"
Write-Host
Write-Ok ("Embedded payload SHA-256 verified (" + $VerifiedPayload.sha256.Substring(0, 12) + "...).")

# ---------------------------------------------------------------
# (1) Admin check / self-elevate (forwards all CLI parameters, incl. -Refresh)
# ---------------------------------------------------------------
if (-not (Test-IsAdmin)) {
    Write-Warn "Admin rights required - relaunching elevated..."
    $scriptPath = $ScriptSelfPath
    if (-not $scriptPath) { $scriptPath = Join-Path (Get-Location).Path "install-agent-harness-v0.7.2-windows10-11.ps1" }
    $argList = Format-SelfInvocationArgs -ScriptPath $scriptPath -BoundParams $script:InitialBoundParams
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
Write-Step ("WSL feature state: " + $featState + " ; " + $Dist + " present: " + $hasDistro.present + " ; " + $hasDistro.status + " ; state marker: '" + (Read-State) + "'")

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
    Write-Err "After the reboot, this installer will resume automatically on login (or re-run the SAME self-extracting artifact)."
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
    if (-not $hasDistro.present) {
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

if (-not $Quiet) {
    $wantPw = [bool]$SetPassword
    if (-not $wantPw -and (-not $userExists)) {
        $ans = Read-Host "Set a Linux password? [y/N (Enter = leave empty)]"
        $wantPw = ($ans -and ($ans.Trim().ToLower() -match '^(y|yes)$'))
    }
    if ($wantPw) {
        $ss = Read-Host -AsSecureString "Type the Linux password, then Enter"
        $b  = [System.Runtime.InteropServices.Marshal]::SecureStringToBString($ss)
        try {
            $plainPw = [System.Runtime.InteropServices.Marshal]::PtrToStringBString($b)
            $pwFile = Join-Path $env:TEMP ("agent-harness-pw-" + [Guid]::NewGuid().ToString("N"))
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($pwFile, ($safeUser + ":" + $plainPw + "`n"), $utf8NoBom)
            $plainPw = $null
            # Resolve the Windows-side temp path to the WSL view so the bash payload below
            # (running inside WSL) can actually locate and read the staged password.
            $pwFileWslSq = ConvertTo-BashSingleQuoted (Convert-WindowsToWslPath $pwFile)
        } finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBString($b) }
        $pwInject = "if [ -f '$pwFileWslSq' ]; then chmod 600 '$pwFileWslSq' && chpasswd < '$pwFileWslSq'; rm -f '$pwFileWslSq'; fi; "
    }
    if (-not $userExists) {
        $s = Read-Host "Give '$safeUser' passwordless sudo? [y/N]"
        $sudoOK = (-not [bool]$NoSudo) -and ($s -and $s.Trim().ToLower() -match '^(y|yes)$')
    } else {
        $sudoOK = -not [bool]$NoSudo
    }
} else {
    $sudoOK = -not [bool]$NoSudo
}

# Record the chosen profile for later reference (does not affect resume token logic).
try {
    if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }
    Set-Content -Path (Join-Path $StateDir "profile") -Value $profile -Force -ErrorAction SilentlyContinue
} catch { }

$sudoFlag = if ($sudoOK) { "1" } else { "0" }   # PowerShell substitutes literal 1/0 (injection-safe)
# Only clear the password on newly-created users when no password was requested; never wipe
# an existing user's password on re-run or -Refresh.
$pwStep = if ($pwInject) {
    $pwInject
} elseif (-not $userExists) {
    "usermod -p '' '$safeUser'; "
} else {
    ""
}

$inner = "set -e; " +
  "if ! id '$safeUser' >/dev/null 2>&1; then useradd -m -s /bin/bash '$safeUser'; fi; " +
  "usermod -aG sudo '$safeUser'; " +
  "if [ `"$sudoFlag`" = 1 ]; then echo '$safeUser ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/agent-harness; chmod 440 /etc/sudoers.d/agent-harness; fi; " +
  $pwStep +
  "if [ ! -f /etc/wsl.conf ]; then : > /etc/wsl.conf; fi; " +
  "if grep -q '^\[boot\]' /etc/wsl.conf 2>/dev/null; then " +
    "if grep -q '^[[:space:]]*systemd[[:space:]]*=' /etc/wsl.conf 2>/dev/null; then " +
      "sed -i 's/^[[:space:]]*systemd[[:space:]]*=.*/systemd=true/' /etc/wsl.conf; " +
    "else " +
      "sed -i '/^\[boot\]/a systemd=true' /etc/wsl.conf; " +
    "fi; " +
  "else " +
    "printf '\n[boot]\nsystemd=true\n' >> /etc/wsl.conf; " +
  "fi; " +
  "grep -q '^\[user\]' /etc/wsl.conf 2>/dev/null || printf '\n[user]\ndefault=$safeUser\n' >> /etc/wsl.conf"

# Backwards-compatible alias for the downstream success message.
$u = $safeUser
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
try {
    wsl.exe -d $Dist -u root -- bash -lc $inner
    $rc = $LASTEXITCODE
} catch { $rc = $LASTEXITCODE }
finally {
    if ($pwFile -and (Test-Path -LiteralPath $pwFile)) {
        Remove-Item -LiteralPath $pwFile -Force -ErrorAction SilentlyContinue
    }
}
$ErrorActionPreference = $oldEap
if ($rc -ne 0) { Write-Err "Default user setup failed (exit code $rc)"; exit $rc }
Write-Ok "Default WSL user '$u' ready (systemd enabled)."

# Force WSL up fresh so the new /etc/wsl.conf [boot] systemd=true takes effect on the
# next launch (the running distro otherwise keeps its stale boot config). --shutdown is
# idempotent and safe when WSL is already down.
wsl.exe --shutdown

Write-State "READY"
# Install reached READY: the post-reboot auto-resume task is no longer needed.
Unregister-WslInstallResume

# ---------------------------------------------------------------
# (4) Self-extract the verified base64(tar.gz) runtime payload to
#     $InstallTarget via WSL tar. Payload was already decoded and
#     SHA-256 verified (fail-closed) at startup before any mutations.
#     Idempotent: skipped if already extracted unless -Refresh is passed.
# ---------------------------------------------------------------
$wslInstallTarget   = Convert-WindowsToWslPath $InstallTarget
$wslInstallTargetSq = ConvertTo-BashSingleQuoted $wslInstallTarget
$bundleHasInstallSh = Test-Path (Join-Path $InstallTarget "install.sh")
if ($Refresh.IsPresent -or -not $bundleHasInstallSh) {
    if (-not $VerifiedPayload -or -not $VerifiedPayload.bytes) {
        $VerifiedPayload = Resolve-VerifiedEmbeddedPayload -ScriptPath $ScriptSelfPath
    }
    $payloadBytes = $VerifiedPayload.bytes

    New-Item -ItemType Directory -Force -Path $InstallTarget | Out-Null
    $tempPkg = Join-Path ([System.IO.Path]::GetTempPath()) ("agent-harness-pkg-" + [Guid]::NewGuid().ToString("N") + ".tar.gz")
    [System.IO.File]::WriteAllBytes($tempPkg, $payloadBytes)
    $wslTempPkgSq = ConvertTo-BashSingleQuoted (Convert-WindowsToWslPath $tempPkg)

    Write-Step "Extracting embedded runtime tree to $InstallTarget ..."
    $oldEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    $rc = 1
    try {
        $extractCmd = "rm -rf '$wslInstallTargetSq/harness' '$wslInstallTargetSq/config' '$wslInstallTargetSq/scripts' '$wslInstallTargetSq/core' '$wslInstallTargetSq/install.sh' && tar -xzf '$wslTempPkgSq' -C '$wslInstallTargetSq'"
        wsl.exe -d $Dist -- bash -lc $extractCmd
        $rc = $LASTEXITCODE
    } catch {
        $rc = if ($LASTEXITCODE) { $LASTEXITCODE } else { 1 }
    } finally {
        if (Test-Path -LiteralPath $tempPkg) {
            Remove-Item -LiteralPath $tempPkg -Force -ErrorAction SilentlyContinue
        }
    }
    $ErrorActionPreference = $oldEap
    if ($rc -ne 0) { Write-Err "Payload extraction failed (exit code $rc)"; exit $rc }
    Write-Ok "Runtime tree extracted to $InstallTarget."
} else {
    Write-Warn "Existing runtime tree at $InstallTarget detected; re-running the installer without re-extracting."
    Write-Warn "Use -Refresh (with a newer self-extracting artifact) to update."
}

# ---------------------------------------------------------------
# (5) Run the installer inside WSL (stream + surface exit code).
#     The WSL target path is single-quoted inside bash, so it is
#     made apostrophe-safe via ConvertTo-BashSingleQuoted.
#     Pin AGENT_HARNESS_CANONICAL_ROOT and invoke `bash ./install.sh`
#     so DrvFS execute-bit issues and unrelated parent .git repos
#     cannot break execution or canonical repo resolution.
# ---------------------------------------------------------------

# Pre-flight: confirm the Linux view of the target exists (quote-safe path).
$preExists = $false
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
try {
    wsl.exe -d $Dist -- bash -lc "test -d '$wslInstallTargetSq' && test -f '$wslInstallTargetSq/install.sh'"
    $preExists = ($LASTEXITCODE -eq 0)
} catch { $preExists = $false }
$ErrorActionPreference = $oldEap
if (-not $preExists) {
    Write-Err "Install target or install.sh not found inside WSL: $InstallTarget"
    exit 1
}

Write-Step "Running the harness installer inside WSL..."
$code = 0
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
try {
    wsl.exe -d $Dist -- bash -lc "cd '$wslInstallTargetSq' && AGENT_HARNESS_CANONICAL_ROOT='$wslInstallTargetSq' bash ./install.sh --global --target all --with-backends --no-firewall --no-obsidian --skip-warmup -y"
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
Write-Host "agent-harness v0.7.2 install complete." -ForegroundColor Green
Write-Host ""
Write-Host "What was installed:" -ForegroundColor Cyan
Write-Host "  - Embedded harness runtime tree extracted to $InstallTarget (Windows side),"
Write-Host "    with harness state in the WSL Linux home."
Write-Host "  - WSL + $Dist (systemd enabled), git/curl/python, and default WSL user '$u'."
Write-Host ""
Write-Host "How to enter WSL:" -ForegroundColor Cyan
Write-Host "  In a new PowerShell, type: wsl"
Write-Host ""
Write-Host "How to update:" -ForegroundColor Cyan
Write-Host "  Download the next release's self-extracting installer and run it with -Refresh"
Write-Host "    (re-extracts the embedded runtime tree over $InstallTarget)."
Write-Host ""
Write-Host "How to uninstall:" -ForegroundColor Cyan
Write-Host "  - Windows side: remove the runtime dir ($InstallTarget)."
Write-Host "  - WSL: remove ~/.config/opencode*, ~/.local/share/opencode-sglang-stack, ~/.orchestration"
Write-Host "  - Optional: wsl.exe --unregister $Dist (removes the distro and its data)."
Write-Host ""
Write-Host "One-command start (download install-agent-harness-v0.7.2-windows10-11.ps1, then):" -ForegroundColor Cyan
Write-Host "    powershell -NoProfile -ExecutionPolicy Bypass -File .\install-agent-harness-v0.7.2-windows10-11.ps1"
Write-Host ""
exit 0
