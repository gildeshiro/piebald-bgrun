@echo off
REM bg-clean-task.cmd — entry point for the scheduled task `piebald-bg-clean`.
REM Runs the bgrun maintenance sweep (GC completed >6h, kill+purge stuck >24h, reap
REM dead-pid orphans) so the TTL fires even when `bgrun` isn't being used. Invokes
REM bash via the 8.3 path (a scheduled task's environment has no git-bash in PATH).
REM A login shell (-lc) sets HOME so bg-clean resolves ~/.piebald-bg. Always exits 0.
"C:\Progra~1\Git\bin\bash.exe" -lc "$HOME/bin/bg-clean --quiet" 2>nul
exit /b 0
