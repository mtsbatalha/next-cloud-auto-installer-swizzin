#!/bin/bash
#===============================================================================
# 07-security.sh - Security hardening
#===============================================================================

configure_security() {
    log_info "Applying security hardening..."
    
    configure_fail2ban
    configure_firewall
    configure_permissions
    configure_php_security
    configure_cron
    
    log_success "Security hardening applied"
}

configure_fail2ban() {
    log_info "Configuring Fail2ban for Nextcloud..."
    
    # Create Nextcloud filter
    cat > /etc/fail2ban/filter.d/nextcloud.conf << 'EOF'
[Definition]
_groupsre = (?:(?:,?\s*"\w+":(?:"[^"]+"|\w+))*)
failregex = ^{"reqId":".*","level":2,"time":".*","remoteAddr":"<HOST>","user":".*","app":"core","method":".*","url":".*","message":"Login failed: .*}$
            ^{"reqId":".*","level":2,"time":".*","remoteAddr":"<HOST>","user":".*","app":"core","method":".*","url":".*","message":"Trusted domain error..*}$
            ^.*\"remoteAddr\":\"<HOST>\".*failed.*$
            ^.*\"remoteAddr\":\"<HOST>\".*Invalid credentials.*$
datepattern = ,?"time"\s*:\s*"%%Y-%%m-%%d[T ]%%H:%%M:%%S(%%z)?"
EOF

    # Create Nextcloud jail
    cat > /etc/fail2ban/jail.d/nextcloud.conf << EOF
[nextcloud]
enabled = true
backend = auto
port = ${HTTP_PORT},${HTTPS_PORT}
protocol = tcp
filter = nextcloud
maxretry = 5
bantime = 3600
findtime = 600
logpath = ${DATA_PATH}/nextcloud.log
EOF

    # Restart Fail2ban
    systemctl enable fail2ban
    systemctl restart fail2ban
    
    log_success "Fail2ban configured"
}

configure_firewall() {
    log_info "Configuring UFW firewall..."
    
    # Reset UFW to defaults
    ufw --force reset
    
    # Default policies
    ufw default deny incoming
    ufw default allow outgoing
    
    # Allow SSH
    ufw allow 22/tcp comment 'SSH'
    
    # Allow HTTP/HTTPS
    ufw allow ${HTTP_PORT}/tcp comment 'HTTP'
    ufw allow ${HTTPS_PORT}/tcp comment 'HTTPS'
    
    # Allow Office port if Docker is on different network
    if [[ "$OFFICE_SUITE" != "none" ]]; then
        ufw allow 9980/tcp comment 'Office Suite'
    fi
    
    # Enable UFW
    ufw --force enable
    
    log_success "Firewall configured"
}

configure_permissions() {
    log_info "Setting file permissions..."
    
    # Nextcloud directory permissions
    find "${NEXTCLOUD_PATH}" -type f -print0 | xargs -0 chmod 0640
    find "${NEXTCLOUD_PATH}" -type d -print0 | xargs -0 chmod 0750
    
    # Specific permissions
    chown -R www-data:www-data "${NEXTCLOUD_PATH}"
    chown -R www-data:www-data "${DATA_PATH}"
    
    # Config.php should be readable only by web server
    chmod 0600 "${NEXTCLOUD_PATH}/config/config.php"
    chown www-data:www-data "${NEXTCLOUD_PATH}/config/config.php"
    
    # .htaccess permissions
    if [[ -f "${NEXTCLOUD_PATH}/.htaccess" ]]; then
        chmod 0644 "${NEXTCLOUD_PATH}/.htaccess"
        chown www-data:www-data "${NEXTCLOUD_PATH}/.htaccess"
    fi
    
    # Data directory extra protection
    chmod 0750 "${DATA_PATH}"
    
    log_success "File permissions set"
}

configure_php_security() {
    log_info "Hardening PHP configuration..."
    
    PHP_INI="/etc/php/${PHP_VERSION}/fpm/php.ini"
    PHP_CLI_INI="/etc/php/${PHP_VERSION}/cli/php.ini"
    
    # Security settings for FPM
    cat > "/etc/php/${PHP_VERSION}/fpm/conf.d/99-security.ini" << EOF
; Security hardening for Nextcloud

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

; Error handling (don't expose errors)
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

; Open basedir restriction
; open_basedir = ${NEXTCLOUD_PATH}:${DATA_PATH}:/tmp:/var/tmp

; Disable URL fopen for remote files
allow_url_fopen = On
allow_url_include = Off
EOF

    # Restart PHP-FPM
    systemctl restart php${PHP_VERSION}-fpm
    
    log_success "PHP security configured"
}

configure_cron() {
    log_info "Configuring Nextcloud cron job..."
    
    # Disable AJAX cron
    cd "${NEXTCLOUD_PATH}"
    sudo -u www-data php occ background:cron
    
    # Create system cron job
    cat > /etc/cron.d/nextcloud << EOF
# Nextcloud background jobs
*/5 * * * * www-data php -f ${NEXTCLOUD_PATH}/cron.php
EOF
    
    # Reload cron
    systemctl reload cron 2>/dev/null || systemctl reload crond 2>/dev/null || true
    
    log_success "Cron job configured"
}
