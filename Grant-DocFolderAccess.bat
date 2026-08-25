@echo off
title Famax QC - grant write access to document folder

REM One-time fix: C:\Users\FamaxQC_Doc inherits the read-only ACL of C:\Users, so
REM the node server (running as a normal user) cannot create part folders in it.
REM Just double-click this file - it re-launches itself with administrator rights.

if not "%~1"=="elevated" (
    echo Requesting administrator rights...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList 'elevated' -Verb RunAs"
    exit /b
)

set "DOCROOT=C:\Users\FamaxQC_Doc"

echo ============================================
echo   Granting Modify on %DOCROOT%
echo   to the local Users group (SID S-1-5-32-545)
echo ============================================
echo.
icacls "%DOCROOT%" /grant "*S-1-5-32-545:(OI)(CI)M" /T /C
echo.
echo --- Resulting permissions ---
icacls "%DOCROOT%"
echo.
echo Done. Generate the WI again - no server restart needed.
pause
