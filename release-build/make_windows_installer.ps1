#Requires -Version 5.1
# ==============================================================================
# make_windows_installer.ps1  --  build the self-extracting Windows/WSL installer.
#
#   Output  : <OutputDir>/install-agent-harness-v<version>-windows10-11.ps1
#             (default: <repo>/dist)
#   Layout  : [windows/install-windows.ps1 WSL + self-extract bootstrap]
#             + '<#'
#             + '# HARNESS_PAYLOAD_SHA256=<hex>'
#             + '#__HARNESS_PKG_EOF__'   (sentinel marker)
#             + base64( tar.gz( payload ) )
#             + '#>'
#   Payload : harness config scripts core install.sh
#             (windows/install-windows.ps1 is the outer self-extracting script)
#   On run  : verifies embedded SHA-256 at startup (fail-closed), provisions
#             WSL2/Ubuntu/systemd/identity/auto-resume, writes verified tar.gz
#             to %TEMP%, converts via Convert-WindowsToWslPath, extracts via
#             `wsl.exe ... tar -xzf`, and runs `bash ./install.sh` inside WSL.
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
$pyprojectText = [System.IO.File]::ReadAllText((Join-Path $repoRoot "pyproject.toml"))
$verMatch = [regex]::Match($pyprojectText, '(?m)^version\s*=\s*"([^"]+)"')
$version  = if ($verMatch.Success) { "v" + $verMatch.Groups[1].Value } else { "v0.7.7" }
$outName  = "install-agent-harness-${version}-windows10-11.ps1"

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $repoRoot "dist"
}
if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
}
# Resolve against PowerShell's $PWD so .NET File APIs write to the exact absolute path.
$OutputDir = (Resolve-Path -LiteralPath $OutputDir).Path
$outPath   = Join-Path $OutputDir $outName

# Runtime tree embedded in the self-extracting artifact.
$payloadPaths = @("harness", "config", "scripts", "core", "install.sh")

# Build deterministic gzip payload (GZIP=-n omits gzip timestamp header).
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

$prevGzip = $env:GZIP
try {
    $env:GZIP = "-n"
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
    if ($null -eq $prevGzip) {
        Remove-Item Env:GZIP -ErrorAction SilentlyContinue
    } else {
        $env:GZIP = $prevGzip
    }
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
# so Windows PowerShell 5.1 and PowerShell 7+ ALWAYS parse the artifact with 0
# syntax errors regardless of base64 characters (+, /, =).
$full = @(
    $bootstrap,
    "<#",
    "# HARNESS_PAYLOAD_SHA256=$payloadSha",
    $marker,
    ($payloadB64 -replace "`r`n", "`n"),
    "#>"
) -join $nl
$full += $nl

# Write UTF-8 WITH BOM so Windows PowerShell 5.1 (powershell.exe) decodes UTF-8
# characters cleanly instead of falling back to Windows-1252 ANSI.
[System.IO.File]::WriteAllText($outPath, $full, [System.Text.UTF8Encoding]::new($true))

Write-Host "Wrote $outPath" -ForegroundColor Green
Write-Host ("  payload gz : " + $payloadBytes.Length + " bytes  sha256=" + $payloadSha) -ForegroundColor Cyan
