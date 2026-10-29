@echo off
setlocal
cd /d "%~dp0"

rem --- 1. Droits administrateur : se relance tout seul si besoin
net session >nul 2>&1
if errorlevel 1 (
    echo Diag-Ami demande les droits administrateur...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

rem --- 2. Mise a jour depuis GitHub (silencieuse : si pas d'internet, on continue avec les fichiers presents)
echo Diag-Ami : recherche de mises a jour...
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { [Net.ServicePointManager]::SecurityProtocol = 'Tls12'; $z = Join-Path $env:TEMP 'diagami.zip'; $d = Join-Path $env:TEMP 'diagami-up'; Invoke-WebRequest 'https://github.com/Tryne-graphik/Diag-Ami/archive/refs/heads/main.zip' -OutFile $z -UseBasicParsing; if (Test-Path $d) { Remove-Item $d -Recurse -Force }; Expand-Archive $z $d -Force; Get-ChildItem (Join-Path $d 'Diag-Ami-main') -File | Where-Object { $_.Name -ne 'Lancer.bat' } | Copy-Item -Destination '%~dp0' -Force; Remove-Item $z -Force; Remove-Item $d -Recurse -Force; Write-Host 'Fichiers a jour.' } catch { Write-Host 'Pas de mise a jour (hors ligne ?), on continue.' }"

rem --- 3. Debloque les fichiers telecharges (evite les avertissements Windows)
powershell -NoProfile -Command "Get-ChildItem '%~dp0' -File | Unblock-File"

rem --- 4. Verifie que tout est la
if not exist "%~dp0DiagAmi.ps1" (
    echo.
    echo ERREUR : DiagAmi.ps1 est introuvable. Telecharge le dossier complet :
    echo https://github.com/Tryne-graphik/Diag-Ami
    pause
    exit /b 1
)

rem --- 5. Lance la fenetre
start "" powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0DiagAmi.ps1"
exit /b 0
