# ==============================================================================
# Instalar-AutoInstantReplay.ps1 — Registra AutoInstantReplay en el Programador de Tareas
# y se elimina a sí mismo al terminar.
# Ejecutar como Administrador una sola vez.
# ==============================================================================

$taskName    = "AutoInstantReplay"
$scriptPath  = Join-Path $PSScriptRoot "AutoInstantReplay.ps1"
$description = "AMD Instant Replay automático basado en juegos activos y llamadas de Discord."

# --- Verificar que AutoInstantReplay.ps1 está en la misma carpeta ---
if (-not (Test-Path $scriptPath)) {
    Write-Host "[ERROR] No se encontró AutoInstantReplay.ps1 en: $PSScriptRoot" -ForegroundColor Red
    Write-Host "Asegúrate de que ambos scripts estén en la misma carpeta." -ForegroundColor Yellow
    pause
    exit 1
}

# --- Verificar que se ejecuta como Administrador ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[ERROR] Ejecuta este script como Administrador." -ForegroundColor Red
    pause
    exit 1
}

# --- Eliminar tarea anterior si existe ---
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "[INFO] Tarea anterior eliminada." -ForegroundColor Yellow
}

# --- Acción: PowerShell oculto ejecutando AutoInstantReplay.ps1 ---
$action = New-ScheduledTaskAction `
    -Execute  "powershell.exe" `
    -Argument "-WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass -File `"$scriptPath`""

# --- Disparador 1: al iniciar sesión ---
$triggerLogon = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"

# --- Configuración: sin límite de tiempo, reintentar 3 veces si falla ---
$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

# --- Registrar tarea con el trigger de logon ---
Register-ScheduledTask `
    -TaskName    $taskName `
    -Action      $action `
    -Trigger     $triggerLogon `
    -Settings    $settings `
    -Description $description `
    -RunLevel    Highest `
    -Force | Out-Null

# --- Disparador 2: al volver de suspensión ---
# Se inyecta vía XML porque New-ScheduledTaskTrigger no soporta EventTrigger
$taskXml = [xml](Export-ScheduledTask -TaskName $taskName)
$ns = "http://schemas.microsoft.com/windows/2004/02/mit/task"

$resumeNode       = $taskXml.CreateElement("EventTrigger", $ns)
$enabledNode      = $taskXml.CreateElement("Enabled", $ns)
$enabledNode.InnerText = "true"
$subscriptionNode = $taskXml.CreateElement("Subscription", $ns)
$subscriptionNode.InnerText = '<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name=''Microsoft-Windows-Power-Troubleshooter''] and EventID=1]]</Select></Query></QueryList>'

$resumeNode.AppendChild($enabledNode)       | Out-Null
$resumeNode.AppendChild($subscriptionNode)  | Out-Null
$taskXml.Task.Triggers.AppendChild($resumeNode) | Out-Null

Register-ScheduledTask -TaskName $taskName -Xml $taskXml.OuterXml -Force | Out-Null

# --- Confirmación ---
Write-Host ""
Write-Host "Tarea '$taskName' registrada con 2 disparadores:" -ForegroundColor Green
Write-Host "  - Al iniciar sesión"                                          -ForegroundColor Green
Write-Host "  - Al volver de suspensión (con o sin contraseña de bloqueo)"  -ForegroundColor Green
Write-Host ""
Write-Host "Comandos útiles:" -ForegroundColor Cyan
Write-Host "  Iniciar ahora : Start-ScheduledTask -TaskName '$taskName'"
Write-Host "  Detener       : Stop-ScheduledTask  -TaskName '$taskName'"
Write-Host "  Desinstalar   : Unregister-ScheduledTask -TaskName '$taskName' -Confirm:`$false"
Write-Host ""

# --- Auto-eliminación: borra este instalador al terminar ---
$self = $MyInvocation.MyCommand.Path
Write-Host "Eliminando instalador..." -ForegroundColor DarkGray
Start-Sleep -Seconds 2

# Se lanza un proceso separado que espera a que este script termine y luego borra el archivo
Start-Process "cmd.exe" -ArgumentList "/c timeout /t 2 >nul & del /f /q `"$self`"" -WindowStyle Hidden
