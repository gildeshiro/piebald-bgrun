@echo off
REM bg-wake-hook.cmd - UserPromptSubmit hook: notifica conclusao de jobs do wrapper bg.
REM Gate nativo barato (espelha fullstep-wake-hook.cmd): so spawna git-bash se o
REM marcador .pending existir. Sem job pendente -> exit ~5ms, zero spawn.
REM Invoca o bash pelo caminho 8.3 (o cmd /C do Piebald nao tem git-bash no PATH).
REM Degrade gracioso: qualquer falha -> stdout vazio -> nao injeta.
if not exist "%USERPROFILE%\.piebald-bg\.pending" exit /b 0
"C:\Progra~1\Git\bin\bash.exe" "%USERPROFILE%\bin\bg-wake.sh" 2>nul
exit /b 0
