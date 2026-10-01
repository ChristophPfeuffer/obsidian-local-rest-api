@echo off
setlocal EnableExtensions

rem Double-click launcher for the Obsidian plugin installer (install.js) on
rem Windows. Keep it in the same folder as install.js.
rem
rem Which Node.js is used (MIN_NODE differs: Zotero MCP 20, Obsidian plugin 22)
rem is decided by the PowerShell code embedded at the end of this file (below
rem the marker line); it hands the chosen folder back to this script.
rem
rem Fresh install (nothing in the shared Node folder %LOCALAPPDATA%\node, used
rem by the Zotero MCP, Obsidian plugin and Obsidian bridge installers):
rem   An installed Node.js (PATH, Program Files, nvm-windows) is used if it
rem   passes the compatibility test: version >= MIN_NODE, its npm runs, and
rem   this repo's installer tests (installer\*.test.cjs) pass with it.
rem   Otherwise the newest LTS is downloaded into the shared Node folder (only
rem   the build for this machine; MCP_NODE_CHANNEL=current for the newest
rem   "Current" release; SHA-256 verified before unpacking; no admin rights;
rem   MCP_NO_NODE_DOWNLOAD=1 disables it).
rem
rem Re-run:
rem   The Node.js in use (the shared Node folder, or one chosen earlier, saved
rem   in its file use-node.txt; delete that file to go back) stays, unless a
rem   NEWER installed Node.js passes the compatibility test. Then you are asked
rem   whether to move to it (Enter = yes) and, if so, whether to delete the
rem   copies in the shared Node folder (Enter = yes). Only too-old copies
rem   there: the same offer, otherwise the newest LTS is downloaded and the old
rem   copies are replaced.
rem
rem Claude Desktop (node-wrapper.cmd and entries) is re-pointed first
rem (installer\relink-node.cjs, config backed up); nothing is deleted if that
rem fails. Other Node.js installs are never changed.
rem
rem Then runs `node install.js` and keeps the window open so you can read it.

cd /d "%~dp0"
set "MIN_NODE=22"
set "ZM_SELF=%~f0"
set "ZM_REPO=%~dp0"
set "ZM_RESULT=%TEMP%\mcp-node-dir-%RANDOM%.txt"
if exist "%ZM_RESULT%" del "%ZM_RESULT%"

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command "$s = [IO.File]::ReadAllText($env:ZM_SELF); $i = $s.IndexOf('#'+'#PS-BEGIN'); Invoke-Expression $s.Substring($i)"
if errorlevel 1 goto nodefail
if not exist "%ZM_RESULT%" goto nodefail

set "NODE_DIR="
set /p NODE_DIR=<"%ZM_RESULT%"
del "%ZM_RESULT%" >nul 2>nul
if "%NODE_DIR%"=="" goto nodefail
if not exist "%NODE_DIR%\node.exe" goto nodefail

set "PATH=%NODE_DIR%;%PATH%"
call :nodeok
if errorlevel 1 goto nodefail
goto run

:nodeok
rem Sets NODE_MAJOR from `node -v` (e.g. v24.1.0 -> 24); errorlevel 0 if >= MIN_NODE.
set "NODE_MAJOR="
for /f "tokens=1 delims=v." %%a in ('node -v 2^>nul') do set "NODE_MAJOR=%%a"
if not defined NODE_MAJOR exit /b 1
if %NODE_MAJOR% GEQ %MIN_NODE% exit /b 0
exit /b 1

:nodefail
echo.
echo Could not set up Node.js %MIN_NODE% or newer automatically.
echo.
echo Install Node.js ^(version %MIN_NODE% or newer^) from:
echo   https://nodejs.org
echo.
echo Then run this file again.
echo.
echo Press any key to close.
pause >nul
exit /b 1

:run
echo Using Node.js %NODE_MAJOR% from:
echo   %NODE_DIR%
echo.
node install.js %*
set "RC=%errorlevel%"

echo.
if "%RC%"=="0" (echo Done.) else (echo Installer exited with status %RC%.)
echo Press any key to close.
pause >nul
exit /b %RC%

rem ---------------------------------------------------------------------------
rem Nothing below this line is executed by cmd.exe (the script ends above).
rem PowerShell reads everything from the marker line on. Kept ASCII-only.
rem installer\test-launcher-win.ps1 runs it with test doubles inserted before
rem the "Main" section.
rem ---------------------------------------------------------------------------
##PS-BEGIN
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$MinMajor   = [int]$env:MIN_NODE
$Root       = Join-Path $env:LOCALAPPDATA 'node'
$ChoiceFile = Join-Path $Root 'use-node.txt'
$Repo       = $env:ZM_REPO
$BaseUrl    = 'https://nodejs.org/download/release'
$script:Tmp = $null

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

function Read-Answer([string]$prompt) { return (Read-Host $prompt) }

# Enter = yes.
function Ask-Yes([string]$question) {
    $a = Read-Answer ($question + ' [Y/n]')
    return -not ("$a" -match '^\s*[nN]')
}

function Get-Platform {
    $arch = $env:PROCESSOR_ARCHITEW6432
    if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
    if ($arch -eq 'AMD64') { return 'win-x64' }
    if ($arch -eq 'ARM64') { return 'win-arm64' }
    if ($arch -eq 'x86') { return 'win-x86' }
    throw ('Unsupported CPU architecture: ' + $arch)
}

function New-NodeInfo([string]$exe, [version]$version) {
    return [pscustomobject]@{ Exe = $exe; Dir = (Split-Path -Parent $exe); Version = $version }
}

function Test-InRoot([string]$p) {
    return $p.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-Text($resp) {
    $c = $resp.Content
    if ($c -is [byte[]]) { $c = [Text.Encoding]::UTF8.GetString($c) }
    return $c
}

# ---------------------------------------------------------------------------
# Asking a node.exe (replaced by test doubles in test-launcher-win.ps1)
# ---------------------------------------------------------------------------

# [version] of a node.exe, or $null.
function Get-NodeVersion([string]$exe) {
    $ErrorActionPreference = 'Continue'
    try { $v = & $exe -v 2>$null | Select-Object -First 1 } catch { return $null }
    if ("$v" -match '^v(\d+\.\d+\.\d+)') { return [version]$Matches[1] }
    return $null
}

# Its npm runs (install.js needs npm).
function Test-NodeNpm([string]$exe) {
    $ErrorActionPreference = 'Continue'
    $cli = Join-Path (Split-Path -Parent $exe) 'node_modules\npm\bin\npm-cli.js'
    if (-not (Test-Path -LiteralPath $cli)) { return $false }
    try { & $exe $cli -v *> $null } catch { return $false }
    return ($LASTEXITCODE -eq 0)
}

# This repo's installer tests pass with it.
function Invoke-InstallerTests([string]$exe) {
    $ErrorActionPreference = 'Continue'
    $files = @(Get-ChildItem -LiteralPath (Join-Path $Repo 'installer') -Filter '*.test.cjs' -File | ForEach-Object { $_.FullName })
    if ($files.Count -eq 0) { return $true }
    Push-Location -LiteralPath $Repo
    try { & $exe --test @files *> $null; $ok = ($LASTEXITCODE -eq 0) } catch { $ok = $false } finally { Pop-Location }
    return $ok
}

# Re-points Claude Desktop (node-wrapper.cmd, entries) from $olds to $to.
function Invoke-Relink([string]$runExe, [string]$to, [string[]]$olds) {
    $ErrorActionPreference = 'Continue'
    $relink = Join-Path $Repo 'installer\relink-node.cjs'
    & $runExe $relink ('--to=' + $to) @olds | Out-Host
    return ($LASTEXITCODE -eq 0)
}

# Installed Node.js outside the shared Node folder (paths, may repeat).
function Get-ForeignCandidates {
    $list = @()
    $list += @(Get-Command node.exe -All -CommandType Application -ErrorAction SilentlyContinue | ForEach-Object { $_.Source })
    if ($env:ProgramFiles) { $list += (Join-Path $env:ProgramFiles 'nodejs\node.exe') }
    if (${env:ProgramFiles(x86)}) { $list += (Join-Path ${env:ProgramFiles(x86)} 'nodejs\node.exe') }
    if ($env:NVM_SYMLINK) { $list += (Join-Path $env:NVM_SYMLINK 'node.exe') }
    return $list
}

# ---------------------------------------------------------------------------
# The shared Node folder and other installs
# ---------------------------------------------------------------------------

# Copies in the shared Node folder for this machine, newest first (version
# from the folder name, e.g. node-v24.11.0-win-x64).
function Get-PrivateNodes {
    $plat = Get-Platform
    $found = @()
    foreach ($d in @(Get-ChildItem -LiteralPath $Root -Directory -Filter ('node-v*-' + $plat) -ErrorAction SilentlyContinue)) {
        $exe = Join-Path $d.FullName 'node.exe'
        if (($d.Name -match '^node-v(\d+\.\d+\.\d+)-') -and (Test-Path -LiteralPath $exe)) {
            $found += New-NodeInfo $exe ([version]$Matches[1])
        }
    }
    return @($found | Sort-Object Version -Descending)
}

function Get-ForeignNodes {
    $seen = @{}
    $found = @()
    foreach ($c in @(Get-ForeignCandidates)) {
        if (-not $c -or -not (Test-Path -LiteralPath $c -PathType Leaf)) { continue }
        $full = [IO.Path]::GetFullPath($c)
        if (Test-InRoot $full) { continue }
        $key = $full.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $v = Get-NodeVersion $full
        if ($v) { $found += New-NodeInfo $full $v }
    }
    return $found
}

# Compatibility test "for our purpose"; prints one line.
function Test-Compat($n) {
    $label = '  Compatibility test: Node.js v' + $n.Version + ' at ' + $n.Exe + ' - '
    if ($n.Version.Major -lt $MinMajor) { Write-Host ($label + 'too old (needs ' + $MinMajor + ' or newer).'); return $false }
    if (-not (Test-NodeNpm $n.Exe)) { Write-Host ($label + 'npm does not run.'); return $false }
    if (-not (Invoke-InstallerTests $n.Exe)) { Write-Host ($label + 'installer tests failed.'); return $false }
    Write-Host ($label + 'passed.')
    return $true
}

# Downloads the newest release into the shared Node folder.
function Install-PrivateNode {
    if ($env:MCP_NO_NODE_DOWNLOAD -eq '1') { throw 'Download disabled (MCP_NO_NODE_DOWNLOAD=1).' }
    $channel = $env:MCP_NODE_CHANNEL
    if (-not $channel) { $channel = 'lts' }
    $channel = $channel.ToLower()
    if ($channel -ne 'lts' -and $channel -ne 'current') { throw ('MCP_NODE_CHANNEL must be lts or current (got: ' + $channel + ')') }
    $plat = Get-Platform

    Write-Host 'Downloading from nodejs.org into'
    Write-Host ('  ' + $Root)
    Write-Host '(no admin rights needed; set MCP_NO_NODE_DOWNLOAD=1 to skip this)'
    Write-Host ''

    # Windows PowerShell 5.1 defaults to old TLS versions; nodejs.org needs TLS 1.2.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $script:Tmp = Join-Path ([IO.Path]::GetTempPath()) ('mcp-node-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:Tmp | Out-Null

    # index.tab: tab-separated, newest version first. Columns:
    # version date files npm v8 uv zlib openssl modules lts security
    # "lts" is a codename for LTS releases and "-" otherwise. A release whose
    # files list does not (yet) contain our zip is skipped.
    Write-Host ('Looking up the newest ' + $channel + ' release ...')
    $index = Get-Text (Invoke-WebRequest -UseBasicParsing -Uri ($BaseUrl + '/index.tab'))
    $tok = $plat + '-zip'
    $ver = $null
    foreach ($line in ($index -split "`n")) {
        $cols = $line.TrimEnd("`r") -split "`t"
        if ($cols.Count -lt 10) { continue }
        if ($cols[0] -notmatch '^v\d+\.\d+\.\d+$') { continue }
        if (($cols[2] -split ',') -notcontains $tok) { continue }
        $isLts = ($cols[9] -ne '-' -and $cols[9] -ne '' -and $cols[9] -ne 'false')
        if ($channel -eq 'lts' -and -not $isLts) { continue }
        $ver = $cols[0]
        break
    }
    if (-not $ver) { throw ('No ' + $channel + ' release with a ' + $plat + ' zip found in the release index.') }
    if ([int]($ver -replace '^v(\d+)\..*$', '$1') -lt $MinMajor) { throw ('Newest ' + $channel + ' release ' + $ver + ' is older than the required Node.js ' + $MinMajor + '.') }
    Write-Host ('Newest ' + $channel + ' release for ' + $plat + ': ' + $ver)

    $dirUrl = $BaseUrl + '/' + $ver
    $file = 'node-' + $ver + '-' + $plat + '.zip'
    $sums = Get-Text (Invoke-WebRequest -UseBasicParsing -Uri ($dirUrl + '/SHASUMS256.txt'))

    # Format of each line: <64 hex chars><two spaces><file name>
    $rx = '(?m)^([0-9a-fA-F]{64})\s+' + [regex]::Escape($file) + '\s*$'
    $m = [regex]::Match($sums, $rx)
    if (-not $m.Success) { throw ('No checksum for ' + $file + ' found in the checksum list.') }
    $expected = $m.Groups[1].Value.ToLower()

    $zip = Join-Path $script:Tmp $file
    Write-Host ('Downloading ' + $file + ' ...')
    Invoke-WebRequest -UseBasicParsing -Uri ($dirUrl + '/' + $file) -OutFile $zip

    $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $expected) {
        throw ('SHA-256 check FAILED for ' + $file + ' (expected ' + $expected + ', got ' + $actual + '). Nothing was installed.')
    }
    Write-Host 'SHA-256 OK.'

    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    $stage = Join-Path $Root ('.staging-' + [Guid]::NewGuid().ToString('N'))
    Expand-Archive -LiteralPath $zip -DestinationPath $stage -Force
    $dirName = $file -replace '\.zip$', ''
    $src = Join-Path $stage $dirName
    if (-not (Test-Path -LiteralPath (Join-Path $src 'node.exe'))) {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        throw 'node.exe not found after extraction.'
    }
    $dest = Join-Path $Root $dirName
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    Move-Item -LiteralPath $src -Destination $dest
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host ('Installed: ' + $dest)
    Write-Host ''
    return New-NodeInfo (Join-Path $dest 'node.exe') ([version]($ver.TrimStart('v')))
}

# ---------------------------------------------------------------------------
# Replacing and moving (Claude Desktop is re-pointed first)
# ---------------------------------------------------------------------------

# Update case: deletes copies older than the one in use, without asking.
function Remove-OlderPrivateNodes($cur) {
    $olds = @(Get-PrivateNodes | Where-Object { $_.Version -lt $cur.Version })
    if ($olds.Count -eq 0) { return }
    if (-not (Invoke-Relink $cur.Exe $cur.Exe @($olds | ForEach-Object { $_.Exe }))) {
        Write-Host 'Older Node.js copies kept: Claude Desktop could not be re-pointed.'
        return
    }
    foreach ($o in $olds) {
        Remove-Item -LiteralPath $o.Dir -Recurse -Force
        Write-Host ('Replaced old Node.js v' + $o.Version + ': ' + $o.Dir)
    }
    Write-Host ''
}

# Moves to installed Node.js $f (already tested): asks (Enter = yes),
# re-points Claude Desktop, saves the choice, then offers to delete the copies
# in the shared Node folder (Enter = yes). Returns $true if moved.
function Move-ToForeign($f, $cur) {
    if (-not (Ask-Yes ('Newer Node.js v' + $f.Version + ' found at ' + $f.Exe + '. Use it from now on?'))) { Write-Host ''; return $false }
    $olds = @(Get-PrivateNodes | ForEach-Object { $_.Exe })
    if ($cur -and ($cur.Exe -ne $f.Exe)) { $olds += $cur.Exe }
    if (-not (Invoke-Relink $f.Exe $f.Exe $olds)) {
        Write-Host 'Not moved: Claude Desktop could not be re-pointed.'
        Write-Host ''
        return $false
    }
    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    [IO.File]::WriteAllText($ChoiceFile, $f.Exe)
    Write-Host ('Moved to ' + $f.Exe + ' (saved in ' + $ChoiceFile + '; delete that file to go back).')
    $privs = @(Get-PrivateNodes)
    if ($privs.Count -gt 0 -and (Ask-Yes ('Delete the Node.js copies in ' + $Root + '?'))) {
        foreach ($p in $privs) {
            Remove-Item -LiteralPath $p.Dir -Recurse -Force
            Write-Host ('Deleted ' + $p.Dir)
        }
    }
    Write-Host ''
    return $true
}

function Show-UnusedForeign($foreign, $cur) {
    $shown = $false
    foreach ($f in $foreign) {
        if ($f.Exe -eq $cur.Exe) { continue }
        if (-not $shown) { Write-Host 'Note: other Node.js on this PC (not used, left unchanged):'; $shown = $true }
        $line = '  v' + $f.Version + ' at ' + $f.Exe
        if ($f.Version.Major -lt $MinMajor) { $line += ' (too old for this installer)' }
        Write-Host $line
    }
    if ($shown) { Write-Host '' }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$code = 1
try {
    $foreign = @(Get-ForeignNodes)
    $best = $foreign | Where-Object { $_.Version.Major -ge $MinMajor } | Sort-Object Version -Descending | Select-Object -First 1
    $cur = $null

    # 1) Re-run: a Node.js chosen earlier instead of the shared Node folder.
    if (Test-Path -LiteralPath $ChoiceFile) {
        $chosen = ([IO.File]::ReadAllText($ChoiceFile)).Trim()
        $v = $null
        if ($chosen -and (Test-Path -LiteralPath $chosen -PathType Leaf)) { $v = Get-NodeVersion $chosen }
        if ($v -and $v.Major -ge $MinMajor) {
            $cur = New-NodeInfo $chosen $v
            Write-Host ('Using the Node.js chosen earlier: ' + $chosen + ' (v' + $v + ')')
            Write-Host ('(delete ' + $ChoiceFile + ' to go back to the shared Node folder)')
        } else {
            Write-Host ('The Node.js chosen earlier (' + $chosen + ') is missing or too old for this installer;')
            Write-Host 'back to the shared Node folder.'
            Remove-Item -LiteralPath $ChoiceFile -Force
        }
        Write-Host ''
    }

    # 2) Re-run: the shared Node folder.
    $tooOld = $null
    if (-not $cur) {
        $priv = @(Get-PrivateNodes)
        if ($priv.Count -gt 0) {
            if ($priv[0].Version.Major -ge $MinMajor) { $cur = $priv[0] } else { $tooOld = $priv[0] }
        }
    }

    if ($cur) {
        # Re-run: move to a newer installed Node.js if it passes the test.
        if ($best -and ($best.Exe -ne $cur.Exe) -and ($best.Version -gt $cur.Version)) {
            Write-Host 'Checking the newer Node.js installed on this PC:'
            if (Test-Compat $best) {
                Write-Host ''
                if (Move-ToForeign $best $cur) { $cur = $best }
            } else { Write-Host '' }
        }
    } else {
        if ($tooOld) {
            # Update case (re-run): our copy is too old.
            Write-Host ('Node.js in the shared Node folder is too old for this installer (needs ' + $MinMajor + ' or newer):')
            Write-Host ('  v' + $tooOld.Version + ' at ' + $tooOld.Dir)
            Write-Host ''
            if ($best) {
                Write-Host 'Checking the Node.js installed on this PC:'
                if (Test-Compat $best) {
                    Write-Host ''
                    if (Move-ToForeign $best $null) { $cur = $best }
                } else { Write-Host '' }
            }
            if (-not $cur) { Write-Host 'Updating to the newest Node.js; the old copy is replaced.'; Write-Host '' }
        } else {
            # Fresh install: use an installed Node.js if it passes the test.
            Write-Host 'No Node.js in the shared Node folder yet.'
            if ($best) {
                Write-Host 'Checking the Node.js installed on this PC:'
                if (Test-Compat $best) { $cur = $best }
            } elseif ($foreign.Count -gt 0) {
                Write-Host ('The Node.js installed on this PC is too old for this installer (needs ' + $MinMajor + ' or newer).')
            }
            if (-not $cur) { Write-Host ('Installing Node.js ' + $MinMajor + '+ into the shared Node folder.') }
            Write-Host ''
        }
        if (-not $cur) { $cur = Install-PrivateNode }
    }

    if (Test-InRoot $cur.Exe) { Remove-OlderPrivateNodes $cur }
    Show-UnusedForeign $foreign $cur

    # Hand the folder back to the launcher, in the console's code page
    # (that is how cmd's `set /p` reads it).
    [IO.File]::WriteAllBytes($env:ZM_RESULT, [Console]::OutputEncoding.GetBytes($cur.Dir))
    $code = 0
}
catch {
    Write-Host ('ERROR: ' + $_.Exception.Message)
    $code = 1
}
if ($script:Tmp -and (Test-Path -LiteralPath $script:Tmp)) {
    Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue
}
exit $code
