# 🎮 AutoInstantReplay

Script de PowerShell que automatiza la activación y desactivación de **AMD Instant Replay** según la actividad del equipo. Permite mantener la función activa mientras se ejecuta un juego o durante una llamada de Discord, incluso cuando la grabación de escritorio está habilitada.

---

## ¿Cómo funciona?

El script monitorea dos fuentes de actividad independientes:

- **Juegos:** detecta el juego que está en primer plano mediante su ejecutable. Si cambias a otra ventana o minimizas el juego, Instant Replay permanece activo mientras el proceso del juego siga ejecutándose.
- **Discord:** comprueba de forma independiente si Discord está en una llamada de voz o vídeo. No es necesario que haya un juego abierto para activar Instant Replay.

La decisión final combina ambos estados: **si hay un juego activo o Discord está en llamada, Instant Replay se activa**. Solo se desactiva cuando ninguna de las dos condiciones se cumple.

```
┌──────────────────────────────────────────────────────┐
│                  Monitoreo continuo                  │
│                                                      │
│  ┌────────────────────┐  ┌───────────────────────┐  │
│  │ Flujo 1: Juegos     │  │ Flujo 2: Discord      │  │
│  │                    │  │                       │  │
│  │ Juego detectado    │  │ ¿En llamada?          │  │
│  │ ¿Sigue ejecutándose│  │                       │  │
│  │ en segundo plano?  │  │ Sí / No               │  │
│  └─────────┬──────────┘  └───────────┬───────────┘  │
│            │                         │              │
│            └────────────┬────────────┘              │
│                         ▼                           │
│             ¿Juego activo O llamada?                │
│                         │                           │
│               ┌─────────┴─────────┐                 │
│               │                   │                 │
│              Sí                  No                 │
│               │                   │                 │
│               ▼                   ▼                 │
│       Activar Instant      Desactivar Instant       │
│            Replay                 Replay             │
└──────────────────────────────────────────────────────┘
```

Los dos flujos se evalúan por separado. Por ejemplo, si no hay un juego activo y comienza una llamada de Discord, el flujo de Discord puede activar Instant Replay por sí mismo. Del mismo modo, cerrar la llamada no lo desactiva si todavía hay un juego ejecutándose.

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
| `AutoInstantReplay.ps1` | Script principal. Monitorea juegos y Discord, y controla Instant Replay. |
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

**Ubicación recomendada:** guarda el proyecto en `Documentos\Scripts\AutoInstantReplay`. Si aún no existe, crea primero la carpeta `Documentos\Scripts` y dentro de ella `AutoInstantReplay`. Puedes hacerlo desde el Explorador de archivos (File Explorer).

1. Descarga `AutoInstantReplay.ps1` e `Instalar-AutoInstantReplay.ps1` desde el repositorio y coloca ambos archivos dentro de `Documentos\Scripts\AutoInstantReplay` (deben estar en la misma carpeta).
2. Abre el menú **Inicio (Start)**, busca **PowerShell** o **Windows PowerShell** y selecciona **Ejecutar como administrador (Run as administrator)**.
3. En la ventana de PowerShell, ejecuta el instalador con esta ruta:

   ```powershell
   & "$env:USERPROFILE\Documents\Scripts\AutoInstantReplay\Instalar-AutoInstantReplay.ps1"
   ```

   Si guardaste los archivos en otra ubicación, ajusta la ruta.
4. Confirma el aviso de Control de cuentas de usuario (UAC) con **Sí (Yes)**, si aparece.
5. El instalador registra la tarea **AutoInstantReplay** en el Programador de tareas y se elimina automáticamente al finalizar.


**Si no aparece la opción «Ejecutar con PowerShell como administrador»:**

1. Abre el menú **Inicio (Start)** y busca **PowerShell** o **Windows PowerShell**.
2. Haz clic derecho en el resultado y selecciona **Ejecutar como administrador (Run as administrator)**. También puedes seleccionar la opción desde el panel derecho del menú Inicio.
3. En la ventana de PowerShell, ejecuta el instalador usando su ruta completa. Por ejemplo:

   ```powershell
   & "$env:USERPROFILE\Downloads\AutoInstantReplay\Instalar-AutoInstantReplay.ps1"
   ```

   Ajusta la ruta si guardaste los archivos en otra carpeta.
4. Si aparece el aviso de Control de cuentas de usuario (UAC), confirma con **Sí (Yes)**.


La tarea se ejecuta:
- Al iniciar sesión en Windows.
- Al volver de suspensión.

El script se ejecuta en segundo plano y la ventana de PowerShell permanece oculta.

---

## Configuración

Las opciones principales se encuentran al inicio de `AutoInstantReplay.ps1`:

```powershell
$foregroundPollMilliseconds = 500
$discordCheckMilliseconds   = 4000
$maxLogSizeBytes            = 1MB
```

| Variable | Descripción |
|---|---|
| `$foregroundPollMilliseconds` | Intervalo de revisión del proceso en primer plano, en milisegundos. |
| `$discordCheckMilliseconds` | Intervalo de comprobación de la actividad de Discord, en milisegundos. |
| `$maxLogSizeBytes` | Tamaño máximo del log antes de rotarlo. |

El valor predeterminado revisa la ventana en primer plano cada 500 ms y comprueba Discord cada 1000 ms. El log se limita a 1 MB; al superar ese tamaño, el registro anterior se mueve a `instantreplay.log.old` y se reemplaza en la siguiente escritura.

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
- El script modifica el estado de Instant Replay mediante el registro de Windows. No cambia otras opciones de AMD Software.

---

## Licencia

MIT — consulta el archivo [LICENSE](LICENSE) para más detalles.
