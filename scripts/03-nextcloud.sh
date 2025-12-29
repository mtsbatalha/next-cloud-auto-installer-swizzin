#!/bin/bash
#===============================================================================
# 03-nextcloud.sh - Download and install Nextcloud
#===============================================================================

install_nextcloud() {
    log_info "Downloading Nextcloud..."
    
    # Create directories
    mkdir -p "${NEXTCLOUD_PATH}"
    mkdir -p "${DATA_PATH}"
    mkdir -p "${BACKUP_PATH}"
    
    # Download latest Nextcloud
    DOWNLOAD_URL="https://download.nextcloud.com/server/releases/latest.tar.bz2"
    wget -q "${DOWNLOAD_URL}" -O /tmp/nextcloud.tar.bz2
    wget -q "${DOWNLOAD_URL}.sha256" -O /tmp/nextcloud.tar.bz2.sha256
    
    # Verify download
    log_info "Verifying download integrity..."
    cd /tmp
    if ! sha256sum -c nextcloud.tar.bz2.sha256; then
        log_error "Download verification failed!"
        exit 1
    fi
    
    # Extract Nextcloud
    log_info "Extracting Nextcloud..."
    tar -xjf /tmp/nextcloud.tar.bz2 -C /var/www/
    rm /tmp/nextcloud.tar.bz2 /tmp/nextcloud.tar.bz2.sha256
    
    # Set permissions
    log_info "Setting permissions..."
    chown -R www-data:www-data "${NEXTCLOUD_PATH}"
    chown -R www-data:www-data "${DATA_PATH}"
    chmod -R 755 "${NEXTCLOUD_PATH}"
    chmod -R 750 "${DATA_PATH}"
    
    # Install Nextcloud via OCC
    log_info "Installing Nextcloud..."
    cd "${NEXTCLOUD_PATH}"
    
    sudo -u www-data php occ maintenance:install \
        --database "mysql" \
        --database-name "${DB_NAME}" \
        --database-user "${DB_USER}" \
        --database-pass "${DB_PASS}" \
        --admin-user "${ADMIN_USER}" \
        --admin-pass "${ADMIN_PASS}" \
        --admin-email "${ADMIN_EMAIL}" \
        --data-dir "${DATA_PATH}"
    
    # Configure trusted domains
    log_info "Configuring trusted domains..."
    sudo -u www-data php occ config:system:set trusted_domains 0 --value="localhost"
    sudo -u www-data php occ config:system:set trusted_domains 1 --value="${DOMAIN}"
    
    # Configure overwrite CLI URL
    sudo -u www-data php occ config:system:set overwrite.cli.url --value="https://${DOMAIN}"
    
    # Configure default phone region
    sudo -u www-data php occ config:system:set default_phone_region --value="BR"
    
    # Set maintenance window
    sudo -u www-data php occ config:system:set maintenance_window_start --type=integer --value=1
    
    # Configure logging
    sudo -u www-data php occ config:system:set loglevel --value=2 --type=integer
    sudo -u www-data php occ config:system:set log_type --value="file"
    sudo -u www-data php occ config:system:set logfile --value="${DATA_PATH}/nextcloud.log"
    sudo -u www-data php occ config:system:set log_rotate_size --value=104857600 --type=integer
    
    # Enable pretty URLs
    sudo -u www-data php occ config:system:set htaccess.RewriteBase --value="/"
    sudo -u www-data php occ maintenance:update:htaccess
    
    # Install recommended apps
    log_info "Installing recommended apps..."
    sudo -u www-data php occ app:install calendar || true
    sudo -u www-data php occ app:install contacts || true
    sudo -u www-data php occ app:install tasks || true
    sudo -u www-data php occ app:install notes || true
    sudo -u www-data php occ app:install deck || true
    sudo -u www-data php occ app:install photos || true
    sudo -u www-data php occ app:install talk || true
    
    # Enable apps
    sudo -u www-data php occ app:enable calendar || true
    sudo -u www-data php occ app:enable contacts || true
    sudo -u www-data php occ app:enable tasks || true
    sudo -u www-data php occ app:enable notes || true
    sudo -u www-data php occ app:enable deck || true
    sudo -u www-data php occ app:enable photos || true
    sudo -u www-data php occ app:enable talk || true
    
    log_success "Nextcloud installed successfully"
}
