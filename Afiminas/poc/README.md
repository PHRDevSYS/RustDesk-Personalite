# PoC — Acesso Remoto Corporativo Afiminas

Prova de conceito da stack **100% gratuita** (AGPL-3.0) de acesso remoto:
`hbbs`/`hbbr` **oficiais RustDesk** + console OSS de terceiros para auto-registro,
lista de dispositivos e grupos.

Contexto, decisões e riscos: [`../memoria.md`](../memoria.md)

---

## Objetivo do PoC

Responder **três perguntas** que decidem se a stack gratuita atende. Nada além disso.

| # | Pergunta | Como se verifica |
|---|---|---|
| **1** | O dispositivo aparece **sozinho** no console após instalar e configurar o cliente? | Teste 3 |
| **2** | Dá para organizar em **grupos/pastas** e isso reflete no *book* do técnico? | Teste 4 |
| **3** | O técnico logado no cliente **vê a lista e conecta** com um clique? | Teste 5 |

Se as três responderem SIM, a stack gratuita atende o escopo e seguimos para produção
(HTTPS, backup, pin de versões). Se alguma falhar, o plano B é o
[BetterDesk](https://github.com/UNITRONIX/BetterDesk) — trocar só o console, mantendo `hbbs`/`hbbr`.

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

> `21114` fica aberta **apenas durante o PoC** para acessar o console por HTTP.
> Em produção ela volta a ser interna e o acesso passa por Nginx/443.
> `21118` e `21119` permanecem **fechadas** (ver `memoria.md` §4).

---

## Instalação

```bash
cp .env.example .env
cp config/server.yaml.example config/server.yaml
```

Edite **`.env`** — no mínimo `CONSOLE_ADMIN_USER`, `CONSOLE_ADMIN_PASS` e `RUSTDESK_*`.

Edite **`config/server.yaml`** — gere o `signKey`:

```bash
openssl rand -base64 32
```

Suba a stack:

```bash
docker compose up -d
docker compose ps
```

---

## Teste 1 — Servidor no ar

```bash
chmod +x scripts/healthcheck.sh
./scripts/healthcheck.sh -v
```

Esperado: `RESULTADO: PASS`. O `-v` imprime a **Key** pública, necessária no próximo passo.

Se falhar, veja *Troubleshooting* no fim.

**Guarde a Key:**

```bash
cat data-rustdesk/id_ed25519.pub
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

Numa **segunda** máquina Windows, ainda sem RustDesk, execute como Administrador:

```powershell
.\deploy\windows\install-agent.ps1 -ConfigString "COLE_A_STRING_AQUI"
```

O script instala, cria o serviço, aplica a config, define senha aleatória e imprime o ID.

**Critério de aceite:** em até ~30 s o dispositivo aparece **sozinho** na lista do console,
sem nenhum cadastro manual e sem login de usuário na máquina remota.

```bash
# acompanhar o heartbeat chegando
docker compose logs -f console
```

Rode o script **duas vezes** na mesma máquina: a segunda execução deve detectar a versão
já instalada e não reinstalar (idempotência).

---

## Teste 4 — Grupos ⭐ (pergunta 2)

No console: crie ao menos dois grupos (ex.: `Cliente A`, `Cliente B`), mova dispositivos
entre eles e confirme que a organização persiste após `docker compose restart console`.

**Critério de aceite:** a hierarquia de grupos existe, é editável e sobrevive a restart.

---

## Teste 5 — Conexão pelo book ⭐ (pergunta 3)

1. No console, crie um usuário técnico.
2. No cliente RustDesk do técnico, faça login com esse usuário.
3. A lista de dispositivos / address book deve sincronizar.
4. Conecte em um dispositivo pela lista.

**Critério de aceite:** o técnico vê a lista e conecta sem digitar ID manualmente.

---

## Teste 6 — Relay (fallback)

Confirma que o `hbbr` funciona quando o P2P não é possível:

```bash
docker compose logs hbbr | grep -i relay
```

Para forçar relay, adicione `ALWAYS_USE_RELAY=Y` ao serviço `hbbs` no `compose.yml`,
reinicie e refaça uma conexão. **Reverta depois** — em produção o P2P é o caminho desejado.

---

## Teste 7 — Persistência

```bash
docker compose down
docker compose up -d
./scripts/healthcheck.sh
```

**Critério de aceite:** dispositivos, grupos e usuários continuam lá. Se sumirem, o volume
`/app/data` não persistiu (ver `memoria.md` §6, achado 3).

---

## Registro dos resultados

| # | Teste | Resultado | Observações |
|---|---|---|---|
| 1 | Servidor no ar | ⬜ PASS / FAIL | |
| 2 | Console + config string | ⬜ PASS / FAIL | |
| 3 | **Auto-registro** | ⬜ PASS / FAIL | |
| 4 | **Grupos** | ⬜ PASS / FAIL | |
| 5 | **Book + conexão** | ⬜ PASS / FAIL | |
| 6 | Relay | ⬜ PASS / FAIL | |
| 7 | Persistência | ⬜ PASS / FAIL | |

Preencha e me devolva — os achados voltam para `memoria.md`.

---

## Troubleshooting

**Console responde 404 / página em branco**
Achado 2 do `memoria.md` §6 se confirmou: o `staticdir` está sendo lido como relativo.
Confirme qual config o app usou:
```bash
docker compose exec console cat /app/data/server.yaml
```
Se vier um YAML gerado automaticamente (porta `:8080`, `staticdir: dist`), a nossa config
não foi lida. Ajuste o caminho do bind mount no `compose.yml` e recrie o container.

**Dispositivo não aparece no console**
- `API Server` está preenchido no cliente? Sem ele não há heartbeat.
- `docker compose logs console | grep -i heartbeat`
- Porta 21114 alcançável a partir da máquina cliente? `Test-NetConnection SEU_IP -Port 21114`

**`Key mismatch` no cliente**
A Key não confere com `data-rustdesk/id_ed25519.pub`. Recopie — sem espaços ou quebras.

**`Failed to connect to relay server`**
`hbbr` fora do ar ou 21117 bloqueada. `docker compose ps` e cheque o firewall.

**Cliente na mesma LAN do servidor não conecta, mas de fora funciona**
NAT loopback (hairpin NAT). Habilite no roteador ou aponte o domínio para o IP LAN via
DNS interno. Ver documentação oficial de *NAT Loopback issues*.

---

## O que este PoC **não** cobre

Deliberadamente fora do escopo — só entram se o PoC passar:

- HTTPS/TLS (Nginx + Certbot) — o console roda em HTTP puro aqui
- Backup automatizado com retenção e teste de restore
- Pin de versões por digest
- Branding "AzureDesk" (rebuild do cliente)
- Hardening do host e do Docker
