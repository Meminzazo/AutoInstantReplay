# 🎮 AutoInstantReplay

Script de PowerShell que automatiza la activación y desactivación de **AMD Instant Replay** según la actividad del equipo. Permite activar AMD Instant Replay automáticamente durante los juegos o las llamadas de Discord. También incluye una excepción para desactivarlo mientras haya software de streaming abierto.

---

## ¿Cómo funciona?

El script monitorea dos fuentes de actividad independientes y una condición de excepción:

- **Juegos:** detecta el juego que está en primer plano mediante su ejecutable. Si cambias a otra ventana o minimizas el juego, Instant Replay permanece activo mientras el proceso del juego siga ejecutándose.
- **Discord:** comprueba de forma independiente si Discord está en una llamada de voz o vídeo. No es necesario que haya un juego abierto para activar Instant Replay.
- **Software de streaming:** comprueba si alguno de los procesos configurados está abierto. Si detecta uno, bloquea la activación de Instant Replay, aunque haya un juego o una llamada activos.

La decisión final es: **si hay software de streaming abierto, Instant Replay se desactiva; de lo contrario, se activa si hay un juego activo o Discord está en llamada**. Si no se cumple ninguna condición de activación, permanece desactivado.

```
┌──────────────────────────────────────────────────────┐
│                  Monitoreo continuo                  │
│                                                      │
│  ┌────────────────────┐  ┌───────────────────────┐  │
│  │ Flujo 1: Juegos     │  │ Flujo 2: Discord      │  │
│  │ Juego activo       │  │ ¿En llamada?          │  │
│  └─────────┬──────────┘  └───────────┬───────────┘  │
│            │                         │              │
│            └────────────┬────────────┘              │
│                         ▼                           │
│             ¿Juego activo O llamada?                │
│                         │                           │
│                         ▼                           │
│           ¿Streaming abierto?                       │
│                  │             │                    │
│                 Sí             No                   │
│                  │             │                    │
│                  ▼             ▼                    │
│          Desactivar       ¿Hay activador?           │
│        Instant Replay       │       │               │
│                            Sí      No               │
│                             │       │               │
│                             ▼       ▼               │
│                          Activar  Desactivar        │
│                        Instant    Instant           │
│                         Replay    Replay            │
└──────────────────────────────────────────────────────┘
```

Los dos flujos de activación se evalúan por separado. Por ejemplo, si no hay un juego activo y comienza una llamada de Discord, el flujo de Discord puede activar Instant Replay por sí mismo. Del mismo modo, cerrar la llamada no lo desactiva si todavía hay un juego ejecutándose. La detección de software de streaming tiene prioridad sobre ambos activadores.

---

## Detección de juegos

La base de datos de juegos se construye al iniciar el script. No realiza un escaneo completo de los discos: consulta ubicaciones conocidas de los launchers y busca ejecutables dentro de las carpetas de instalación encontradas.

Se contemplan instalaciones de:

- Steam
- Epic Games
- EA app
- Ubisoft Connect
- GOG
- Battle.net
- Xbox / Microsoft Store
- Directorios y ejecutables definidos manualmente

La detección se basa en la ruta del ejecutable, no solamente en el nombre del proceso. Esto ayuda a distinguir el juego de otros programas que puedan tener nombres similares.

La base de datos se actualiza al iniciar el script. Si instalas un juego nuevo o cambias su ubicación, reinicia el script para reconstruirla.

### Juegos personalizados

El archivo `games-config.json` permite agregar carpetas o ejecutables que no se detecten automáticamente.

Al iniciar por primera vez, el script crea este archivo en la misma carpeta. Puedes editar sus listas:

```json
{
  "ManualDirectories": [
    "F:\\Games",
    "D:\\Emulators"
  ],
  "ManualExecutables": [
    "F:\\Games\\MiJuego\\Game.exe"
  ]
}
```

- `ManualDirectories`: carpetas de juegos que se deben revisar.
- `ManualExecutables`: rutas completas a ejecutables específicos.

Después de modificar la configuración, reinicia el script para que los cambios se incorporen a la base de datos.

---

## Archivos

| Archivo | Descripción |
|---|---|
| `AutoInstantReplay.ps1` | Script principal. Monitorea juegos, Discord y software de streaming, y controla Instant Replay. |
| `Instalar-AutoInstantReplay.ps1` | Registra la tarea en el Programador de tareas de Windows y se elimina automáticamente. |
| `games-config.json` | Configuración opcional para agregar juegos manualmente. Se genera al iniciar. |
| `games-db.json` | Base de datos de juegos detectados. Se genera y actualiza al iniciar. |
| `instantreplay.log` | Registro de actividad. Se crea junto al script y tiene rotación de tamaño. |

---

## Requisitos

- Windows 10 / 11
- PowerShell 5.1 o superior
- AMD Software: Adrenalin Edition
- Una GPU AMD compatible con AMD Instant Replay
- Discord (opcional; solo si quieres utilizar la detección de llamadas)

La función Instant Replay debe estar disponible y configurada en AMD Software. El script controla su estado mediante el valor de registro `HKCU:\\Software\\AMD\\DVR\\InstantReplayEnabled`.

---

## Instalación

Hay dos formas de instalar el proyecto:

- **Instalación automática (recomendada):** ejecuta `Instalar-AutoInstantReplay.bat`. El archivo BAT solicita permisos de administrador, copia los archivos necesarios a la carpeta de Documentos, ejecuta el instalador de PowerShell, registra la tarea y la inicia inmediatamente.
- **Instalación manual:** descarga los archivos y ejecuta directamente el instalador de PowerShell desde una consola elevada. Esta opción permite elegir la ubicación y controlar cada paso.

### Opción 1: instalación automática con `Instalar-AutoInstantReplay.bat`

1. Descarga el repositorio como ZIP desde GitHub (**Code → Download ZIP**) o descarga los archivos de instalación.
2. Si descargaste un ZIP, extráelo primero. No ejecutes el BAT directamente dentro del archivo comprimido.
3. Asegúrate de que estos tres archivos estén juntos en la misma carpeta:
   - `Instalar-AutoInstantReplay.bat`
   - `Instalar-AutoInstantReplay.ps1`
   - `AutoInstantReplay.ps1`
4. Haz doble clic en `Instalar-AutoInstantReplay.bat`.
5. Si Windows muestra el aviso de Control de cuentas de usuario (**User Account Control / Control de cuentas de usuario**, UAC), acepta con **Sí (Yes)** para permitir la instalación. El BAT solicita elevación automáticamente; no es necesario abrir PowerShell como administrador.
6. El instalador copia los dos archivos de PowerShell a:
   
   `Documentos\\Scripts\\AutoInstantReplay`

   La ruta de Documentos se obtiene desde Windows, por lo que también funciona si la carpeta está redirigida a otra ubicación (por ejemplo, OneDrive).
7. El instalador registra la tarea programada **AutoInstantReplay** y, si todo termina correctamente, el BAT comprueba que la tarea exista y la inicia de inmediato, sin esperar al siguiente inicio de sesión.
8. Se genera en la carpeta de destino un archivo `Desinstalar-AutoInstantReplay.bat`. Puedes usarlo más adelante para quitar la tarea y, opcionalmente, los archivos del programa.
9. Cuando la instalación termina correctamente, el BAT elimina los instaladores de PowerShell de la carpeta de origen y se elimina a sí mismo. Los archivos de la carpeta de destino permanecen.

**Importante:** no elimines `Documentos\\Scripts\\AutoInstantReplay`; contiene el script que se ejecuta en segundo plano y los archivos de configuración o registro que correspondan. Si la instalación falla, el BAT muestra un error y conserva los archivos originales para que puedas volver a intentarlo. Si cancelas el aviso de administrador, la instalación no se realiza.

### Opción 2: instalación manual con PowerShell

Usa este método si prefieres instalar en una ruta distinta o no quieres utilizar el BAT.

1. Descarga y extrae el repositorio, o descarga los archivos necesarios.
2. Coloca `AutoInstantReplay.ps1` y `Instalar-AutoInstantReplay.ps1` juntos en la carpeta donde quieras mantener el programa. El instalador de PowerShell busca el script principal en su propia carpeta.
3. Abre **Start / Inicio**, busca **PowerShell** o **Windows PowerShell**, haz clic derecho y selecciona **Run as administrator / Ejecutar como administrador**. Si no aparece esa opción en el menú contextual, selecciónala desde el panel derecho del menú Inicio.
4. Ejecuta el instalador usando su ruta completa. Por ejemplo, si elegiste la ubicación recomendada:

   ```powershell
   & "$env:USERPROFILE\\Documents\\Scripts\\AutoInstantReplay\\Instalar-AutoInstantReplay.ps1"
   ```

   Si lo guardaste en otra ubicación, sustituye la ruta por la carpeta que elegiste.
5. Confirma el aviso UAC si aparece. El instalador verifica que el script principal esté presente y que PowerShell se esté ejecutando como administrador.
6. Al finalizar, se registra la tarea **AutoInstantReplay**, configurada para ejecutarse al iniciar sesión y al volver de suspensión. El instalador de PowerShell se elimina automáticamente.

En la instalación manual, el BAT no se ejecuta, por lo que **no se crea automáticamente** el archivo `Desinstalar-AutoInstantReplay.bat`. Para iniciar la tarea sin cerrar sesión, ejecuta:

```powershell
Start-ScheduledTask -TaskName "AutoInstantReplay"
```


---

## Configuración

Las opciones principales se encuentran al inicio de `AutoInstantReplay.ps1`:

```powershell
$foregroundPollMilliseconds = 500
$discordCheckMilliseconds   = 5000
$maxLogSizeBytes            = 1MB
```

| Variable | Descripción |
|---|---|
| `$foregroundPollMilliseconds` | Intervalo de revisión del proceso en primer plano, en milisegundos. |
| `$discordCheckMilliseconds` | Intervalo de comprobación de la actividad de Discord, en milisegundos. |
| `$maxLogSizeBytes` | Tamaño máximo del log antes de rotarlo. |
| `$streamingProcesses` | Nombres de procesos que bloquean Instant Replay mientras estén abiertos. Se indican sin la extensión `.exe`. |

El valor predeterminado revisa la ventana en primer plano cada 500 ms. Cada 5000 ms comprueba Discord y si hay software de streaming abierto. El log se limita a 1 MB; al superar ese tamaño, el registro anterior se mueve a `instantreplay.log.old` y se reemplaza en la siguiente escritura.

### Excepción de software de streaming

La lista `$streamingProcesses`, ubicada al inicio de `AutoInstantReplay.ps1`, contiene los nombres de los procesos que bloquean Instant Replay:

```powershell
$streamingProcesses = @(
    'obs64',
    'obs32',
    'Streamlabs Desktop',
    'XSplit.Core',
    'Twitch Studio'
)
```

La detección se basa en que el proceso esté ejecutándose; no comprueba si el programa está transmitiendo, grabando o simplemente abierto. Mientras cualquiera de los procesos de la lista esté activo, Instant Replay permanece desactivado. Al cerrar el software, se reanuda la lógica normal de juegos y Discord. Para agregar o quitar programas, modifica esta lista y reinicia el script.

---

## Registro (log)

El archivo `instantreplay.log` se guarda en la misma carpeta que el script. Registra el inicio, la detección de juegos, los cambios en el estado de Discord y las activaciones o desactivaciones de Instant Replay.

Ejemplo:

```text
[2026-09-27 13:45:47] AutoInstantReplay iniciado
[2026-09-27 13:45:47] Base de datos actualizada: 26 juegos
[2026-09-27 13:45:47] Índice de ejecutables creado: 183 ejecutables
[2026-09-27 13:45:48] JUEGO ACTIVO: [Steam] Nombre del juego
[2026-09-27 13:45:48] Instant Replay ACTIVADO
[2026-09-27 14:00:00] STREAMING DETECTADO: Instant Replay bloqueado
[2026-09-27 14:00:00] Instant Replay DESACTIVADO
[2026-09-27 14:10:12] DISCORD EN LLAMADA
[2026-09-27 14:35:00] JUEGO INACTIVO
[2026-09-27 14:35:01] DISCORD SIN LLAMADA
[2026-09-27 14:35:01] Instant Replay DESACTIVADO
```

Los mensajes son ilustrativos; los nombres de juegos y horarios dependerán de la actividad detectada.

---

## Desinstalar

Abre PowerShell como administrador y ejecuta:

```powershell
Stop-ScheduledTask -TaskName "AutoInstantReplay"
Unregister-ScheduledTask -TaskName "AutoInstantReplay" -Confirm:$false
```

Después, elimina manualmente la carpeta donde guardaste los archivos. Si el script se está ejecutando, detén primero la tarea.

---

## Notas

- AutoInstantReplay es independiente de [AutoSuspend](https://github.com/Meminzazo/AutoSuspend).
- La detección de llamadas de Discord se basa en la actividad de red del proceso y puede depender de cambios en el funcionamiento de Discord.
- La detección de software de streaming comprueba únicamente si los procesos configurados están abiertos; no determina si están transmitiendo o grabando.
- El script modifica el estado de Instant Replay mediante el registro de Windows. No cambia otras opciones de AMD Software.

---

## Licencia

MIT — consulta el archivo [LICENSE](LICENSE) para más detalles.
