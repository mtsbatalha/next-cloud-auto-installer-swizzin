# Nextcloud para Swizzin

Pacote Nextcloud avancado para [swizzin](https://github.com/swizzin/swizzin) com Redis, OPcache, APCu, Fail2ban, PHP-FPM otimizado e suite Office opcional.

Substitui o pacote nextcloud basico do swizzin com uma instalacao completa e otimizada.

## Funcionalidades

- Nextcloud com download verificado (SHA256)
- MariaDB otimizado (InnoDB tuning, UTF8MB4)
- Redis via Unix socket para cache distribuido e file locking
- OPcache (256MB) + APCu (128MB) para cache local
- PHP-FPM pool dedicado com auto-sizing baseado em RAM
- Fail2ban para protecao contra brute force
- Hardening PHP (funcoes perigosas desabilitadas, session security)
- Nginx com config oficial Nextcloud (50GB uploads, HTTP/2)
- Apps pre-instalados: Calendar, Contacts, Tasks, Notes, Deck, Photos
- Suite Office separada: Collabora Online ou OnlyOffice (Docker)

## Requisitos

- Swizzin instalado no servidor
- Nginx instalado via swizzin (`box install nginx`)
- Ubuntu 22.04+ ou Debian 11+
- Minimo 2GB RAM (4GB+ recomendado)
- Minimo 20GB disco livre
- Dominio configurado apontando para o servidor

## Instalacao

### 1. Copiar scripts para o swizzin

```bash
# Clone o repositorio
git clone https://github.com/seu-usuario/next-cloud-swizzin.git
cd next-cloud-swizzin

# Copiar para o swizzin
sudo cp scripts/install/nextcloud.sh /etc/swizzin/scripts/install/
sudo cp scripts/install/nextcloudoffice.sh /etc/swizzin/scripts/install/
sudo cp scripts/remove/nextcloud.sh /etc/swizzin/scripts/remove/
sudo cp scripts/remove/nextcloudoffice.sh /etc/swizzin/scripts/remove/
sudo cp scripts/update/nextcloud.sh /etc/swizzin/scripts/update/
sudo cp sources/functions/nextcloud /etc/swizzin/sources/functions/
```

### 2. Instalar Nextcloud

```bash
sudo box install nextcloud
```

O instalador ira solicitar:
- Dominio do Nextcloud (ex: cloud.exemplo.com)
- Usuario e senha do administrador (min 10 caracteres)
- Email do administrador

### 3. Instalar Office (opcional)

```bash
sudo box install nextcloudoffice
```

O instalador ira solicitar:
- Escolha da suite (Collabora Online ou OnlyOffice)
- Subdominio para o Office (ex: office.cloud.exemplo.com)

### 4. Configurar SSL (recomendado)

```bash
sudo box install letsencrypt
```

## Instalacao Unattended

Para instalacao automatizada, exporte as variaveis antes de instalar:

```bash
export NEXTCLOUD_DOMAIN="cloud.exemplo.com"
export NEXTCLOUD_ADMIN_USER="admin"
export NEXTCLOUD_ADMIN_PASS="senhasegura123"
export NEXTCLOUD_ADMIN_EMAIL="admin@exemplo.com"

sudo box install nextcloud

# Para Office:
export NEXTCLOUD_OFFICE="onlyoffice"
export NEXTCLOUD_OFFICE_DOMAIN="office.cloud.exemplo.com"

sudo box install nextcloudoffice
```

## Gerenciamento

### Comandos box

```bash
# Instalar
sudo box install nextcloud
sudo box install nextcloudoffice

# Remover
sudo box remove nextcloudoffice    # remover Office primeiro
sudo box remove nextcloud

# Atualizar (roda automaticamente com box update)
sudo box update
```

### OCC (Nextcloud CLI)

```bash
sudo -u www-data php /srv/nextcloud/occ status
sudo -u www-data php /srv/nextcloud/occ app:list
sudo -u www-data php /srv/nextcloud/occ files:scan --all
sudo -u www-data php /srv/nextcloud/occ maintenance:mode --on
sudo -u www-data php /srv/nextcloud/occ maintenance:mode --off
```

### Servicos

```bash
# PHP-FPM (pool nextcloud)
sudo systemctl restart php*-fpm

# Redis
sudo systemctl restart redis-server

# Nginx
sudo systemctl reload nginx

# Fail2ban
sudo systemctl restart fail2ban
```

## Paths Importantes

| Descricao | Caminho |
|-----------|---------|
| Nextcloud | `/srv/nextcloud` |
| Dados | `/srv/nextcloud-data` |
| Configuracao | `/srv/nextcloud/config/config.php` |
| Backups | `/var/backups/nextcloud` |
| Logs | `/srv/nextcloud-data/nextcloud.log` |
| Nginx config | `/etc/nginx/conf.d/nextcloud.conf` |
| Nginx Office | `/etc/nginx/conf.d/nextcloud-office.conf` |
| PHP-FPM pool | `/etc/php/*/fpm/pool.d/nextcloud.conf` |
| MariaDB tuning | `/etc/mysql/mariadb.conf.d/99-nextcloud.cnf` |
| Fail2ban | `/etc/fail2ban/jail.d/nextcloud.conf` |
| Cron | `/etc/cron.d/nextcloud` |
| Lock file | `/install/.nextcloud.lock` |
| Config DB | `/var/lib/swizzin/db/nextcloud/` |

## Estrutura do Projeto

```
next-cloud-swizzin/
├── scripts/
│   ├── install/
│   │   ├── nextcloud.sh            # Instalacao principal
│   │   └── nextcloudoffice.sh      # Suite Office (Collabora/OnlyOffice)
│   ├── remove/
│   │   ├── nextcloud.sh            # Remocao completa
│   │   └── nextcloudoffice.sh      # Remocao Office
│   └── update/
│       └── nextcloud.sh            # Atualizacao
├── sources/
│   └── functions/
│       └── nextcloud               # Funcoes helper compartilhadas
├── extras/
│   ├── install-talk.sh             # Instalacao do Nextcloud Talk
│   └── install-pagespeed.sh        # Modulo PageSpeed para Nginx
├── backup.sh                       # Backup interativo (NC + apps)
├── restore.sh                      # Restauracao interativa (NC + apps)
├── update.sh                       # Atualizacao com opcao de backup
├── manage.sh                       # Gerenciamento de servicos
├── status.sh                       # Status dos servicos
├── diagnose-nextcloud.sh           # Diagnostico e reparacao
├── optimize-uploads.sh             # Otimizacao de uploads grandes + Office
├── clean-install.sh                # Reset completo da instalacao
├── fix-database.sh                 # Correcao de problemas no banco
├── fix-nginx.sh                    # Correcao de problemas no Nginx
├── fix-office-ssl.sh               # Correcao de SSL para Office
├── fix-proxy.sh                    # Correcao de problemas de proxy
└── README.md
```

## Atualizacao

O script `update.sh` verifica e instala atualizacoes do Nextcloud com opcao de backup antes da atualizacao.

### Uso interativo

```bash
# Verificar e atualizar (modo interativo)
sudo ./update.sh
```

No modo interativo, apos confirmar a atualizacao, o script oferece opcoes de backup:

```
Deseja fazer backup antes da atualizacao?

  1) Sim - backup rapido (banco + config, sem dados)  (Recomendado)
  2) Sim - backup completo (banco + config + dados)
  3) Sim - usando o script de backup interativo
  4) Nao - pular backup (nao recomendado)
```

- **Opcao 1**: Backup rapido do banco de dados e configuracao (mais rapido, recomendado)
- **Opcao 2**: Backup completo incluindo diretorio de dados (pode demorar para instalacoes grandes)
- **Opcao 3**: Abre o menu interativo do `backup.sh` para escolher exatamente o que incluir
- **Opcao 4**: Pula o backup (nao recomendado, mas util se ja fez backup manualmente)

### Uso automatizado

```bash
# Somente verificar se ha atualizacao disponivel
sudo ./update.sh --check

# Atualizar automaticamente com backup (ideal para cron)
sudo ./update.sh --auto

# Atualizar sem backup (nao recomendado)
sudo ./update.sh --skip-backup

# Somente criar backup, sem atualizar
sudo ./update.sh --backup-only
```

**Opcoes do update.sh:**

| Flag | Descricao |
|------|-----------|
| `--check` | Apenas verificar se ha atualizacao (nao instala) |
| `--auto` | Instalar automaticamente com backup (sem confirmacao) |
| `--skip-backup` | Pular backup antes da atualizacao |
| `--backup-only` | Somente criar backup, sem atualizar |

### Atualizacao automatica via cron

```bash
# Verificar e atualizar automaticamente toda segunda as 3h da manha
echo "0 3 * * 1 root /caminho/update.sh --auto >> /var/log/nextcloud-update.log 2>&1" | sudo tee /etc/cron.d/nextcloud-update
```

Se a atualizacao falhar, o script informa o caminho do backup para restauracao:

```bash
sudo ./restore.sh /var/backups/nextcloud/backup-XXXXXXXX_XXXXXX.tar.gz
```

## Backup e Restauracao

Scripts completos de backup e restauracao com menu interativo e suporte a multiplos servicos.

### Servicos suportados

| Servico | O que e salvo |
|---------|---------------|
| **Nextcloud** | Banco de dados, config, dados, apps, temas, configs do sistema (PHP-FPM, Nginx, MariaDB) |
| **ruTorrent/rTorrent** | `.rtorrent.rc`, session files (resume), config do web UI, settings do usuario |
| **qBittorrent** | `qBittorrent.conf`, `BT_backup/` (resume data / .torrent files) |
| **Deluge** | Diretorio completo `.config/deluge/` (core.conf, web.conf, auth, state) |
| **Plex** | `Preferences.xml`, databases, plugin preferences (metadata opcional) |

### Backup

```bash
# Menu interativo (detecta servicos instalados e exibe tamanhos estimados)
sudo ./backup.sh

# Backup completo (Nextcloud + todas as apps)
sudo ./backup.sh --full

# Somente banco de dados Nextcloud
sudo ./backup.sh --db-only

# Nextcloud sem dados (rapido) + ruTorrent
sudo ./backup.sh --nc-no-data --rutorrent

# Somente aplicacoes (sem Nextcloud)
sudo ./backup.sh --apps-only

# Plex com metadata (posters, art, etc.)
sudo ./backup.sh --plex-full

# Diretorio personalizado + upload remoto (rclone)
sudo ./backup.sh --full --output /mnt/backup --remote
```

**Opcoes de backup Nextcloud:**

| Flag | Descricao |
|------|-----------|
| `--full` | Tudo (Nextcloud + todas as apps detectadas) |
| `--nc-full` | Nextcloud completo (banco + config + dados) |
| `--nc-no-data` | Nextcloud sem diretorio de dados |
| `--db-only` | Somente banco de dados |
| `--data-only` | Somente diretorio de dados |
| `--config-only` | Somente configuracao |

**Opcoes de backup aplicacoes (combinaveis):**

| Flag | Descricao |
|------|-----------|
| `--rutorrent` | Incluir ruTorrent/rTorrent |
| `--qbittorrent` | Incluir qBittorrent |
| `--deluge` | Incluir Deluge |
| `--plex` | Incluir Plex (essencial) |
| `--plex-full` | Incluir Plex com metadata |
| `--all-apps` | Todas as apps detectadas |
| `--apps-only` | Somente apps (sem Nextcloud) |

**Opcoes gerais:**

| Flag | Descricao |
|------|-----------|
| `--output DIR` | Diretorio de saida personalizado |
| `--remote` | Upload para storage remoto via rclone |
| `--retention DIAS` | Dias de retencao dos backups (padrao: 7) |

### Restauracao

```bash
# Menu interativo (lista backups disponiveis)
sudo ./restore.sh

# Restaurar arquivo especifico (restaura tudo que estiver no backup)
sudo ./restore.sh /var/backups/nextcloud/backup-20260304_020000.tar.gz

# Restaurar somente banco de dados
sudo ./restore.sh backup.tar.gz --db-only

# Restaurar somente aplicacoes
sudo ./restore.sh backup.tar.gz --apps-only

# Migracao para novo dominio
sudo ./restore.sh backup.tar.gz --new-domain novo.exemplo.com

# Pular componentes especificos
sudo ./restore.sh backup.tar.gz --no-data --no-plex
```

**Opcoes de restauracao:**

| Flag | Descricao |
|------|-----------|
| `--target DIR` | Caminho customizado do Nextcloud |
| `--data-dir DIR` | Caminho customizado do diretorio de dados |
| `--new-domain NOME` | Atualizar dominio (migracao de servidor) |
| `--db-only` | Restaurar somente banco de dados |
| `--nc-only` | Restaurar somente Nextcloud |
| `--apps-only` | Restaurar somente aplicacoes |
| `--no-database` | Pular banco de dados |
| `--no-data` | Pular diretorio de dados |
| `--no-config` | Pular configuracao |
| `--no-rutorrent` | Pular ruTorrent |
| `--no-qbittorrent` | Pular qBittorrent |
| `--no-deluge` | Pular Deluge |
| `--no-plex` | Pular Plex |

### Backup automatico via cron

```bash
# Backup completo diario as 2h da manha
echo "0 2 * * * root /caminho/backup.sh --full >> /var/log/backup.log 2>&1" | sudo tee /etc/cron.d/backup-nextcloud

# Somente banco de dados a cada 6 horas
echo "0 */6 * * * root /caminho/backup.sh --db-only >> /var/log/backup.log 2>&1" | sudo tee /etc/cron.d/backup-nextcloud-db
```

### Estrutura do arquivo de backup

```
backup-20260304_020000.tar.gz
└── 20260304_020000/
    ├── manifest.json
    ├── nextcloud/
    │   ├── database/nextcloud.sql.gz
    │   ├── data/
    │   ├── config/
    │   ├── apps/
    │   └── themes/
    ├── rutorrent/
    │   ├── rtorrent.rc
    │   ├── sessions/
    │   ├── webui-conf/
    │   └── webui-user/
    ├── qbittorrent/
    │   ├── config/
    │   └── BT_backup/
    ├── deluge/
    │   ├── core.conf
    │   ├── web.conf
    │   ├── auth
    │   └── state/
    └── plex/
        ├── Preferences.xml
        ├── databases/
        ├── plugin-preferences/
        └── metadata/          (opcional, --plex-full)
```

## Gerenciamento de Servicos

O `manage.sh` permite iniciar, parar e reiniciar todos os servicos do Nextcloud de forma centralizada.

```bash
# Reiniciar todos os servicos (web, PHP-FPM, DB, Redis, Office)
sudo ./manage.sh restart

# Parar todos os servicos
sudo ./manage.sh stop

# Iniciar todos os servicos
sudo ./manage.sh start

# Ver status rapido de todos os servicos
sudo ./manage.sh status

# Reiniciar somente o web server
sudo ./manage.sh restart --web-only

# Reiniciar somente o banco de dados
sudo ./manage.sh restart --db-only

# Reiniciar somente cache (Redis)
sudo ./manage.sh restart --cache-only

# Reiniciar somente Office (Collabora/OnlyOffice)
sudo ./manage.sh restart --office-only

# Habilitar/desabilitar inicio automatico no boot
sudo ./manage.sh enable
sudo ./manage.sh disable

# Ver logs recentes
sudo ./manage.sh logs
```

## Status e Diagnostico

```bash
# Dashboard de status (servicos, portas, health checks)
sudo ./status.sh

# Diagnostico e reparacao automatica (permissoes, config, erros 403/500)
sudo ./diagnose-nextcloud.sh
```

## Scripts de Correcao

Scripts para resolver problemas especificos:

```bash
# Corrigir problemas no banco de dados
sudo ./fix-database.sh

# Corrigir configuracao do Nginx
sudo ./fix-nginx.sh

# Corrigir SSL para suite Office (Collabora/OnlyOffice)
sudo ./fix-office-ssl.sh

# Corrigir problemas de proxy reverso
sudo ./fix-proxy.sh

# Otimizar para uploads grandes (ate 50GB) e suite Office
sudo ./optimize-uploads.sh

# Reset completo da instalacao (CUIDADO: apaga tudo!)
sudo ./clean-install.sh
```

## Solucao de Problemas

### Verificar status

```bash
# Servicos
systemctl status nginx php*-fpm redis-server mariadb fail2ban

# Nextcloud
sudo -u www-data php /srv/nextcloud/occ status
sudo -u www-data php /srv/nextcloud/occ config:list system
```

### Testar Redis

```bash
redis-cli -s /var/run/redis/redis-server.sock ping
```

### Reparar instalacao

```bash
sudo -u www-data php /srv/nextcloud/occ maintenance:repair
sudo -u www-data php /srv/nextcloud/occ db:add-missing-indices
sudo -u www-data php /srv/nextcloud/occ db:convert-filecache-bigint --no-interaction
```

### Logs

```bash
# Nextcloud
tail -f /srv/nextcloud-data/nextcloud.log

# Nginx
tail -f /var/log/nginx/error.log

# PHP-FPM
tail -f /var/log/php*-fpm-nextcloud.log

# Fail2ban
sudo fail2ban-client status nextcloud
```

## Seguranca

O pacote configura automaticamente:

- **Fail2ban** - Protecao contra brute force (5 tentativas, ban 1 hora)
- **PHP Hardening** - Funcoes perigosas desabilitadas, sessoes seguras
- **Security Headers** - HSTS, X-Content-Type-Options, X-Frame-Options, etc.
- **Permissoes** - 0640 arquivos, 0750 diretorios, 0600 config.php
- **Redis** - Socket Unix com senha, sem exposicao de porta

SSL e gerenciado pelo swizzin via `box install letsencrypt`.

## Performance

- **OPcache** - Cache de bytecode PHP (256MB, 10000 arquivos)
- **APCu** - Cache local de memoria (128MB)
- **Redis** - Cache distribuido + file locking via Unix socket (256MB)
- **PHP-FPM** - Pool dedicado com processo dinamico (auto-sized pela RAM)
- **MariaDB** - InnoDB buffer pool = 25% da RAM, slow query log
- **Nginx** - 50GB upload, HTTP/2, gzip, cache de assets estaticos

## Licenca

GPL-3.0
