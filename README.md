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
├── backup.sh                       # Backup (script auxiliar)
├── restore.sh                      # Restauracao (script auxiliar)
├── status.sh                       # Status dos servicos (auxiliar)
├── diagnose-nextcloud.sh           # Diagnostico (auxiliar)
└── README.md
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
