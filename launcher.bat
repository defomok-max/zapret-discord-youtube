@echo off
:: codeDPI — alias of start.bat for backward compatibility.
:: Forwards any arguments.
call "%~dp0start.bat" %*
exit /b %ERRORLEVEL%
