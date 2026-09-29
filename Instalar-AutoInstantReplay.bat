@echo off
setlocal
title Instalador de AutoInstantReplay
cd /d "%~dp0"

set "SELF=%~f0"
set "SRC=%~dp0"
if "%SRC:~-1%"=="\" set "SRC=%SRC:~0,-1%"

echo ==============================================
echo   AutoInstantReplay - Instalador
echo ==============================================
echo.

rem --- Verificar que estan los dos scripts ---
if not exist "%SRC%\Instalar-AutoInstantReplay.ps1" (
    echo [ERROR] Falta Instalar-AutoInstantReplay.ps1 en esta carpeta.
    pause
    exit /b 1
)
if not exist "%SRC%\AutoInstantReplay.ps1" (
    echo [ERROR] Falta AutoInstantReplay.ps1 en esta carpeta.
    pause
    exit /b 1
)

rem --- Pedir permisos de administrador si hacen falta ---
fltmc >nul 2>&1
if errorlevel 1 (
    if "%~1"=="elevated" (
        echo [ERROR] No se obtuvieron permisos de administrador.
        pause
        exit /b 1
    )
    echo Solicitando permisos de administrador...
    powershell -NoProfile -Command "Start-Process -FilePath '%SELF:'=''%' -ArgumentList 'elevated' -Verb RunAs"
    if errorlevel 1 (
        echo [AVISO] No se concedieron permisos. Instalacion cancelada.
        pause
    )
    exit /b
)

rem --- Carpeta destino: Documentos\Scripts\AutoInstantReplay ---
set "DOCS="
for /f "usebackq delims=" %%D in (`powershell -NoProfile -Command "[Environment]::GetFolderPath('MyDocuments')"`) do set "DOCS=%%D"
if not defined DOCS set "DOCS=%USERPROFILE%\Documents"
set "DEST=%DOCS%\Scripts\AutoInstantReplay"
set "DESTPS=%DEST:'=''%"

rem --- Si ya estan en la carpeta destino, no hay nada que copiar ---
if /i "%SRC%"=="%DEST%" goto instalar

echo Los archivos se copiaran a esta carpeta, para que no se pierdan en Descargas:
echo.
echo   %DEST%
echo.

rem --- Si habia una instalacion previa en ejecucion, detenerla para poder reemplazar los archivos ---
schtasks /end /tn "AutoInstantReplay" >nul 2>&1

if not exist "%DEST%" mkdir "%DEST%"
copy /y "%SRC%\Instalar-AutoInstantReplay.ps1" "%DEST%\" >nul
if errorlevel 1 goto errorcopia
copy /y "%SRC%\AutoInstantReplay.ps1" "%DEST%\" >nul
if errorlevel 1 goto errorcopia

:instalar
rem --- Ejecutar el instalador de PowerShell desde la carpeta destino ---
echo Instalando...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%DEST%\Instalar-AutoInstantReplay.ps1"
if errorlevel 1 goto errorinstalar

rem --- Comprobar que la tarea quedo registrada ---
schtasks /query /tn "AutoInstantReplay" >nul 2>&1
if errorlevel 1 goto errorinstalar

rem --- Arrancar ahora, sin esperar al proximo inicio de sesion ---
echo Iniciando AutoInstantReplay...
schtasks /run /tn "AutoInstantReplay" >nul 2>&1

rem --- Crear el desinstalador (las lineas que empiezan por ::U:: de este archivo) ---
powershell -NoProfile -Command "Get-Content -LiteralPath '%SELF:'=''%' | Where-Object { $_.StartsWith('::U::') } | ForEach-Object { $_.Substring(5) } | Set-Content -LiteralPath '%DESTPS%\Desinstalar-AutoInstantReplay.bat' -Encoding ASCII"
if not exist "%DEST%\Desinstalar-AutoInstantReplay.bat" echo [AVISO] No se pudo crear Desinstalar-AutoInstantReplay.bat.

rem --- Borrar los archivos originales (solo ahora que todo salio bien) ---
if /i not "%SRC%"=="%DEST%" del /f /q "%SRC%\AutoInstantReplay.ps1" "%SRC%\Instalar-AutoInstantReplay.ps1" >nul 2>&1

echo.
echo ==================================================
echo   Instalacion completada
echo ==================================================
echo.
echo Los archivos del programa estan ahora en:
echo.
echo   %DEST%
echo.
echo NO borres esa carpeta: contiene el script que se
echo ejecuta en segundo plano. Ya puedes eliminar lo que
echo haya quedado en la carpeta de descarga.
echo.
echo Para desinstalar, ejecuta dentro de esa carpeta:
echo   Desinstalar-AutoInstantReplay.bat
echo.
pause

rem --- Auto-eliminar este instalador ---
(goto) 2>nul & del /f /q "%SELF%"
exit /b

:errorcopia
echo.
echo [ERROR] No se pudieron copiar los archivos a la carpeta de destino.
echo Los archivos originales no se han modificado.
pause
exit /b 1

:errorinstalar
echo.
echo [ERROR] La instalacion no se completo. Revisa los mensajes anteriores.
echo Los archivos originales siguen en la carpeta de descarga:
echo puedes volver a ejecutar este instalador.
pause
exit /b 1

rem ===== A partir de aqui: texto del desinstalador (no se ejecuta) =====
::U::@echo off
::U::setlocal
::U::title Desinstalar AutoInstantReplay
::U::cd /d "%~dp0"
::U::set "SELF=%~f0"
::U::
::U::echo ==============================================
::U::echo   AutoInstantReplay - Desinstalador
::U::echo ==============================================
::U::echo.
::U::
::U::rem --- Pedir permisos de administrador si hacen falta ---
::U::fltmc >nul 2>&1
::U::if errorlevel 1 (
::U::    if "%~1"=="elevated" (
::U::        echo [ERROR] No se obtuvieron permisos de administrador.
::U::        pause
::U::        exit /b 1
::U::    )
::U::    echo Solicitando permisos de administrador...
::U::    powershell -NoProfile -Command "Start-Process -FilePath '%SELF:'=''%' -ArgumentList 'elevated' -Verb RunAs"
::U::    if errorlevel 1 (
::U::        echo [AVISO] No se concedieron permisos. Desinstalacion cancelada.
::U::        pause
::U::    )
::U::    exit /b
::U::)
::U::
::U::echo Deteniendo y eliminando la tarea AutoInstantReplay...
::U::schtasks /end /tn "AutoInstantReplay" >nul 2>&1
::U::schtasks /delete /tn "AutoInstantReplay" /f >nul 2>&1
::U::
::U::schtasks /query /tn "AutoInstantReplay" >nul 2>&1
::U::if not errorlevel 1 (
::U::    echo [ERROR] No se pudo eliminar la tarea.
::U::    pause
::U::    exit /b 1
::U::)
::U::echo Tarea eliminada.
::U::echo.
::U::
::U::choice /c SN /n /m "Eliminar tambien los archivos del script (log, games-db.json, games-config.json)? [S/N] "
::U::if errorlevel 2 goto conservar
::U::
::U::del /f /q "%~dp0AutoInstantReplay.ps1" "%~dp0instantreplay.log" "%~dp0instantreplay.log.old" "%~dp0games-db.json" "%~dp0games-config.json" >nul 2>&1
::U::echo.
::U::echo Archivos eliminados. La carpeta queda vacia y puedes borrarla a mano.
::U::echo.
::U::pause
::U::(goto) 2>nul & del /f /q "%SELF%"
::U::exit /b
::U::
::U:::conservar
::U::echo.
::U::echo Se conservaron los archivos. Puedes borrar esta carpeta a mano cuando quieras.
::U::echo.
::U::pause
::U::exit /b