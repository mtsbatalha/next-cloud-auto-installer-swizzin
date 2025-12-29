#!/bin/bash
#===============================================================================
# 05-ssl.sh - Configure SSL with Let's Encrypt
#===============================================================================

configure_ssl() {
    log_info "Configuring SSL certificate..."
    
    # Check if domain resolves to this server
    SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null)
    DOMAIN_IP=$(dig +short "${DOMAIN}" | head -n1)
    
    if [[ "$SERVER_IP" != "$DOMAIN_IP" ]]; then
        log_warning "Domain ${DOMAIN} does not resolve to this server's IP (${SERVER_IP})"
        log_warning "Please ensure DNS is configured correctly"
        log_info "Continuing with SSL setup..."
    fi
    
    # Obtain SSL certificate
    if [[ "$WEBSERVER" == "apache" ]]; then
        log_info "Obtaining SSL certificate for Apache..."
        certbot --apache \
            --non-interactive \
            --agree-tos \
            --email "${ADMIN_EMAIL}" \
            --domains "${DOMAIN}" \
            --redirect
    else
        log_info "Obtaining SSL certificate for Nginx..."
        certbot --nginx \
            --non-interactive \
            --agree-tos \
            --email "${ADMIN_EMAIL}" \
            --domains "${DOMAIN}" \
            --redirect
    fi
    
    # Configure SSL for Office subdomain if enabled
    if [[ "$OFFICE_SUITE" != "none" && -n "$OFFICE_DOMAIN" ]]; then
        log_info "Obtaining SSL certificate for Office domain..."
        if [[ "$WEBSERVER" == "apache" ]]; then
            certbot --apache \
                --non-interactive \
                --agree-tos \
                --email "${ADMIN_EMAIL}" \
                --domains "${OFFICE_DOMAIN}" \
                --redirect || log_warning "Could not obtain SSL for ${OFFICE_DOMAIN}"
        else
            certbot --nginx \
                --non-interactive \
                --agree-tos \
                --email "${ADMIN_EMAIL}" \
                --domains "${OFFICE_DOMAIN}" \
                --redirect || log_warning "Could not obtain SSL for ${OFFICE_DOMAIN}"
        fi
    fi
    
    # Configure SSL settings for security
    configure_ssl_security
    
    # Setup auto-renewal cron job
    log_info "Setting up automatic certificate renewal..."
    cat > /etc/cron.d/certbot-renewal << EOF
# Automatic Let's Encrypt certificate renewal
0 3 * * * root certbot renew --quiet --post-hook "systemctl reload ${WEBSERVER}"
EOF
    
    # Test renewal
    certbot renew --dry-run
    
    log_success "SSL certificates configured successfully"
}

configure_ssl_security() {
    log_info "Hardening SSL configuration..."
    
    if [[ "$WEBSERVER" == "apache" ]]; then
        # Apache SSL hardening
        cat > /etc/apache2/conf-available/ssl-hardening.conf << 'EOF'
# SSL Hardening Configuration

<IfModule mod_ssl.c>
    # Disable SSLv2 and SSLv3
    SSLProtocol all -SSLv2 -SSLv3 -TLSv1 -TLSv1.1
    
    # Use strong cipher suites
    SSLCipherSuite ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384
    SSLHonorCipherOrder off
    
    # Enable OCSP Stapling
    SSLUseStapling on
    SSLStaplingCache "shmcb:logs/stapling-cache(150000)"
    
    # Enable session tickets
    SSLSessionTickets off
    
    # Compression (disabled for security)
    SSLCompression off
</IfModule>
EOF
        a2enconf ssl-hardening
        systemctl reload apache2
        
    else
        # Nginx SSL hardening
        cat > /etc/nginx/conf.d/ssl-hardening.conf << 'EOF'
# SSL Hardening Configuration

# SSL protocols
ssl_protocols TLSv1.2 TLSv1.3;

# Cipher suites
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
ssl_prefer_server_ciphers off;

# SSL session
ssl_session_timeout 1d;
ssl_session_cache shared:SSL:50m;
ssl_session_tickets off;

# OCSP Stapling
ssl_stapling on;
ssl_stapling_verify on;

# DH parameters
# ssl_dhparam /etc/nginx/dhparam.pem;

# Resolver
resolver 8.8.8.8 8.8.4.4 valid=300s;
resolver_timeout 5s;
EOF
        
        # Generate DH parameters (optional, takes time)
        # openssl dhparam -out /etc/nginx/dhparam.pem 2048
        
        nginx -t && systemctl reload nginx
    fi
    
    log_success "SSL hardening applied"
}
