@echo off
setlocal

rem 1) Пытаемся запустить именно PowerShell 7+
set PWSH_EXE=%ProgramFiles%\PowerShell\7\pwsh.exe
if exist "%PWSH_EXE%" (
  set PWSH="%PWSH_EXE%"
) else (
  set PWSH=pwsh
)

rem 2) Скрипт запускается из папки, где лежит main
set SCRIPT_DIR=%~dp0

%PWSH% -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%shiki.main.ps1"

endlocal
