<#
.SYNOPSIS
    Instala e configura o agente RustDesk apontando para a infraestrutura Afiminas.

.DESCRIPTION
    Script idempotente de deploy do endpoint Windows. Fluxo (conforme PDF §17):
      Instalar -> Configurar servidor -> Aplicar configuração -> Configurar serviço
      -> Validar execução -> Coletar ID -> Registrar endpoint

    O registro no console é AUTOMÁTICO: assim que o cliente tem o API Server
    configurado, ele envia heartbeat/sysinfo e o console cria o dispositivo no
    primeiro heartbeat. Não há chamada de registro neste script.

.PARAMETER ConfigString
    Config string do RustDesk (ID Server + Key + API Server já embutidos).
    Obtenha em uma máquina configurada manualmente:
      cliente -> menu (⋮) -> Network -> destravar -> preencher -> "Export Server Config"

.PARAMETER Version
    Versão do cliente RustDesk a instalar. Padrão: 1.4.9

.PARAMETER Password
    Senha permanente de acesso não supervisionado. Se omitida, gera aleatória de 16 chars.
    NUNCA fixar uma senha compartilhada entre dispositivos.

.PARAMETER LogPath
    Arquivo de log. Padrão: $env:ProgramData\Afiminas\deploy-rustdesk.log

.EXAMPLE
    .\install-agent.ps1 -ConfigString "9WGJ...=="

.NOTES
    Executar como Administrador. Códigos de saída:
      0 = sucesso   1 = sem privilégio   2 = download falhou
      3 = instalação falhou   4 = serviço não subiu   5 = configuração falhou
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigString,

    [string]$Version = '1.4.9',

    [string]$Password,

    [string]$LogPath = "$env:ProgramData\Afiminas\deploy-rustdesk.log"
)

$ErrorActionPreference = 'Stop'
$InstallDir = "$env:ProgramFiles\RustDesk"
$ServiceName = 'RustDesk'

# --------------------------------------------------------------------------- log
$logDir = Split-Path -Parent $LogPath
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }

function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERRO')][string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $LogPath -Value $line -Encoding utf8
    Write-Host $line
}

function Exit-With {
    param([int]$Code, [string]$Message)
    if ($Code -eq 0) { Write-Log $Message 'INFO' } else { Write-Log $Message 'ERRO' }
    exit $Code
}

Write-Log "=== Deploy RustDesk iniciado (versão alvo $Version) ==="

# --------------------------------------------------------------- privilégio admin
$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Exit-With 1 'Este script precisa ser executado como Administrador.'
}

# ------------------------------------------------------------- senha (se omitida)
if ([string]::IsNullOrWhiteSpace($Password)) {
    # Sem 0/O/1/I/l para evitar ambiguidade na leitura por telefone.
    $chars = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $Password = -join (1..16 | ForEach-Object { $chars | Get-Random })
    Write-Log 'Senha permanente gerada aleatoriamente para este dispositivo.'
}

# ------------------------------------------------------- idempotência: já instalado?
$installedVersion = $null
try {
    $installedVersion = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\RustDesk\' -ErrorAction Stop).Version
} catch { }

$needsInstall = $true
if ($installedVersion -eq $Version) {
    Write-Log "RustDesk $installedVersion já instalado — pulando download e instalação."
    $needsInstall = $false
} elseif ($installedVersion) {
    Write-Log "RustDesk $installedVersion instalado, alvo é $Version — atualizando." 'WARN'
}

# ------------------------------------------------------------- download + instalação
if ($needsInstall) {
    $url = "https://github.com/rustdesk/rustdesk/releases/download/$Version/rustdesk-$Version-x86_64.exe"
    $tmp = Join-Path $env:TEMP "rustdesk-$Version.exe"

    Write-Log "Baixando $url"
    try {
        $pp = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing
        $ProgressPreference = $pp
    } catch {
        Exit-With 2 "Falha no download: $_"
    }
    if (-not (Test-Path $tmp) -or (Get-Item $tmp).Length -lt 1MB) {
        Exit-With 2 'Arquivo baixado ausente ou truncado.'
    }
    Write-Log ('Download concluído ({0:N1} MB).' -f ((Get-Item $tmp).Length / 1MB))

    Write-Log 'Executando instalação silenciosa.'
    try {
        Start-Process -FilePath $tmp -ArgumentList '--silent-install' -Wait -NoNewWindow
    } catch {
        Exit-With 3 "Instalação falhou: $_"
    }

    # O instalador retorna antes de terminar de registrar os arquivos.
    $deadline = (Get-Date).AddSeconds(120)
    while (-not (Test-Path "$InstallDir\rustdesk.exe") -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
    }
    if (-not (Test-Path "$InstallDir\rustdesk.exe")) {
        Exit-With 3 "rustdesk.exe não encontrado em $InstallDir após a instalação."
    }
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    Write-Log 'Instalação concluída.'
}

$exe = Join-Path $InstallDir 'rustdesk.exe'

# ------------------------------------------------------------------------ serviço
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-Log 'Serviço ausente — instalando.'
    Start-Process -FilePath $exe -ArgumentList '--install-service' -Wait -NoNewWindow
    $deadline = (Get-Date).AddSeconds(90)
    while (-not $svc -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    }
}
if (-not $svc) { Exit-With 4 'Serviço RustDesk não foi criado.' }

if ($svc.Status -ne 'Running') {
    Write-Log "Serviço em '$($svc.Status)' — iniciando."
    $deadline = (Get-Date).AddSeconds(90)
    while ($svc.Status -ne 'Running' -and (Get-Date) -lt $deadline) {
        try { Start-Service $ServiceName -ErrorAction Stop } catch { }
        Start-Sleep -Seconds 5
        $svc.Refresh()
    }
}
if ($svc.Status -ne 'Running') { Exit-With 4 "Serviço não entrou em Running (estado: $($svc.Status))." }
Write-Log 'Serviço em execução.'

# ------------------------------------------------------------------- configuração
Write-Log 'Aplicando configuração de servidor (ID Server / Key / API Server).'
try {
    & $exe --config $ConfigString | Out-String | ForEach-Object { if ($_.Trim()) { Write-Log $_.Trim() } }
} catch {
    Exit-With 5 "Falha ao aplicar --config: $_"
}

Write-Log 'Definindo senha permanente do dispositivo.'
try {
    & $exe --password $Password | Out-Null
} catch {
    Exit-With 5 "Falha ao aplicar --password: $_"
}

# ------------------------------------------------------------------- coleta do ID
$deviceId = $null
$deadline = (Get-Date).AddSeconds(60)
while (-not $deviceId -and (Get-Date) -lt $deadline) {
    try {
        $raw = (& $exe --get-id | Out-String).Trim()
        if ($raw -match '\d{6,}') { $deviceId = $Matches[0] }
    } catch { }
    if (-not $deviceId) { Start-Sleep -Seconds 5 }
}
if (-not $deviceId) { Exit-With 5 'Não foi possível coletar o ID do dispositivo.' }

# --------------------------------------------------------------------- resultado
Write-Log "ID do dispositivo: $deviceId"
Write-Log 'Registro no console ocorre automaticamente no primeiro heartbeat (até ~30s).'

Write-Host ''
Write-Host '======================================================='
Write-Host " Dispositivo : $env:COMPUTERNAME"
Write-Host " RustDesk ID : $deviceId"
Write-Host " Senha       : $Password"
Write-Host '======================================================='
Write-Host ' Recolha estes dados por canal seguro e apague desta tela.'
Write-Host " A senha NAO foi gravada em $LogPath."
Write-Host ''

Exit-With 0 "=== Deploy concluído com sucesso (ID $deviceId) ==="
