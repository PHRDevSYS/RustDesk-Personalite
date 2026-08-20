# RustDesk-Personalite — AzureControlDesk

Plataforma de **acesso remoto corporativo** construída sobre o
[RustDesk](https://github.com/rustdesk/rustdesk) OSS, com console próprio de
gerenciamento (auto-registro de dispositivos, lista de clientes e grupos) e
atualização automática de servidores e endpoints.

> **Status:** Fase 1 — PoC em montagem.
> **Licença dos componentes:** AGPL-3.0 (stack 100% gratuita, sem Server Pro).

---

## O que o sistema faz

1. O agente é instalado no dispositivo do cliente e ele **aparece sozinho no console** (auto-registro).
2. O dispositivo fica registrado e disponível para receber conexão remota.
3. Os dispositivos são organizados por **hierarquia de grupos** — um *book* de clientes.
4. O técnico abre o cliente RustDesk, vê a lista e conecta.
5. Quando uma nova versão é publicada em produção, **servidores e endpoints se
   atualizam sozinhos** no próximo boot ou ciclo.

Sem Active Directory. Autenticação local no console.

## Arquitetura

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
| Reverse proxy HTTPS | Nginx + Certbot | — |

## Ambientes

| Branch | Ambiente | Recebe |
|---|---|---|
| `main` | — | onde se commita |
| `homologacao` | teste | tudo que entra em `main` |
| `producao` | real | só o que foi validado em homologação |

Promoção é sempre fast-forward, o que torna estruturalmente impossível pular a
homologação. Fluxo completo, manifesto de release e mecânica do auto-update:
**[`VERSIONAMENTO.md`](VERSIONAMENTO.md)**.

```powershell
.\scripts\promover.ps1 -Versao 1.0.0 -VersaoAgente 1.4.9   # prepara em main
.\scripts\promover.ps1 -Para homologacao                   # publica para teste
.\scripts\promover.ps1 -Para producao                      # após validar; cria a tag
```

## Estrutura do repositório

```
├── VERSIONAMENTO.md          # branches, promoção, manifesto, auto-update
├── release/manifest.json     # contrato do auto-update: versões e SHA256
├── scripts/promover.ps1      # promoção entre branches de ambiente
│
├── ambientes/                # o que muda de um ambiente para o outro
│   ├── homologacao/{.env.example, config/server.yaml.example}
│   └── producao/{.env.example, config/server.yaml.example}
│
├── servidor/                 # stack Linux
│   ├── compose.yml           # hbbs + hbbr + console (único p/ todos os ambientes)
│   ├── scripts/{comum.sh, healthcheck.sh, autoupdate-servidor.sh}
│   └── systemd/azuredesk-autoupdate.{service,timer}
│
├── agente/windows/           # endpoint
│   ├── install-agent.ps1     # deploy idempotente + registro do auto-update
│   └── autoupdate-agent.ps1  # Tarefa Agendada: boot + a cada 6h
│
└── Afiminas/                 # o cliente
    ├── memoria.md            # documento vivo: escopo, decisões, riscos
    └── roteiro-poc.md        # os 9 testes que validam a stack
```

## Começando

Requer **host Linux** com Docker (`network_mode: host` não funciona em Docker
Desktop Windows/macOS).

```bash
git clone https://github.com/PHRDevSYS/RustDesk-Personalite.git /opt/azuredesk
cd /opt/azuredesk && git checkout homologacao

cp ambientes/homologacao/.env.example               ambientes/homologacao/.env
cp ambientes/homologacao/config/server.yaml.example ambientes/homologacao/config/server.yaml
# preencher os dois; gerar o signKey com: openssl rand -base64 32

export AMBIENTE=homologacao
docker compose --project-directory ambientes/$AMBIENTE \
               --env-file ambientes/$AMBIENTE/.env \
               -f servidor/compose.yml up -d

./servidor/scripts/healthcheck.sh -v
```

O `-v` imprime a **Key** pública, necessária para configurar o cliente.
Roteiro completo de validação: [`Afiminas/roteiro-poc.md`](Afiminas/roteiro-poc.md).
Instalar o auto-update como serviço: [`VERSIONAMENTO.md` §4](VERSIONAMENTO.md).

Endpoint Windows, como Administrador:

```powershell
.\agente\windows\install-agent.ps1 -ConfigString "COLE_A_STRING" -Ambiente homologacao
```

## Segurança

- Nenhum secret vai para o Git — `.env`, `server.yaml`, chaves e certificados são ignorados.
- `signKey` do console **deve** ser gerado (o valor do projeto upstream é público)
  e **diferente entre homologação e produção**: iguais, um token de HML vale em PRD.
- Nunca usar `admin/test1234` nem qualquer credencial default.
- Portas `21118`/`21119` (WebSocket) ficam **fechadas** — ver `Afiminas/memoria.md` §4.
- `data-rustdesk/id_ed25519` é o ativo mais crítico: se perdida, **todos** os
  clientes precisam ser reconfigurados. Faça backup e teste o restore.
- A senha de acesso não supervisionado é **aleatória por dispositivo**, gerada no
  script de deploy — nunca compartilhada entre máquinas.
- O instalador baixado pelo auto-update tem o **SHA256 verificado** contra o
  manifesto; sem hash, a atualização é recusada.
- **Push na branch `producao` equivale a executar código como SYSTEM em toda a
  frota.** Ver [`VERSIONAMENTO.md` §6](VERSIONAMENTO.md).
