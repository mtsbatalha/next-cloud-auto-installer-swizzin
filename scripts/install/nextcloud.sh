#!/bin/bash
#
# Nextcloud installer for swizzin
# Enhanced version with Redis, OPcache, APCu, Fail2ban, and PHP-FPM optimization
#
# Licensed under GNU General Public License v3.0 GPL-3

#shellcheck source=sources/functions/php
. /etc/swizzin/sources/functions/php
. /etc/swizzin/sources/functions/utils
. /etc/swizzin/sources/functions/os
. /etc/swizzin/sources/functions/nextcloud

#--- Prerequisites -----------------------------------------------------------

_nc_check_prerequisites() {
    if [[ ! -f /install/.nginx.lock ]]; then
        echo_error "Nginx not detected. Please install nginx first: box install nginx"
        exit 1
    fi

    # Check RAM (minimum 2GB)
    local total_ram
    total_ram=$(free -m | awk '/^Mem:/{print $2}')
    if [[ "$total_ram" -lt 2048 ]]; then
        echo_error "Minimum 2GB RAM required. Found: ${total_ram}MB"
        exit 1
    fi
    if [[ "$total_ram" -lt 4096 ]]; then
        echo_warn "4GB+ RAM recommended for best performance. Found: ${total_ram}MB"
    fi

    # Check disk space (minimum 20GB)
    local free_disk
    free_disk=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')
    if [[ "$free_disk" -lt 20 ]]; then
        echo_error "Minimum 20GB free disk space required. Found: ${free_disk}GB"
        exit 1
    fi
}

#--- Configuration collection ------------------------------------------------

_nc_collect_config() {
    # Support environment variables for unattended install
    local domain admin_user admin_pass admin_email

    domain=${NEXTCLOUD_DOMAIN:-}
    admin_user=${NEXTCLOUD_ADMIN_USER:-}
    admin_pass=${NEXTCLOUD_ADMIN_PASS:-}
    admin_email=${NEXTCLOUD_ADMIN_EMAIL:-}

    if [[ -z "$domain" ]]; then
        echo_query "Enter your Nextcloud domain (e.g., cloud.example.com)"
        read -r domain
        if [[ -z "$domain" ]]; then
            echo_error "Domain cannot be empty"
            exit 1
        fi
    fi

    if [[ -z "$admin_user" ]]; then
        echo_query "Enter Nextcloud admin username"
        read -r admin_user
        admin_user=${admin_user:-admin}
    fi

    if [[ -z "$admin_pass" ]]; then
        echo_query "Enter Nextcloud admin password (min 10 chars)" "hidden"
        read -rs admin_pass
        echo
        if [[ ${#admin_pass} -lt 10 ]]; then
            echo_error "Password must be at least 10 characters"
            exit 1
        fi
        echo_query "Confirm admin password" "hidden"
        read -rs admin_pass_confirm
        echo
        if [[ "$admin_pass" != "$admin_pass_confirm" ]]; then
            echo_error "Passwords do not match"
            exit 1
        fi
    fi

    if [[ -z "$admin_email" ]]; then
        echo_query "Enter admin email address"
        read -r admin_email
    fi

    # Generate passwords
    local db_pass redis_pass
    db_pass=$(nc_generate_password)
    redis_pass=$(nc_generate_password)

    # Store configuration in swizdb
    swizdb set nextcloud/domain "$domain"
    swizdb set nextcloud/admin_user "$admin_user"
    swizdb set nextcloud/admin_email "$admin_email"
    swizdb set nextcloud/db_name "nextcloud"
    swizdb set nextcloud/db_user "nextcloud"
    swizdb set nextcloud/db_pass "$db_pass"
    swizdb set nextcloud/redis_pass "$redis_pass"

    # Export for use in this script
    export NC_DOMAIN="$domain"
    export NC_ADMIN_USER="$admin_user"
    export NC_ADMIN_PASS="$admin_pass"
    export NC_ADMIN_EMAIL="$admin_email"
    export NC_DB_NAME="nextcloud"
    export NC_DB_USER="nextcloud"
    export NC_DB_PASS="$db_pass"
    export NC_REDIS_PASS="$redis_pass"
}

#--- Dependencies ------------------------------------------------------------

_nc_install_dependencies() {
    echo_progress_start "Installing dependencies"

    #shellcheck source=sources/functions/php
    . /etc/swizzin/sources/functions/php
    local phpv
    phpv=$(php_service_version)

    apt_install \
        php${phpv}-gd \
        php${phpv}-mysql \
        php${phpv}-curl \
        php${phpv}-mbstring \
        php${phpv}-intl \
        php${phpv}-gmp \
        php${phpv}-bcmath \
        php${phpv}-xml \
        php${phpv}-zip \
        php${phpv}-bz2 \
        php${phpv}-redis \
        php${phpv}-apcu \
        php${phpv}-imagick \
        php${phpv}-opcache \
        php${phpv}-ldap \
        php${phpv}-smbclient

    apt_install \
        redis-server \
        imagemagick \
        ffmpeg \
        libmagickcore-6.q16-6-extra \
        bzip2 \
        unzip

    # Install MariaDB if not present
    local inst
    inst=$(which mysql 2>/dev/null)
    if [[ -z "$inst" ]]; then
        apt_install mariadb-server mariadb-client
        systemctl start mariadb >> $log 2>&1
        systemctl enable mariadb >> $log 2>&1
    fi

    # Install Fail2ban if not present
    if ! dpkg -s fail2ban > /dev/null 2>&1; then
        apt_install fail2ban
    fi

    echo_progress_done "Dependencies installed"
}

#--- Database ----------------------------------------------------------------

_nc_configure_database() {
    echo_progress_start "Configuring database"

    local inst password
    inst=$(which mysql 2>/dev/null)

    if [[ -n "$inst" ]]; then
        # Check if MySQL has existing root password
        if ! mysql -e "SELECT 1;" >> $log 2>&1; then
            echo_query "Enter MySQL root password" "hidden"
            read -rs password
            echo
        else
            password=""
        fi
    fi

    local mysql_auth=""
    if [[ -n "$password" ]]; then
        mysql_auth="--password=${password}"
    fi

    # Secure MariaDB (skip if already secured)
    mysql ${mysql_auth} -e "DELETE FROM mysql.user WHERE User='';" >> $log 2>&1 || true
    mysql ${mysql_auth} -e "DROP DATABASE IF EXISTS test;" >> $log 2>&1 || true
    mysql ${mysql_auth} -e "FLUSH PRIVILEGES;" >> $log 2>&1

    # Drop existing nextcloud user/db if present
    mysql ${mysql_auth} -e "DROP USER IF EXISTS '${NC_DB_USER}'@'localhost';" >> $log 2>&1 || true
    mysql ${mysql_auth} -e "DROP DATABASE IF EXISTS ${NC_DB_NAME};" >> $log 2>&1 || true
    mysql ${mysql_auth} -e "FLUSH PRIVILEGES;" >> $log 2>&1

    # Create database and user
    mysql ${mysql_auth} -e "CREATE DATABASE ${NC_DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;" >> $log 2>&1
    mysql ${mysql_auth} -e "CREATE USER '${NC_DB_USER}'@'localhost' IDENTIFIED BY '${NC_DB_PASS}';" >> $log 2>&1
    mysql ${mysql_auth} -e "GRANT ALL PRIVILEGES ON ${NC_DB_NAME}.* TO '${NC_DB_USER}'@'localhost' WITH GRANT OPTION;" >> $log 2>&1
    mysql ${mysql_auth} -e "FLUSH PRIVILEGES;" >> $log 2>&1

    # Optimize MariaDB for Nextcloud
    local total_ram_mb buffer_pool_size
    total_ram_mb=$(free -m | awk '/^Mem:/{print $2}')
    buffer_pool_size=$((total_ram_mb / 4))M

    cat > /etc/mysql/mariadb.conf.d/99-nextcloud.cnf << EOF
# Nextcloud optimized MariaDB configuration

[mysqld]
# InnoDB settings
innodb_buffer_pool_size = ${buffer_pool_size}
innodb_log_file_size = 256M
innodb_flush_log_at_trx_commit = 2
innodb_flush_method = O_DIRECT
innodb_file_per_table = 1

# Query cache (disabled for InnoDB)
query_cache_type = 0
query_cache_size = 0

# Connection settings
max_connections = 200
wait_timeout = 600
interactive_timeout = 600

# Character set
character-set-server = utf8mb4
collation-server = utf8mb4_general_ci

# Logging
slow_query_log = 1
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 2

# Temporary tables
tmp_table_size = 64M
max_heap_table_size = 64M

[client]
default-character-set = utf8mb4
EOF

    systemctl restart mariadb >> $log 2>&1

    # Test connection
    if ! mysql -u "${NC_DB_USER}" -p"${NC_DB_PASS}" -e "USE ${NC_DB_NAME}; SELECT 1;" >> $log 2>&1; then
        echo_error "Database connection test failed"
        exit 1
    fi

    echo_progress_done "Database configured"
}

#--- Nextcloud installation --------------------------------------------------

_nc_install_nextcloud() {
    echo_progress_start "Downloading and installing Nextcloud"

    mkdir -p "${NEXTCLOUD_PATH}"
    mkdir -p "${NC_DATA_PATH}"
    mkdir -p "${NC_BACKUP_PATH}"

    # Download latest Nextcloud
    cd /tmp
    wget -q https://download.nextcloud.com/server/releases/latest.tar.bz2 -O /tmp/nextcloud.tar.bz2 >> $log 2>&1 || {
        echo_error "Could not download Nextcloud"
        exit 1
    }

    # Verify SHA256 if available
    if wget -q https://download.nextcloud.com/server/releases/latest.tar.bz2.sha256 -O /tmp/nextcloud.tar.bz2.sha256 >> $log 2>&1; then
        local expected actual
        expected=$(head -1 /tmp/nextcloud.tar.bz2.sha256 | awk '{print $1}')
        actual=$(sha256sum /tmp/nextcloud.tar.bz2 | awk '{print $1}')
        if [[ "$expected" != "$actual" ]]; then
            echo_error "SHA256 verification failed"
            exit 1
        fi
    fi

    # Extract to /srv/
    tar -xjf /tmp/nextcloud.tar.bz2 -C /srv/ >> $log 2>&1
    rm -f /tmp/nextcloud.tar.bz2 /tmp/nextcloud.tar.bz2.sha256

    # Set initial permissions
    chown -R www-data:www-data "${NEXTCLOUD_PATH}"
    chown -R www-data:www-data "${NC_DATA_PATH}"

    # Install via OCC
    cd "${NEXTCLOUD_PATH}"
    sudo -u www-data php occ maintenance:install \
        --database "mysql" \
        --database-name "${NC_DB_NAME}" \
        --database-user "${NC_DB_USER}" \
        --database-pass "${NC_DB_PASS}" \
        --admin-user "${NC_ADMIN_USER}" \
        --admin-pass "${NC_ADMIN_PASS}" \
        --admin-email "${NC_ADMIN_EMAIL}" \
        --data-dir "${NC_DATA_PATH}" >> $log 2>&1

    # Configure trusted domains
    nc_occ config:system:set trusted_domains 0 --value="localhost" >> $log 2>&1
    nc_occ config:system:set trusted_domains 1 --value="${NC_DOMAIN}" >> $log 2>&1

    # Basic configuration
    nc_occ config:system:set overwrite.cli.url --value="https://${NC_DOMAIN}" >> $log 2>&1
    nc_occ config:system:set default_phone_region --value="BR" >> $log 2>&1
    nc_occ config:system:set maintenance_window_start --type=integer --value=1 >> $log 2>&1

    # Logging
    nc_occ config:system:set loglevel --value=2 --type=integer >> $log 2>&1
    nc_occ config:system:set log_type --value="file" >> $log 2>&1
    nc_occ config:system:set logfile --value="${NC_DATA_PATH}/nextcloud.log" >> $log 2>&1
    nc_occ config:system:set log_rotate_size --value=104857600 --type=integer >> $log 2>&1

    # Pretty URLs
    nc_occ config:system:set htaccess.RewriteBase --value="/" >> $log 2>&1
    nc_occ maintenance:update:htaccess >> $log 2>&1

    # Install recommended apps
    local apps="calendar contacts tasks notes deck photos"
    for app in $apps; do
        nc_occ app:install "$app" >> $log 2>&1 || true
        nc_occ app:enable "$app" >> $log 2>&1 || true
    done

    echo_progress_done "Nextcloud installed"
}

#--- Nginx configuration (subdomain mode) ------------------------------------

_nc_configure_nginx() {
    echo_progress_start "Configuring nginx"

    local phpv sock
    phpv=$(php_service_version)
    sock="php${phpv}-fpm-nextcloud"

    cat > /etc/nginx/conf.d/nextcloud.conf << NGINXEOF
# Nextcloud nginx configuration (swizzin)
# Based on official Nextcloud nginx docs

upstream nc-php-handler {
    server unix:/var/run/php/${sock}.sock;
}

map \$arg_v \$nc_asset_immutable {
    "" "";
    default ", immutable";
}

server {
    listen 80;
    listen [::]:80;
    server_name ${NC_DOMAIN};

    server_tokens off;

    # Enforce HTTPS
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${NC_DOMAIN};

    server_tokens off;

    # SSL is managed by swizzin's letsencrypt package or self-signed certs
    # Include swizzin SSL if available, otherwise use snakeoil
    include /etc/nginx/snippets/ssl-params.conf;
    ssl_certificate /etc/nginx/ssl/${NC_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/${NC_DOMAIN}/key.pem;

    root ${NEXTCLOUD_PATH};

    # HSTS
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;

    # Upload limits (50GB)
    client_max_body_size 50G;
    client_body_timeout 7200s;
    fastcgi_buffers 64 4K;
    client_body_buffer_size 512k;

    # Gzip
    gzip on;
    gzip_vary on;
    gzip_comp_level 4;
    gzip_min_length 256;
    gzip_proxied expired no-cache no-store private no_last_modified no_etag auth;
    gzip_types application/atom+xml text/javascript application/javascript application/json application/ld+json application/manifest+json application/rss+xml application/vnd.geo+json application/vnd.ms-fontobject application/wasm application/x-font-ttf application/x-web-app-manifest+json application/xhtml+xml application/xml font/opentype image/bmp image/svg+xml image/x-icon text/cache-manifest text/css text/plain text/vcard text/vnd.rim.location.xloc text/vtt text/x-component text/x-cross-domain-policy;

    # Security headers
    add_header Referrer-Policy "no-referrer" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Permitted-Cross-Domain-Policies "none" always;
    add_header X-Robots-Tag "noindex, nofollow" always;

    fastcgi_hide_header X-Powered-By;

    include mime.types;
    types {
        text/javascript mjs;
        application/wasm wasm;
    }

    index index.php index.html /index.php\$request_uri;

    # Microsoft DAV clients
    location = / {
        if ( \$http_user_agent ~ ^DavClnt ) {
            return 302 /remote.php/webdav/\$is_args\$args;
        }
    }

    location = /robots.txt {
        allow all;
        log_not_found off;
        access_log off;
    }

    # Well-known URIs
    location ^~ /.well-known {
        location = /.well-known/carddav { return 301 /remote.php/dav/; }
        location = /.well-known/caldav  { return 301 /remote.php/dav/; }
        location /.well-known/acme-challenge { try_files \$uri \$uri/ =404; }
        location /.well-known/pki-validation { try_files \$uri \$uri/ =404; }
        return 301 /index.php\$request_uri;
    }

    # Hide sensitive paths
    location ~ ^/(?:build|tests|config|lib|3rdparty|templates|data)(?:\$|/)  { return 404; }
    location ~ ^/(?:\.|autotest|occ|issue|indie|db_|console)                { return 404; }

    # PHP handling
    location ~ \.php(?:\$|/) {
        rewrite ^/(?!index|remote|public|cron|core\/ajax\/update|status|ocs\/v[12]|updater\/.+|ocs-provider\/.+|.+\/richdocumentscode(_arm64)?\/proxy) /index.php\$request_uri;

        fastcgi_split_path_info ^(.+?\.php)(/.*)$;
        set \$path_info \$fastcgi_path_info;

        try_files \$fastcgi_script_name =404;

        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$path_info;
        fastcgi_param HTTPS on;
        fastcgi_param modHeadersAvailable true;
        fastcgi_param front_controller_active true;
        fastcgi_pass nc-php-handler;

        fastcgi_intercept_errors on;
        fastcgi_request_buffering on;

        # Timeouts for large uploads (2 hours)
        fastcgi_read_timeout 7200;
        fastcgi_send_timeout 7200;
        fastcgi_connect_timeout 7200;
        fastcgi_max_temp_file_size 0;
    }

    # Static assets
    location ~ \.(?:css|js|mjs|svg|gif|ico|jpg|png|webp|wasm|tflite|map|ogg|flac)$ {
        try_files \$uri /index.php\$request_uri;
        add_header Cache-Control "public, max-age=15778463\$nc_asset_immutable";
        add_header Referrer-Policy "no-referrer" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Permitted-Cross-Domain-Policies "none" always;
        add_header X-Robots-Tag "noindex, nofollow" always;
        access_log off;
    }

    location ~ \.(otf|woff2?)$ {
        try_files \$uri /index.php\$request_uri;
        expires 7d;
        access_log off;
    }

    location /remote {
        return 301 /remote.php\$request_uri;
    }

    location / {
        try_files \$uri \$uri/ /index.php\$request_uri;
    }
}
NGINXEOF

    # Create SSL directory and self-signed cert if letsencrypt is not configured
    if [[ ! -d /etc/nginx/ssl/${NC_DOMAIN} ]]; then
        mkdir -p "/etc/nginx/ssl/${NC_DOMAIN}"
        if [[ -f /etc/nginx/ssl/default/fullchain.pem ]]; then
            # Use swizzin's default self-signed cert
            ln -sf /etc/nginx/ssl/default/fullchain.pem "/etc/nginx/ssl/${NC_DOMAIN}/fullchain.pem"
            ln -sf /etc/nginx/ssl/default/key.pem "/etc/nginx/ssl/${NC_DOMAIN}/key.pem"
        else
            # Generate self-signed cert for this domain
            openssl req -x509 -nodes -days 3650 \
                -newkey rsa:2048 \
                -keyout "/etc/nginx/ssl/${NC_DOMAIN}/key.pem" \
                -out "/etc/nginx/ssl/${NC_DOMAIN}/fullchain.pem" \
                -subj "/CN=${NC_DOMAIN}" >> $log 2>&1
        fi
    fi

    # Ensure ssl-params snippet exists
    if [[ ! -f /etc/nginx/snippets/ssl-params.conf ]]; then
        cat > /etc/nginx/snippets/ssl-params.conf << 'SSLEOF'
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers 'HIGH:!aNULL:!MD5:!3DES';
ssl_prefer_server_ciphers on;
ssl_session_timeout 1d;
ssl_session_cache shared:SSL:50m;
ssl_session_tickets off;
SSLEOF
    fi

    nginx -t >> $log 2>&1 || {
        echo_error "Nginx configuration test failed"
        exit 1
    }

    systemctl reload nginx >> $log 2>&1

    echo_progress_done "Nginx configured"
}

#--- Fail2ban ----------------------------------------------------------------

_nc_configure_fail2ban() {
    echo_progress_start "Configuring Fail2ban"

    cat > /etc/fail2ban/filter.d/nextcloud.conf << 'EOF'
[Definition]
_groupsre = (?:(?:,?\s*"\w+":(?:"[^"]+"|\w+))*)
failregex = ^{"reqId":".*","level":2,"time":".*","remoteAddr":"<HOST>","user":".*","app":"core","method":".*","url":".*","message":"Login failed: .*}$
            ^{"reqId":".*","level":2,"time":".*","remoteAddr":"<HOST>","user":".*","app":"core","method":".*","url":".*","message":"Trusted domain error..*}$
            ^.*"remoteAddr":"<HOST>".*failed.*$
            ^.*"remoteAddr":"<HOST>".*Invalid credentials.*$
datepattern = ,?"time"\s*:\s*"%%Y-%%m-%%d[T ]%%H:%%M:%%S(%%z)?"
EOF

    cat > /etc/fail2ban/jail.d/nextcloud.conf << EOF
[nextcloud]
enabled = true
backend = auto
port = 80,443
protocol = tcp
filter = nextcloud
maxretry = 5
bantime = 3600
findtime = 600
logpath = ${NC_DATA_PATH}/nextcloud.log
EOF

    systemctl enable fail2ban >> $log 2>&1
    systemctl restart fail2ban >> $log 2>&1

    echo_progress_done "Fail2ban configured"
}

#--- Permissions -------------------------------------------------------------

_nc_configure_permissions() {
    echo_progress_start "Setting file permissions"

    nc_fix_permissions

    echo_progress_done "Permissions set"
}

#--- PHP security ------------------------------------------------------------

_nc_configure_php_security() {
    echo_progress_start "Hardening PHP"

    local phpv
    phpv=$(php_service_version)

    cat > "/etc/php/${phpv}/fpm/conf.d/99-nextcloud-security.ini" << 'EOF'
; Nextcloud PHP security hardening

; Disable dangerous functions
disable_functions = exec,passthru,shell_exec,system,proc_open,popen,parse_ini_file,show_source

; Hide PHP version
expose_php = Off

; Session security
session.cookie_secure = On
session.cookie_httponly = On
session.cookie_samesite = Strict
session.use_strict_mode = On
session.use_only_cookies = On

; Error handling
display_errors = Off
display_startup_errors = Off
log_errors = On
error_reporting = E_ALL & ~E_DEPRECATED & ~E_STRICT

; File uploads
file_uploads = On
upload_max_filesize = 16G
max_file_uploads = 100
post_max_size = 16G

; Memory and execution limits
memory_limit = 512M
max_execution_time = 3600
max_input_time = 3600

; Security
allow_url_fopen = On
allow_url_include = Off
EOF

    echo_progress_done "PHP hardened"
}

#--- Cron --------------------------------------------------------------------

_nc_configure_cron() {
    echo_progress_start "Configuring cron"

    cd "${NEXTCLOUD_PATH}"
    nc_occ background:cron >> $log 2>&1

    cat > /etc/cron.d/nextcloud << EOF
# Nextcloud background jobs
*/5 * * * * www-data php -f ${NEXTCLOUD_PATH}/cron.php
EOF

    systemctl reload cron >> $log 2>&1 || systemctl reload crond >> $log 2>&1 || true

    echo_progress_done "Cron configured"
}

#--- OPcache -----------------------------------------------------------------

_nc_configure_opcache() {
    echo_progress_start "Configuring OPcache"

    local phpv
    phpv=$(php_service_version)

    cat > "/etc/php/${phpv}/mods-available/opcache-nextcloud.ini" << 'EOF'
; Nextcloud OPcache configuration
opcache.enable=1
opcache.interned_strings_buffer=32
opcache.max_accelerated_files=10000
opcache.memory_consumption=256
opcache.save_comments=1
opcache.revalidate_freq=1
opcache.fast_shutdown=1
opcache.enable_cli=1
opcache.validate_timestamps=0
opcache.file_cache=/tmp/opcache
opcache.file_cache_only=0
opcache.file_cache_consistency_checks=1
EOF

    mkdir -p /tmp/opcache
    chown www-data:www-data /tmp/opcache

    ln -sf "/etc/php/${phpv}/mods-available/opcache-nextcloud.ini" \
        "/etc/php/${phpv}/fpm/conf.d/10-opcache-nextcloud.ini"
    ln -sf "/etc/php/${phpv}/mods-available/opcache-nextcloud.ini" \
        "/etc/php/${phpv}/cli/conf.d/10-opcache-nextcloud.ini"

    echo_progress_done "OPcache configured"
}

#--- APCu --------------------------------------------------------------------

_nc_configure_apcu() {
    echo_progress_start "Configuring APCu"

    local phpv
    phpv=$(php_service_version)

    cat > "/etc/php/${phpv}/mods-available/apcu-nextcloud.ini" << 'EOF'
; Nextcloud APCu configuration
apc.enabled=1
apc.shm_size=128M
apc.ttl=7200
apc.enable_cli=1
apc.gc_ttl=3600
apc.entries_hint=4096
apc.slam_defense=1
EOF

    ln -sf "/etc/php/${phpv}/mods-available/apcu-nextcloud.ini" \
        "/etc/php/${phpv}/fpm/conf.d/20-apcu-nextcloud.ini"
    ln -sf "/etc/php/${phpv}/mods-available/apcu-nextcloud.ini" \
        "/etc/php/${phpv}/cli/conf.d/20-apcu-nextcloud.ini"

    echo_progress_done "APCu configured"
}

#--- Redis -------------------------------------------------------------------

_nc_configure_redis() {
    echo_progress_start "Configuring Redis"

    local redis_already_running=false
    if systemctl is-active redis-server >> $log 2>&1; then
        redis_already_running=true
    fi

    if [[ "$redis_already_running" == "true" ]]; then
        # Redis is already running (another swizzin package may use it)
        # Only add www-data to redis group and use a different dbindex
        echo_info "Redis already running, using dbindex 1 for Nextcloud"
        swizdb set nextcloud/redis_dbindex "1"
    else
        # Configure Redis from scratch
        mkdir -p /var/run/redis
        chown redis:redis /var/run/redis
        chmod 755 /var/run/redis

        cat > /etc/redis/redis.conf << EOF
# Nextcloud optimized Redis configuration

# Network
bind 127.0.0.1 ::1
port 0
unixsocket /var/run/redis/redis-server.sock
unixsocketperm 770

# Security
requirepass ${NC_REDIS_PASS}
protected-mode yes

# Memory management
maxmemory 256mb
maxmemory-policy allkeys-lru

# Persistence (disabled for caching)
save ""
appendonly no

# Performance
tcp-backlog 511
timeout 0
tcp-keepalive 300
databases 16

# Logging
loglevel notice
logfile /var/log/redis/redis-server.log

# Slow log
slowlog-log-slower-than 10000
slowlog-max-len 128

# Advanced config
hash-max-ziplist-entries 512
hash-max-ziplist-value 64
list-max-ziplist-size -2
set-max-intset-entries 512
zset-max-ziplist-entries 128
zset-max-ziplist-value 64
activerehashing yes
hz 10
dynamic-hz yes
EOF
        swizdb set nextcloud/redis_dbindex "0"

        systemctl enable redis-server >> $log 2>&1
        systemctl restart redis-server >> $log 2>&1
    fi

    # Add www-data to redis group
    usermod -aG redis www-data >> $log 2>&1

    echo_progress_done "Redis configured"
}

#--- PHP-FPM pool ------------------------------------------------------------

_nc_configure_php_fpm() {
    echo_progress_start "Configuring PHP-FPM pool"

    local phpv
    phpv=$(php_service_version)

    # Calculate optimal settings based on RAM
    local total_ram_mb php_mem_per_process max_children start_servers min_spare max_spare
    total_ram_mb=$(free -m | awk '/^Mem:/{print $2}')
    php_mem_per_process=80

    max_children=$(( (total_ram_mb * 70 / 100) / php_mem_per_process ))
    [[ $max_children -lt 5 ]] && max_children=5
    [[ $max_children -gt 100 ]] && max_children=100

    start_servers=$(( max_children / 4 ))
    min_spare=$(( max_children / 4 ))
    max_spare=$(( max_children / 2 ))

    cat > "/etc/php/${phpv}/fpm/pool.d/nextcloud.conf" << EOF
; Nextcloud PHP-FPM Pool

[nextcloud]
user = www-data
group = www-data

listen = /var/run/php/php${phpv}-fpm-nextcloud.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

; Process Management
pm = dynamic
pm.max_children = ${max_children}
pm.start_servers = ${start_servers}
pm.min_spare_servers = ${min_spare}
pm.max_spare_servers = ${max_spare}
pm.max_requests = 500
pm.process_idle_timeout = 10s

; Status page
pm.status_path = /nc-status

; Environment
env[HOSTNAME] = \$HOSTNAME
env[PATH] = /usr/local/bin:/usr/bin:/bin
env[TMP] = /tmp
env[TMPDIR] = /tmp
env[TEMP] = /tmp

; PHP settings
php_admin_value[error_log] = /var/log/php${phpv}-fpm-nextcloud.log
php_admin_flag[log_errors] = on
php_admin_value[memory_limit] = 512M
php_admin_value[upload_max_filesize] = 16G
php_admin_value[post_max_size] = 16G
php_admin_value[max_execution_time] = 3600
php_admin_value[max_input_time] = 3600
php_admin_value[output_buffering] = Off
EOF

    restart_php_fpm >> $log 2>&1

    echo_progress_done "PHP-FPM pool configured (max_children: ${max_children})"
}

#--- Nextcloud caching -------------------------------------------------------

_nc_configure_caching() {
    echo_progress_start "Configuring Nextcloud caching"

    local redis_dbindex
    redis_dbindex=$(swizdb get nextcloud/redis_dbindex 2>/dev/null || echo "0")

    cd "${NEXTCLOUD_PATH}"

    # Memory caching
    nc_occ config:system:set memcache.local --value="\\OC\\Memcache\\APCu" >> $log 2>&1
    nc_occ config:system:set memcache.distributed --value="\\OC\\Memcache\\Redis" >> $log 2>&1
    nc_occ config:system:set memcache.locking --value="\\OC\\Memcache\\Redis" >> $log 2>&1

    # Redis connection
    nc_occ config:system:set redis host --value="/var/run/redis/redis-server.sock" >> $log 2>&1
    nc_occ config:system:set redis port --value=0 --type=integer >> $log 2>&1
    nc_occ config:system:set redis password --value="${NC_REDIS_PASS}" >> $log 2>&1
    nc_occ config:system:set redis dbindex --value="${redis_dbindex}" --type=integer >> $log 2>&1
    nc_occ config:system:set redis timeout --value=1.5 --type=float >> $log 2>&1

    # File locking
    nc_occ config:system:set filelocking.enabled --value=true --type=boolean >> $log 2>&1

    # Preview settings
    nc_occ config:system:set preview_max_x --value=2048 --type=integer >> $log 2>&1
    nc_occ config:system:set preview_max_y --value=2048 --type=integer >> $log 2>&1
    nc_occ config:system:set jpeg_quality --value=60 --type=integer >> $log 2>&1
    nc_occ config:app:set preview jpeg_quality --value="60" >> $log 2>&1

    # Preview providers
    local i=0
    for provider in PNG JPEG GIF MP3 TXT MarkDown Movie PDF; do
        nc_occ config:system:set enabledPreviewProviders $i --value="OC\\Preview\\${provider}" >> $log 2>&1
        i=$((i + 1))
    done

    echo_progress_done "Caching configured"
}

#--- Finalize ----------------------------------------------------------------

_nc_finalize() {
    echo_progress_start "Finalizing installation"

    cd "${NEXTCLOUD_PATH}"

    nc_maintenance_off
    nc_occ db:add-missing-indices >> $log 2>&1
    nc_occ db:convert-filecache-bigint --no-interaction >> $log 2>&1
    nc_occ maintenance:repair >> $log 2>&1

    local phpv
    phpv=$(php_service_version)

    restart_php_fpm >> $log 2>&1
    systemctl restart redis-server >> $log 2>&1
    systemctl reload nginx >> $log 2>&1

    echo_progress_done "Installation finalized"
}

#--- Main execution ----------------------------------------------------------

echo_info "Starting Nextcloud installation"

_nc_check_prerequisites
_nc_collect_config
_nc_install_dependencies
_nc_configure_database
_nc_install_nextcloud
_nc_configure_nginx
_nc_configure_fail2ban
_nc_configure_permissions
_nc_configure_php_security
_nc_configure_cron
_nc_configure_opcache
_nc_configure_apcu
_nc_configure_redis
_nc_configure_php_fpm
_nc_configure_caching
_nc_finalize

touch /install/.nextcloud.lock

echo_success "Nextcloud installed"
echo_info "Visit https://$(swizdb get nextcloud/domain) to access Nextcloud"
echo_info "Admin user: $(swizdb get nextcloud/admin_user)"
echo_info "Data directory: ${NC_DATA_PATH}"
