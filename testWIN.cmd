@echo off
setlocal EnableExtensions

rem Double-click: tests the Node.js selection / update logic of installWIN.cmd
rem (installer\test-launcher-win.ps1). Changes nothing on this PC - everything
rem runs in a temporary folder that is deleted afterwards.

cd /d "%~dp0"

echo Tests for the Node.js update in installWIN.cmd
echo.
echo   Enter    run all cases
echo   l        list the cases
echo   ^<text^>   run only cases whose name contains ^<text^> (e.g. update:)
echo   v        all cases, with the installer window output of each
echo.
set "CHOICE="
set /p "CHOICE=Choice: "
echo.

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "TEST=installer\test-launcher-win.ps1"
if "%CHOICE%"=="" goto all
if /i "%CHOICE%"=="l" goto list
if /i "%CHOICE%"=="v" goto verbose
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%TEST%" "%CHOICE%"
goto done

:all
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%TEST%"
goto done

:list
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%TEST%" --list
goto done

:verbose
set "VERBOSE=1"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%TEST%"
goto done

:done
set "RC=%errorlevel%"
echo.
if "%RC%"=="0" (echo All good.) else (echo Something failed ^(see above^).)
echo.
echo Press any key to close.
pause >nul
exit /b %RC%
