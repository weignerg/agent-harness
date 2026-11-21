#Requires -Version 7.0
# ==============================================================================
# make_windows_installer.ps1  --  build the self-extracting Windows/WSL installer.
#
#   Output  : <OutputDir>/install-agent-harness-v0.7.1-windows10-11.ps1
#             (default: <repo>/dist)
#   Layout  : [windows/install-windows.ps1 WSL + self-extract bootstrap]
#             + '<#'
#             + '# HARNESS_PAYLOAD_SHA256=<hex>'
#             + '#__HARNESS_PKG_EOF__'   (sentinel marker)
#             + base64( tar.gz( payload ) )
#             + '#>'
#   Payload : harness config scripts core install.sh
#             (windows/install-windows.ps1 is the outer self-extracting script)
#   On run  : provisions WSL2/Ubuntu/systemd/identity/auto-resume, decodes the
#             embedded base64(tar.gz) payload with .NET, verifies SHA-256 BEFORE
#             extraction, writes tar.gz to %TEMP%, converts via
#             Convert-WindowsToWslPath, extracts via `wsl.exe ... tar -xzf`,
#             and executes the embedded install.sh.
#   Excludes: .git, build/, .venv, uv.lock, tests/, release-build/, __pycache__.
#   Builder scripts are NOT shipped inside the artifact.
# ==============================================================================
[CmdletBinding()]
param(
    [string]$OutputDir = ""
)

$ErrorActionPreference = "Stop"

$here     = $PSScriptRoot
$repoRoot = (Resolve-Path (Join-Path $here "..")).Path
$version  = "v0.7.1"
$outName  = "install-agent-harness-${version}-windows10-11.ps1"

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $repoRoot "dist"
}
if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
}
$outPath = Join-Path $OutputDir $outName

# Runtime tree embedded in the self-extracting artifact.
$payloadPaths = @("harness", "config", "scripts", "core", "install.sh")

# Build the gzip payload with tar (tar.exe on Windows 10/11, GNU tar on Linux).
$gz = Join-Path ([System.IO.Path]::GetTempPath()) ("ahpkg-" + [Guid]::NewGuid().ToString("N") + ".tar.gz")
$tarArgs = @(
    "-czf", $gz,
    "--exclude=__pycache__",
    "--exclude=*.pyc",
    "--exclude=*.pyo",
    "--exclude=.DS_Store",
    "--exclude=.git",
    "--exclude=build",
    "--exclude=.venv",
    "--exclude=uv.lock",
    "--exclude=tests",
    "--exclude=release-build",
    "-C", $repoRoot
) + $payloadPaths

try {
    & tar @tarArgs
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $gz)) {
        throw "make_windows_installer.ps1: tar failed (exit code $LASTEXITCODE)."
    }

    $payloadBytes = [System.IO.File]::ReadAllBytes($gz)
    $payloadB64   = [Convert]::ToBase64String($payloadBytes, [System.Base64FormattingOptions]::InsertLineBreaks)
    $sha          = [System.Security.Cryptography.SHA256]::Create()
    try {
        $payloadSha = -join (($sha.ComputeHash($payloadBytes) | ForEach-Object { $_.ToString("x2") }))
    } finally {
        $sha.Dispose()
    }
} finally {
    if (Test-Path -LiteralPath $gz) {
        Remove-Item -LiteralPath $gz -Force -ErrorAction SilentlyContinue
    }
}

# Read the Windows/WSL self-extracting bootstrap script (cross-platform path).
$bootstrapPath = Join-Path (Join-Path $repoRoot "windows") "install-windows.ps1"
$bootstrap     = [System.IO.File]::ReadAllText($bootstrapPath).TrimEnd("`r", "`n")
$marker        = "#" + "__HARNESS_PKG_EOF__"
$nl            = "`n"

# Wrap the sentinel + base64 payload in a PowerShell block comment (<# ... #>)
# so PowerShell 5.1 and 7+ ALWAYS parse the artifact with 0 syntax errors
# regardless of base64 characters (+, /, =).
$full = @(
    $bootstrap,
    "<#",
    "# HARNESS_PAYLOAD_SHA256=$payloadSha",
    $marker,
    ($payloadB64 -replace "`r`n", "`n"),
    "#>"
) -join $nl
$full += $nl

[System.IO.File]::WriteAllText($outPath, $full, [System.Text.UTF8Encoding]::new($false))

Write-Host "Wrote $outPath" -ForegroundColor Green
Write-Host ("  payload gz : " + $payloadBytes.Length + " bytes  sha256=" + $payloadSha) -ForegroundColor Cyan
