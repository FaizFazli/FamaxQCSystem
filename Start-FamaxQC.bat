@echo off
title Famax QC System Server
cd /d "%~dp0"

echo ============================================
echo   Famax QC System - starting server
echo   Folder: %CD%
echo ============================================
echo.

node server.js

echo.
echo ============================================
echo   Server stopped (exit code %ERRORLEVEL%)
echo ============================================
pause
