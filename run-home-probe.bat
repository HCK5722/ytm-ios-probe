@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-home-probe.ps1" %*
set "EXIT_CODE=%ERRORLEVEL%"
echo.
if "%EXIT_CODE%"=="0" (
  echo 已完成。请打开 probe-result.txt，把全部内容贴回对话。
) else (
  echo 运行失败。请先阅读上面的安装或错误提示。
)
pause
exit /b %EXIT_CODE%
