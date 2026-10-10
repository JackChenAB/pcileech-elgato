@echo off
REM ---------------------------------------------------------------------------
REM  Interactive wizard to generate a pcileech-hd60pro Vivado project.
REM  Pick a board from the menu (or pass one as an argument), and it runs the
REM  matching vivado_generate_project_<board>.tcl. After this, open the project
REM  and run vivado_build.tcl to build the bitstream (see build.md).
REM
REM  Usage:  generate.bat                 (menu)
REM          generate.bat squirrel        (skip the menu)
REM  Vivado: taken from %VIVADO%, else PATH, else C:\ or D:\Xilinx\Vivado\*.
REM ---------------------------------------------------------------------------
setlocal enableextensions
cd /d "%~dp0"

set "TCL="
set "PROJ="
set "SEL=%~1"
if not "%SEL%"=="" goto :map

echo.
echo Generate a pcileech-hd60pro Vivado project.
echo.
echo    1) squirrel      PCIeSquirrel  (XC7A35T)
echo    2) enigma_x1     Enigma-X1     (XC7A75T)
echo    3) captain_75T   Captain 75T   (XC7A75T)
echo    4) m2            Screamer M2   (XC7A35T)
echo.
set /p "SEL=Board [1-4]: "

:map
if "%SEL%"=="1" set "SEL=squirrel"
if "%SEL%"=="2" set "SEL=enigma_x1"
if "%SEL%"=="3" set "SEL=captain_75T"
if "%SEL%"=="4" set "SEL=m2"

if /i "%SEL%"=="squirrel"    ( set "TCL=vivado_generate_project_squirrel.tcl"    & set "PROJ=pcileech_squirrel" )
if /i "%SEL%"=="enigma_x1"   ( set "TCL=vivado_generate_project_enigma_x1.tcl"   & set "PROJ=pcileech_enigma_x1" )
if /i "%SEL%"=="captain_75T" ( set "TCL=vivado_generate_project_captain_75T.tcl" & set "PROJ=pcileech_enigma_x1" )
if /i "%SEL%"=="m2"          ( set "TCL=vivado_generate_project_m2.tcl"          & set "PROJ=pcileech_screamer_m2" )

if not defined TCL ( echo Invalid choice: "%SEL%" & exit /b 1 )
if not exist "%TCL%" ( echo Cannot find %TCL% in "%CD%". & exit /b 1 )

REM --- locate Vivado -----------------------------------------------------------
set "VIV=%VIVADO%"
if not defined VIV for /f "delims=" %%I in ('where vivado.bat 2^>nul') do if not defined VIV set "VIV=%%I"
if not defined VIV for /f "delims=" %%I in ('where vivado 2^>nul')     do if not defined VIV set "VIV=%%I"
if not defined VIV for %%D in ("C:\Xilinx\Vivado" "D:\Xilinx\Vivado" "D:\Xilinix\Vivado") do (
    if exist "%%~D\" for /f "delims=" %%V in ('dir /b /ad /on "%%~D" 2^>nul') do (
        if exist "%%~D\%%V\bin\vivado.bat" set "VIV=%%~D\%%V\bin\vivado.bat"
    )
)
if not defined VIV (
    echo Vivado not found. Set VIVADO to your vivado.bat and retry, e.g.:
    echo     set VIVADO=C:\Xilinx\Vivado\2023.2\bin\vivado.bat
    exit /b 1
)

echo.
echo Board   : %SEL%  (project %PROJ%)
echo Vivado  : %VIV%
echo Script  : %TCL%
echo.
"%VIV%" -source %TCL% -notrace -nolog -nojournal
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" ( echo Vivado exited with code %RC%. & exit /b %RC% )

echo.
echo Project generated: %PROJ%
echo Next: open %PROJ%\%PROJ%.xpr (or source vivado_build.tcl) to build the bitstream.
exit /b 0
