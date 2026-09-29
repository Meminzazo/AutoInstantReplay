# ============================================================
# AutoInstantReplay.ps1
#
# AMD Instant Replay automático
#
# ACTIVACIÓN INDEPENDIENTE:
#   1. Juego detectado
#   2. Discord en llamada
#
# La activación ocurre si cualquiera de los dos está activo.
#
# EXCEPCIÓN: si hay software de streaming abierto (ver
# $streamingProcesses), Instant Replay NUNCA se activa.
#
# La base de juegos NO escanea discos completos.
# Solo utiliza:
#   - Steam libraries
#   - Epic manifests
#   - EA
#   - Ubisoft Connect
#   - GOG
#   - Battle.net
#   - Xbox / Microsoft Store
#   - Rutas/EXE definidos manualmente
#
# La detección de juegos se actualiza UNA VEZ al iniciar.
# ============================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'

# ============================================================
# CONFIGURACIÓN
# ============================================================

$scriptRoot = $PSScriptRoot

$logFile          = Join-Path $scriptRoot 'instantreplay.log'
$gameDatabaseFile = Join-Path $scriptRoot 'games-db.json'
$gameConfigFile   = Join-Path $scriptRoot 'games-config.json'

$foregroundPollMilliseconds = 500
$discordCheckMilliseconds   = 5000
$maxLogSizeBytes            = 1MB

$amdRegistryPath       = 'HKCU:\Software\AMD\DVR'
$amdInstantReplayValue = 'InstantReplayEnabled'

$discordProcessName = 'Discord'

# Si alguno de estos procesos está abierto, Instant Replay NO se activa
# (aunque haya un juego o una llamada). Nombres de proceso sin ".exe".
$streamingProcesses = @(
    'obs64',
    'obs32',
    'Streamlabs Desktop',
    'XSplit.Core',
    'Twitch Studio'
)

# Rango de puertos UDP que Discord abre durante llamadas de voz/vídeo.
$discordVoicePortMin = 50000
$discordVoicePortMax = 65535

# Puerto remoto de QUIC / HTTP-3. Discord lo usa para tráfico web
# y de señalización, NO para voz. Se excluye explícitamente para
# evitar falsos positivos.
$quicRemotePort = 443

# ============================================================
# WIN32
# ============================================================

if (-not ('AutoInstantReplayWin32' -as [type])) {

    Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class AutoInstantReplayWin32
{
    public const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(
        IntPtr hWnd,
        out uint processId
    );

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr OpenProcess(
        uint processAccess,
        bool bInheritHandle,
        uint processId
    );

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool CloseHandle(
        IntPtr hObject
    );

    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool QueryFullProcessImageName(
        IntPtr hProcess,
        uint flags,
        StringBuilder exeName,
        ref uint size
    );
}
'@
}

# ============================================================
# ESTADO GLOBAL
# ============================================================

$script:gameDatabase         = @()
$script:gameExecutableIndex  = @{}

$script:lastForegroundHwnd        = [IntPtr]::Zero
$script:lastForegroundProcessPath = $null
$script:lastGame                  = $null

# [P0] PID del juego activo para verificar si sigue vivo cuando
# está en background. Se actualiza al detectar un juego en foreground.
$script:activeGamePid = 0

$script:discordInCall    = $false
$script:lastDiscordCheck = [datetime]::MinValue

$script:instantReplayState = $null

# Software de streaming abierto (se actualiza junto con la revisión de Discord).
$script:streamingActive = $false

# ============================================================
# LOG
# ============================================================

function Write-Log {
    param(
        [string]$Message
    )

    try {

        if (Test-Path $logFile) {

            $size = (Get-Item $logFile).Length

            if ($size -gt $maxLogSizeBytes) {

                $old = "$logFile.old"

                Remove-Item $old -Force -ErrorAction SilentlyContinue
                Move-Item $logFile $old -Force -ErrorAction SilentlyContinue
            }
        }

        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $line = "[$timestamp] $Message"

        Add-Content -Path $logFile `
            -Value $line `
            -Encoding UTF8
    }
    catch {
    }

    # [P4] Salida en consola con color segun el tipo de mensaje.
    $color = if ($Message -match '^ERROR') { 'Red' }
             elseif ($Message -match '^(WARN|AVISO)') { 'Yellow' }
             elseif ($Message -match '(ACTIVADO|JUEGO ACTIVO|DISCORD EN LLAMADA)') { 'Green' }
             elseif ($Message -match '(DESACTIVADO|JUEGO INACTIVO|DISCORD SIN LLAMADA)') { 'Yellow' }
             else { 'Gray' }

    Write-Host "[$( Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor $color
}

# ============================================================
# NORMALIZAR RUTAS
# ============================================================

function Normalize-Path {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    try {

        $full = [System.IO.Path]::GetFullPath($Path)

        return $full.TrimEnd('\').ToLowerInvariant()
    }
    catch {

        return $Path.TrimEnd('\').ToLowerInvariant()
    }
}

# ============================================================
# CONFIGURACIÓN MANUAL
# ============================================================

function Initialize-GameConfig {

    if (Test-Path $gameConfigFile) {
        return
    }

    $config = [ordered]@{

        ManualDirectories = @(
            # Ejemplo:
            # "F:\Games",
            # "D:\Emulators"
        )

        ManualExecutables = @(
            # Ejemplo:
            # "F:\Games\MiJuego\Game.exe"
        )
    }

    $config |
        ConvertTo-Json -Depth 5 |
        Set-Content -Path $gameConfigFile -Encoding UTF8

    Write-Log 'Creado games-config.json'
}

function Get-GameConfig {

    Initialize-GameConfig

    try {

        $config = Get-Content $gameConfigFile -Raw |
            ConvertFrom-Json

        return $config
    }
    catch {

        Write-Log 'ERROR leyendo games-config.json'
        return [pscustomobject]@{
            ManualDirectories = @()
            ManualExecutables = @()
        }
    }
}

# ============================================================
# EXE EXCLUSIONES
#
# [P7] Renombrada de Test-ExcludedGameExecutable a
# Test-ValidGameExecutable para reflejar lo que realmente
# devuelve: true = ejecutable válido, false = excluido.
# ============================================================

function Test-ValidGameExecutable {

    param(
        [string]$Name
    )

    $n = $Name.ToLowerInvariant()

    $excluded = @(
        'unins000.exe',
        'uninstall.exe',
        'uninstaller.exe',
        'crashhandler.exe',
        'crashhandler64.exe',
        'crashreportclient.exe',
        'reportcrash.exe',
        'updater.exe',
        'update.exe',
        'launcher.exe',
        'setup.exe',
        'install.exe',
        'installer.exe',
        'repair.exe',
        'bootstrapper.exe',
        'redist.exe',
        'vcredist.exe',
        'dxsetup.exe',
        'easyanticheat_launcher.exe'
    )

    return ($excluded -notcontains $n)
}

# ============================================================
# BUSCAR EXE DENTRO DE UNA INSTALACIÓN
#
# IMPORTANTE:
# Aquí sí se utiliza búsqueda recursiva, pero únicamente
# dentro de la carpeta concreta de un juego.
# ============================================================

function Find-GameExecutables {

    param(
        [string]$Directory
    )

    $result = New-Object System.Collections.Generic.List[string]

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        return @()
    }

    try {

        Get-ChildItem `
            -LiteralPath $Directory `
            -Filter '*.exe' `
            -File `
            -Recurse `
            -ErrorAction SilentlyContinue |
        ForEach-Object {

            # [P7] Actualizada para usar el nombre corregido.
            if (Test-ValidGameExecutable $_.Name) {

                $normalized = Normalize-Path $_.FullName

                if ($normalized) {
                    $result.Add($normalized)
                }
            }
        }
    }
    catch {
    }

    return $result.ToArray()
}

# ============================================================
# STEAM
# ============================================================

function Get-SteamInstallPaths {

    $paths = New-Object System.Collections.Generic.List[string]

    $registryPaths = @(
        'HKCU:\Software\Valve\Steam',
        'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
        'HKLM:\SOFTWARE\Valve\Steam'
    )

    foreach ($key in $registryPaths) {

        try {

            if (Test-Path $key) {

                $props = Get-ItemProperty $key

                foreach ($property in @('SteamPath','InstallPath')) {

                    if ($props.$property) {

                        $path = $props.$property

                        if (Test-Path $path) {
                            $paths.Add((Normalize-Path $path))
                        }
                    }
                }
            }
        }
        catch {
        }
    }

    return $paths | Select-Object -Unique
}

function Get-SteamLibraries {

    $libraries = New-Object System.Collections.Generic.List[string]

    foreach ($steam in Get-SteamInstallPaths) {

        $main = Join-Path $steam 'steamapps'

        if (Test-Path $main) {
            $libraries.Add($steam)
        }

        $vdf = Join-Path $main 'libraryfolders.vdf'

        if (-not (Test-Path $vdf)) {
            continue
        }

        try {

            $content = Get-Content $vdf -Raw

            # Compatible con las estructuras modernas y antiguas
            $matches = [regex]::Matches(
                $content,
                '(?im)"path"\s*"([^"]+)"'
            )

            foreach ($match in $matches) {

                $path = $match.Groups[1].Value `
                    -replace '\\\\','\'

                if (Test-Path $path) {
                    $libraries.Add((Normalize-Path $path))
                }
            }
        }
        catch {
        }
    }

    return $libraries | Select-Object -Unique
}

function Get-SteamGames {

    $games = New-Object System.Collections.Generic.List[object]

    foreach ($library in Get-SteamLibraries) {

        $manifestDirectory = Join-Path $library 'steamapps'

        if (-not (Test-Path $manifestDirectory)) {
            continue
        }

        Get-ChildItem `
            -LiteralPath $manifestDirectory `
            -Filter 'appmanifest_*.acf' `
            -File `
            -ErrorAction SilentlyContinue |
        ForEach-Object {

            try {

                $content = Get-Content $_.FullName -Raw

                $nameMatch = [regex]::Match(
                    $content,
                    '(?im)"name"\s*"([^"]+)"'
                )

                $installMatch = [regex]::Match(
                    $content,
                    '(?im)"installdir"\s*"([^"]+)"'
                )

                $appidMatch = [regex]::Match(
                    $_.Name,
                    'appmanifest_(\d+)\.acf'
                )

                if (-not $installMatch.Success) {
                    return
                }

                $installDir = Join-Path `
                    $manifestDirectory `
                    'common'

                $installDir = Join-Path `
                    $installDir `
                    $installMatch.Groups[1].Value

                if (-not (Test-Path $installDir)) {
                    return
                }

                $name = $nameMatch.Groups[1].Value

                $appId = $null

                if ($appidMatch.Success) {
                    $appId = $appidMatch.Groups[1].Value
                }

                $executables = Find-GameExecutables $installDir

                if ($executables.Count -eq 0) {
                    return
                }

                $games.Add([pscustomobject]@{
                    Name             = $name
                    Launcher         = 'Steam'
                    AppId            = $appId
                    InstallDirectory = Normalize-Path $installDir
                    Executables      = $executables
                })
            }
            catch {
            }
        }
    }

    return $games.ToArray()
}

# ============================================================
# EPIC GAMES
# ============================================================

function Get-EpicManifestDirectories {

    # [P3] Eliminada la ruta duplicada. Se agrega el path
    # alternativo real que Epic usa en algunas instalaciones.
    $paths = @(
        "$env:ProgramData\Epic\EpicGamesLauncher\Data\Manifests",
        "$env:LocalAppData\EpicGamesLauncher\Saved\Config\Windows"
    )

    return $paths |
        Where-Object {
            Test-Path $_
        } |
        Select-Object -Unique
}

function Get-EpicGames {

    $games = New-Object System.Collections.Generic.List[object]

    foreach ($manifestDir in Get-EpicManifestDirectories) {

        Get-ChildItem `
            -LiteralPath $manifestDir `
            -Filter '*.item' `
            -File `
            -ErrorAction SilentlyContinue |
        ForEach-Object {

            try {

                $item = Get-Content $_.FullName -Raw |
                    ConvertFrom-Json

                if (-not $item.InstallLocation) {
                    return
                }

                $installDir = $item.InstallLocation

                if (-not (Test-Path $installDir)) {
                    return
                }

                $executables = Find-GameExecutables $installDir

                if ($executables.Count -eq 0) {
                    return
                }

                $name = $item.DisplayName

                if (-not $name) {
                    $name = $_.BaseName
                }

                $games.Add([pscustomobject]@{
                    Name             = $name
                    Launcher         = 'Epic'
                    AppId            = $item.AppName
                    InstallDirectory = Normalize-Path $installDir
                    Executables      = $executables
                })
            }
            catch {
            }
        }
    }

    return $games.ToArray()
}

# ============================================================
# REGISTRY INSTALLATIONS
#
# Se consultan claves conocidas de primer nivel.
# NO se hace búsqueda recursiva del Registry.
#
# [P2] Agregada la variante 'Install Dir' (con espacio) que
# usa EA en sus entradas de registro.
# ============================================================

function Get-RegistryInstalledGames {

    param(
        [string]$Launcher,
        [string[]]$RegistryRoots
    )

    $games = New-Object System.Collections.Generic.List[object]

    foreach ($root in $RegistryRoots) {

        if (-not (Test-Path $root)) {
            continue
        }

        try {

            Get-ChildItem $root -ErrorAction SilentlyContinue |
            ForEach-Object {

                try {

                    $props = Get-ItemProperty $_.PSPath

                    $installDir = $null

                    foreach ($property in @(
                        'InstallLocation',
                        'InstallDir',
                        'Install Dir',
                        'InstallPath',
                        'Path',
                        'Location'
                    )) {

                        if ($props.$property) {

                            if (Test-Path $props.$property) {
                                $installDir = $props.$property
                                break
                            }
                        }
                    }

                    if (-not $installDir) {
                        return
                    }

                    $executables = Find-GameExecutables $installDir

                    if ($executables.Count -eq 0) {
                        return
                    }

                    $name = $props.DisplayName

                    if (-not $name) {
                        $name = $_.PSChildName
                    }

                    $games.Add([pscustomobject]@{
                        Name             = $name
                        Launcher         = $Launcher
                        AppId            = $null
                        InstallDirectory = Normalize-Path $installDir
                        Executables      = $executables
                    })
                }
                catch {
                }
            }
        }
        catch {
        }
    }

    return $games.ToArray()
}

# ============================================================
# EA
# ============================================================

function Get-EAGames {

    $roots = @(
        'HKLM:\SOFTWARE\Electronic Arts',
        'HKLM:\SOFTWARE\WOW6432Node\Electronic Arts',
        'HKCU:\Software\Electronic Arts'
    )

    return Get-RegistryInstalledGames `
        -Launcher 'EA' `
        -RegistryRoots $roots
}

# ============================================================
# UBISOFT
#
# [P1] Corregida la ruta del registro. Ubisoft Connect guarda
# las rutas de instalacion en:
#   \Ubisoft\Launcher\Installs\{gameId}\InstallDir
# La versión anterior apuntaba a \Ubisoft directamente, lo que
# hacía que Get-RegistryInstalledGames nunca encontrara juegos.
# ============================================================

function Get-UbisoftGames {

    $roots = @(
        'HKLM:\SOFTWARE\WOW6432Node\Ubisoft\Launcher\Installs',
        'HKLM:\SOFTWARE\Ubisoft\Launcher\Installs',
        'HKCU:\Software\Ubisoft\Launcher\Installs'
    )

    return Get-RegistryInstalledGames `
        -Launcher 'Ubisoft' `
        -RegistryRoots $roots
}

# ============================================================
# GOG
# ============================================================

function Get-GOGGames {

    $roots = @(
        'HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games',
        'HKLM:\SOFTWARE\GOG.com\Games',
        'HKCU:\Software\GOG.com\Games'
    )

    return Get-RegistryInstalledGames `
        -Launcher 'GOG' `
        -RegistryRoots $roots
}

# ============================================================
# BATTLE.NET
# ============================================================

function Get-BattleNetGames {

    $roots = @(
        'HKLM:\SOFTWARE\WOW6432Node\Blizzard Entertainment',
        'HKLM:\SOFTWARE\Blizzard Entertainment',
        'HKCU:\Software\Blizzard Entertainment'
    )

    return Get-RegistryInstalledGames `
        -Launcher 'Battle.net' `
        -RegistryRoots $roots
}

# ============================================================
# XBOX / MICROSOFT STORE
#
# [P6] Reemplazado el filtro de inclusión por nombre
# (que bloqueaba juegos de Game Pass sin keywords conocidos)
# por un filtro de exclusión de paquetes del sistema basado
# en prefijos de nombre. Find-GameExecutables actúa como
# segunda criba: si no hay EXE válido, no se agrega.
# ============================================================

function Get-XboxGames {

    $games = New-Object System.Collections.Generic.List[object]

    # Prefijos de nombre de paquete que corresponden a componentes
    # del sistema operativo o apps de Microsoft que no son juegos.
    $systemNamePrefixes = @(
        'Microsoft.',
        'Windows.',
        'MicrosoftWindows.',
        'MicrosoftCorporation.',
        'MicrosoftTeams',
        'Clipchamp.',
        'MSTeams',
        'NcsiUwpApp',
        'SecHealthUI'
    )

    try {

        $packages = Get-AppxPackage -ErrorAction SilentlyContinue

        foreach ($package in $packages) {

            if (-not $package.InstallLocation) {
                continue
            }

            if (-not (Test-Path $package.InstallLocation)) {
                continue
            }

            # Excluir componentes del sistema por prefijo de nombre.
            $isSystem = $false

            foreach ($prefix in $systemNamePrefixes) {

                if ($package.Name.StartsWith(
                    $prefix,
                    [System.StringComparison]::OrdinalIgnoreCase
                )) {
                    $isSystem = $true
                    break
                }
            }

            if ($isSystem) {
                continue
            }

            $executables = Find-GameExecutables `
                $package.InstallLocation

            if ($executables.Count -eq 0) {
                continue
            }

            $games.Add([pscustomobject]@{
                Name             = $package.Name
                Launcher         = 'Xbox'
                AppId            = $package.PackageFamilyName
                InstallDirectory = Normalize-Path $package.InstallLocation
                Executables      = $executables
            })
        }
    }
    catch {
    }

    return $games.ToArray()
}

# ============================================================
# JUEGOS MANUALES
# ============================================================

function Get-ManualGames {

    $games = New-Object System.Collections.Generic.List[object]

    $config = Get-GameConfig

    # --------------------------------------------------------
    # Directorios
    # --------------------------------------------------------

    foreach ($directory in @($config.ManualDirectories)) {

        if ([string]::IsNullOrWhiteSpace($directory)) {
            continue
        }

        if (-not (Test-Path $directory -PathType Container)) {
            Write-Log "Directorio manual no encontrado: $directory"
            continue
        }

        $executables = Find-GameExecutables $directory

        if ($executables.Count -eq 0) {
            continue
        }

        $name = Split-Path $directory -Leaf

        $games.Add([pscustomobject]@{
            Name             = $name
            Launcher         = 'Manual'
            AppId            = $null
            InstallDirectory = Normalize-Path $directory
            Executables      = $executables
        })
    }

    # --------------------------------------------------------
    # EXE individuales
    # --------------------------------------------------------

    foreach ($exe in @($config.ManualExecutables)) {

        if ([string]::IsNullOrWhiteSpace($exe)) {
            continue
        }

        if (-not (Test-Path $exe -PathType Leaf)) {

            Write-Log "Ejecutable manual no encontrado: $exe"
            continue
        }

        $normalizedExe = Normalize-Path $exe

        $directory = Split-Path $normalizedExe -Parent
        $name = [System.IO.Path]::GetFileNameWithoutExtension($exe)

        $games.Add([pscustomobject]@{
            Name             = $name
            Launcher         = 'Manual'
            AppId            = $null
            InstallDirectory = Normalize-Path $directory
            Executables      = @($normalizedExe)
        })
    }

    return $games.ToArray()
}

# ============================================================
# DEDUPLICAR JUEGOS
# ============================================================

function Merge-GameList {

    param(
        [array]$Games
    )

    $map = @{}

    foreach ($game in $Games) {

        if (-not $game.InstallDirectory) {
            continue
        }

        $key = (
            "$($game.Launcher)|$($game.InstallDirectory)"
        ).ToLowerInvariant()

        if (-not $map.ContainsKey($key)) {

            $map[$key] = [pscustomobject]@{
                Name             = $game.Name
                Launcher         = $game.Launcher
                AppId            = $game.AppId
                InstallDirectory = $game.InstallDirectory
                Executables      = @(
                    $game.Executables
                )
            }

            continue
        }

        # Fusionar EXE encontrados por diferentes métodos.

        $existing = @(
            $map[$key].Executables
        )

        $combined = @(
            $existing
            $game.Executables
        ) |
        Where-Object { $_ } |
        Select-Object -Unique

        $map[$key].Executables = $combined
    }

    return @($map.Values)
}

# ============================================================
# CONSTRUIR DATABASE
# ============================================================

function Build-GameDatabase {

    Write-Log '========================================'
    Write-Log 'Iniciando actualización de base de datos de juegos'
    Write-Log 'No se realizará escaneo completo de disco'

    $oldGames = @()

    if (Test-Path $gameDatabaseFile) {

        try {

            $oldDb = Get-Content `
                $gameDatabaseFile `
                -Raw |
                ConvertFrom-Json

            $oldGames = @($oldDb.Games)
        }
        catch {
            Write-Log 'No se pudo leer games-db.json anterior'
        }
    }

    $allGames = New-Object System.Collections.Generic.List[object]

    # --------------------------------------------------------
    # Launchers
    # --------------------------------------------------------

    Write-Log 'Escaneando bibliotecas de Steam'
    foreach ($game in Get-SteamGames) {
        $allGames.Add($game)
    }

    Write-Log 'Escaneando manifiestos de Epic'
    foreach ($game in Get-EpicGames) {
        $allGames.Add($game)
    }

    Write-Log 'Escaneando registro de EA'
    foreach ($game in Get-EAGames) {
        $allGames.Add($game)
    }

    Write-Log 'Escaneando registro de Ubisoft'
    foreach ($game in Get-UbisoftGames) {
        $allGames.Add($game)
    }

    Write-Log 'Escaneando registro de GOG'
    foreach ($game in Get-GOGGames) {
        $allGames.Add($game)
    }

    Write-Log 'Escaneando registro de Battle.net'
    foreach ($game in Get-BattleNetGames) {
        $allGames.Add($game)
    }

    Write-Log 'Escaneando paquetes de Xbox / Microsoft Store'
    foreach ($game in Get-XboxGames) {
        $allGames.Add($game)
    }

    # --------------------------------------------------------
    # Manual
    # --------------------------------------------------------

    Write-Log 'Escaneando ubicaciones manuales'

    foreach ($game in Get-ManualGames) {
        $allGames.Add($game)
    }

    $newGames = Merge-GameList $allGames.ToArray()

    # --------------------------------------------------------
    # Detectar cambios respecto a la DB anterior
    # --------------------------------------------------------

    $oldKeys = @{}

    foreach ($game in $oldGames) {

        $key = (
            "$($game.Launcher)|$($game.InstallDirectory)"
        ).ToLowerInvariant()

        $oldKeys[$key] = $game
    }

    $newKeys = @{}

    foreach ($game in $newGames) {

        $key = (
            "$($game.Launcher)|$($game.InstallDirectory)"
        ).ToLowerInvariant()

        $newKeys[$key] = $game

        if (-not $oldKeys.ContainsKey($key)) {

            Write-Log "JUEGO NUEVO: [$($game.Launcher)] $($game.Name)"
        }
    }

    foreach ($key in $oldKeys.Keys) {

        if (-not $newKeys.ContainsKey($key)) {

            $oldGame = $oldKeys[$key]

            Write-Log `
                "JUEGO ELIMINADO: [$($oldGame.Launcher)] $($oldGame.Name)"
        }
    }

    # --------------------------------------------------------
    # Guardar DB — escritura atómica via archivo temporal
    # --------------------------------------------------------

    $database = [ordered]@{
        DatabaseVersion = 2
        LastUpdated     = (Get-Date).ToString('o')
        Games           = $newGames
    }

    $tempFile = "$gameDatabaseFile.tmp"

    try {

        $database |
            ConvertTo-Json -Depth 8 |
            Set-Content $tempFile -Encoding UTF8

        Move-Item `
            $tempFile `
            $gameDatabaseFile `
            -Force

        Write-Log `
            "Base de datos actualizada: $($newGames.Count) juegos"
    }
    catch {

        Write-Log 'ERROR al guardar games-db.json'
    }

    return $newGames
}

# ============================================================
# ÍNDICE EXE → JUEGO
# ============================================================

function Build-GameExecutableIndex {

    param(
        [array]$Games
    )

    $index = @{}

    foreach ($game in $Games) {

        foreach ($exe in @($game.Executables)) {

            $path = Normalize-Path $exe

            if (-not $path) {
                continue
            }

            if (-not $index.ContainsKey($path)) {

                $index[$path] = $game
            }
        }
    }

    $script:gameExecutableIndex = $index

    Write-Log `
        "Índice de ejecutables creado: $($index.Count) ejecutables"
}

# ============================================================
# OBTENER PATH DEL PROCESO EN FOREGROUND
# ============================================================

function Get-ProcessPathFromPid {

    param(
        [uint32]$ProcessId
    )

    if ($ProcessId -eq 0) {
        return $null
    }

    $handle = [AutoInstantReplayWin32]::OpenProcess(
        [AutoInstantReplayWin32]::PROCESS_QUERY_LIMITED_INFORMATION,
        $false,
        $ProcessId
    )

    if ($handle -eq [IntPtr]::Zero) {
        return $null
    }

    try {

        $capacity = 32768

        $buffer = New-Object System.Text.StringBuilder $capacity

        $size = [uint32]$buffer.Capacity

        $success = [AutoInstantReplayWin32]::QueryFullProcessImageName(
            $handle,
            0,
            $buffer,
            [ref]$size
        )

        if ($success) {

            return Normalize-Path $buffer.ToString()
        }
    }
    finally {

        [AutoInstantReplayWin32]::CloseHandle($handle) |
            Out-Null
    }

    return $null
}

# ============================================================
# DETECTAR JUEGO EN FOREGROUND
# ============================================================

function Get-ForegroundGame {

    $hwnd = [AutoInstantReplayWin32]::GetForegroundWindow()

    if ($hwnd -eq [IntPtr]::Zero) {
        return $null
    }

    if (-not [AutoInstantReplayWin32]::IsWindowVisible($hwnd)) {
        return $null
    }

    $processId = [uint32]0

    [AutoInstantReplayWin32]::GetWindowThreadProcessId(
        $hwnd,
        [ref]$processId
    ) | Out-Null

    if ($processId -eq 0) {
        return $null
    }

    $processPath = Get-ProcessPathFromPid $processId

    if (-not $processPath) {
        return $null
    }

    if ($script:gameExecutableIndex.ContainsKey($processPath)) {

        # [P0] Guardar el PID del juego detectado para poder
        # verificar si sigue vivo cuando pase al background.
        $script:activeGamePid = [int]$processId

        return $script:gameExecutableIndex[$processPath]
    }

    return $null
}

# ============================================================
# DISCORD
#
# [P5-FIX] Detección de llamada por sockets UDP CONECTADOS.
#
# El error anterior: la regex exigía "*:*" en el remoto, por lo
# que matcheaba sockets UDP meramente *bound* (sin peer), que
# Discord mantiene abiertos incluso en reposo. Eso producía
# activaciones falsas (por ejemplo, al hacer click en Discord).
#
# Corrección: solo cuentan los sockets UDP que cumplen TODO:
#   1. Pertenecen a un proceso Discord
#   2. Puerto LOCAL en el rango de voz (50000-65535)
#   3. Tienen dirección remota REAL (no "*:*", no 0.0.0.0, no ::)
#   4. NO son QUIC / HTTP-3 (puerto remoto distinto de 443)
#
# En WebRTC (que es lo que usa Discord para voz/vídeo) el
# transporte ICE hace connect() sobre el socket UDP, así que
# durante una llamada aparecen sockets "conectados" en netstat.
# En reposo, Discord solo tiene sockets bound sin peer.
#
# Nota: Get-NetUDPEndpoint (CIM) NO sirve aquí porque no expone
# la dirección remota. La única fuente fiable es netstat -ano,
# que sí muestra la tupla completa para sockets connect()ados.
# ============================================================

function Test-DiscordInCall {

    $discordProcesses = Get-Process `
        -Name $discordProcessName `
        -ErrorAction SilentlyContinue

    if (-not $discordProcesses) {
        return $false
    }

    $pids = @(
        $discordProcesses |
        Select-Object -ExpandProperty Id
    )

    try {

        $netstatOutput = netstat -ano -p UDP 2>$null

        if ($LASTEXITCODE -ne 0) {
            Write-Log "ERROR netstat código $LASTEXITCODE"
        }

        foreach ($line in $netstatOutput) {

            if ($line -match '^\s*UDP\s+\S+:(\d+)\s+\*:\*\s+(\d+)') {

                $port   = [int]$Matches[1]
                $procId = [int]$Matches[2]

                if ($pids -contains $procId -and $port -ge 50000) {
                    return $true
                }
            }
        }
    }
    catch {

        Write-Log "ERROR en Test-DiscordInCall: $($_.Exception.Message)"
    }

    return $false
}

# ============================================================
# INSTANT REPLAY
# ============================================================

function Get-InstantReplayState {

    try {

        if (-not (Test-Path $amdRegistryPath)) {
            return $null
        }

        $value = Get-ItemPropertyValue `
            -Path $amdRegistryPath `
            -Name $amdInstantReplayValue `
            -ErrorAction SilentlyContinue

        if ($null -eq $value) {
            return $null
        }

        return ([int]$value -ne 0)
    }
    catch {

        return $null
    }
}

function Set-InstantReplay {

    param(
        [bool]$Enabled
    )

    $desiredValue = if ($Enabled) { 1 } else { 0 }

    try {

        if (-not (Test-Path $amdRegistryPath)) {

            New-Item `
                -Path $amdRegistryPath `
                -Force |
                Out-Null
        }

        Set-ItemProperty `
            -Path $amdRegistryPath `
            -Name $amdInstantReplayValue `
            -Value $desiredValue `
            -Type DWord `
            -Force

        $script:instantReplayState = $Enabled

        if ($Enabled) {
            Write-Log 'Instant Replay ACTIVADO'
        }
        else {
            Write-Log 'Instant Replay DESACTIVADO'
        }

        return $true
    }
    catch {

        Write-Log `
            "ERROR al cambiar Instant Replay: $($_.Exception.Message)"

        return $false
    }
}

# ============================================================
# DETECCIÓN DE SOFTWARE DE STREAMING
#
# Detecta el programa abierto, no que esté transmitiendo.
# ============================================================

function Test-StreamingSoftwareRunning {

    foreach ($name in $streamingProcesses) {

        if (Get-Process -Name $name -ErrorAction SilentlyContinue) {
            return $true
        }
    }

    return $false
}

# ============================================================
# ACTUALIZAR ESTADO
# ============================================================

function Update-InstantReplayState {

    $gameActive    = $null -ne $script:lastGame
    $discordActive = $script:discordInCall

    # --------------------------------------------------------
    # CUALQUIERA DE LOS DOS ACTIVADORES = ON
    # ...salvo que haya software de streaming abierto.
    # --------------------------------------------------------

    $desiredState = (
        ($gameActive -or $discordActive) -and
        -not $script:streamingActive
    )

    if ($null -eq $script:instantReplayState) {

        $script:instantReplayState =
            Get-InstantReplayState
    }

    # Solo tocar el Registry si realmente cambia.
    if ($script:instantReplayState -ne $desiredState) {

        Set-InstantReplay $desiredState
    }
}

# ============================================================
# MOSTRAR ESTADO
# ============================================================

function Write-StateChange {

    param(
        [object]$Game,
        [bool]$Discord
    )

    if ($Game) {

        Write-Log `
            "JUEGO ACTIVO: [$($Game.Launcher)] $($Game.Name)"
    }
    else {

        Write-Log 'JUEGO INACTIVO'
    }

    if ($Discord) {
        Write-Log 'DISCORD EN LLAMADA'
    }
    else {
        Write-Log 'DISCORD SIN LLAMADA'
    }
}

# ============================================================
# COMPROBAR SI EL JUEGO ACTIVO SIGUE ABIERTO
#
# Cubre el caso en que el juego se cierra estando en background
# (el foreground no cambia, así que el flujo 1 no lo detecta).
# ============================================================

function Update-GameProcessState {

    if ($null -eq $script:lastGame -or $script:activeGamePid -eq 0) {
        return
    }

    $alive = Get-Process `
        -Id $script:activeGamePid `
        -ErrorAction SilentlyContinue

    if (-not $alive) {

        $script:lastGame      = $null
        $script:activeGamePid = 0

        Write-StateChange `
            $null `
            $script:discordInCall
    }
}

# ============================================================
# INICIALIZACIÓN
# ============================================================

Write-Log ''
Write-Log '========================================'
Write-Log 'AutoInstantReplay iniciado'
Write-Log '========================================'

Initialize-GameConfig

# ------------------------------------------------------------
# Actualizar DB SOLO AL ARRANCAR
# ------------------------------------------------------------

$script:gameDatabase = Build-GameDatabase

Build-GameExecutableIndex $script:gameDatabase

Write-Log "Monitoreo iniciado. Poll=$foregroundPollMilliseconds ms"

# ============================================================
# LOOP PRINCIPAL
# ============================================================

while ($true) {

    try {

        # ====================================================
        # FLUJO 1: JUEGO
        #
        # Solo hacemos trabajo cuando cambia la ventana
        # foreground.
        #
        # [P0] CORRECCIÓN: ya no se borra lastGame cuando el
        # foreground cambia a algo que no es un juego.
        # En su lugar se verifica si el PID del juego detectado
        # sigue vivo. Solo se desactiva cuando el proceso termina.
        # Esto permite Alt+Tab, ventanas minimizadas, etc.
        # ====================================================

        $currentHwnd =
            [AutoInstantReplayWin32]::GetForegroundWindow()

        if ($currentHwnd -ne $script:lastForegroundHwnd) {

            $script:lastForegroundHwnd = $currentHwnd

            $newGame = Get-ForegroundGame

            if ($null -ne $newGame) {

                # Un juego está en foreground.
                if (
                    $null -eq $script:lastGame -or
                    $script:lastGame.InstallDirectory -ne
                    $newGame.InstallDirectory
                ) {
                    $script:lastGame = $newGame

                    Write-StateChange `
                        $script:lastGame `
                        $script:discordInCall
                }
            }
            elseif ($null -ne $script:lastGame) {

                # Foreground cambió a algo que no es un juego.
                # Solo desactivar si el proceso del juego ya terminó.
                $alive = Get-Process `
                    -Id $script:activeGamePid `
                    -ErrorAction SilentlyContinue

                if (-not $alive) {

                    $script:lastGame      = $null
                    $script:activeGamePid = 0

                    Write-StateChange `
                        $null `
                        $script:discordInCall
                }

                # Si el proceso sigue vivo, no tocar lastGame:
                # el juego está en background y Instant Replay
                # debe permanecer activo.
            }
        }

        # ====================================================
        # FLUJO 2: DISCORD
        #
        # Completamente independiente del juego.
        # ====================================================

        $now = Get-Date

        if (
            ($now - $script:lastDiscordCheck).TotalMilliseconds `
            -ge $discordCheckMilliseconds
        ) {

            $script:lastDiscordCheck = $now

            $newDiscordState = Test-DiscordInCall

            if ($newDiscordState -ne $script:discordInCall) {

                $script:discordInCall = $newDiscordState

                Write-StateChange `
                    $script:lastGame `
                    $script:discordInCall
            }

            # Software de streaming (misma cadencia que Discord)
            $newStreaming = Test-StreamingSoftwareRunning

            if ($newStreaming -ne $script:streamingActive) {

                $script:streamingActive = $newStreaming

                if ($newStreaming) {
                    Write-Log 'STREAMING DETECTADO: Instant Replay bloqueado'
                }
                else {
                    Write-Log 'STREAMING CERRADO: Instant Replay desbloqueado'
                }
            }

            # Verificar que el juego siga abierto
            Update-GameProcessState
        }

        # ====================================================
        # DECISIÓN FINAL
        #
        # Juego OR Discord
        # ====================================================

        Update-InstantReplayState
    }
    catch {

        Write-Log `
            "ERROR en el loop: $($_.Exception.Message)"
    }

    Start-Sleep -Milliseconds $foregroundPollMilliseconds
}
