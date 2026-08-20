# Roteiro de validação — PoC Acesso Remoto Afiminas

Prova de conceito da stack **100% gratuita** (AGPL-3.0): `hbbs`/`hbbr`
**oficiais RustDesk** + console OSS de terceiros para auto-registro, lista de
dispositivos e grupos.

Este roteiro roda em **homologação**. Depois do PoC ele continua útil: é a
bateria de testes que valida uma promoção antes de ela ir para produção.

Contexto, decisões e riscos: [`memoria.md`](memoria.md)
Fluxo de branches e auto-update: [`../VERSIONAMENTO.md`](../VERSIONAMENTO.md)

---

## Objetivo do PoC

Responder **três perguntas** que decidem se a stack gratuita atende. Nada além disso.

| # | Pergunta | Como se verifica |
|---|---|---|
| **1** | O dispositivo aparece **sozinho** no console após instalar e configurar o cliente? | Teste 3 |
| **2** | Dá para organizar em **grupos/pastas** e isso reflete no *book* do técnico? | Teste 4 |
| **3** | O técnico logado no cliente **vê a lista e conecta** com um clique? | Teste 5 |

Se as três responderem SIM, a stack gratuita atende o escopo e seguimos para
produção (HTTPS, backup, digest fixo do console). Se alguma falhar, o plano B é o
[BetterDesk](https://github.com/UNITRONIX/BetterDesk) — trocar só o console,
mantendo `hbbs`/`hbbr`.

---

## Pré-requisitos

- **Host Linux** com Docker + Docker Compose.
  `network_mode: host` é obrigatório aqui e **não funciona** em Docker Desktop no Windows/macOS.
- Portas liberadas no firewall do SO **e** no security group do provedor (se for cloud):

```bash
sudo ufw allow 21115:21117/tcp
sudo ufw allow 21116/udp
sudo ufw allow 21114/tcp
sudo ufw enable
```

> `21114` fica aberta **apenas em homologação** para acessar o console por HTTP.
> Em produção ela volta a ser interna e o acesso passa por Nginx/443.
> `21118` e `21119` permanecem **fechadas** (ver [`memoria.md`](memoria.md) §4).

---

## Instalação

```bash
git clone https://github.com/PHRDevSYS/RustDesk-Personalite.git /opt/azuredesk
cd /opt/azuredesk && git checkout homologacao

cp ambientes/homologacao/.env.example               ambientes/homologacao/.env
cp ambientes/homologacao/config/server.yaml.example ambientes/homologacao/config/server.yaml
```

Edite **`ambientes/homologacao/.env`** — no mínimo `CONSOLE_ADMIN_USER`,
`CONSOLE_ADMIN_PASS` e `RUSTDESK_*`.

Edite **`ambientes/homologacao/config/server.yaml`** — gere o `signKey`:

```bash
openssl rand -base64 32
```

Suba a stack:

```bash
export AMBIENTE=homologacao
alias dc="docker compose --project-directory ambientes/$AMBIENTE --env-file ambientes/$AMBIENTE/.env -f servidor/compose.yml"

dc up -d
dc ps
```

> As instruções abaixo usam esse `dc`. Sem o alias, repita a linha inteira.

---

## Teste 1 — Servidor no ar

```bash
AMBIENTE=homologacao ./servidor/scripts/healthcheck.sh -v
```

Esperado: `RESULTADO: PASS`. O `-v` imprime a **Key** pública, necessária no próximo passo.

Se falhar, veja *Troubleshooting* no fim.

**Guarde a Key:**

```bash
cat ambientes/homologacao/data-rustdesk/id_ed25519.pub
```

> ⚠️ `data-rustdesk/id_ed25519` (a chave **privada**) é o ativo mais crítico do ambiente.
> Se for perdida, **todos** os clientes precisam ser reconfigurados. Faça backup antes de prosseguir.

---

## Teste 2 — Console acessível e config string

1. Abra `http://SEU_IP:21114` e faça login com `CONSOLE_ADMIN_USER` / `CONSOLE_ADMIN_PASS`.
2. Numa máquina Windows de teste, instale o cliente RustDesk manualmente e configure:
   - menu `⋮` ao lado do ID → **Network** → destravar (requer privilégio elevado)
   - **ID Server:** `SEU_IP` · **Key:** conteúdo de `id_ed25519.pub` · **API Server:** `http://SEU_IP:21114`
   - **Apply**
3. Ainda em Network, clique em **Export Server Config** e guarde a string.

Essa string é o `-ConfigString` do script de deploy. É o caminho oficial documentado
(*Client Configuration* §3) e não depende de nenhum recurso Pro.

---

## Teste 3 — Auto-registro ⭐ (pergunta 1)

Numa **segunda** máquina Windows, ainda sem RustDesk, copie a pasta
`agente\windows` e execute como Administrador:

```powershell
.\install-agent.ps1 -ConfigString "COLE_A_STRING_AQUI" -Ambiente homologacao
```

O script instala, cria o serviço, aplica a config, define senha aleatória,
registra a Tarefa Agendada de auto-update e imprime o ID.

**Critério de aceite:** em até ~30 s o dispositivo aparece **sozinho** na lista do console,
sem nenhum cadastro manual e sem login de usuário na máquina remota.

```bash
dc logs -f console          # acompanhar o heartbeat chegando
```

Rode o script **duas vezes** na mesma máquina: a segunda execução deve detectar a versão
já instalada e não reinstalar (idempotência).

---

## Teste 4 — Grupos ⭐ (pergunta 2)

No console: crie ao menos dois grupos (ex.: `Cliente A`, `Cliente B`), mova dispositivos
entre eles e confirme que a organização persiste após `dc restart console`.

**Critério de aceite:** a hierarquia de grupos existe, é editável e sobrevive a restart.

---

## Teste 5 — Conexão pelo book ⭐ (pergunta 3)

1. No console, crie um usuário técnico.
2. No cliente RustDesk do técnico, faça login com esse usuário.
3. A lista de dispositivos / address book deve sincronizar.
4. Conecte em um dispositivo pela lista.

**Critério de aceite:** o técnico vê a lista e conecta sem digitar ID manualmente.

---

## Teste 6 — Registro de acessos (audit)

Confirma que o console grava o **log de conexão**. O contrato de API lista
`/api/audit` como *opcional* ([`memoria.md`](memoria.md) §5.4); a leitura do
código confirmou que este console implementa (§6.2), mas isso ainda não foi
observado em execução.

Depois de abrir e **fechar** uma conexão no Teste 5:

```bash
DB=ambientes/homologacao/data-console/server.db
SQL="SELECT id, rustdesk_id, ip, type, created_at, closed_at FROM audit ORDER BY id DESC LIMIT 5;"

sqlite3 "$DB" "$SQL"
```

Se o host não tiver `sqlite3` instalado, use um container descartável em vez de
instalar no servidor:

```bash
docker run --rm -v "$PWD/ambientes/homologacao/data-console:/d" -w /d alpine \
  sh -c "apk add -q sqlite && sqlite3 server.db '$SQL'"
```

**Critérios de aceite:**
- Existe uma linha para a sessão do Teste 5, com o `rustdesk_id` do dispositivo
  acessado e o `ip` de origem.
- `type` = `0` (controle remoto).
- `closed_at` é preenchido ao encerrar a sessão — se ficar nulo, o `action:"close"`
  não chegou e a duração da sessão não é confiável.
- A mesma informação aparece na tela de auditoria do console.

Transferindo um arquivo durante a sessão, `file_transfer` também deve receber uma
linha. O `uuid` dessa tabela vem errado por um defeito upstream
([`memoria.md`](memoria.md) §6.1, achado 9) — ignore essa coluna.

> Se este teste falhar, o acesso remoto continua funcionando, mas **não há
> rastro de quem acessou o quê**. Para um provedor de suporte a farmácias isso é
> requisito de prestação de contas, não item opcional — trate como bloqueante
> para produção, ainda que não bloqueie o PoC.

---

## Teste 7 — Relay (fallback)

Confirma que o `hbbr` funciona quando o P2P não é possível:

```bash
dc logs hbbr | grep -i relay
```

Para forçar relay, adicione `ALWAYS_USE_RELAY=Y` ao serviço `hbbs` em
`servidor/compose.yml`, reinicie e refaça uma conexão. **Reverta depois** — em
produção o P2P é o caminho desejado.

---

## Teste 8 — Persistência

```bash
dc down
dc up -d
AMBIENTE=homologacao ./servidor/scripts/healthcheck.sh
```

**Critério de aceite:** dispositivos, grupos e usuários continuam lá. Se sumirem, o volume
`/app/data` não persistiu (ver [`memoria.md`](memoria.md) §6, achado 3).

---

## Teste 9 — Auto-update

Valida o mecanismo que leva uma nova versão até servidores e endpoints.

**Servidor:**

```bash
AMBIENTE=homologacao ./servidor/scripts/autoupdate-servidor.sh --forcar
cat ambientes/homologacao/.versao-aplicada
journalctl -u azuredesk-autoupdate -n 50
```

**Endpoint** (na máquina Windows, como Administrador):

```powershell
& "$env:ProgramFiles\AzureControlDesk\autoupdate-agent.ps1" -Verificar
Get-Content "$env:ProgramData\Afiminas\autoupdate.log" -Tail 20
Get-ScheduledTask -TaskName 'AzureControlDesk - AutoUpdate' | Get-ScheduledTaskInfo
```

**Critérios de aceite:**
- O servidor aplica a versão do manifesto e o healthcheck passa depois.
- Uma versão deliberadamente quebrada dispara **rollback** e o ambiente volta a funcionar
  (teste apontando `console_image` para uma tag inexistente).
- O endpoint com `agente.sha256` vazio **recusa** a atualização (exit 2) — falha fechada.
- Reiniciar a máquina Windows dispara a tarefa sozinha em até ~15 min.

---

## Registro dos resultados

| # | Teste | Resultado | Observações |
|---|---|---|---|
| 1 | Servidor no ar | ⬜ PASS / FAIL | |
| 2 | Console + config string | ⬜ PASS / FAIL | |
| 3 | **Auto-registro** | ⬜ PASS / FAIL | |
| 4 | **Grupos** | ⬜ PASS / FAIL | |
| 5 | **Book + conexão** | ⬜ PASS / FAIL | |
| 6 | **Log de acessos (audit)** | ⬜ PASS / FAIL | |
| 7 | Relay | ⬜ PASS / FAIL | |
| 8 | Persistência | ⬜ PASS / FAIL | |
| 9 | Auto-update + rollback | ⬜ PASS / FAIL | |

Preencha e me devolva — os achados voltam para [`memoria.md`](memoria.md).

---

## Troubleshooting

**Console responde 404 / página em branco**
Achado 2 do [`memoria.md`](memoria.md) §6 se confirmou: o `staticdir` está sendo lido como relativo.
Confirme qual config o app usou:
```bash
dc exec console cat /app/data/server.yaml
```
Se vier um YAML gerado automaticamente (porta `:8080`, `staticdir: dist`), a nossa config
não foi lida. Ajuste o caminho do bind mount em `servidor/compose.yml` e recrie o container.

**Dispositivo não aparece no console**
- `API Server` está preenchido no cliente? Sem ele não há heartbeat.
- `dc logs console | grep -i heartbeat`
- Porta 21114 alcançável a partir da máquina cliente? `Test-NetConnection SEU_IP -Port 21114`

**`Key mismatch` no cliente**
A Key não confere com `data-rustdesk/id_ed25519.pub`. Recopie — sem espaços ou quebras.

**`Failed to connect to relay server`**
`hbbr` fora do ar ou 21117 bloqueada. `dc ps` e cheque o firewall.

**Cliente na mesma LAN do servidor não conecta, mas de fora funciona**
NAT loopback (hairpin NAT). Habilite no roteador ou aponte o domínio para o IP LAN via
DNS interno. Ver documentação oficial de *NAT Loopback issues*.

**Nenhuma linha em `audit` depois de uma conexão**
O cliente só envia auditoria quando tem `API Server` configurado — o mesmo pré-requisito
do auto-registro. Confirme com `dc logs console | grep -i audit`. Lembre que quem reporta
é a **máquina acessada**, não a do técnico ([`memoria.md`](memoria.md) §6.2).

**Auto-update do servidor sai com código 9**
Rollback também falhou — o ambiente está quebrado e não se auto-recupera.
`dc logs` e `journalctl -u azuredesk-autoupdate`. Exige intervenção manual.

---

## O que este PoC **não** cobre

Deliberadamente fora do escopo — só entram se o PoC passar:

- HTTPS/TLS (Nginx + Certbot) — o console de homologação roda em HTTP puro
- Backup automatizado com retenção e teste de restore
- Branding "AzureDesk" (rebuild do cliente)
- Hardening do host e do Docker
- Deployment macOS / Linux nos endpoints
