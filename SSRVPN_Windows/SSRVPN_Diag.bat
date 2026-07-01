@echo off
setlocal EnableDelayedExpansion

echo ============================================
echo  SSRVPN Windows 便携版 启动诊断工具
echo ============================================
echo.

REM ── 检查 SmartScreen 拦截 ──
echo [1/6] 检查 Windows SmartScreen 拦截...
set EXE_PATH=%~dp0ssrvpn_windows.exe
if not exist "%EXE_PATH%" (
    echo [ERROR] ssrvpn_windows.exe 不存在！
    echo 请确保解压了完整的 ZIP 包。
    goto :summary
)

REM 检查 Zone.Identifier (下载标记)
set ZONE_FILE=%EXE_PATH%:Zone.Identifier
dir "%ZONE_FILE%" >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    echo [WARN]  检测到 Windows 下载安全标记 (Zone.Identifier)
    echo           这可能导致 SmartScreen 拦截或静默失败
    echo           正在尝试解除...
    echo.
    echo           如果以下命令失败，请右键点击 exe → 属性
    echo           → 勾选"解除锁定" → 确定
    echo.
    
    REM 对整个目录解除锁定（最彻底）
    powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -Command ^
        "Get-ChildItem -LiteralPath '%~dp0' -Recurse | Unblock-File 2>$null; Write-Host '   [OK] 已解除所有文件锁定'"
) else (
    echo [OK]  未检测到下载安全标记
)

echo.
echo [2/6] 检查必备 DLL 文件...

set MISSING_DLLS=0
set DLL_LIST=ssrvpn_windows_app.exe flutter_windows.dll screen_retriever_windows_plugin.dll system_tray_plugin.dll window_manager_plugin.dll mihomo.exe concrt140.dll msvcp140.dll msvcp140_1.dll msvcp140_2.dll msvcp140_atomic_wait.dll msvcp140_codecvt_ids.dll vcruntime140.dll vcruntime140_1.dll d3dcompiler_47.dll

for %%d in (%DLL_LIST%) do (
    if exist "%~dp0%%d" (
        echo [OK]  %%d
    ) else (
        echo [MISS] %%d -- 文件缺失！
        set /a MISSING_DLLS+=1
    )
)

echo.
echo [3/6] 检查 VC++ 运行时...

REM 检查系统级 VC++ 安装
reg query "HKLM\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64" >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    echo [OK]  系统已安装 VC++ 2015-2022 运行时
) else (
    echo [INFO] 系统未安装 VC++ 运行时（便携版已自带 DLL，通常无需额外安装）
)

echo.
echo [4/6] 检查 DirectX 运行时...

where d3dcompiler_47.dll >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    echo [OK]  系统已有 d3dcompiler_47.dll
) else (
    if exist "%~dp0d3dcompiler_47.dll" (
        echo [OK]  便携版自带 d3dcompiler_47.dll
    ) else (
        echo [ERR]  缺少 d3dcompiler_47.dll！这是 Flutter 渲染引擎的必需组件。
        echo           部分精简版/服务器版 Windows 默认不带此文件。
        echo           请从正常工作的 Windows 10/11 电脑复制
        echo           C:\Windows\System32\d3dcompiler_47.dll 到本目录
        set /a MISSING_DLLS+=1
    )
)

echo.
echo [5/6] 检查 Mihomo 核心...

if exist "%~dp0mihomo.exe" (
    for /f "delims=" %%v in ('"%~dp0mihomo.exe" -v 2^>^&1') do (
        echo [OK]  Mihomo 核心: %%v
    )
) else (
    echo [ERR]  Mihomo 核心文件丢失！
)

echo.
echo [6/6] 尝试启动 SSRVPN（捕获错误输出）...

echo 启动日志将写入: "%~dp0ssrvpn_startup.log"
echo.

"%~dp0ssrvpn_windows.exe" --verbose > "%~dp0ssrvpn_startup.log" 2>&1
set EXITCODE=%ERRORLEVEL%

echo 退出代码: %EXITCODE% >> "%~dp0ssrvpn_startup.log"

if %EXITCODE% NEQ 0 (
    echo [ERR] SSRVPN 启动失败，退出代码: %EXITCODE%
    echo.
    echo 最近的启动日志:
    type "%~dp0ssrvpn_startup.log" | findstr /i "error fail exception crash"
) else (
    echo [OK]  SSRVPN 已启动（窗口可能在其他桌面或最小化到托盘）
)

:summary
echo.
echo ============================================
echo  诊断完成
echo ============================================
echo.
if %MISSING_DLLS% GTR 0 (
    echo 发现 %MISSING_DLLS% 个缺失文件，请根据上述提示修复。
    echo.
    echo 常见解决方案:
    echo   1. 重新解压完整的 ZIP 包（不要在压缩包内直接运行）
    echo   2. 右键 exe → 属性 → 勾选"解除锁定"
    echo   3. 安装 Visual C++ Redist 2015-2022:
    echo      https://aka.ms/vs/17/release/vc_redist.x64.exe
    echo   4. 从正常 Win10/11 电脑复制 d3dcompiler_47.dll 到本目录
) else (
    echo 所有检查通过。如果软件仍无法打开，请将:
    echo   - ssrvpn_startup.log
    echo   - ssrvpn_diag.log
    echo 发送给开发者分析。
)

echo.
pause
