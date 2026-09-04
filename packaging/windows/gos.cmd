@echo off
setlocal

rem Prefer Git for Windows' bash. On a machine with WSL enabled the first
rem bash.exe on PATH is C:\Windows\System32\bash.exe, the WSL launcher, which
rem cannot run a Windows path such as %~dp0gos.sh; "where bash.exe" alone
rem used to pick it and gos failed with a confusing error.
set "GOS_BASH="
if exist "%ProgramFiles%\Git\bin\bash.exe" set "GOS_BASH=%ProgramFiles%\Git\bin\bash.exe"
if not defined GOS_BASH if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" set "GOS_BASH=%ProgramFiles(x86)%\Git\bin\bash.exe"
if not defined GOS_BASH if exist "%LocalAppData%\Programs\Git\bin\bash.exe" set "GOS_BASH=%LocalAppData%\Programs\Git\bin\bash.exe"
if not defined GOS_BASH (
  for /f "delims=" %%B in ('where bash.exe 2^>NUL') do (
    if not defined GOS_BASH (
      echo "%%~B" | findstr /I /L /C:"\System32\bash.exe" >NUL || set "GOS_BASH=%%~B"
    )
  )
)
if not defined GOS_BASH (
  echo gos requires Git Bash. Install Git for Windows or run gos inside WSL. 1>&2
  exit /b 1
)

"%GOS_BASH%" "%~dp0gos.sh" %*
exit /b %ERRORLEVEL%
