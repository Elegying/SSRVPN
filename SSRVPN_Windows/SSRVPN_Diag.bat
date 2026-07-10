@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001 >nul
cd /d "%~dp0"

set "EXE_PATH=%~dp0ssrvpn_windows.exe"
set "BIN_DIR=%~dp0bin\"
set "DIAG_LOG=%~dp0ssrvpn_diag.log"
set "STARTUP_LOG=%~dp0ssrvpn_startup.log"
set "STARTUP_ERR_LOG=%~dp0ssrvpn_startup.err.log"
set "TEMP_OUT=%TEMP%\ssrvpn_diag_%RANDOM%_%RANDOM%.log"
set MISSING_DLLS=0

> "%DIAG_LOG%" (
  echo SSRVPN Windows 便携版启动诊断工具
  echo 生成时间: %date% %time%
  echo 目录: %~dp0
  echo.
)

call :log "============================================"
call :log " SSRVPN Windows 便携版启动诊断工具"
call :log "============================================"
call :log ""

call :log "[1/7] 检查 Windows SmartScreen 拦截..."
if not exist "%EXE_PATH%" (
    call :log "[ERROR] ssrvpn_windows.exe 不存在！"
    call :log "请确认已经完整解压 ZIP 包，不要在压缩包预览窗口中直接运行。"
    set /a MISSING_DLLS+=1
    goto :summary
)

set "ZONE_FILE=%EXE_PATH%:Zone.Identifier"
dir "%ZONE_FILE%" >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    call :log "[WARN] 检测到 Windows 下载安全标记 (Zone.Identifier)"
    call :log "       正在尝试解除目录内文件锁定..."
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0' -Recurse | Unblock-File 2>$null" > "%TEMP_OUT%" 2>&1
    type "%TEMP_OUT%"
    type "%TEMP_OUT%" >> "%DIAG_LOG%"
) else (
    call :log "[OK]  未检测到下载安全标记"
)

call :log ""
call :log "[2/7] 检查必需 DLL 和程序文件..."
set "ROOT_RUNTIME_DLL_LIST=concrt140.dll msvcp140.dll msvcp140_1.dll msvcp140_2.dll msvcp140_atomic_wait.dll msvcp140_codecvt_ids.dll vcruntime140.dll vcruntime140_1.dll"
set "BIN_FILE_LIST=ssrvpn_windows_app.exe flutter_windows.dll screen_retriever_windows_plugin.dll system_tray_plugin.dll window_manager_plugin.dll mihomo.exe d3dcompiler_47.dll"
set "BIN_RUNTIME_DLL_LIST=concrt140.dll msvcp140.dll msvcp140_1.dll msvcp140_2.dll msvcp140_atomic_wait.dll msvcp140_codecvt_ids.dll vcruntime140.dll vcruntime140_1.dll"

for %%d in (%ROOT_RUNTIME_DLL_LIST%) do (
    if exist "%~dp0%%d" (
        call :log "[OK]  %%d"
    ) else (
        call :log "[MISS] %%d -- 主启动器运行库缺失"
        set /a MISSING_DLLS+=1
    )
)

for %%d in (%BIN_FILE_LIST% %BIN_RUNTIME_DLL_LIST%) do (
    if exist "%BIN_DIR%%%d" (
        call :log "[OK]  bin\%%d"
    ) else (
        call :log "[MISS] bin\%%d -- 文件缺失"
        set /a MISSING_DLLS+=1
    )
)

call :log ""
call :log "[3/7] 检查 VC++ 运行时..."
reg query "HKLM\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64" >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    call :log "[OK]  系统已安装 VC++ 2015-2022 运行时"
) else (
    call :log "[INFO] 系统未检测到 VC++ 运行时；便携版应自带所需 DLL。"
)

call :log ""
call :log "[4/7] 检查 DirectX 渲染组件..."
where d3dcompiler_47.dll >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    call :log "[OK]  系统已有 d3dcompiler_47.dll"
) else if exist "%BIN_DIR%d3dcompiler_47.dll" (
    call :log "[OK]  便携版自带 bin\d3dcompiler_47.dll"
) else (
    call :log "[ERR]  缺少 d3dcompiler_47.dll，这是 Flutter 渲染必需组件。"
    set /a MISSING_DLLS+=1
)

call :log ""
call :log "[5/7] 检查 Mihomo 核心..."
if exist "%BIN_DIR%mihomo.exe" (
    "%BIN_DIR%mihomo.exe" -v > "%TEMP_OUT%" 2>&1
    type "%TEMP_OUT%"
    type "%TEMP_OUT%" >> "%DIAG_LOG%"
) else (
    call :log "[ERR]  Mihomo 核心文件缺失。"
    set /a MISSING_DLLS+=1
)

call :log ""
call :log "[6/7] 检查旧版 SSRVPN 安全例外..."
set "LEGACY_MITIGATION=0"
for %%e in (ssrvpn_windows.exe ssrvpn_windows_app.exe) do (
    reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\%%e" /v DisableUserShadowStack >nul 2>&1
    if !ERRORLEVEL! EQU 0 set "LEGACY_MITIGATION=1"
    reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\%%e" /v MitigationOptions >nul 2>&1
    if !ERRORLEVEL! EQU 0 set "LEGACY_MITIGATION=1"
)
if "!LEGACY_MITIGATION!"=="1" (
    call :log "[WARN] 检测到旧版可能留下的进程安全例外。"
    call :log "       请右键 remove_legacy_cet_exemption.bat，以管理员身份运行一次。"
) else (
    call :log "[OK]  未检测到旧版注册表安全例外。"
)

call :log ""
call :log "[7/7] 尝试启动 SSRVPN 并观察 10 秒..."
call :log "启动日志: %STARTUP_LOG%"
call :log "错误输出: %STARTUP_ERR_LOG%"
del "%STARTUP_LOG%" "%STARTUP_ERR_LOG%" >nul 2>&1

set "SSRVPN_EXE_PATH=%EXE_PATH%"
set "SSRVPN_STARTUP_LOG=%STARTUP_LOG%"
set "SSRVPN_STARTUP_ERR_LOG=%STARTUP_ERR_LOG%"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$exe=$env:SSRVPN_EXE_PATH; $out=$env:SSRVPN_STARTUP_LOG; $err=$env:SSRVPN_STARTUP_ERR_LOG; $p=Start-Process -FilePath $exe -ArgumentList '--verbose' -RedirectStandardOutput $out -RedirectStandardError $err -PassThru; Start-Sleep -Seconds 10; if ($p.HasExited) { Write-Host ('[ERR] SSRVPN 过早退出，退出代码: ' + $p.ExitCode); exit $p.ExitCode } else { Write-Host '[OK] SSRVPN 已启动且 10 秒后仍在运行。'; exit 0 }" > "%TEMP_OUT%" 2>&1
set EXITCODE=%ERRORLEVEL%
type "%TEMP_OUT%"
type "%TEMP_OUT%" >> "%DIAG_LOG%"

if %EXITCODE% NEQ 0 (
    call :log "[ERR] SSRVPN 启动检查失败，退出代码: %EXITCODE%"
    if exist "%STARTUP_LOG%" (
        call :log "最近的启动日志关键字:"
        findstr /i "error fail exception crash" "%STARTUP_LOG%" >> "%DIAG_LOG%" 2>nul
        findstr /i "error fail exception crash" "%STARTUP_LOG%" 2>nul
    )
) else (
    call :log "[OK]  启动检查通过。"
)

:summary
call :log ""
call :log "============================================"
call :log " 诊断完成"
call :log "============================================"
call :log ""
if %MISSING_DLLS% GTR 0 (
    call :log "发现 %MISSING_DLLS% 个缺失文件，请重新解压完整 ZIP 或检查安全软件隔离记录。"
) else (
    call :log "未发现必需文件缺失。若仍无法打开，请把以下文本日志发给开发者："
    call :log "  - ssrvpn_diag.log"
    call :log "  - ssrvpn_startup.log"
    call :log "  - ssrvpn_startup.err.log"
    call :log "不要公开发送 crashes 目录中的 .dmp 文件。"
)
call :log ""
call :log "诊断日志已保存到: %DIAG_LOG%"
del "%TEMP_OUT%" >nul 2>&1
pause
exit /b 0

:log
if "%~1"=="" (
echo.
>> "%DIAG_LOG%" echo.
exit /b 0
)
echo %~1
>> "%DIAG_LOG%" echo %~1
exit /b 0
