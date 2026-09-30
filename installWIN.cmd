@echo off
setlocal EnableExtensions

rem Double-click launcher for the Obsidian plugin installer (install.js) on
rem Windows. Keep it in the same folder as install.js.
rem
rem 1) Uses Node.js from PATH if it is version 22 or newer.
rem 2) Otherwise re-uses, or downloads, a private copy in
rem      %LOCALAPPDATA%\node
rem    shared by the Zotero MCP, Obsidian plugin and Obsidian bridge installers. Only the build
rem    for this Windows machine is downloaded (newest LTS; set
rem    MCP_NODE_CHANNEL=current for the newest "Current" release). The
rem    SHA-256 checksum is verified before anything is unpacked. No admin
rem    rights needed. Set MCP_NO_NODE_DOWNLOAD=1 to disable the download.
rem    The PowerShell code that does this is embedded at the end of this file,
rem    below the marker line.
rem 3) Runs `node install.js` and keeps the window open so you can read it.

cd /d "%~dp0"
set "MIN_NODE=22"

call :nodeok
if not errorlevel 1 goto run
if defined NODE_MAJOR echo Node.js on PATH is version %NODE_MAJOR%; this installer needs 22 or newer.

if "%MCP_NO_NODE_DOWNLOAD%"=="1" goto nonode

echo.
echo Setting up Node.js 22+ in
echo   %LOCALAPPDATA%\node
echo ^(no admin rights needed; set MCP_NO_NODE_DOWNLOAD=1 to skip this^)
echo.

set "ZM_SELF=%~f0"
set "ZM_RESULT=%TEMP%\mcp-node-dirname-%RANDOM%.txt"
if exist "%ZM_RESULT%" del "%ZM_RESULT%"

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command "$s = [IO.File]::ReadAllText($env:ZM_SELF); $i = $s.IndexOf('#'+'#PS-BEGIN'); Invoke-Expression $s.Substring($i)"
if errorlevel 1 goto dlfail
if not exist "%ZM_RESULT%" goto dlfail

set "NODE_DIRNAME="
set /p NODE_DIRNAME=<"%ZM_RESULT%"
del "%ZM_RESULT%" >nul 2>nul
if "%NODE_DIRNAME%"=="" goto dlfail
if not exist "%LOCALAPPDATA%\node\%NODE_DIRNAME%\node.exe" goto dlfail

set "PATH=%LOCALAPPDATA%\node\%NODE_DIRNAME%;%PATH%"
call :nodeok
if errorlevel 1 goto dlfail
goto run

:nodeok
rem Sets NODE_MAJOR from `node -v` (e.g. v24.1.0 -> 24); errorlevel 0 if >= MIN_NODE.
set "NODE_MAJOR="
for /f "tokens=1 delims=v." %%a in ('node -v 2^>nul') do set "NODE_MAJOR=%%a"
if not defined NODE_MAJOR exit /b 1
if %NODE_MAJOR% GEQ %MIN_NODE% exit /b 0
exit /b 1

:nonode
echo.
echo Node.js 22 or newer not found.
echo.
echo Install Node.js ^(version 22 or newer^) from:
echo   https://nodejs.org
echo.
echo Then run this file again.
goto fail

:dlfail
echo.
echo Could not set up Node.js automatically.
echo.
echo Install Node.js ^(version 22 or newer^) from:
echo   https://nodejs.org
echo.
echo Then run this file again.
goto fail

:fail
echo.
echo Press any key to close.
pause >nul
exit /b 1

:run
echo Using Node.js %NODE_MAJOR% from:
where node
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
rem PowerShell reads everything from the marker line on.
rem ---------------------------------------------------------------------------
##PS-BEGIN
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$code = 1
$tmp = $null

function Get-Text($resp) {
    $c = $resp.Content
    if ($c -is [byte[]]) { $c = [Text.Encoding]::UTF8.GetString($c) }
    return $c
}

try {
    $base = 'https://nodejs.org/download/release'
    $root = Join-Path $env:LOCALAPPDATA 'node'
    $minMajor = [int]$env:MIN_NODE

    $channel = $env:MCP_NODE_CHANNEL
    if (-not $channel) { $channel = 'lts' }
    $channel = $channel.ToLower()
    if ($channel -ne 'lts' -and $channel -ne 'current') {
        throw ('MCP_NODE_CHANNEL must be lts or current (got: ' + $channel + ')')
    }

    $arch = $env:PROCESSOR_ARCHITEW6432
    if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
    if ($arch -eq 'AMD64') { $plat = 'win-x64' }
    elseif ($arch -eq 'ARM64') { $plat = 'win-arm64' }
    elseif ($arch -eq 'x86') { $plat = 'win-x86' }
    else { throw ('Unsupported CPU architecture: ' + $arch) }

    # Re-use a copy downloaded by an earlier run of either installer (newest
    # version wins; only versions that meet this installer's minimum).
    $dirName = $null
    $existing = @(Get-ChildItem -LiteralPath $root -Directory -Filter ('node-v*-' + $plat) -ErrorAction SilentlyContinue |
        Where-Object { (Test-Path -LiteralPath (Join-Path $_.FullName 'node.exe')) -and ($_.Name -match '^node-v(\d+)\.\d+\.\d+-') -and ([int]$Matches[1] -ge $minMajor) } |
        Sort-Object { [version]($_.Name -replace '^node-v(\d+\.\d+\.\d+)-.*$', '$1') } -Descending)
    if ($existing.Count -gt 0) {
        $dirName = $existing[0].Name
        Write-Host ('Using existing download: ' + (Join-Path $root $dirName))
    }
    else {
        # Windows PowerShell 5.1 defaults to old TLS versions; nodejs.org needs TLS 1.2.
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        $tmp = Join-Path ([IO.Path]::GetTempPath()) ('mcp-node-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp | Out-Null

        # index.tab: tab-separated, newest version first. Columns:
        # version date files npm v8 uv zlib openssl modules lts security
        # "lts" is a codename for LTS releases and "-" otherwise. A release whose
        # files list does not (yet) contain our zip is skipped.
        Write-Host ('Looking up the newest ' + $channel + ' release ...')
        $index = Get-Text (Invoke-WebRequest -UseBasicParsing -Uri ($base + '/index.tab'))
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
        if ([int]($ver -replace '^v(\d+)\..*$', '$1') -lt $minMajor) { throw ('Newest ' + $channel + ' release ' + $ver + ' is older than the required Node.js ' + $minMajor + '.') }
        Write-Host ('Newest ' + $channel + ' release for ' + $plat + ': ' + $ver)

        $dirUrl = $base + '/' + $ver
        $file = 'node-' + $ver + '-' + $plat + '.zip'
        $sums = Get-Text (Invoke-WebRequest -UseBasicParsing -Uri ($dirUrl + '/SHASUMS256.txt'))

        # Format of each line: <64 hex chars><two spaces><file name>
        $rx = '(?m)^([0-9a-fA-F]{64})\s+' + [regex]::Escape($file) + '\s*$'
        $m = [regex]::Match($sums, $rx)
        if (-not $m.Success) { throw ('No checksum for ' + $file + ' found in the checksum list.') }
        $expected = $m.Groups[1].Value.ToLower()

        $zip = Join-Path $tmp $file
        Write-Host ('Downloading ' + $file + ' ...')
        Invoke-WebRequest -UseBasicParsing -Uri ($dirUrl + '/' + $file) -OutFile $zip

        $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()
        if ($actual -ne $expected) {
            throw ('SHA-256 check FAILED for ' + $file + ' (expected ' + $expected + ', got ' + $actual + '). Nothing was installed.')
        }
        Write-Host 'SHA-256 OK.'

        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $stage = Join-Path $root ('.staging-' + [Guid]::NewGuid().ToString('N'))
        Expand-Archive -LiteralPath $zip -DestinationPath $stage -Force
        $dirName = $file -replace '\.zip$', ''
        $src = Join-Path $stage $dirName
        if (-not (Test-Path -LiteralPath (Join-Path $src 'node.exe'))) {
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
            throw 'node.exe not found after extraction.'
        }
        $dest = Join-Path $root $dirName
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
        Move-Item -LiteralPath $src -Destination $dest
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host ('Installed: ' + $dest)
    }

    # Hand the (ASCII-only) folder name back to the launcher.
    [IO.File]::WriteAllText($env:ZM_RESULT, $dirName)
    $code = 0
}
catch {
    Write-Host ('ERROR: ' + $_.Exception.Message)
    $code = 1
}
if ($tmp -and (Test-Path -LiteralPath $tmp)) {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
exit $code
