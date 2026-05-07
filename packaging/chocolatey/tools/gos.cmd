@echo off
setlocal

where bash.exe >NUL 2>NUL
if errorlevel 1 (
  echo gos requires Git Bash on PATH. Install Git for Windows or run gos inside WSL.
  exit /b 1
)

bash.exe "%~dp0gos.sh" %*
exit /b %ERRORLEVEL%
