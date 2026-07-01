@echo off
setlocal EnableExtensions

cd /d "%~dp0" || (
    echo [ERROR] Could not enter project directory.
    pause
    exit /b 1
)

echo ============================================
echo   SSRVPN Windows Portable One-Click Build
echo ============================================
echo.

set "SCRIPT=%~dp0tool\package_windows.ps1"
set "ZIP=%~dp0SSRVPN.zip"
set "HASH=%~dp0SSRVPN.zip.sha256"
set "LOG=%~dp0build_release.log"
set "RELEASE_DIR=%~dp0SSRVPN_Windows_Release"

if not exist "%SCRIPT%" (
    echo [ERROR] Packaging script not found:
    echo         %SCRIPT%
    pause
    exit /b 1
)

where powershell.exe >nul 2>nul
if errorlevel 1 (
    echo [ERROR] powershell.exe was not found.
    echo         This build script requires Windows PowerShell.
    pause
    exit /b 1
)

if exist "%LOG%" del /f /q "%LOG%" >nul 2>nul

echo [1/3] Checking build entry...
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command ^
    "$PSVersionTable.PSVersion.ToString()" >nul 2>nul
if errorlevel 1 (
    echo [ERROR] PowerShell could not start.
    pause
    exit /b 1
)
echo [OK] PowerShell is available.
echo.

echo [2/3] Building release and collecting portable runtime files...
echo       Log: %LOG%
echo.

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass ^
    -File "%SCRIPT%" -LogPath "%LOG%" %*
set "BUILD_EXIT=%ERRORLEVEL%"

if not "%BUILD_EXIT%"=="0" (
    echo.
    echo [ERROR] Build or packaging failed. Exit code: %BUILD_EXIT%
    echo         Full log: %LOG%
    echo.
    echo Common fixes:
    echo   1. Open build_release.log and look for the first [ERROR] or throw line.
    echo   2. If pub.dev timed out, run this file again. It retries a China mirror.
    echo   3. If your network uses a proxy, set HTTPS_PROXY/HTTP_PROXY first.
    echo   4. If packages are already cached, try:
    echo      build_release.bat -OfflinePub
    echo   5. For build tool errors, install Flutter SDK and Visual Studio 2022 C++.
    echo.
    pause
    exit /b %BUILD_EXIT%
)

echo.
echo [3/3] Verifying output files...
if not exist "%ZIP%" (
    echo [ERROR] ZIP was not created:
    echo         %ZIP%
    echo         Full log: %LOG%
    pause
    exit /b 1
)
if not exist "%HASH%" (
    echo [ERROR] SHA256 file was not created:
    echo         %HASH%
    echo         Full log: %LOG%
    pause
    exit /b 1
)
if not exist "%RELEASE_DIR%\ssrvpn_windows.exe" (
    echo [ERROR] Release folder is missing ssrvpn_windows.exe:
    echo         %RELEASE_DIR%
    echo         Full log: %LOG%
    pause
    exit /b 1
)

for %%I in ("%ZIP%") do set "ZIP_SIZE=%%~zI"

echo [OK] Portable package is ready.
echo.
echo ============================================
echo   Build complete
echo.
echo   Portable ZIP: %ZIP%
echo   ZIP size:     %ZIP_SIZE% bytes
echo   SHA256:       %HASH%
echo   Build log:    %LOG%
echo ============================================
echo.
echo Send SSRVPN.zip to users. They only need to:
echo   1. Extract the ZIP completely.
echo   2. Double-click ssrvpn_windows.exe.
echo.
pause
