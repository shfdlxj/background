@echo off
chcp 65001 >nul
if not "%~1"=="" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0background.ps1" %*
    exit /b
)
rem 인자 없이 실행(더블클릭)하면 켜기/끄기 토글
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$f = Join-Path $env:TEMP 'temp-background.pid'; $p = Get-Content $f -ErrorAction SilentlyContinue; if ($p -and (Get-Process -Id ([int]$p) -ErrorAction SilentlyContinue)) { & '%~dp0background.ps1' off } else { & '%~dp0background.ps1' }"
