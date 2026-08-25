@echo off
REM ============================================================
REM  Famax QC - External calibration due/overdue alert
REM
REM  What Windows Task Scheduler runs, once a morning. See
REM  docs/external-calibration-setup.md for the task settings.
REM
REM  Everything the script prints is appended to
REM  temp\calibration-alert.log, because a scheduled task writes
REM  its output to a console nobody is looking at. When somebody
REM  asks "did the alert go out on the 3rd", that file is the
REM  only thing that can answer.
REM
REM  Pass flags straight through:
REM     Run-CalibrationAlert.bat --dry-run
REM     Run-CalibrationAlert.bat --force
REM ============================================================

cd /d "%~dp0"

if not exist "temp" mkdir "temp"

set LOGFILE=temp\calibration-alert.log

echo. >> "%LOGFILE%"
echo ============================================================ >> "%LOGFILE%"
echo  Run started %DATE% %TIME% >> "%LOGFILE%"
echo ============================================================ >> "%LOGFILE%"

REM 2>&1 so a crash lands in the log too - a stack trace on stderr
REM that goes nowhere is the failure mode this is guarding against.
node scripts\calibration-alert.js %* >> "%LOGFILE%" 2>&1
set RC=%ERRORLEVEL%

echo  Exit code %RC% >> "%LOGFILE%"

REM Handed back to Task Scheduler, which shows it as "Last Run
REM Result". 0 = sent or correctly nothing to send, 1 = something
REM failed and somebody should look.
exit /b %RC%
