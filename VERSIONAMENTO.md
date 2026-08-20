# Versionamento, ambientes e auto-update

Como uma alteração sai da máquina do desenvolvedor e chega aos servidores e aos
endpoints dos clientes.

---

## 1. As três branches

| Branch | Papel | Quem consome |
|---|---|---|
| `main` | Integração. É a única branch onde se commita. | ninguém em produção |
| `homologacao` | Ambiente de teste. Recebe tudo que entra em `main`. | servidor + endpoints de HML |
| `producao` | Ambiente real. Só recebe o que foi validado em homologação. | servidor + frota de clientes |

```
        commit / PR
             │
             ▼
          [ main ] ──promover──► [ homologacao ] ──validar──► [ producao ] ──► tag vX.Y.Z
                                       │                            │
                                  auto-update                  auto-update
                                       ▼                            ▼
                                 servidor HML              servidor PRD + frota
```

**Toda promoção é um merge fast-forward.** Nada é editado na branch de destino,
então as três branches têm conteúdo idêntico e nunca entram em conflito — o que
distingue um ambiente do outro é apenas *até onde* cada branch avançou.

Isso dá a garantia central pedida: **`producao` só faz fast-forward a partir de
`homologacao`**, então é estruturalmente impossível uma alteração chegar em
produção sem ter passado por homologação. Se alguém commitar direto numa branch
de ambiente, o fast-forward deixa de ser possível e o `promover.ps1` recusa a
promoção em vez de resolver o conflito silenciosamente.

---

## 2. O manifesto

`release/manifest.json` é o contrato entre o repositório e o auto-update. É
editado **sempre em `main`**, nunca no destino.

```json
{
  "versao": "1.0.0",
  "gerado_em": "2026-08-20T12:00:00Z",
  "servidor": {
    "rustdesk_server_image": "rustdesk/rustdesk-server:1.1.16",
    "console_image": "ghcr.io/lantongxue/rustdesk-api-server-pro@sha256:..."
  },
  "agente": {
    "versao": "1.4.9",
    "url": "https://github.com/rustdesk/rustdesk/releases/download/1.4.9/rustdesk-1.4.9-x86_64.exe",
    "sha256": "A1B2C3..."
  },
  "notas": "texto livre"
}
```

| Campo | Consumido por | Efeito |
|---|---|---|
| `versao` | ambos | identidade do release; vira a tag `vX.Y.Z` na promoção para produção |
| `servidor.rustdesk_server_image` | servidor | imagem de `hbbs`/`hbbr` |
| `servidor.console_image` | servidor | imagem do console. **Em produção, sempre digest `@sha256:`** |
| `agente.versao` | endpoint | versão alvo do cliente RustDesk |
| `agente.url` | endpoint | de onde baixar o instalador |
| `agente.sha256` | endpoint | **obrigatório.** Vazio ou divergente = instalação recusada |

> O `sha256` não é formalidade. O instalador vem das releases públicas do
> RustDesk, que são de terceiros; sem verificar o hash, o auto-update seria um
> canal para executar como SYSTEM qualquer binário servido naquela URL.
> O comportamento é **falha fechada**: sem hash, não instala.

Não há campo de canal/ambiente no manifesto de propósito — ele obrigaria a
editar o arquivo em cada branch, e cada promoção passaria a dar conflito. A
branch já identifica o ambiente.

---

## 3. Publicando um release

Tudo pelo `scripts/promover.ps1`, a partir de `main` com o working tree limpo.

```powershell
# 1. Preparar o release em main.
#    -VersaoAgente busca o SHA256 do asset na API de releases do RustDesk
#    (e só baixa o instalador se a API não trouxer o digest).
.\scripts\promover.ps1 -Versao 1.0.0 -VersaoAgente 1.4.9

# 2. Publicar em homologação. O servidor HML aplica em até 30 min (ou no boot);
#    os endpoints de HML, em até 6h (ou no boot).
.\scripts\promover.ps1 -Para homologacao

# 3. Validar em homologação:
#      AMBIENTE=homologacao ./servidor/scripts/healthcheck.sh
#      + os testes de Afiminas/roteiro-poc.md que a alteração afeta

# 4. Publicar em produção (pede confirmação e cria a tag v1.0.0).
.\scripts\promover.ps1 -Para producao
```

Fixando o digest do console (recomendado antes de qualquer promoção para
produção — o upstream não publica releases tagueadas):

```powershell
docker buildx imagetools inspect ghcr.io/lantongxue/rustdesk-api-server-pro:latest
.\scripts\promover.ps1 -ImagemConsole 'ghcr.io/lantongxue/rustdesk-api-server-pro@sha256:...'
```

---

## 4. Auto-update do servidor

`servidor/scripts/autoupdate-servidor.sh`, disparado pelo systemd no boot e a
cada 30 min pelo timer.

```
fetch origin <branch do ambiente>
   │
   ├── sem novidade ──► sai (exit 0)
   │
   └── novidade
         ├── guarda o commit e as imagens atuais (estado de rollback)
         ├── git reset --hard origin/<branch>
         ├── lê o manifesto -> exporta as imagens
         ├── docker compose pull && up -d
         └── healthcheck (6 tentativas, ~60s)
               ├── PASS ──► grava .versao-aplicada     (exit 0)
               └── FAIL ──► ROLLBACK para o commit e as imagens anteriores
                              ├── healthcheck PASS ──► ambiente intacto  (exit 1)
                              └── healthcheck FAIL ──► intervenção manual (exit 9)
```

O rollback é o que torna isso aceitável. Sem ele, o auto-update seria uma forma
automatizada de derrubar produção às 3 da manhã.

**Instalação no servidor** (root, uma vez por host):

```bash
git clone https://github.com/PHRDevSYS/RustDesk-Personalite.git /opt/azuredesk
cd /opt/azuredesk && git checkout producao        # ou homologacao

cp ambientes/producao/.env.example              ambientes/producao/.env
cp ambientes/producao/config/server.yaml.example ambientes/producao/config/server.yaml
# preencher os dois; gerar o signKey com: openssl rand -base64 32

sed -i 's/^Environment=AMBIENTE=.*/Environment=AMBIENTE=producao/' \
    servidor/systemd/azuredesk-autoupdate.service
cp servidor/systemd/azuredesk-autoupdate.* /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now azuredesk-autoupdate.service azuredesk-autoupdate.timer

journalctl -u azuredesk-autoupdate -f
```

`.env`, `config/server.yaml` e os diretórios de dados são ignorados pelo Git, e
por isso sobrevivem intactos ao `git reset --hard` do auto-update.

**Operação manual:**

```bash
AMBIENTE=producao ./servidor/scripts/autoupdate-servidor.sh --forcar   # aplicar agora
AMBIENTE=producao ./servidor/scripts/healthcheck.sh -v                 # validar
systemctl stop azuredesk-autoupdate.timer                              # congelar o ambiente
```

---

## 5. Auto-update dos endpoints

`agente/windows/autoupdate-agent.ps1`, registrado como Tarefa Agendada pelo
`install-agent.ps1`.

| | |
|---|---|
| Conta | `SYSTEM` |
| Gatilhos | no boot (atraso de 5 min) + a cada 6h |
| Atraso aleatório | até 10 min, para a frota não baixar tudo no mesmo minuto |
| Local do script | `%ProgramFiles%\AzureControlDesk\` |
| Estado | `%ProgramData%\Afiminas\` — `ambiente.txt`, `config-string.txt`, `versao-aplicada.txt`, `autoupdate.log` |

```
lê %ProgramData%\Afiminas\ambiente.txt
   └── baixa raw.githubusercontent.com/<repo>/<ambiente>/release/manifest.json
        ├── agente.versao == versão instalada ──► sai
        ├── sessão remota em andamento ──────────► adia para o próximo ciclo
        └── atualiza:
              baixa o instalador
              -> VERIFICA O SHA256 (não confere = descarta e aborta)
              -> --silent-install
              -> reaplica a config string
              -> confirma o serviço em Running
              -> atualiza o próprio script a partir da branch
```

O script instala-se em `%ProgramFiles%` e não em `%ProgramData%`: um script
executado como SYSTEM a partir de um diretório gravável por usuário comum é
escalonamento de privilégio. Pelo mesmo motivo o `install-agent.ps1` restringe
a ACL de `%ProgramData%\Afiminas` a SYSTEM e Administradores.

**Instalação de um endpoint:**

```powershell
# copiar a pasta agente\windows inteira para a máquina, e como Administrador:
.\install-agent.ps1 -ConfigString "COLE_A_STRING" -Ambiente producao
```

**Diagnóstico:**

```powershell
Get-Content "$env:ProgramData\Afiminas\autoupdate.log" -Tail 40
& "$env:ProgramFiles\AzureControlDesk\autoupdate-agent.ps1" -Verificar   # o que faria
& "$env:ProgramFiles\AzureControlDesk\autoupdate-agent.ps1" -Forcar      # aplicar agora
Get-ScheduledTask -TaskName 'AzureControlDesk - AutoUpdate' | Get-ScheduledTaskInfo
```

Para congelar um endpoint: `Disable-ScheduledTask -TaskName 'AzureControlDesk - AutoUpdate'`,
ou instalar com `-SemAutoUpdate`.

---

## 6. O risco que este desenho cria

**Quem tem push na branch `producao` executa código como SYSTEM em toda a frota
e como root nos servidores.** Isso não é um efeito colateral: é o mecanismo. O
auto-update existe justamente para que um commit vire execução em toda a base
instalada, sem intervenção.

Controles proporcionais a isso:

| Controle | Estado |
|---|---|
| `producao` protegida contra force-push e deleção | ✅ aplicado |
| Promoção só por fast-forward a partir de `homologacao` | ✅ no `promover.ps1` |
| SHA256 do instalador verificado no endpoint | ✅ falha fechada |
| Rollback automático no servidor se o healthcheck falhar | ✅ |
| **2FA obrigatório na conta com push** | ⬜ **verificar** |
| Revisão obrigatória (PR) antes de merge em `main` | ⬜ decisão do time |
| Assinatura de commits | ⬜ |

O SHA256 protege contra o binário do RustDesk mudar debaixo dos pés — **não**
contra alguém com acesso de escrita ao repositório, porque essa pessoa também
edita o manifesto. Contra esse cenário, o controle real é o acesso à conta.

---

## 7. Convenções

**Versões** seguem SemVer (`MAJOR.MINOR.PATCH`) e se referem a *esta plataforma*,
não ao RustDesk. `agente.versao` é que rastreia o cliente RustDesk.

- `MAJOR` — exige ação manual na atualização (migração de dados, troca de chave)
- `MINOR` — nova capacidade, atualização automática segura
- `PATCH` — correção, atualização automática segura

**Commits** usam prefixo: `feat:`, `fix:`, `docs:`, `chore:`, `release:`.
`release:` é reservado para os commits gerados pelo `promover.ps1`.
