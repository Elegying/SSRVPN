@echo off
cd /d "%~dp0"
echo SSRVPN Safe Mode 启动中... 日志: ssrvpn_safe.log
echo 启动时间: %date% %time% > "%~dp0ssrvpn_safe.log"
"%~dp0ssrvpn_windows.exe" --safe-mode --verbose >> "%~dp0ssrvpn_safe.log" 2>&1
set EXITCODE=%ERRORLEVEL%
echo 退出代码: %EXITCODE% >> "%~dp0ssrvpn_safe.log"

if %EXITCODE% NEQ 0 (
    echo ============================================
    echo  SSRVPN 安全模式启动失败 (退出代码: %EXITCODE%)
    echo ============================================
    echo.
    echo 日志已保存到: ssrvpn_safe.log
    echo.
    echo 常见原因:
    echo   1. 缺少 DirectX 组件 (d3dcompiler_47.dll)
    echo   2. 文件被 Windows SmartScreen 拦截
    echo   3. VC++ 运行时不完整
    echo.
    echo 请运行 SSRVPN_Diag.bat 进行完整诊断。
    echo.
    pause
)
