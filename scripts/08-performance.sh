#!/bin/bash
#===============================================================================
# 08-performance.sh - Performance optimization and caching
#===============================================================================

configure_performance() {
    log_info "Configuring performance optimizations..."
    
    configure_opcache
    configure_apcu
    configure_redis
    configure_php_fpm
    configure_nextcloud_caching
    
    log_success "Performance optimizations applied"
}

configure_opcache() {
    log_info "Configuring PHP OPcache..."
    
    cat > "/etc/php/${PHP_VERSION}/mods-available/opcache-nextcloud.ini" << 'EOF'
; Nextcloud OPcache configuration
; https://docs.nextcloud.com/server/latest/admin_manual/installation/server_tuning.html

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

    # Create OPcache file cache directory
    mkdir -p /tmp/opcache
    chown www-data:www-data /tmp/opcache
    
    # Enable configuration
    ln -sf "/etc/php/${PHP_VERSION}/mods-available/opcache-nextcloud.ini" \
        "/etc/php/${PHP_VERSION}/fpm/conf.d/10-opcache-nextcloud.ini"
    ln -sf "/etc/php/${PHP_VERSION}/mods-available/opcache-nextcloud.ini" \
        "/etc/php/${PHP_VERSION}/cli/conf.d/10-opcache-nextcloud.ini"
    
    log_success "OPcache configured"
}

configure_apcu() {
    log_info "Configuring APCu..."
    
    cat > "/etc/php/${PHP_VERSION}/mods-available/apcu-nextcloud.ini" << 'EOF'
; Nextcloud APCu configuration

apc.enabled=1
apc.shm_size=128M
apc.ttl=7200
apc.enable_cli=1
apc.gc_ttl=3600
apc.entries_hint=4096
apc.slam_defense=1
EOF

    # Enable configuration
    ln -sf "/etc/php/${PHP_VERSION}/mods-available/apcu-nextcloud.ini" \
        "/etc/php/${PHP_VERSION}/fpm/conf.d/20-apcu-nextcloud.ini"
    ln -sf "/etc/php/${PHP_VERSION}/mods-available/apcu-nextcloud.ini" \
        "/etc/php/${PHP_VERSION}/cli/conf.d/20-apcu-nextcloud.ini"
    
    log_success "APCu configured"
}

configure_redis() {
    log_info "Configuring Redis..."
    
    # Create Redis socket directory
    mkdir -p /var/run/redis
    chown redis:redis /var/run/redis
    chmod 755 /var/run/redis
    
    # Configure Redis
    cat > /etc/redis/redis.conf << EOF
# Nextcloud optimized Redis configuration

# Network
bind 127.0.0.1 ::1
port 0
unixsocket /var/run/redis/redis-server.sock
unixsocketperm 770

# Security
requirepass ${REDIS_PASS}
protected-mode yes

# Memory management
maxmemory 256mb
maxmemory-policy allkeys-lru

# Persistence (disable for pure caching)
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
client-output-buffer-limit normal 0 0 0
client-output-buffer-limit replica 256mb 64mb 60
client-output-buffer-limit pubsub 32mb 8mb 60
hz 10
dynamic-hz yes
EOF

    # Add www-data to redis group
    usermod -aG redis www-data
    
    # Restart Redis
    systemctl enable redis-server
    systemctl restart redis-server
    
    log_success "Redis configured"
}

configure_php_fpm() {
    log_info "Configuring PHP-FPM..."
    
    # Calculate optimal settings based on RAM
    TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
    
    # Estimate memory per PHP process (approximately 50-100MB)
    PHP_MEM_PER_PROCESS=80
    
    # Calculate max children (use 70% of RAM for PHP)
    MAX_CHILDREN=$(( (TOTAL_RAM_MB * 70 / 100) / PHP_MEM_PER_PROCESS ))
    
    # Ensure reasonable limits
    [[ $MAX_CHILDREN -lt 5 ]] && MAX_CHILDREN=5
    [[ $MAX_CHILDREN -gt 100 ]] && MAX_CHILDREN=100
    
    START_SERVERS=$(( MAX_CHILDREN / 4 ))
    MIN_SPARE=$(( MAX_CHILDREN / 4 ))
    MAX_SPARE=$(( MAX_CHILDREN / 2 ))
    
    cat > "/etc/php/${PHP_VERSION}/fpm/pool.d/nextcloud.conf" << EOF
; Nextcloud PHP-FPM Pool

[nextcloud]
user = www-data
group = www-data

listen = /var/run/php/php${PHP_VERSION}-fpm.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

; Process Management
pm = dynamic
pm.max_children = ${MAX_CHILDREN}
pm.start_servers = ${START_SERVERS}
pm.min_spare_servers = ${MIN_SPARE}
pm.max_spare_servers = ${MAX_SPARE}
pm.max_requests = 500
pm.process_idle_timeout = 10s

; Status page
pm.status_path = /status

; Environment
env[HOSTNAME] = \$HOSTNAME
env[PATH] = /usr/local/bin:/usr/bin:/bin
env[TMP] = /tmp
env[TMPDIR] = /tmp
env[TEMP] = /tmp

; PHP settings
php_admin_value[error_log] = /var/log/php${PHP_VERSION}-fpm-nextcloud.log
php_admin_flag[log_errors] = on
php_admin_value[memory_limit] = 512M
php_admin_value[upload_max_filesize] = 16G
php_admin_value[post_max_size] = 16G
php_admin_value[max_execution_time] = 3600
php_admin_value[max_input_time] = 3600
php_admin_value[output_buffering] = Off

; Opcache
php_admin_value[opcache.memory_consumption] = 256
php_admin_value[opcache.max_accelerated_files] = 10000
php_admin_value[opcache.revalidate_freq] = 1
EOF

    # Disable www pool
    mv "/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf" \
       "/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf.disabled" 2>/dev/null || true
    
    # Restart PHP-FPM
    systemctl restart php${PHP_VERSION}-fpm
    
    log_success "PHP-FPM configured (max_children: ${MAX_CHILDREN})"
}

configure_nextcloud_caching() {
    log_info "Configuring Nextcloud caching..."
    
    cd "${NEXTCLOUD_PATH}"
    
    # Configure memory caching
    sudo -u www-data php occ config:system:set memcache.local --value="\\OC\\Memcache\\APCu"
    sudo -u www-data php occ config:system:set memcache.distributed --value="\\OC\\Memcache\\Redis"
    sudo -u www-data php occ config:system:set memcache.locking --value="\\OC\\Memcache\\Redis"
    
    # Configure Redis connection (using socket)
    sudo -u www-data php occ config:system:set redis host --value="/var/run/redis/redis-server.sock"
    sudo -u www-data php occ config:system:set redis port --value=0 --type=integer
    sudo -u www-data php occ config:system:set redis password --value="${REDIS_PASS}"
    sudo -u www-data php occ config:system:set redis dbindex --value=0 --type=integer
    sudo -u www-data php occ config:system:set redis timeout --value=1.5 --type=float
    
    # Enable file locking
    sudo -u www-data php occ config:system:set filelocking.enabled --value=true --type=boolean
    
    # Configure preview settings for performance
    sudo -u www-data php occ config:system:set preview_max_x --value=2048 --type=integer
    sudo -u www-data php occ config:system:set preview_max_y --value=2048 --type=integer
    sudo -u www-data php occ config:system:set jpeg_quality --value=60 --type=integer
    sudo -u www-data php occ config:app:set preview jpeg_quality --value="60"
    
    # Enable preview providers
    sudo -u www-data php occ config:system:set enabledPreviewProviders 0 --value="OC\\Preview\\PNG"
    sudo -u www-data php occ config:system:set enabledPreviewProviders 1 --value="OC\\Preview\\JPEG"
    sudo -u www-data php occ config:system:set enabledPreviewProviders 2 --value="OC\\Preview\\GIF"
    sudo -u www-data php occ config:system:set enabledPreviewProviders 3 --value="OC\\Preview\\MP3"
    sudo -u www-data php occ config:system:set enabledPreviewProviders 4 --value="OC\\Preview\\TXT"
    sudo -u www-data php occ config:system:set enabledPreviewProviders 5 --value="OC\\Preview\\MarkDown"
    sudo -u www-data php occ config:system:set enabledPreviewProviders 6 --value="OC\\Preview\\Movie"
    sudo -u www-data php occ config:system:set enabledPreviewProviders 7 --value="OC\\Preview\\PDF"
    
    log_success "Nextcloud caching configured"
}
