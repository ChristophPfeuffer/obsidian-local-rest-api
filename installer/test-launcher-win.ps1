# Scenario test for the Node.js selection / update logic in installWIN.cmd.
# Started by testWIN.cmd (double-click), or:
#   powershell -ExecutionPolicy Bypass -File installer\test-launcher-win.ps1 [filter|--list]
#
# Runs the PowerShell part of installWIN.cmd in a throw-away LOCALAPPDATA /
# APPDATA with fake Node.js folders (an empty node.exe plus a VERSION file).
# Test doubles replace: asking a node.exe for its version / npm / installer
# tests, finding installed Node.js, and the download. Re-pointing
# Claude Desktop runs for real (installer\relink-node.cjs with your real node).
# Nothing outside the temp folder is touched. Set VERBOSE=1 to see the output.
#
# Shared file: identical copies ship with every installer that uses the shared
# Node.js folder (each under installer\). Change it in one repository, then
# copy the change to every other copy.
# ASCII only (Windows PowerShell 5.1 reads BOM-less scripts as ANSI).

param([string]$Filter = '')
$ErrorActionPreference = 'Stop'

$Repo = Split-Path -Parent $PSScriptRoot
$LauncherText = [IO.File]::ReadAllText((Join-Path $Repo 'installWIN.cmd'))
$PsCode = $LauncherText.Substring($LauncherText.IndexOf('#' + '#PS-BEGIN'))
# MIN_NODE in the launcher: MAJOR or MAJOR.MINOR (e.g. 20 or 22.13).
$MinMatch = [regex]::Match($LauncherText, '(?m)^set "MIN_NODE=(\d+)(?:\.(\d+))?"')
$MinRaw = $MinMatch.Value -replace '^set "MIN_NODE=|"$', ''
$Min = [int]$MinMatch.Groups[1].Value                                    # major
$Minor = 0
if ($MinMatch.Groups[2].Success) { $Minor = [int]$MinMatch.Groups[2].Value }
$OLD = '{0}.0.0' -f ($Min - 2)   # too old
$OK  = '{0}.{1}.0' -f $Min, ($Minor + 1)   # new enough
# Just below MIN_NODE: same major, one minor lower (or the major before).
if ($Minor -gt 0) { $BELOW = '{0}.{1}.9' -f $Min, ($Minor - 1) } else { $BELOW = '{0}.99.0' -f ($Min - 1) }
$NEW = '{0}.2.0' -f ($Min + 4)   # newer than OK
$DL  = '99.0.0'                  # what the stubbed download "installs"

# A real node to re-point Claude Desktop with: PATH, else the shared Node folder.
$RealNode = $null
$cmd = Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if ($cmd) { $RealNode = $cmd.Source }
if (-not $RealNode) {
    $RealNode = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'node\node-v*\node.exe') -ErrorAction SilentlyContinue |
        Sort-Object { [version]($_.Directory.Name -replace '^node-v(\d+\.\d+\.\d+)-.*$', '$1') } -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $RealNode) { Write-Host 'No node found (PATH or %LOCALAPPDATA%\node).'; exit 1 }

# Test doubles, inserted just before the launcher's "Main" section.
$Doubles = @'
function Get-Platform { return 'win-x64' }
function Get-NodeVersion([string]$exe) {
    $f = Join-Path (Split-Path -Parent $exe) 'VERSION'
    if (Test-Path -LiteralPath $f) { return [version]((Get-Content -LiteralPath $f -Raw).Trim()) }
    return $null
}
function Test-NodeNpm([string]$exe) { return -not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $exe) 'NONPM')) }
function Invoke-InstallerTests([string]$exe) { return -not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $exe) 'FAILTESTS')) }
function Get-ForeignCandidates { if ($env:ZM_TEST_FOREIGN) { return @($env:ZM_TEST_FOREIGN) }; return @() }
function Invoke-Relink([string]$runExe, [string]$to, [string[]]$olds) {
    $ErrorActionPreference = 'Continue'
    & $env:ZM_TEST_REAL_NODE (Join-Path $Repo 'installer\relink-node.cjs') ('--to=' + $to) @olds | Out-Host
    return ($LASTEXITCODE -eq 0)
}
function Install-PrivateNode {
    Write-Host 'STUB_DOWNLOAD v99.0.0'
    $d = Join-Path $Root 'node-v99.0.0-win-x64'
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    Set-Content -LiteralPath (Join-Path $d 'node.exe') -Value ''
    Set-Content -LiteralPath (Join-Path $d 'VERSION') -Value '99.0.0'
    return New-NodeInfo (Join-Path $d 'node.exe') ([version]'99.0.0')
}

'@
$m = [regex]::Match($PsCode, '(?m)^# Main\s*$')
$TestCode = $PsCode.Substring(0, $m.Index) + $Doubles + $PsCode.Substring($m.Index)

$Root = Join-Path ([IO.Path]::GetTempPath()) ('launcher-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Root | Out-Null
$Script = Join-Path $Root 'launcher.ps1'
[IO.File]::WriteAllText($Script, $TestCode)
$PowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

$SavedEnv = @{}
foreach ($k in 'LOCALAPPDATA', 'APPDATA', 'MIN_NODE', 'ZM_REPO', 'ZM_RESULT', 'ZM_TEST_FOREIGN', 'ZM_TEST_REAL_NODE') {
    $SavedEnv[$k] = [Environment]::GetEnvironmentVariable($k)
}

$script:Pass = 0; $script:Fail = 0; $script:Ran = 0
$script:Case = ''; $script:Out = ''; $script:Result = ''

# --- sandbox -----------------------------------------------------------------
function Start-Case([string]$name) {
    $script:Case = $name
    if ($Filter -eq '--list') { Write-Host ('  ' + $name); return $false }
    if ($Filter -and ($name.IndexOf($Filter, [StringComparison]::OrdinalIgnoreCase) -lt 0)) { return $false }
    $script:Ran++
    $script:T = Join-Path $Root ('case' + $script:Ran)
    $script:N = Join-Path $script:T 'local\node'
    $script:F = Join-Path $script:T 'other\nodejs\node.exe'
    $script:Cfg = Join-Path $script:T 'roaming\Claude\claude_desktop_config.json'
    $script:Wrapper = Join-Path $script:T 'local\node-wrapper\node-wrapper.cmd'
    $script:Foreign = ''
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:Cfg) | Out-Null
    return $true
}
function New-FakeNode([string]$exe, [string]$version, [string]$flag = '') {
    $d = Split-Path -Parent $exe
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    Set-Content -LiteralPath $exe -Value ''
    Set-Content -LiteralPath (Join-Path $d 'VERSION') -Value $version
    if ($flag) { Set-Content -LiteralPath (Join-Path $d $flag) -Value '' }
}
function PrivExe([string]$v) { return (Join-Path $script:N ('node-v' + $v + '-win-x64\node.exe')) }
function PrivateNode([string]$v) { New-FakeNode (PrivExe $v) $v }
function ForeignNode([string]$v, [string]$flag = '') { New-FakeNode $script:F $v $flag; $script:Foreign = $script:F }
function Claude-Wrapper([string]$target) {
    # Like install-lib.cjs: the entry runs node-wrapper.cmd, which forwards to node.exe.
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:Wrapper) | Out-Null
    [IO.File]::WriteAllText($script:Wrapper, "@echo off`r`n`"$target`" %*`r`nexit /b %errorlevel%`r`n")
    $json = '{"mcpServers":{"zotero":{"command":' + (ConvertTo-Json $script:Wrapper) + '},"direct":{"command":' + (ConvertTo-Json $target) + '}}}'
    [IO.File]::WriteAllText($script:Cfg, $json)
}
function OldChoice([string]$exe) {
    # use-node.txt as left by earlier versions of the launcher.
    New-Item -ItemType Directory -Force -Path $script:N | Out-Null
    [IO.File]::WriteAllText((Join-Path $script:N 'use-node.txt'), $exe)
}

# Runs the launcher's PowerShell part.
function Run {
    $env:LOCALAPPDATA = Join-Path $script:T 'local'
    $env:APPDATA = Join-Path $script:T 'roaming'
    $env:MIN_NODE = $MinRaw
    $env:ZM_REPO = $Repo + '\'
    $env:ZM_RESULT = Join-Path $script:T 'result.txt'
    $env:ZM_TEST_FOREIGN = $script:Foreign
    $env:ZM_TEST_REAL_NODE = $RealNode
    $ErrorActionPreference = 'Continue'
    $script:Out = (& $PowerShell -NoProfile -ExecutionPolicy Bypass -File $Script 2>&1 | Out-String)
    $script:Result = ''
    if (Test-Path -LiteralPath $env:ZM_RESULT) {
        $script:Result = [Console]::OutputEncoding.GetString([IO.File]::ReadAllBytes($env:ZM_RESULT))
    }
}

# --- assertions --------------------------------------------------------------
function Check([bool]$cond, [string]$what) {
    if ($cond) { $script:Pass++ } else { $script:Fail++; Write-Host ('  FAIL [' + $script:Case + '] ' + $what) }
}
function Uses([string]$exe) { Check ($script:Result -eq (Split-Path -Parent $exe)) ('should use ' + $exe + ' (uses ' + $script:Result + ')') }
function UsesPrivate([string]$v) { Uses (PrivExe $v) }
function Says([string]$text) { Check ($script:Out.Contains($text)) ('output should contain: ' + $text) }
function NotSays([string]$text) { Check (-not $script:Out.Contains($text)) ('output should not contain: ' + $text) }
function HasPrivate([string]$v) { Check (Test-Path -LiteralPath (PrivExe $v)) ('shared folder should have v' + $v) }
function NoPrivate([string]$v) { Check (-not (Test-Path -LiteralPath (PrivExe $v))) ('shared folder should not have v' + $v) }
function NoChoice {
    Check (-not (Test-Path -LiteralPath (Join-Path $script:N 'use-node.txt'))) "use-node.txt (earlier versions' remembered choice) should be gone"
}
function WrapperIs([string]$exe) {
    $text = [IO.File]::ReadAllText($script:Wrapper)
    Check ($text.Contains('"' + $exe + '" %*')) ('node-wrapper.cmd should forward to ' + $exe)
}
function DirectIs([string]$exe) {
    $c = (Get-Content -LiteralPath $script:Cfg -Raw | ConvertFrom-Json).mcpServers.direct.command
    Check ($c -eq $exe) ('Claude entry "direct" should use ' + $exe + ' (is ' + $c + ')')
}
function Finish {
    if ($env:VERBOSE -eq '1') { Write-Host ('----- ' + $script:Case); Write-Host $script:Out }
}

try {
    # --- rule 3: nothing in the shared folder yet ---------------------------
    if (Start-Case 'rule 3: installed Node passes the test -> used, nothing downloaded') {
        ForeignNode $OK; Run
        Uses $script:F; Says 'passed.'; NoPrivate $DL; Finish
    }
    if (Start-Case 'rule 3: installed Node too old -> download') {
        ForeignNode $OLD; Run
        UsesPrivate $DL; Says 'too old for this installer'; Finish
    }
    if (Start-Case 'rule 3: installed Node just below MIN_NODE -> download') {
        ForeignNode $BELOW; Run
        UsesPrivate $DL; Says 'too old for this installer'; Finish
    }
    if (Start-Case 'rule 3: installed Node fails the installer tests -> download') {
        ForeignNode $OK 'FAILTESTS'; Run
        UsesPrivate $DL; Says 'installer tests failed'; Finish
    }
    if (Start-Case 'rule 3: installed Node without npm -> download') {
        ForeignNode $OK 'NONPM'; Run
        UsesPrivate $DL; Says 'npm does not run'; Finish
    }
    if (Start-Case 'rule 3: no Node at all -> download') {
        Run
        UsesPrivate $DL; Says 'No Node.js in the shared Node folder yet.'; Finish
    }

    # --- rule 1: the shared copy is new enough ------------------------------
    if (Start-Case 'rule 1: shared copy new enough -> used') {
        PrivateNode $OK; Claude-Wrapper (PrivExe $OK); Run
        UsesPrivate $OK; NoPrivate $DL; WrapperIs (PrivExe $OK); Finish
    }
    if (Start-Case 'rule 1: newer installed Node -> shared copy still used, no question') {
        PrivateNode $OK; ForeignNode $NEW; Run
        UsesPrivate $OK; NotSays '[Y/n]'; Says 'not used, left unchanged'; Finish
    }
    if (Start-Case 'rule 1: older shared copies -> deleted, Claude re-pointed') {
        PrivateNode $OLD; PrivateNode $OK; Claude-Wrapper (PrivExe $OLD); Run
        UsesPrivate $OK; NoPrivate $OLD; HasPrivate $OK; WrapperIs (PrivExe $OK); DirectIs (PrivExe $OK); Finish
    }
    if (Start-Case 'rule 1: use-node.txt left by an earlier launcher -> removed, ignored') {
        PrivateNode $OK; ForeignNode $NEW; OldChoice $script:F; Run
        UsesPrivate $OK; NoChoice; Finish
    }

    # --- rule 2: the shared copy is too old ---------------------------------
    if (Start-Case 'rule 2: shared copy too old -> download, old copy replaced, wrapper re-pointed') {
        PrivateNode $OLD; Claude-Wrapper (PrivExe $OLD); Run
        UsesPrivate $DL; Says 'too old for this installer'; NoPrivate $OLD; HasPrivate $DL
        WrapperIs (PrivExe $DL); DirectIs (PrivExe $DL); Finish
    }
    if (Start-Case 'rule 2: shared copy just below MIN_NODE -> download, old copy replaced') {
        PrivateNode $BELOW; Claude-Wrapper (PrivExe $BELOW); Run
        UsesPrivate $DL; Says 'too old for this installer'; NoPrivate $BELOW; HasPrivate $DL
        WrapperIs (PrivExe $DL); Finish
    }
    if (Start-Case 'rule 2: installed Node would pass -> still replaced by a download') {
        PrivateNode $OLD; ForeignNode $OK; Claude-Wrapper (PrivExe $OLD); Run
        UsesPrivate $DL; NoPrivate $OLD; HasPrivate $DL; NotSays 'Checking the Node.js installed'
        WrapperIs (PrivExe $DL); Finish
    }
    if (Start-Case 'rule 2: Claude config unreadable -> old copy NOT deleted') {
        PrivateNode $OLD; [IO.File]::WriteAllText($script:Cfg, '{ broken'); Run
        UsesPrivate $DL; HasPrivate $OLD; Says 'could not be re-pointed'; Finish
    }
}
finally {
    foreach ($k in $SavedEnv.Keys) { [Environment]::SetEnvironmentVariable($k, $SavedEnv[$k]) }
    Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($Filter -eq '--list') { exit 0 }
if ($script:Ran -eq 0) { Write-Host ('No case matches "' + $Filter + '" (see --list).'); exit 1 }
Write-Host ''
Write-Host ('Launcher scenarios (MIN_NODE=' + $MinRaw + ', real node ' + (& $RealNode -v) + '): ' + $script:Ran + ' cases, ' + $script:Pass + ' checks passed, ' + $script:Fail + ' failed.')
Write-Host '(VERBOSE=1 shows the launcher output of every case.)'
if ($script:Fail -gt 0) { exit 1 }
exit 0
