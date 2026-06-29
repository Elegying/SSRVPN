@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

REM SSRVPN Windows 绿色便携版构建脚本
REM 要求: Flutter SDK + Visual Studio（含"使用C++的桌面开发"）

cd /d "%~dp0"
set "PROJECT_ROOT=%~dp0"
set "RELEASE_DIR=%PROJECT_ROOT%build\windows\x64\runner\Release"
set "ZIP_NAME=SSRVPN_Windows_v2.0.0_portable.zip"
set "ZIP_OUT=%PROJECT_ROOT%..\%ZIP_NAME%"

echo ============================================
echo   SSRVPN Windows 便携版构建
echo ============================================
echo.

echo [1/4] 清理旧构建...
call flutter clean
if %ERRORLEVEL% neq 0 (
    echo [错误] flutter clean 失败
    pause
    exit /b 1
)

echo [2/4] 获取依赖...
call flutter pub get
if %ERRORLEVEL% neq 0 (
    echo [错误] flutter pub get 失败
    pause
    exit /b 1
)

echo [3/4] 构建 Release...
call flutter build windows --release
if %ERRORLEVEL% neq 0 (
    echo [错误] flutter build windows --release 失败
    pause
    exit /b 1
)

if not exist "%RELEASE_DIR%\ssrvpn_windows.exe" (
    echo [错误] 构建产物不存在: %RELEASE_DIR%\ssrvpn_windows.exe
    echo 请检查构建日志排查问题。
    pause
    exit /b 1
)

echo [4/4] 打包便携版 ZIP...
del "%ZIP_OUT%" 2>nul
powershell -NoProfile -Command ^
    "Compress-Archive -Path '%RELEASE_DIR%\*' -DestinationPath '%ZIP_OUT%' -Force"
if %ERRORLEVEL% neq 0 (
    echo [错误] ZIP 打包失败
    pause
    exit /b 1
)

echo.
echo ============================================
echo   构建完成！
echo.
echo   便携版 ZIP: %ZIP_OUT%
echo.
dir "%ZIP_OUT%" 2>nul
echo ============================================
echo.
echo 解压后直接运行 ssrvpn_windows.exe 即可使用。
echo.
pause
