# MEMÓRIA DO PROJETO — Acesso Remoto Corporativo (RustDesk OSS) — Afiminas

> Documento vivo do projeto. Consolida escopo, arquitetura e fatos técnicos validados
> na documentação oficial do RustDesk e na leitura do código-fonte dos componentes.
>
> **Última atualização:** 2026-08-10
> **Status:** Fase 1 — PoC em montagem
> **Escopo:** ENXUTO (ver §1.2 — redefinido em 2026-08-10)

---

## 1. Escopo

### 1.1 O que o sistema precisa fazer

1. Instalar o agente no dispositivo do cliente e **o dispositivo aparecer sozinho no console** (auto-registro).
2. O dispositivo fica **registrado e disponível para receber conexão remota**.
3. Os dispositivos são **organizados por hierarquia de grupos** — uma espécie de *book* com a lista de clientes disponíveis.
4. O técnico abre o cliente, vê a lista e conecta.

**Sem necessidade de Active Directory.** Autenticação local no console.

### 1.2 Mudança de escopo (2026-08-10)

O PDF `Projeto Plataforma Corporativa RustDesk.pdf` (39 seções) descrevia um projeto
significativamente maior, que tornava o **RustDesk Server Pro obrigatório**. O escopo foi
reduzido pelo solicitante para o descrito em §1.1, o que **elimina a obrigatoriedade do Pro**.

| Requisito do PDF original | Status no escopo enxuto |
|---|---|
| Web Console, gerenciamento centralizado | ✅ Mantido — via console OSS de terceiros |
| Address Book / grupos de dispositivos | ✅ Mantido — requisito central |
| Auto-registro de dispositivos | ✅ Mantido — requisito central |
| HTTPS / TLS no console | ✅ Mantido (etapa pós-PoC) |
| Backup e restore | ✅ Mantido (simplificado) |
| Branding / cliente próprio ("AzureDesk") | 🟡 Adiado — etapa de build separada, não bloqueia |
| OIDC / LDAP / Active Directory | ❌ **Removido** — explicitamente dispensado |
| 2FA corporativo, Admin Role, Control Role | ❌ Removido |
| Strategy (push de políticas em massa) | ❌ Removido |
| Múltiplos relays + GeoLocation | ❌ Removido |
| Disaster Recovery formal (RPO/RTO) | ❌ Removido — backup simples atende |
| CI/CD, ambientes DEV/STAGING/PROD formais | 🟡 Reduzido — DEV para PoC, depois produção |
| Deployment macOS / Linux | 🟡 Sob demanda — foco inicial em Windows |

**Consequência:** o projeto passa a ser **100% gratuito** (AGPL-3.0), sem licença comercial.
O solicitante declarou explicitamente não se opor à obrigação AGPL de disponibilizar código-fonte.

### 1.3 O que permanece válido do PDF original

- §3 — **Não recriar o RustDesk.** O núcleo remoto continua sendo código oficial RustDesk.
- §12 — Security by default: firewall, TLS, menor privilégio, secrets fora do Git, sem `admin/test1234`.
- §28 — `.gitignore` protegendo chaves, certificados e secrets.
- §29 — Toda configuração parametrizada via `.env`; nunca domínio ou secret hardcoded.
- §34 — Não executar comandos destrutivos (`rm -rf`, `docker volume prune`) sem confirmação explícita.
- §38 — Formato de resposta: STATUS / OBJETIVO / ANÁLISE / ALTERAÇÕES / IMPLEMENTAÇÃO / VALIDAÇÃO / RISCOS / PRÓXIMA ETAPA.

---

## 2. Decisão de arquitetura

### 2.1 O gancho técnico

O cliente RustDesk conversa com **dois servidores independentes**:

| Camada | Componente | Origem | Custo |
|---|---|---|---|
| Protocolo remoto (P2P, relay, cripto, hole punching) | `hbbs` + `hbbr` | **RustDesk oficial, AGPL-3.0** | Grátis |
| Plano de controle (console, lista, address book) | **API Server** (HTTP) | Pro (fechado) **ou terceiro OSS** | Grátis com terceiro |

O cliente aponta para um `api-server` **configurável** e o RustDesk não valida quem responde.
É essa separação que permite substituir apenas o plano de controle.

### 2.2 Família A vs Família B (decisão tomada)

| | **A — Só o console é de terceiros** | **B — Substituto completo do servidor** |
|---|---|---|
| `hbbs`/`hbbr` | Oficiais RustDesk | Reimplementados pelo terceiro |
| Modo de falha do console | **Conexões continuam funcionando** — técnico perde a lista, conecta digitando o ID | Perde o acesso remoto inteiro |
| Risco de quebra de protocolo | Baixo (só o console) | Alto (todo o stack) |

**DECISÃO: Família A.** O tráfego de acesso remoto roda código oficial RustDesk. O componente
de terceiros é aquele cuja falha é **degradação graciosa**, não indisponibilidade.

### 2.3 Topologia

```
Técnico (cliente RustDesk logado)
   │
   ├── HTTP(S) ──► [Nginx :443] ──► API Server :21114  (console + address book)   ← terceiro, AGPL
   │                                      ▲
   │                                      │ heartbeat + sysinfo  →  AUTO-REGISTRO
   │                                      │
   └── TCP 21115/21116/21117 + UDP 21116 ──► hbbs + hbbr ──► Dispositivo do cliente
                                                              ← RustDesk oficial
```

### 2.4 Mecanismo de auto-registro (o requisito central)

Quando o cliente RustDesk tem um `api-server` configurado, ele passa a enviar **heartbeat** e
**sysinfo** por HTTP para esse endereço. **No primeiro heartbeat, o servidor cria o registro do
dispositivo.** Não é preciso agente próprio, AD ou login prévio.

Confirmado em implementações independentes: o `rustdesk-api-server-pro` cria o registro no primeiro
heartbeat e marca o dispositivo como offline após 30 s sem heartbeat (`jobsConfig.deviceCheckJob.duration: 30`);
o `rustdesk-minimal-api` popula `/api/users`, `/api/peers` e `/api/device-group/accessible` a partir de
heartbeat e sysinfo.

---

## 3. Componentes escolhidos

| Componente | Imagem / origem | Licença | Papel |
|---|---|---|---|
| `hbbs` | `rustdesk/rustdesk-server:latest` | AGPL-3.0 | ID Server / Rendezvous / signaling |
| `hbbr` | `rustdesk/rustdesk-server:latest` | AGPL-3.0 | Relay (fallback quando P2P falha) |
| Console / API | `ghcr.io/lantongxue/rustdesk-api-server-pro:latest` | AGPL-3.0 | Console web, dispositivos, grupos, address book |
| Reverse proxy | `nginx` + Certbot | — | HTTPS do console (etapa pós-PoC) |

### 3.1 Candidatos avaliados (dados de 2026-08-10)

| Projeto | Licença | ★ | Último commit | Família | Avaliação |
|---|---|---|---|---|---|
| [lantongxue/rustdesk-api-server-pro](https://github.com/lantongxue/rustdesk-api-server-pro) | AGPL-3.0 | 334 | 2026-04-20 | **A** | **ESCOLHIDO** para o PoC. Go + SQLite, API server puro sobre hbbs/hbbr oficiais |
| [UNITRONIX/BetterDesk](https://github.com/UNITRONIX/BetterDesk) | AGPL-3.0 | 334 | 2026-08-09 | B | **Plano B.** Mais completo e mais ativo, mas substitui hbbs+hbbr. Auto-registro com modos Open/Managed/Locked, RBAC, grupos, WoL. Windows marcado "Tier 3: Experimental" |
| [marcpope/cortendesk](https://github.com/marcpope/cortendesk) | AGPL-3.0 | 75 | 2026-08-10 | A ou B | Laravel/PHP. Suporta hbbs/hbbr existentes (`CORTENDESK_EMBEDDED_SERVER=false`). **Criado em 2026-07-23 — imaturo demais para produção agora**, reavaliar em 6 meses |
| [lejianwen/rustdesk-api](https://github.com/lejianwen/rustdesk-api) | MIT | 3.062 | 2025-09-28 | A | O mais popular, mas **~10 meses sem commit e 110 issues abertas**. Descartado por vitalidade |
| [kingmo888/rustdesk-api-server](https://github.com/kingmo888/rustdesk-api-server) | — | 1.565 | 2024-09-25 | A | Django. ~23 meses parado — considerar morto |

---

## 4. Portas (escopo enxuto)

| Porta | Protocolo | Serviço | Finalidade | Exposição |
|---|---|---|---|---|
| 21115 | TCP | hbbs | Teste de tipo de NAT | Pública |
| 21116 | TCP | hbbs | TCP hole punching + conexão | Pública |
| 21116 | **UDP** | hbbs | Registro de ID + heartbeat | Pública (**obrigatória**) |
| 21117 | TCP | hbbr | Relay | Pública |
| 21114 | TCP | API Server | Console + API (auto-registro) | **Interna** — publicar via 443 |
| 443 | TCP | Nginx | HTTPS do console | Pública (pós-PoC) |
| 80 | TCP | Nginx | ACME + redirect HTTPS | Pública (pós-PoC) |
| ~~21118~~ | ~~TCP~~ | ~~hbbs ws~~ | Web client — **não usado** | **FECHADA** |
| ~~21119~~ | ~~TCP~~ | ~~hbbr ws~~ | Web client — **não usado** | **FECHADA** |

> 🔴 Manter 21118/21119 fechadas é decisão de segurança, não só simplificação. Com WebSocket
> habilitado, `hbbs`/`hbbr` **confiam sem validar** nos headers `X-Real-IP` / `X-Forwarded-For`:
> quem alcança essas portas diretamente forja IP, burla rate limiting e falsifica os IPs dos logs.
> Como não usamos web client, ficam fechadas.

**Nota:** a porta 21114 é livre no OSS (é exclusiva do Pro), então usá-la para o API server de
terceiros mantém a convenção do RustDesk e simplifica o proxy 443 → 21114.

Firewall:
```bash
ufw allow 21115:21117/tcp
ufw allow 21116/udp
ufw allow 80,443/tcp
sudo ufw enable
```
Em nuvem, liberar também no security group do provedor.

---

## 5. Configuração do cliente

### 5.1 Valores necessários

| Valor | Origem |
|---|---|
| `ID Server` | host/IP do `hbbs` |
| `Key` | conteúdo de `data/id_ed25519.pub`, gerado pelo `hbbs` no primeiro boot |
| `API Server` | `http(s)://<host>:21114` (ou `https://<dominio>` atrás do Nginx) |
| `Relay Server` | opcional — o RustDesk deduz sozinho |

> O `Key` é a **chave pública de criptografia** — não confundir com licença.

### 5.2 Como obter a config string sem console Pro

Caminho oficial documentado (Client Configuration §3), sem depender de recurso Pro:

1. Configurar **uma** máquina manualmente: cliente → menu `⋮` → Network → destravar → preencher ID Server, Key e API Server.
2. Clicar em **Export Server Config** → gera a config string.
3. Usar essa string na variável `$rustdesk_cfg` do script de deploy.

### 5.3 CLI do cliente (oficial)

| Comando | Função |
|---|---|
| `rustdesk.exe --silent-install` | Instalação silenciosa |
| `rustdesk.exe --install-service` | Instala o serviço |
| `rustdesk.exe --get-id` | Retorna o ID |
| `rustdesk.exe --config <string>` | Aplica configuração de servidor |
| `rustdesk.exe --password <pw>` | Define senha permanente |

No Windows não há saída por padrão: usar `| more` ou `| Out-String`.

---

### 5.4 Contrato de API que o cliente exige (levantado do código-fonte)

Superfície completa extraída de `rustdesk/rustdesk@master` (varredura de 279 arquivos `.rs`/`.dart`)
e do fluxo detalhado em `src/hbbs_http/sync.rs`. **Base para avaliar um console próprio.**

**Núcleo mínimo — 10 endpoints** para atender o escopo §1.1:

| Endpoint | Papel |
|---|---|
| `POST /api/sysinfo` | **Auto-registro.** Cria/atualiza o dispositivo |
| `POST /api/heartbeat` | Presença + canal de push do servidor para o cliente |
| `GET /api/login-options` | Consultado antes do login |
| `POST /api/login` · `POST /api/logout` | Sessão do técnico |
| `GET /api/currentUser` | Identidade da sessão |
| `GET /api/peers` | Lista de dispositivos |
| `GET /api/users` | Usuários |
| `GET /api/device-group/accessible` | Grupos visíveis ao usuário |
| `GET /api/ab/*` | Address book (o *book*) — 13 rotas para o conjunto completo |

**Opcionais:** `/api/audit`, `/api/audit/{}`, `/api/record`, `/api/switch-grant`,
`/api/devices/cli`, `/api/devices/deploy`, `/api/oidc/auth`, `/api/oidc/auth-query`, `/api/plugin-sign`.

#### Fluxo exato do auto-registro (`sync.rs`)

```
loop a cada 3s (TIME_CONN):
  url = {api-server}/api/heartbeat        # vazio se api-server ausente OU servidor público
  se sysinfo ainda não enviado:
      POST {api}/api/sysinfo  { id, uuid(base64), version, hostname, username, ...presets }
        resposta "SYSINFO_UPDATED" -> registrado; cliente marca servidor como Pro
        resposta "ID_NOT_FOUND"    -> reenvia no próximo ciclo
        outra resposta             -> aguarda 120s (UPLOAD_SYSINFO_TIMEOUT)
  POST {api}/api/heartbeat  { id, uuid, ver, conns?, modified_at }
        resposta pode conter: sysinfo (força reenvio), disconnect[], modified_at, strategy{}
```

Heartbeat a cada **15 s** (`TIME_HEARTBEAT`) quando não há conexões ativas.

#### Três descobertas que mudam avaliações anteriores

1. **Não há validação de licença no cliente.** O flag interno `PRO` é ligado simplesmente quando o
   servidor responde `SYSINFO_UPDATED`. Qualquer servidor que fale o protocolo é tratado como Pro.
2. **Strategy é implementável em console próprio.** O push de políticas chega como o campo `strategy`
   na *resposta* do heartbeat e é aplicado por `handle_config_options()`. Corrige a avaliação anterior
   de que Strategy seria inalcançável fora do Pro — é um campo JSON, não um subsistema.
3. **Presets viajam no sysinfo.** `preset-address-book-name`, `preset-address-book-tag`,
   `preset-address-book-alias`, `preset-device-group-name`, `preset-strategy-name`, `preset-username`,
   `preset-device-name`, `preset-note` — permitem que o **cliente já chegue classificado** no grupo/book
   correto, sem passo manual no console. Diretamente útil para o requisito de hierarquia (§1.1.3).

#### Viabilidade de console próprio

| A favor | Contra |
|---|---|
| Superfície pequena e enumerada (10 obrigatórios) | Contrato **não documentado oficialmente** — derivado de engenharia reversa |
| Contrato derivável do código AGPL público | Strings mágicas (`SYSINFO_UPDATED`, `ID_NOT_FOUND`) e semântica só se descobrem lendo o código |
| Existe prova de conceito de terceiro feita em ~1 dia (`mrexodia/rustdesk-minimal-api`) | Cada upgrade do cliente vira risco de regressão **nosso** |
| **Integração com a base de clientes da Afiminas** — a hierarquia desejada provavelmente já existe no ERP | Address book completo = 13 rotas com semântica de perfis/tags |
| Sem dependência de projeto que pode ser abandonado | Auth, UI, persistência e backup já resolvidos pelos projetos existentes |

**Caminho recomendado (3 estágios):**
1. PoC com console de terceiros — valida o conceito e permite **capturar o tráfego real**, documentando
   o contrato por evidência em vez de leitura de código.
2. Decidir com dados: se a hierarquia do terceiro atender, fica. Se a necessidade for amarrar dispositivo
   ao cadastro de clientes da Afiminas, console próprio se justifica.
3. Se construir: **fork do `lantongxue/rustdesk-api-server-pro`** (Go + SQLite, AGPL) em vez de greenfield —
   herda a compatibilidade de protocolo e mantém o controle do roadmap.

---

## 6. Achados da leitura do código (`rustdesk-api-server-pro`)

Derivados de `Dockerfile`, `docker/start.sh`, `backend/config/config.go` e `backend/server.yaml`.
**Ainda não confirmados em execução** — são o primeiro item de validação do PoC.

| # | Achado | Impacto | Mitigação aplicada |
|---|---|---|---|
| 1 | `start.sh` faz `cd /app/data`, e `config.go` lê a config de `path.Join(wd, "server.yaml")` = **`/app/data/server.yaml`** — mas o `docker-compose.yaml` do projeto monta em `/app/server.yaml` | A config montada seria **ignorada**; o app cai nos defaults do Go | Montar em **ambos** os caminhos no nosso compose |
| 2 | Defaults do Go têm `StaticDir: "dist"` (relativo). Com wd `/app/data`, resolve para `/app/data/dist`, que não existe (o Dockerfile põe em `/app/dist`) | UI web quebrada (404 nos assets) | Fixar `staticdir: "/app/dist"` (absoluto) na nossa config |
| 3 | O compose do projeto **não monta `/app/data`** | SQLite (`server.db`) e `.init.lock` vivem só dentro do container → **perda de dados ao recriar** | Montar `./data-console:/app/data` |
| 4 | `signKey` default é `"sercrethatmaycontainch@r$32chars"` no `server.yaml` versionado | Chave de assinatura de token pública e conhecida | **Gerar valor aleatório** e tratar como secret |
| 5 | `ADMIN_USER`/`ADMIN_PASS` só criam o admin no primeiro boot (guardado por `.init.lock`) | Trocar as env vars depois não tem efeito | Documentado no README do PoC |
| 6 | Porta default do Go é `:8080`; do `server.yaml` versionado é `:12345` | Divergência conforme qual config é lida | Fixar `:21114` explicitamente |
| 7 | `timeZone` default `Asia/Shanghai` | Timestamps errados nos registros | Fixar `America/Sao_Paulo` |
| 8 | Repositório **sem releases tagueadas**; só imagem `:latest` | Sem previsibilidade de versão | Registrar o digest da imagem em uso (§9) |

---

## 7. Segurança (escopo enxuto)

- Console **nunca** exposto direto na internet sem TLS — publicar via Nginx 443.
- `signKey` aleatório, fora do Git.
- Senha do admin do console forte, definida no `.env` (nunca `admin/test1234` nem defaults do projeto).
- `id_ed25519` (chave privada) é o ativo mais crítico: **se for perdida, todos os clientes precisam ser reconfigurados**.
- 21118/21119 fechadas (ver §4).
- Secrets fora do Git — ver `.gitignore` do PoC.
- Senha de acesso não supervisionado: **aleatória por dispositivo**, gerada no script de deploy, nunca fixa em script.

---

## 8. Backup (simplificado)

| Item | Caminho |
|---|---|
| Chave privada do servidor | `data-rustdesk/id_ed25519` |
| Chave pública | `data-rustdesk/id_ed25519.pub` |
| Banco do console | `data-console/server.db` |
| Configuração | `config/server.yaml`, `compose.yml`, `.env` |
| Certificados TLS | `/etc/letsencrypt/` (pós-PoC) |

Ciclo obrigatório: **backup → restore → validação**. "Backup criado" não é suficiente.

---

## 9. Versões

Verificadas em **2026-08-10**:

| Componente | Versão | Adotada no projeto |
|---|---|---|
| RustDesk Client | 1.4.9 (2026-07-06) | ⬜ a fixar |
| rustdesk-server (OSS) | 1.1.16 (2026-07-20) | ⬜ a fixar |
| `rustdesk-api-server-pro` | sem release tagueada — só `:latest` | ⬜ registrar digest |
| Docker / Compose | — | ⬜ |
| SO do servidor | — | ⬜ |

**Regra:** evitar `latest` em produção. Fixar tags/digests no `.env` após o PoC validar.

---

## 10. Riscos

| Risco | Impacto | Mitigação |
|---|---|---|
| Console de terceiros quebra em upgrade do cliente | Perda da lista/auto-registro | Família A: conexões continuam. Fixar versão do cliente e testar upgrade antes |
| Projeto de terceiros abandonado | Sem correções | 3 alternativas mapeadas (§3.1); migração só troca o console, não o servidor |
| Perda de `id_ed25519` | Reconfigurar **todos** os clientes | Backup + teste de restore |
| Sem suporte comercial | Incidente sem SLA | Aceito conscientemente com o escopo gratuito |
| Imagem só em `:latest` | Upgrade não previsível | Registrar digest e fixar |

---

## 11. Pendências

1. **Hospedagem:** cloud (qual provedor/região) ou VM on-premise? — *não respondido*
2. Domínio corporativo para o console e quem administra o DNS.
3. Quantidade estimada de dispositivos/clientes.
4. Hierarquia de grupos desejada (por cliente? por região? por tipo?).
5. Destino do backup externo.
6. Branding "AzureDesk" — confirmar se entra e quando.

---

## 12. Referências

**Documentação oficial RustDesk**
- Self-host / portas — https://rustdesk.com/docs/en/self-host/
- Server OSS / instalação / Docker — https://rustdesk.com/docs/en/self-host/rustdesk-server-oss/
- Client Configuration — https://rustdesk.com/docs/en/self-host/client-configuration/
- Client Deployment — https://rustdesk.com/docs/en/self-host/client-deployment/
- NAT Loopback — https://rustdesk.com/docs/en/self-host/nat-loopback-issues/

**Componentes de terceiros**
- https://github.com/lantongxue/rustdesk-api-server-pro
- https://github.com/UNITRONIX/BetterDesk
- https://github.com/marcpope/cortendesk

---

## 13. Histórico

| Data | Alteração |
|---|---|
| 2026-08-10 | Criação. PDF (39 seções) + documentação oficial RustDesk. Conclusão inicial: **Pro obrigatório**. |
| 2026-08-10 | Levantado o **contrato de API do cliente** direto do código-fonte (§5.4): 10 endpoints obrigatórios, fluxo exato do auto-registro, e 3 descobertas — sem validação de licença no cliente, Strategy implementável via resposta do heartbeat, e presets de grupo/book viajando no sysinfo. Console próprio avaliado como **viável**; recomendado fork em vez de greenfield. |
| 2026-08-10 | **Reescrita por mudança de escopo.** Escopo reduzido a auto-registro + console + grupos, sem AD. Pro deixa de ser necessário → stack **100% gratuita**. Arquitetura Família A definida (hbbs/hbbr oficiais + console OSS de terceiros). Console escolhido: `lantongxue/rustdesk-api-server-pro`. 8 achados de código documentados (§6). |
