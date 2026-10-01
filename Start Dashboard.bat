@echo off
cd /d "%~dp0"
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1"
pause
