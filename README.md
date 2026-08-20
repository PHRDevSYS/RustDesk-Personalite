# RustDesk-Personalite — AzureControlDesk

Plataforma de **acesso remoto corporativo** construída sobre o
[RustDesk](https://github.com/rustdesk/rustdesk) OSS, com console próprio de
gerenciamento (auto-registro de dispositivos, lista de clientes e grupos).

> **Status:** Fase 1 — PoC em montagem.
> **Licença dos componentes:** AGPL-3.0 (stack 100% gratuita, sem Server Pro).

---

## O que o sistema faz

1. O agente é instalado no dispositivo do cliente e ele **aparece sozinho no console** (auto-registro).
2. O dispositivo fica registrado e disponível para receber conexão remota.
3. Os dispositivos são organizados por **hierarquia de grupos** — um *book* de clientes.
4. O técnico abre o cliente RustDesk, vê a lista e conecta.

Sem Active Directory. Autenticação local no console.

## Arquitetura (resumo)

Família **A**: o tráfego de acesso remoto roda **código oficial RustDesk**
(`hbbs` + `hbbr`); apenas o **plano de controle** (console/API) é um componente
OSS de terceiros. Se o console cair, as conexões continuam funcionando — o
técnico só perde a lista e conecta digitando o ID.

```
Técnico (cliente RustDesk)
   │
   ├── HTTP(S) ──► [Nginx :443] ──► API Server :21114   (console + address book)
   │                                     ▲
   │                                     │ heartbeat + sysinfo → AUTO-REGISTRO
   │                                     │
   └── TCP 21115/21116/21117 + UDP 21116 ──► hbbs + hbbr ──► Dispositivo do cliente
```

| Camada | Componente | Origem |
|---|---|---|
| Protocolo remoto (P2P, relay, cripto) | `hbbs` / `hbbr` | RustDesk oficial, AGPL-3.0 |
| Console / API (lista, grupos, address book) | `lantongxue/rustdesk-api-server-pro` | Terceiro, AGPL-3.0 |
| Reverse proxy HTTPS (pós-PoC) | Nginx + Certbot | — |

## Estrutura do repositório

```
Afiminas/
├── memoria.md              # documento vivo: escopo, arquitetura, decisões, riscos
└── poc/                    # prova de conceito executável
    ├── README.md           # roteiro dos 7 testes do PoC
    ├── compose.yml         # hbbs + hbbr + console
    ├── .env.example        # parametrização (copiar para .env)
    ├── config/
    │   └── server.yaml.example
    ├── deploy/windows/
    │   └── install-agent.ps1   # deploy idempotente do endpoint Windows
    └── scripts/
        └── healthcheck.sh      # validação da stack
```

## Começando

O PoC exige um **host Linux** com Docker (`network_mode: host` não funciona em
Docker Desktop Windows/macOS).

```bash
cd Afiminas/poc
cp .env.example .env
cp config/server.yaml.example config/server.yaml
# editar ambos: credenciais do admin, endereços e signKey (openssl rand -base64 32)
docker compose up -d
./scripts/healthcheck.sh -v
```

Roteiro completo de validação: [`Afiminas/poc/README.md`](Afiminas/poc/README.md).
Contexto, decisões e riscos: [`Afiminas/memoria.md`](Afiminas/memoria.md).

## Segurança

- Nenhum secret vai para o Git — `.env`, `server.yaml`, chaves e certificados são ignorados.
- `signKey` do console **deve** ser gerado (o valor do projeto upstream é público).
- Nunca usar `admin/test1234` nem qualquer credencial default.
- Portas `21118`/`21119` (WebSocket) ficam **fechadas** — ver `memoria.md` §4.
- `data-rustdesk/id_ed25519` é o ativo mais crítico: se perdida, **todos** os
  clientes precisam ser reconfigurados. Faça backup e teste o restore.
- A senha de acesso não supervisionado é **aleatória por dispositivo**, gerada no
  script de deploy — nunca compartilhada entre máquinas.
