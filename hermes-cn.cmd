@echo off
rem hermes-cn —— Hermes 大陆网络加速（Windows 版）
rem 这个文件只是入口，真正干活的是同目录下的 hermes-cn.ps1

rem 控制台代码页切到 UTF-8，否则中文提示会乱码
chcp 65001 >nul

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0hermes-cn.ps1" %*
set "HERMES_CN_RC=%ERRORLEVEL%"
endlocal & exit /b %HERMES_CN_RC%
