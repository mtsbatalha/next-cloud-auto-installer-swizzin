#!/bin/bash
#===============================================================================
# 06-office.sh - Install Collabora Online or OnlyOffice
#===============================================================================

install_office() {
    if [[ "$OFFICE_SUITE" == "collabora" ]]; then
        install_collabora
    elif [[ "$OFFICE_SUITE" == "onlyoffice" ]]; then
        install_onlyoffice
    fi
}

install_collabora() {
    log_info "Installing Collabora Online..."
    
    # Pull Collabora CODE Docker image
    docker pull collabora/code:latest
    
    # Create Docker network if not exists
    docker network create nextcloud-office 2>/dev/null || true
    
    # Run Collabora container
    docker run -d \
        --name collabora \
        --restart always \
        --network nextcloud-office \
        -p 9980:9980 \
        -e "aliasgroup1=https://${DOMAIN}:443" \
        -e "username=admin" \
        -e "password=${REDIS_PASS}" \
        -e "extra_params=--o:ssl.enable=false --o:ssl.termination=true" \
        --cap-add MKNOD \
        collabora/code
    
    # Wait for container to start
    sleep 10
    
    # Configure reverse proxy for Collabora
    if [[ "$WEBSERVER" == "apache" ]]; then
        configure_collabora_apache
    else
        configure_collabora_nginx
    fi
    
    # Install Nextcloud Office app
    log_info "Installing Nextcloud Office app..."
    cd "${NEXTCLOUD_PATH}"
    sudo -u www-data php occ app:install richdocuments || true
    sudo -u www-data php occ app:enable richdocuments
    
    # Configure Nextcloud Office
    sudo -u www-data php occ config:app:set richdocuments wopi_url --value="https://${OFFICE_DOMAIN}"
    sudo -u www-data php occ config:app:set richdocuments public_wopi_url --value="https://${OFFICE_DOMAIN}"
    
    log_success "Collabora Online installed successfully"
}

configure_collabora_apache() {
    cat > /etc/apache2/sites-available/collabora.conf << EOF
<VirtualHost *:80>
    ServerName ${OFFICE_DOMAIN}
    
    # Redirect to HTTPS
    Redirect permanent / https://${OFFICE_DOMAIN}/
</VirtualHost>

<VirtualHost *:443>
    ServerName ${OFFICE_DOMAIN}

    # SSL will be configured by Certbot
    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/${OFFICE_DOMAIN}/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/${OFFICE_DOMAIN}/privkey.pem

    # Proxy settings
    SSLProxyEngine On
    SSLProxyVerify None
    SSLProxyCheckPeerCN Off
    SSLProxyCheckPeerName Off

    # Static files
    ProxyPass /browser https://127.0.0.1:9980/browser retry=0
    ProxyPassReverse /browser https://127.0.0.1:9980/browser

    # WOPI discovery URL
    ProxyPass /hosting/discovery https://127.0.0.1:9980/hosting/discovery retry=0
    ProxyPassReverse /hosting/discovery https://127.0.0.1:9980/hosting/discovery

    # Main entry point
    ProxyPass /hosting/capabilities https://127.0.0.1:9980/hosting/capabilities retry=0
    ProxyPassReverse /hosting/capabilities https://127.0.0.1:9980/hosting/capabilities

    # Capabilities
    ProxyPass /cool https://127.0.0.1:9980/cool retry=0
    ProxyPassReverse /cool https://127.0.0.1:9980/cool

    # WebSocket
    ProxyPass /cool/adminws wss://127.0.0.1:9980/cool/adminws retry=0
    ProxyPassReverse /cool/adminws wss://127.0.0.1:9980/cool/adminws

    # Download, presentation and image upload
    ProxyPass /cool https://127.0.0.1:9980/cool
    ProxyPassReverse /cool https://127.0.0.1:9980/cool

    # Loleaflet
    ProxyPass /loleaflet https://127.0.0.1:9980/loleaflet retry=0
    ProxyPassReverse /loleaflet https://127.0.0.1:9980/loleaflet

    # Security Headers
    Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"

    ErrorLog \${APACHE_LOG_DIR}/collabora-error.log
    CustomLog \${APACHE_LOG_DIR}/collabora-access.log combined
</VirtualHost>
EOF

    a2ensite collabora.conf
    systemctl reload apache2
}

configure_collabora_nginx() {
    cat > /etc/nginx/sites-available/collabora << EOF
server {
    listen 80;
    server_name ${OFFICE_DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${OFFICE_DOMAIN};

    # SSL will be configured by Certbot
    ssl_certificate /etc/letsencrypt/live/${OFFICE_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${OFFICE_DOMAIN}/privkey.pem;

    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    # Static files
    location ^~ /browser {
        proxy_pass http://127.0.0.1:9980;
        proxy_set_header Host \$http_host;
    }

    # WOPI discovery URL
    location ^~ /hosting/discovery {
        proxy_pass http://127.0.0.1:9980;
        proxy_set_header Host \$http_host;
    }

    location ^~ /hosting/capabilities {
        proxy_pass http://127.0.0.1:9980;
        proxy_set_header Host \$http_host;
    }

    # Main WebSocket
    location ~ ^/cool/(.*)/ws$ {
        proxy_pass http://127.0.0.1:9980;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_set_header Host \$http_host;
        proxy_read_timeout 36000s;
    }

    # Download, presentation and image upload
    location ~ ^/(c|l)ool {
        proxy_pass http://127.0.0.1:9980;
        proxy_set_header Host \$http_host;
    }

    # Admin console websocket
    location ^~ /cool/adminws {
        proxy_pass http://127.0.0.1:9980;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_set_header Host \$http_host;
        proxy_read_timeout 36000s;
    }
}
EOF

    ln -sf /etc/nginx/sites-available/collabora /etc/nginx/sites-enabled/
    nginx -t && systemctl reload nginx
}

install_onlyoffice() {
    log_info "Installing OnlyOffice Document Server..."
    
    # Generate JWT secret
    ONLYOFFICE_JWT_SECRET=$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-32)
    
    # Pull OnlyOffice Docker image
    docker pull onlyoffice/documentserver:latest
    
    # Create data directories
    mkdir -p /var/lib/onlyoffice/data
    mkdir -p /var/lib/onlyoffice/logs
    mkdir -p /var/lib/onlyoffice/fonts
    
    # Run OnlyOffice container
    docker run -d \
        --name onlyoffice \
        --restart always \
        -p 9980:80 \
        -v /var/lib/onlyoffice/data:/var/www/onlyoffice/Data \
        -v /var/lib/onlyoffice/logs:/var/log/onlyoffice \
        -v /var/lib/onlyoffice/fonts:/usr/share/fonts/truetype/custom \
        -e JWT_ENABLED=true \
        -e JWT_SECRET="${ONLYOFFICE_JWT_SECRET}" \
        onlyoffice/documentserver
    
    # Wait for container to start
    sleep 15
    
    # Configure reverse proxy
    if [[ "$WEBSERVER" == "apache" ]]; then
        configure_onlyoffice_apache
    else
        configure_onlyoffice_nginx
    fi
    
    # Install OnlyOffice app in Nextcloud
    log_info "Installing OnlyOffice app..."
    cd "${NEXTCLOUD_PATH}"
    sudo -u www-data php occ app:install onlyoffice || true
    sudo -u www-data php occ app:enable onlyoffice
    
    # Configure OnlyOffice app
    sudo -u www-data php occ config:app:set onlyoffice DocumentServerUrl --value="https://${OFFICE_DOMAIN}/"
    sudo -u www-data php occ config:app:set onlyoffice jwt_secret --value="${ONLYOFFICE_JWT_SECRET}"
    sudo -u www-data php occ config:app:set onlyoffice jwt_header --value="Authorization"
    
    # Save JWT secret to config file
    echo "ONLYOFFICE_JWT_SECRET=\"${ONLYOFFICE_JWT_SECRET}\"" >> "${SCRIPT_DIR}/.install-config"
    
    log_success "OnlyOffice installed successfully"
}

configure_onlyoffice_apache() {
    cat > /etc/apache2/sites-available/onlyoffice.conf << EOF
<VirtualHost *:80>
    ServerName ${OFFICE_DOMAIN}
    Redirect permanent / https://${OFFICE_DOMAIN}/
</VirtualHost>

<VirtualHost *:443>
    ServerName ${OFFICE_DOMAIN}

    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/${OFFICE_DOMAIN}/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/${OFFICE_DOMAIN}/privkey.pem

    SSLProxyEngine On
    SSLProxyVerify None
    SSLProxyCheckPeerCN Off
    SSLProxyCheckPeerName Off

    # Proxy to OnlyOffice
    ProxyPreserveHost On
    ProxyPass / http://127.0.0.1:9980/
    ProxyPassReverse / http://127.0.0.1:9980/

    # WebSocket
    RewriteEngine on
    RewriteCond %{HTTP:Upgrade} websocket [NC]
    RewriteCond %{HTTP:Connection} upgrade [NC]
    RewriteRule ^/?(.*) "ws://127.0.0.1:9980/\$1" [P,L]

    # Security Headers  
    Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"

    ErrorLog \${APACHE_LOG_DIR}/onlyoffice-error.log
    CustomLog \${APACHE_LOG_DIR}/onlyoffice-access.log combined
</VirtualHost>
EOF

    a2ensite onlyoffice.conf
    systemctl reload apache2
}

configure_onlyoffice_nginx() {
    cat > /etc/nginx/sites-available/onlyoffice << EOF
server {
    listen 80;
    server_name ${OFFICE_DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${OFFICE_DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${OFFICE_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${OFFICE_DOMAIN}/privkey.pem;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    location / {
        proxy_pass http://127.0.0.1:9980;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 36000s;
    }
}
EOF

    ln -sf /etc/nginx/sites-available/onlyoffice /etc/nginx/sites-enabled/
    nginx -t && systemctl reload nginx
}
