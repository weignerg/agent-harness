#
# wsl-bootstrap.tests.ps1
# Unit tests for the Get-InstalledDistro() function in install-windows.ps1.
#
# Strategy: we do NOT dot-source the .ps1 (its main flow runs wsl.exe and needs
# a Windows/WSL box). Instead we extract ONLY the Get-InstalledDistro() function
# via the PowerShell parser and define it in this session, then feed it
# representative `wsl.exe -l` output through the -RawOutput parameter.
#
# NOTE ON PARSING: this pwsh build returns a ScriptBlockAst from
# Parser.ParseFile and does not preload the named AST types, so we locate the
# function by text (between its own header and the next top-level function) and
# define it with Invoke-Expression, which runs in the current scope.
#
# Run with: pwsh -NoProfile -File windows/tests/wsl-bootstrap.tests.ps1
# Exits with the number of failed assertions (0 == all green).
#

# ---------------------------------------------------------------------------
# Loader: pull just the function text out of the .ps1 and Invoke-Expression it.
# ---------------------------------------------------------------------------
$ps1 = Join-Path $PSScriptRoot "..\install-windows.ps1" | Convert-Path
$tokens = $null
$errs = $null
$fileAst = [System.Management.Automation.Language.Parser]::ParseFile($ps1, [ref]$tokens, [ref]$errs)
if ($errs) {
    Write-Host "PARSE ERRORS:"
    $errs | ForEach-Object { Write-Host "  $($_.Extent.Text)" }
    Exit 99
}
$fullText = $fileAst.Extent.Text
$openMarker = "function Get-InstalledDistro {"
$startPos = $fullText.IndexOf($openMarker)
if ($startPos -lt 0) { Write-Host "Get-InstalledDistro header not found"; Exit 97 }
# Stop at the next top-level function definition (keeps extraction precise).
$nextPos = $fullText.IndexOf("function ", $startPos + $openMarker.Length)
if ($nextPos -lt 0) { $nextPos = $fullText.Length }
$fnText = $fullText.Substring($startPos, ($nextPos - $startPos)).TrimEnd("`r", "`n")
iex $fnText

# $Dist is what the function matches against.
$script:Dist = "Ubuntu"
$Dist = "Ubuntu"

# ---------------------------------------------------------------------------
# Tiny assertion harness (no Pester).
# ---------------------------------------------------------------------------
$script:passCount = 0
$script:failCount = 0
function AssertTest($desc, $cond) {
    if ($cond) {
        $script:passCount++
        Write-Host ("  PASS: " + [string]$desc) -ForegroundColor Green
    } else {
        $script:failCount++
        Write-Host ("  FAIL: " + [string]$desc) -ForegroundColor Red
    }
}

# ---------------------------------------------------------------------------
# Dynamic-detection samples (fired through -RawOutput).
# ---------------------------------------------------------------------------
Write-Host "`n== Get-InstalledDistro detection samples ==" -ForegroundColor Cyan

$sample1 = "*  Ubuntu          Running  2`n*  DockerDesktop  Running  3"
$sample2 = "*? Ubuntu  Stopped  2`n  Debian Running 1"
$sample3 = "No installed distributions."
$sample4 = "Windows Subsystem for Linux has no installed distributions`nerror code 0x8007019e"
$sample5 = '"Ubuntu"  Ubuntu  Running  2'
$sample6 = "*?  UBUNTU  Running  2"
$sample7 = "*?  Debian  Running  1"
$sample8 = "*? Ubuntu-22.04  Running  2`n*  Ubuntu  Running  3"

# 1) Installed, running.
$r = Get-InstalledDistro -RawOutput $sample1
AssertTest "1 present (running Ubuntu)" ($r.present -eq $true)
AssertTest "1 code empty" ($r.code -eq "")

# 2) Installed, stopped, with the "*?" marker.
$r = Get-InstalledDistro -RawOutput $sample2
AssertTest "2 present (stopped Ubuntu)" ($r.present -eq $true)
AssertTest "2 code empty" ($r.code -eq "")

# 3) No distros (early return surfaces a literal missing=$true).
$r = Get-InstalledDistro -RawOutput $sample3
AssertTest "3 present == false" ($r.present -eq $false)
AssertTest "3 missing == true" ($r.missing -eq $true)
AssertTest "3 code empty" ($r.code -eq "")

# 4) WSL not ready + surfaced error code.
$r = Get-InstalledDistro -RawOutput $sample4
AssertTest "4 present == false" ($r.present -eq $false)
AssertTest "4 missing == true" ($r.missing -eq $true)
AssertTest "4 code contains 0x8007019e" ($r.code.Contains("0x8007019e"))

# 5) Quoted / renamed instance name -> substring match.
$r = Get-InstalledDistro -RawOutput $sample5
AssertTest "5 present (quoted/renamed)" ($r.present -eq $true)

# 6) Case variant in a localized title.
$r = Get-InstalledDistro -RawOutput $sample6
AssertTest "6 present (case-insensitive)" ($r.present -eq $true)

# 7) Other distro only -> Ubuntu absent. (.present is authoritative;
#    missing is (-$present); a bool. The suite asserts .present explicitly.)
$r = Get-InstalledDistro -RawOutput $sample7
AssertTest "7 present == false" ($r.present -eq $false)
AssertTest "7 absent (Ubuntu not listed)" (-not $r.present)

# 8) Trailing-marker + version column; literal "Ubuntu" row present.
$r = Get-InstalledDistro -RawOutput $sample8
AssertTest "8 present (literal Ubuntu row)" ($r.present -eq $true)

# 9) Negative test (Debian only): no Ubuntu row at all -> Ubuntu is absent.
#    A distro listed here that is not Ubuntu must NOT report present=true.
$sampleDebian = "*? Debian  Running  1"
$r = Get-InstalledDistro -RawOutput $sampleDebian
AssertTest "9 Debian only -> Ubuntu absent" ($r.present -eq $false)

# 10) Lenient test (documented kickoff behavior): a distro NAME is never missed.
#     "Ubuntu" is a substring of the renamed "Ubuntu-22.04" instance, so the
#     lenient substring fallback intentionally reports present=true.
$sampleU22 = "*? Ubuntu-22.04  Running  2"
$r = Get-InstalledDistro -RawOutput $sampleU22
AssertTest "10 Ubuntu-22.04 -> Ubuntu lenient present" ($r.present -eq $true)

# ---------------------------------------------------------------------------
# Static source checks against install-windows.ps1.
# ---------------------------------------------------------------------------
Write-Host "`n== Static source checks ==" -ForegroundColor Cyan
$src = Get-Content -Path $ps1 -Raw

AssertTest "9  contains 'systemd=true'"                          ($src.Contains("systemd=true"))
AssertTest "10 contains 'New-ScheduledTaskAction'"              ($src.Contains("New-ScheduledTaskAction"))
AssertTest "11 contains '-AtLogOn'"                             ($src.Contains("-AtLogOn"))
AssertTest "12 does NOT contain '--no-healthcheck'"            (-not $src.Contains("--no-healthcheck"))
AssertTest "13 contains 'Read-Host'"                            ($src.Contains("Read-Host"))
AssertTest "14 contains 'default=\$safeUser'"                  ($src.Contains("default=`$safeUser"))
AssertTest "15 contains 'Unregister-WslInstallResume'"         ($src.Contains("Unregister-WslInstallResume"))
AssertTest "16 contains 'wsl.exe --shutdown'"                  ($src.Contains("wsl.exe --shutdown"))

# ---------------------------------------------------------------------------
$passCount = $script:passCount
$failCount = $script:failCount
Write-Host "`n== Summary ==" -ForegroundColor Cyan
Write-Host ("{0} passed, {1} failed" -f $passCount, $failCount)

Exit $failCount
