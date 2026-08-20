<#
.SYNOPSIS
    Mantém o agente RustDesk do endpoint na versão publicada para o ambiente.

.DESCRIPTION
    Executa como SYSTEM via Tarefa Agendada: no boot da máquina e periodicamente.

    Fluxo:
      lê o manifesto da branch do ambiente -> compara com a versão instalada
      -> baixa o instalador -> VALIDA O SHA256 -> instala -> reaplica config
      -> valida o serviço -> registra a versão aplicada

    A validação de SHA256 contra o manifesto é obrigatória: o instalador vem
    das releases públicas do RustDesk, que são de terceiros. Manifesto sem
    sha256 preenchido faz o script recusar a atualização (falha fechada).

.PARAMETER Registrar
    Em vez de atualizar, instala este script em %ProgramFiles%\AzureControlDesk
    e cria/atualiza a Tarefa Agendada. Usado pelo install-agent.ps1.

.PARAMETER Ambiente
    homologacao | producao. Se omitido, lê de %ProgramData%\Afiminas\ambiente.txt.

.PARAMETER Forcar
    Aplica mesmo que a versão coincida e ignora a checagem de sessão ativa.

.PARAMETER Verificar
    Só relata o que faria. Não baixa nem instala nada.

.NOTES
    Códigos de saída:
      0 = nada a fazer / atualizado com sucesso   1 = erro de rede ou manifesto
      2 = SHA256 não confere ou ausente          3 = instalação falhou
      4 = serviço não voltou                     5 = adiado (sessão ativa)
#>

[CmdletBinding()]
param(
    [switch]$Registrar,
    [ValidateSet('homologacao', 'producao')][string]$Ambiente,
    [switch]$Forcar,
    [switch]$Verificar
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Repo        = 'PHRDevSYS/RustDesk-Personalite'
$EstadoDir   = "$env:ProgramData\Afiminas"
$InstalDir   = "$env:ProgramFiles\AzureControlDesk"
$RustDeskDir = "$env:ProgramFiles\RustDesk"
$ServiceName = 'RustDesk'
$TaskName    = 'AzureControlDesk - AutoUpdate'
$LogPath     = "$EstadoDir\autoupdate.log"

if (-not (Test-Path $EstadoDir)) { New-Item -ItemType Directory -Force -Path $EstadoDir | Out-Null }

function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERRO')][string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { Add-Content -Path $LogPath -Value $line -Encoding utf8 } catch { }
    Write-Host $line
}

function Exit-With {
    param([int]$Code, [string]$Message)
    if ($Code -eq 0) { Write-Log $Message 'INFO' } else { Write-Log $Message 'ERRO' }
    exit $Code
}

# Atualiza este proprio script a partir da branch do ambiente.
# Roda em TODA execucao, nao so quando ha nova versao do RustDesk: se dependesse
# disso, uma correcao neste script so chegaria a frota quando o cliente mudasse
# de versao - podendo levar meses.
# Substituir o arquivo com ele em execucao e seguro: o PowerShell ja carregou o
# conteudo em memoria; a troca vale a partir da proxima execucao.
function Update-Script {
    param([string]$Ambiente)
    try {
        $scriptUrl = "https://raw.githubusercontent.com/$Repo/$Ambiente/agente/windows/autoupdate-agent.ps1"
        $novoTmp = Join-Path $env:TEMP 'autoupdate-agent.new.ps1'
        Invoke-WebRequest -Uri $scriptUrl -OutFile $novoTmp -UseBasicParsing -TimeoutSec 60 `
            -Headers @{ 'Cache-Control' = 'no-cache' }

        $destino = Join-Path $InstalDir 'autoupdate-agent.ps1'
        $atual = ''
        if (Test-Path $destino) { $atual = (Get-FileHash $destino -Algorithm SHA256).Hash }

        if ((Get-FileHash $novoTmp -Algorithm SHA256).Hash -ne $atual) {
            # So substitui se o novo arquivo for PowerShell valido. Language.Parser
            # pega erros que PSParser::Tokenize deixa passar (ex.: $Var: lido como
            # variavel qualificada por drive).
            $tokens = $null; $erros = $null
            [void][Management.Automation.Language.Parser]::ParseFile($novoTmp, [ref]$tokens, [ref]$erros)
            if ($erros -and $erros.Count -gt 0) {
                Write-Log "Script remoto com $($erros.Count) erro(s) de sintaxe - mantido o atual." 'WARN'
            } else {
                Copy-Item $novoTmp $destino -Force
                Write-Log 'Script de auto-update atualizado a partir da branch.'
            }
        }
        Remove-Item $novoTmp -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Log "Auto-update do script falhou (nao bloqueia): $_" 'WARN'
    }
}

# ===========================================================================
# MODO REGISTRAR — instala o script e cria a Tarefa Agendada
# ===========================================================================
if ($Registrar) {
    if (-not $Ambiente) { Exit-With 1 '-Registrar exige -Ambiente.' }

    if (-not (Test-Path $InstalDir)) { New-Item -ItemType Directory -Force -Path $InstalDir | Out-Null }
    $destino = Join-Path $InstalDir 'autoupdate-agent.ps1'

    # %ProgramFiles% é gravável só por administradores. Não instalar em
    # %ProgramData%: script executado como SYSTEM a partir de diretório
    # gravável por usuário comum é escalonamento de privilégio.
    if ($PSCommandPath -ne $destino) { Copy-Item -Path $PSCommandPath -Destination $destino -Force }

    Set-Content -Path "$EstadoDir\ambiente.txt" -Value $Ambiente -Encoding ascii -NoNewline

    $acao = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $destino)

    # No boot (com atraso para a rede subir) e a cada 6h enquanto a máquina fica ligada.
    $gatilhoBoot = New-ScheduledTaskTrigger -AtStartup
    $gatilhoBoot.Delay = 'PT5M'

    # -RepetitionDuration e obrigatorio: sem ele a repeticao para depois de um
    # dia e o endpoint deixa de verificar ate o proximo boot. MaxValue lanca
    # excecao no PS 5.1; 3650 dias e o equivalente pratico de "indefinidamente".
    $gatilhoCiclo = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddHours(3) `
        -RepetitionInterval (New-TimeSpan -Hours 6) `
        -RepetitionDuration (New-TimeSpan -Days 3650)

    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $config = New-ScheduledTaskSettingsSet -StartWhenAvailable `
        -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 10)
    $config.RandomDelay = 'PT10M'   # espalha a carga: a frota nao atualiza toda no mesmo minuto

    Register-ScheduledTask -TaskName $TaskName -Action $acao `
        -Trigger $gatilhoBoot, $gatilhoCiclo -Principal $principal -Settings $config -Force | Out-Null

    Write-Log "Tarefa '$TaskName' registrada (ambiente: $Ambiente). Executa no boot e a cada 6h."
    exit 0
}

# ===========================================================================
# MODO ATUALIZAR
# ===========================================================================
if (-not $Ambiente) {
    $arq = "$EstadoDir\ambiente.txt"
    if (Test-Path $arq) { $Ambiente = (Get-Content $arq -Raw).Trim() }
}
if (@('homologacao', 'producao') -notcontains $Ambiente) {
    Exit-With 1 "Ambiente indefinido ou invalido ('$Ambiente'). Rode com -Registrar -Ambiente <amb>."
}

Write-Log "=== Verificacao de atualizacao (ambiente: $Ambiente) ==="

# ------------------------------------------------------------------ manifesto
$url = "https://raw.githubusercontent.com/$Repo/$Ambiente/release/manifest.json"
try {
    $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30 `
        -Headers @{ 'Cache-Control' = 'no-cache' }
    $manifesto = $resp.Content | ConvertFrom-Json
} catch {
    Exit-With 1 "Nao foi possivel ler o manifesto em $url : $_"
}

# Antes de qualquer decisao sobre o RustDesk: manter este script em dia.
Update-Script -Ambiente $Ambiente

$alvo = $manifesto.agente.versao
if (-not $alvo) { Exit-With 1 'Manifesto sem agente.versao.' }

# ------------------------------------------------------------ versão instalada
$instalada = $null
try {
    $instalada = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\RustDesk\' -ErrorAction Stop).Version
} catch { }

Write-Log "Instalada: ${instalada}  |  Publicada para ${Ambiente}: ${alvo}  |  release $($manifesto.versao)"

if ($instalada -eq $alvo -and -not $Forcar) {
    Set-Content -Path "$EstadoDir\versao-aplicada.txt" -Value $manifesto.versao -Encoding ascii -NoNewline
    Exit-With 0 'Endpoint ja esta na versao publicada - nada a fazer.'
}

if ($Verificar) {
    Exit-With 0 "[-Verificar] Atualizaria de '${instalada}' para '${alvo}'. Nada foi alterado."
}

# ------------------------------------------------------- guarda: sessão ativa?
# Heurística: conexões estabelecidas do rustdesk.exe que NÃO sejam o canal de
# signaling com o hbbs (21115/21116) indicam sessão em andamento — relay (21117)
# ou P2P direto. No boot isso nunca dispara; serve para o ciclo periódico.
if (-not $Forcar) {
    try {
        $pids = @((Get-Process -Name 'rustdesk' -ErrorAction SilentlyContinue).Id)
        if ($pids.Count -gt 0) {
            $ativas = @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
                Where-Object { $pids -contains $_.OwningProcess -and @(21115, 21116) -notcontains $_.RemotePort })
            if ($ativas.Count -gt 0) {
                Exit-With 5 "Sessao remota em andamento ($($ativas.Count) conexao/oes) - atualizacao adiada para o proximo ciclo."
            }
        }
    } catch {
        Write-Log "Nao foi possivel checar sessoes ativas: $_" 'WARN'
    }
}

# ------------------------------------------------------ download + SHA256
$sha = "$($manifesto.agente.sha256)".Trim()
if ([string]::IsNullOrWhiteSpace($sha)) {
    Exit-With 2 'Manifesto sem agente.sha256. Recusando instalar binario nao verificado.'
}
if ($sha -notmatch '^[0-9a-fA-F]{64}$') {
    Exit-With 2 "agente.sha256 nao e um SHA-256 valido ('$sha'). Recusando."
}

$origem = "$($manifesto.agente.url)".Trim()
# O binario e executado como SYSTEM. Sem HTTPS, qualquer um na rota troca o
# arquivo - e o hash viria do mesmo canal comprometido se a URL do manifesto
# tambem fosse insegura.
if ($origem -notmatch '^https://') {
    Exit-With 2 "agente.url nao usa HTTPS ('$origem'). Recusando."
}
$tmp = Join-Path $env:TEMP "rustdesk-$alvo.exe"
Write-Log "Baixando $origem"
try {
    $pp = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $origem -OutFile $tmp -UseBasicParsing -TimeoutSec 600
    $ProgressPreference = $pp
} catch {
    Exit-With 1 "Falha no download: $_"
}

$calc = (Get-FileHash -Path $tmp -Algorithm SHA256).Hash
if ($calc -ne $sha.ToUpperInvariant()) {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    Exit-With 2 "SHA256 NAO CONFERE. Esperado $($sha.ToUpperInvariant()), obtido $calc. Arquivo descartado."
}
Write-Log 'SHA256 conferido.'

# -------------------------------------------------------------------- instalar
Write-Log "Instalando RustDesk $alvo (silencioso)."
try {
    Start-Process -FilePath $tmp -ArgumentList '--silent-install' -Wait -NoNewWindow
} catch {
    Exit-With 3 "Instalacao falhou: $_"
}

$exe = Join-Path $RustDeskDir 'rustdesk.exe'
$deadline = (Get-Date).AddSeconds(180)
while (-not (Test-Path $exe) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 3 }
if (-not (Test-Path $exe)) { Exit-With 3 "rustdesk.exe nao encontrado em $RustDeskDir apos a instalacao." }
Remove-Item $tmp -Force -ErrorAction SilentlyContinue

# ------------------------------------------- reaplicar config (corrige drift)
$cfgFile = "$EstadoDir\config-string.txt"
if (Test-Path $cfgFile) {
    $cfg = (Get-Content $cfgFile -Raw).Trim()
    if ($cfg) {
        Write-Log 'Reaplicando configuracao de servidor.'
        try { & $exe --config $cfg | Out-Null } catch { Write-Log "Falha ao reaplicar --config: $_" 'WARN' }
    }
}

# --------------------------------------------------------------------- serviço
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-Log 'Servico ausente apos a atualizacao - reinstalando.' 'WARN'
    Start-Process -FilePath $exe -ArgumentList '--install-service' -Wait -NoNewWindow
    Start-Sleep -Seconds 10
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
}
if (-not $svc) { Exit-With 4 'Servico RustDesk nao existe apos a atualizacao.' }

$deadline = (Get-Date).AddSeconds(120)
while ($svc.Status -ne 'Running' -and (Get-Date) -lt $deadline) {
    try { Start-Service $ServiceName -ErrorAction Stop } catch { }
    Start-Sleep -Seconds 5
    $svc.Refresh()
}
if ($svc.Status -ne 'Running') { Exit-With 4 "Servico nao voltou a Running (estado: $($svc.Status))." }

Set-Content -Path "$EstadoDir\versao-aplicada.txt" -Value $manifesto.versao -Encoding ascii -NoNewline
Exit-With 0 "=== Atualizado para RustDesk $alvo (release $($manifesto.versao)) ==="
