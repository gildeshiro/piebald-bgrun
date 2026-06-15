@echo off
REM bg-wake-hook.cmd - UserPromptSubmit hook: notifies completion of bgrun jobs.
REM Cheap native gate (mirrors fullstep-wake-hook.cmd): only spawns git-bash if the
REM .pending sentinel exists. No pending job -> exit ~5ms, zero spawn.
REM Invokes bash via the 8.3 path (Piebald's cmd /C does not have git-bash in PATH).
REM Graceful degradation: any failure -> empty stdout -> nothing injected.
if not exist "%USERPROFILE%\.piebald-bg\.pending" exit /b 0
"C:\Progra~1\Git\bin\bash.exe" "%USERPROFILE%\bin\bg-wake.sh" 2>nul
exit /b 0
