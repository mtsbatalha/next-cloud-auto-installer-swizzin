# Nextcloud Auto-Installer

Instalador automático do Nextcloud para Linux (Ubuntu/Debian) com suporte a Office, segurança avançada, cache otimizado e backup/restauração completo.

## 🚀 Funcionalidades

- ✅ **Instalação automatizada** do Nextcloud com todas as dependências
- ✅ **Suporte a Office** (Collabora Online ou OnlyOffice)
- ✅ **Segurança reforçada** (Fail2ban, UFW, headers de segurança, HTTPS)
- ✅ **Cache otimizado** (Redis, APCu, OPcache)
- ✅ **Performance tunada** (PHP-FPM, MariaDB, web server)
- ✅ **Backup e restauração** para migração de servidor
- ✅ **Suporte a Apache e Nginx**

## 📋 Requisitos

### Sistema Operacional
- Ubuntu 22.04 LTS ou superior
- Debian 11 ou superior

### Hardware Mínimo
- 2 vCPUs
- 4GB RAM (8GB recomendado para Office)
- 50GB de disco (SSD recomendado)

### Pré-requisitos
- Domínio configurado apontando para o servidor
- Acesso root ao servidor
- Porta 80 e 443 liberadas

## 🛠️ Instalação

### 1. Clone ou baixe o projeto

```bash
git clone https://github.com/seu-usuario/nextcloud-installer.git
cd nextcloud-installer
```

### 2. Torne os scripts executáveis

```bash
chmod +x install.sh backup.sh restore.sh update.sh status.sh manage.sh
chmod +x scripts/*.sh
```

### 3. Execute o instalador

```bash
sudo ./install.sh
```

O instalador irá solicitar:
- Domínio do Nextcloud (ex: cloud.exemplo.com)
- Usuário e senha do administrador
- Email para certificado SSL
- Escolha do servidor web (Apache ou Nginx)
- Escolha do Office (Collabora, OnlyOffice ou Nenhum)

## 📁 Estrutura do Projeto

```
nextcloud-installer/
├── install.sh              # Script principal de instalação
├── backup.sh               # Script de backup
├── restore.sh              # Script de restauração
├── update.sh               # Atualizar Nextcloud
├── status.sh               # Verificar status de todos os serviços
├── manage.sh               # Gerenciar serviços (start/stop/restart)
├── extras/
│   ├── install-talk.sh     # Instalar Nextcloud Talk (opcional)
│   ├── install-pagespeed.sh # Nginx com PageSpeed (opcional)
│   └── README.md           # Documentação dos extras
├── scripts/
│   ├── 01-dependencies.sh  # Instalação de dependências
│   ├── 02-database.sh      # Configuração MariaDB
│   ├── 03-nextcloud.sh     # Instalação Nextcloud
│   ├── 04-webserver.sh     # Configuração Apache/Nginx
│   ├── 05-ssl.sh           # Certificado SSL
│   ├── 06-office.sh        # Integração Office
│   ├── 07-security.sh      # Segurança
│   └── 08-performance.sh   # Otimização de performance
└── README.md
```

## 💾 Backup

### Backup Completo

```bash
sudo ./backup.sh
```

### Backup Rápido (sem dados)

```bash
sudo ./backup.sh --no-data
```

### Backup para Local Customizado

```bash
sudo ./backup.sh --output /mnt/backup
```

### Opções de Backup

| Opção | Descrição |
|-------|-----------|
| `--full` | Backup completo (padrão) |
| `--data-only` | Apenas diretório de dados |
| `--config-only` | Apenas configuração |
| `--db-only` | Apenas banco de dados |
| `--no-data` | Exclui dados (mais rápido) |
| `--output DIR` | Diretório de saída customizado |
| `--remote` | Upload para storage remoto |

## 🔄 Restauração

### Restauração Básica

```bash
sudo ./restore.sh /var/backups/nextcloud/backup-20231201.tar.gz
```

### Migração para Novo Servidor

```bash
sudo ./restore.sh backup.tar.gz --new-domain novocloud.exemplo.com
```

### Opções de Restauração

| Opção | Descrição |
|-------|-----------|
| `--target DIR` | Caminho de instalação customizado |
| `--data-dir DIR` | Diretório de dados customizado |
| `--new-domain NAME` | Atualizar domínio (migração) |
| `--no-database` | Não restaurar banco de dados |
| `--no-data` | Não restaurar dados |
| `--no-config` | Não restaurar configuração |

## 🔄 Atualização

### Verificar Atualizações

```bash
sudo ./update.sh --check
```

### Atualizar Manualmente

```bash
sudo ./update.sh
```

### Atualização Automática

```bash
sudo ./update.sh --auto
```

### Opções de Atualização

| Opção | Descrição |
|-------|-----------|
| `--check` | Apenas verificar atualizações |
| `--auto` | Atualizar automaticamente sem confirmação |
| `--skip-backup` | Pular backup (não recomendado) |
| `--backup-only` | Apenas criar backup, não atualizar |

## 🔒 Segurança

O instalador configura automaticamente:

- **Fail2ban** - Proteção contra brute force
- **UFW Firewall** - Regras restritivas
- **SSL/TLS** - Let's Encrypt com renovação automática
- **Headers de Segurança** - HSTS, X-Content-Type-Options, etc.
- **PHP Hardening** - Funções perigosas desabilitadas
- **Permissões** - Arquivos com permissões mínimas

## ⚡ Performance

Otimizações aplicadas automaticamente:

### Cache
- **OPcache** - Cache de bytecode PHP
- **APCu** - Cache local de memória
- **Redis** - Cache distribuído e file locking

### PHP-FPM
- Pool dedicado para Nextcloud
- Configuração dinâmica baseada na RAM disponível
- Limites otimizados para grandes uploads

### MariaDB
- InnoDB buffer pool otimizado
- Configurações de timeout ajustadas
- Slow query logging habilitado

### Web Server
- HTTP/2 habilitado
- Compressão GZIP
- Cache de arquivos estáticos

## 📱 Apps Instalados

O instalador inclui automaticamente os seguintes apps:

- 📅 Calendar
- 👥 Contacts
- ✅ Tasks
- 📝 Notes
- 📋 Deck
- 🖼️ Photos

## 🎁 Funcionalidades Extras (Opcionais)

### Nextcloud Talk
```bash
sudo chmod +x extras/install-talk.sh
sudo ./extras/install-talk.sh
```
Instala Talk completo com:
- Vídeo chamadas e chat
- Coturn (TURN/STUN server)
- High-Performance Backend

### Nginx com PageSpeed
```bash
sudo chmod +x extras/install-pagespeed.sh
sudo ./extras/install-pagespeed.sh
```
Compila Nginx com PageSpeed para:
- Otimização automática de imagens
- Minificação CSS/JS
- Lazy loading

**Ver:** [extras/README.md](extras/README.md) para detalhes

## 🏢 Suítes Office

### Collabora Online
- Baseado em LibreOffice
- Suporte a documentos ODF
- Edição colaborativa em tempo real

### OnlyOffice
- Alta compatibilidade com MS Office
- Suporte a DOCX, XLSX, PPTX
- Edição colaborativa em tempo real

## 🔧 Comandos Úteis

### Gerenciamento de Serviços

```bash
# Ver status completo do sistema
sudo ./status.sh

# Gerenciar todos os serviços
sudo ./manage.sh start              # Iniciar todos
sudo ./manage.sh stop               # Parar todos
sudo ./manage.sh restart            # Reiniciar todos
sudo ./manage.sh status             # Status rápido
sudo ./manage.sh logs               # Ver logs recentes

# Gerenciar serviços específicos
sudo ./manage.sh restart --web-only     # Apenas servidor web
sudo ./manage.sh restart --db-only      # Apenas banco de dados
sudo ./manage.sh restart --cache-only   # Apenas Redis
sudo ./manage.sh restart --office-only  # Apenas Office

# Habilitar/desabilitar início automático
sudo ./manage.sh enable             # Ativar auto-start
sudo ./manage.sh disable            # Desativar auto-start
```

### OCC (Nextcloud CLI)

```bash
# Ver status
sudo -u www-data php /var/www/nextcloud/occ status

# Listar apps
sudo -u www-data php /var/www/nextcloud/occ app:list

# Escanear arquivos
sudo -u www-data php /var/www/nextcloud/occ files:scan --all

# Modo manutenção
sudo -u www-data php /var/www/nextcloud/occ maintenance:mode --on
sudo -u www-data php /var/www/nextcloud/occ maintenance:mode --off
```

### Logs

```bash
# Nextcloud logs
tail -f /var/nextcloud-data/nextcloud.log

# Apache logs
tail -f /var/log/apache2/nextcloud-error.log

# Nginx logs
tail -f /var/log/nginx/nextcloud-error.log

# PHP-FPM logs
tail -f /var/log/php8.2-fpm-nextcloud.log
```

### Serviços

```bash
# Reiniciar PHP-FPM
sudo systemctl restart php8.2-fpm

# Reiniciar Redis
sudo systemctl restart redis-server

# Reiniciar Apache
sudo systemctl restart apache2

# Reiniciar Nginx
sudo systemctl restart nginx
```

## 📊 Paths Importantes

| Descrição | Caminho |
|-----------|---------|
| Nextcloud | `/var/www/nextcloud` |
| Dados | `/var/nextcloud-data` |
| Configuração | `/var/www/nextcloud/config/config.php` |
| Backups | `/var/backups/nextcloud` |
| Logs | `/var/nextcloud-data/nextcloud.log` |

## ❓ Solução de Problemas

### Verificar status dos serviços

```bash
systemctl status apache2 nginx php8.2-fpm redis-server mariadb
```

### Testar conexão Redis

```bash
redis-cli -s /var/run/redis/redis-server.sock ping
```

### Verificar configuração do Nextcloud

```bash
sudo -u www-data php /var/www/nextcloud/occ config:list system
```

### Reparar instalação

```bash
sudo -u www-data php /var/www/nextcloud/occ maintenance:repair
sudo -u www-data php /var/www/nextcloud/occ db:add-missing-indices
```

## 📄 Licença

Este projeto é distribuído sob a licença MIT.

## 🤝 Contribuições

Contribuições são bem-vindas! Por favor, abra uma issue ou pull request.

---

**Desenvolvido para facilitar a instalação e manutenção do Nextcloud** 🚀
