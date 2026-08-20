<#
.SYNOPSIS
    Promove versões entre as branches de ambiente do AzureControlDesk.

.DESCRIPTION
    O fluxo é sempre o mesmo e em uma direção só:

        main  --(promover)-->  homologacao  --(promover)-->  producao

    Toda promoção é um merge FAST-FORWARD. Nenhum arquivo é editado na branch
    de destino, então as três branches têm exatamente o mesmo conteúdo e nunca
    entram em conflito. O que distingue um ambiente do outro é apenas ATÉ ONDE
    cada branch avançou.

    Consequência prática: nada chega em produção sem ter passado por
    homologação, porque `producao` só faz fast-forward a partir de `homologacao`.

    O manifesto (release/manifest.json) é editado SEMPRE em main, nunca no
    destino. É ele que o auto-update de servidores e endpoints lê.

.PARAMETER Para
    homologacao | producao — a branch de destino da promoção.

.PARAMETER Versao
    Nova versão do release (ex.: 1.0.0). Editada em main e commitada antes de
    promover.

.PARAMETER VersaoAgente
    Nova versão do cliente RustDesk (ex.: 1.4.9). Baixa o instalador oficial e
    grava o SHA256 no manifesto. Sem esse hash o auto-update dos endpoints se
    recusa a instalar.

.PARAMETER ImagemConsole
    Imagem do console. Em produção use SEMPRE digest fixo:
    ghcr.io/lantongxue/rustdesk-api-server-pro@sha256:...

.PARAMETER ImagemServidor
    Imagem do rustdesk-server (hbbs/hbbr), ex.: rustdesk/rustdesk-server:1.1.16

.PARAMETER SemConfirmar
    Não pergunta antes de promover para produção. Use só em automação.

.EXAMPLE
    # 1. Preparar o release em main (calcula o SHA256 do instalador)
    .\scripts\promover.ps1 -Versao 1.0.0 -VersaoAgente 1.4.9

.EXAMPLE
    # 2. Publicar em homologação para teste
    .\scripts\promover.ps1 -Para homologacao

.EXAMPLE
    # 3. Depois de validado, publicar em produção (cria a tag v1.0.0)
    .\scripts\promover.ps1 -Para producao
#>

[CmdletBinding()]
param(
    [ValidateSet('homologacao', 'producao')][string]$Para,
    [ValidatePattern('^\d+\.\d+\.\d+$')][string]$Versao,
    [string]$VersaoAgente,
    [string]$ImagemConsole,
    [string]$ImagemServidor,
    [switch]$SemConfirmar
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Raiz = Split-Path -Parent $PSScriptRoot
$Manifesto = Join-Path $Raiz 'release\manifest.json'

function Passo($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Aviso($m) { Write-Host "    $m" -ForegroundColor Yellow }
function Erro($m) { Write-Host "ERRO: $m" -ForegroundColor Red; exit 1 }

# Função simples de propósito: sem param block, todos os argumentos caem em
# $args sem passar por parameter binding — necessário para repassar flags como
# -m e -a ao git. E sem 2>&1: no PS 5.1 isso transformaria o stderr do git
# (que ele usa para mensagens normais) em ErrorRecord terminante.
function Git-Ok {
    $saida = & git -C $Raiz @args
    if ($LASTEXITCODE -ne 0) { Erro "git $($args -join ' ') falhou (exit $LASTEXITCODE)" }
    return $saida
}

if (-not $Para -and -not $Versao -and -not $VersaoAgente -and -not $ImagemConsole -and -not $ImagemServidor) {
    Erro 'Nada a fazer. Use -Para, -Versao, -VersaoAgente, -ImagemConsole ou -ImagemServidor. Veja -? para exemplos.'
}

# --------------------------------------------------------------- pré-condições
if ((Git-Ok status --porcelain) -join '') {
    Erro 'Working tree sujo. Commite ou descarte as alterações antes de promover.'
}
$branchAtual = (Git-Ok rev-parse --abbrev-ref HEAD).Trim()
Passo "Buscando o remoto (branch atual: $branchAtual)"
Git-Ok fetch --prune origin | Out-Null

# ===========================================================================
# PARTE 1 — editar o manifesto em main
# ===========================================================================
if ($Versao -or $VersaoAgente -or $ImagemConsole -or $ImagemServidor) {
    if ($branchAtual -ne 'main') { Erro "O manifesto só é editado em main. Você está em '$branchAtual'." }

    $m = Get-Content $Manifesto -Raw | ConvertFrom-Json

    if ($Versao) {
        Passo "Versão do release: $($m.versao) -> $Versao"
        $m.versao = $Versao
    }

    if ($ImagemServidor) {
        Passo "Imagem hbbs/hbbr: $ImagemServidor"
        $m.servidor.rustdesk_server_image = $ImagemServidor
    }

    if ($ImagemConsole) {
        Passo "Imagem do console: $ImagemConsole"
        if ($ImagemConsole -notmatch '@sha256:') {
            Aviso 'Sem digest fixo. Em produção isso significa "não sei qual versão está rodando".'
        }
        $m.servidor.console_image = $ImagemConsole
    }

    if ($VersaoAgente) {
        $arquivo = "rustdesk-$VersaoAgente-x86_64.exe"
        $url = "https://github.com/rustdesk/rustdesk/releases/download/$VersaoAgente/$arquivo"
        Passo "Agente: $($m.agente.versao) -> $VersaoAgente"

        # A API de releases do GitHub já publica o SHA256 do asset. Evita baixar
        # ~24 MB só para calcular um hash, e vem pelo mesmo canal HTTPS de onde
        # o binário viria. Releases antigas não têm o campo: aí cai no download.
        $hash = $null
        try {
            $rel = Invoke-RestMethod -UseBasicParsing -TimeoutSec 60 `
                -Uri "https://api.github.com/repos/rustdesk/rustdesk/releases/tags/$VersaoAgente" `
                -Headers @{ 'Accept' = 'application/vnd.github+json'; 'User-Agent' = 'AzureControlDesk' }
            $asset = $rel.assets | Where-Object { $_.name -eq $arquivo }
            if (-not $asset) { Erro "A release $VersaoAgente não tem o asset $arquivo." }
            if ($asset.digest -and $asset.digest -match '^sha256:(?<h>[0-9a-fA-F]{64})$') {
                $hash = $Matches['h'].ToUpperInvariant()
                Aviso "SHA256 obtido da API do GitHub (asset de $([math]::Round($asset.size/1MB,1)) MB)."
            }
        } catch {
            Erro "Não foi possível consultar a release ${VersaoAgente}: $_"
        }

        if (-not $hash) {
            Aviso 'API sem digest para este asset. Baixando o instalador para calcular...'
            $tmp = Join-Path $env:TEMP $arquivo
            try {
                $pp = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
                Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 900
                $ProgressPreference = $pp
            } catch {
                Erro "Download falhou: $_"
            }
            $hash = (Get-FileHash -Path $tmp -Algorithm SHA256).Hash
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }

        $m.agente.versao = $VersaoAgente
        $m.agente.url = $url
        $m.agente.sha256 = $hash
        Aviso "SHA256: $hash"
    }

    $m.gerado_em = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

    if ([string]::IsNullOrWhiteSpace($m.agente.sha256)) {
        Aviso 'agente.sha256 continua vazio: os endpoints vao RECUSAR a atualizacao (falha fechada).'
    }

    # Sem BOM de propósito: o manifesto é lido por json.load() no servidor Linux,
    # que quebra em UTF-8 com BOM. Set-Content -Encoding utf8 no PS 5.1 grava BOM.
    [IO.File]::WriteAllText($Manifesto, ($m | ConvertTo-Json -Depth 10) + "`n",
        (New-Object Text.UTF8Encoding($false)))
    Git-Ok add release/manifest.json | Out-Null
    Git-Ok commit -m "release: manifesto $($m.versao) (agente $($m.agente.versao))" | Out-Null
    Git-Ok push origin main | Out-Null
    Passo "main atualizada: release $($m.versao)"
}

if (-not $Para) { exit 0 }

# ===========================================================================
# PARTE 2 — promover (fast-forward)
# ===========================================================================
if ($Para -eq 'homologacao') { $origem = 'main' } else { $origem = 'homologacao' }

$shaOrigem = (Git-Ok rev-parse "origin/$origem").Trim()
$shaDestino = (Git-Ok rev-parse "origin/$Para").Trim()

if ($shaOrigem -eq $shaDestino) {
    Passo "$Para já está em $($shaOrigem.Substring(0,7)) — nada a promover."
    exit 0
}

# Fast-forward só é possível se o destino for ancestral da origem. Se não for,
# alguém commitou direto na branch de ambiente — isso quebra o fluxo.
& git -C $Raiz merge-base --is-ancestor $shaDestino $shaOrigem | Out-Null
if ($LASTEXITCODE -ne 0) {
    Erro "'$Para' tem commits que não estão em '$origem'. Alguém publicou direto na branch de ambiente. Resolva manualmente antes de promover."
}

$versaoRelease = (Get-Content $Manifesto -Raw | ConvertFrom-Json).versao
Write-Host ''
Passo "Promoção: $origem ($($shaOrigem.Substring(0,7)))  ->  $Para ($($shaDestino.Substring(0,7)))"
Git-Ok log --oneline "$shaDestino..$shaOrigem" | ForEach-Object { Write-Host "    $_" }
Write-Host ''

if ($Para -eq 'producao' -and -not $SemConfirmar) {
    Aviso 'Isto publica em PRODUÇÃO. Os servidores e os endpoints da frota vão aplicar'
    Aviso 'esta versão automaticamente no próximo ciclo (até 30min / 6h) ou no próximo boot.'
    $r = Read-Host "Confirmar promoção do release $versaoRelease para produção? (digite: producao)"
    if ($r -ne 'producao') { Erro 'Cancelado.' }
}

Git-Ok checkout $Para | Out-Null
Git-Ok merge --ff-only "origin/$origem" | Out-Null
Git-Ok push origin $Para | Out-Null
Passo "$Para agora em $($shaOrigem.Substring(0,7))"

if ($Para -eq 'producao') {
    $tag = "v$versaoRelease"
    $existe = (& git -C $Raiz tag --list $tag) -join ''
    if ($existe) {
        Aviso "Tag $tag já existe — não recriada. Suba a versão no manifesto para o próximo release."
    } else {
        Git-Ok tag -a $tag -m "Producao: release $versaoRelease" | Out-Null
        Git-Ok push origin $tag | Out-Null
        Passo "Tag $tag criada e publicada"
    }
}

Git-Ok checkout $branchAtual | Out-Null
Write-Host ''
Passo "Concluído. De volta em $branchAtual."
if ($Para -eq 'homologacao') {
    Write-Host '    Próximo passo: validar em homologação e rodar:' -ForegroundColor Green
    Write-Host '      .\scripts\promover.ps1 -Para producao' -ForegroundColor Green
}
