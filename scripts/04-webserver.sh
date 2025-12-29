#!/bin/bash
#===============================================================================
# 04-webserver.sh - Configure Apache or Nginx
#===============================================================================

configure_webserver() {
    if [[ "$WEBSERVER" == "apache" ]]; then
        configure_apache
    else
        configure_nginx
    fi
}

configure_apache() {
    log_info "Configuring Apache for Nextcloud..."
    
    # Disable default site
    a2dissite 000-default.conf 2>/dev/null || true
    
    # Create Nextcloud virtual host
    cat > /etc/apache2/sites-available/nextcloud.conf << 'EOF'
<VirtualHost *:80>
    ServerName DOMAIN_PLACEHOLDER
    DocumentRoot NEXTCLOUD_PATH_PLACEHOLDER

    <Directory NEXTCLOUD_PATH_PLACEHOLDER>
        Require all granted
        AllowOverride All
        Options FollowSymLinks MultiViews

        <IfModule mod_dav.c>
            Dav off
        </IfModule>

        SetEnv HOME NEXTCLOUD_PATH_PLACEHOLDER
        SetEnv HTTP_HOME NEXTCLOUD_PATH_PLACEHOLDER
    </Directory>

    # Security Headers
    Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-XSS-Protection "1; mode=block"
    Header always set X-Robots-Tag "noindex, nofollow"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set Referrer-Policy "no-referrer-when-downgrade"
    Header always set Permissions-Policy "geolocation=(), microphone=(), camera=()"

    # Logging
    ErrorLog ${APACHE_LOG_DIR}/nextcloud-error.log
    CustomLog ${APACHE_LOG_DIR}/nextcloud-access.log combined
</VirtualHost>
EOF

    # Replace placeholders
    sed -i "s|DOMAIN_PLACEHOLDER|${DOMAIN}|g" /etc/apache2/sites-available/nextcloud.conf
    sed -i "s|NEXTCLOUD_PATH_PLACEHOLDER|${NEXTCLOUD_PATH}|g" /etc/apache2/sites-available/nextcloud.conf
    
    # Enable required modules
    a2enmod rewrite
    a2enmod headers
    a2enmod env
    a2enmod dir
    a2enmod mime
    a2enmod ssl
    a2enmod http2
    a2enmod proxy
    a2enmod proxy_http
    a2enmod proxy_wstunnel
    
    # Enable site
    a2ensite nextcloud.conf
    
    # Configure PHP-FPM with Apache
    a2enmod proxy_fcgi setenvif
    a2enconf php${PHP_VERSION}-fpm
    
    # Apache performance tuning
    cat > /etc/apache2/conf-available/nextcloud-tuning.conf << EOF
# Nextcloud performance tuning

# Enable HTTP/2
Protocols h2 h2c http/1.1

# Timeout settings
Timeout 300
KeepAlive On
MaxKeepAliveRequests 100
KeepAliveTimeout 5

# MPM settings (for prefork)
<IfModule mpm_prefork_module>
    StartServers 5
    MinSpareServers 5
    MaxSpareServers 10
    MaxRequestWorkers 150
    MaxConnectionsPerChild 0
</IfModule>

# MPM settings (for event)
<IfModule mpm_event_module>
    StartServers 2
    MinSpareThreads 25
    MaxSpareThreads 75
    ThreadLimit 64
    ThreadsPerChild 25
    MaxRequestWorkers 150
    MaxConnectionsPerChild 0
</IfModule>

# Compression
<IfModule mod_deflate.c>
    AddOutputFilterByType DEFLATE text/html text/plain text/xml text/css text/javascript application/javascript application/json
</IfModule>

# Caching
<IfModule mod_expires.c>
    ExpiresActive On
    ExpiresByType image/jpg "access plus 1 month"
    ExpiresByType image/jpeg "access plus 1 month"
    ExpiresByType image/gif "access plus 1 month"
    ExpiresByType image/png "access plus 1 month"
    ExpiresByType image/svg+xml "access plus 1 month"
    ExpiresByType text/css "access plus 1 month"
    ExpiresByType application/javascript "access plus 1 month"
</IfModule>
EOF

    a2enconf nextcloud-tuning
    
    # Test configuration
    apache2ctl configtest
    
    # Restart Apache
    systemctl restart apache2
    
    log_success "Apache configured successfully"
}

configure_nginx() {
    log_info "Configuring Nginx for Nextcloud..."
    
    # Remove default site
    rm -f /etc/nginx/sites-enabled/default
    
    # Create Nextcloud server block
    cat > /etc/nginx/sites-available/nextcloud << 'NGINX_EOF'
upstream php-handler {
    server unix:/var/run/php/phpPHP_VERSION_PLACEHOLDER-fpm.sock;
}

# Rate limiting
limit_req_zone $binary_remote_addr zone=nextcloud_rate:10m rate=10r/s;

server {
    listen 80;
    listen [::]:80;
    server_name DOMAIN_PLACEHOLDER;

    # Enforce HTTPS
    return 301 https://$server_name$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name DOMAIN_PLACEHOLDER;

    # SSL will be configured by Certbot
    # ssl_certificate /etc/letsencrypt/live/DOMAIN_PLACEHOLDER/fullchain.pem;
    # ssl_certificate_key /etc/letsencrypt/live/DOMAIN_PLACEHOLDER/privkey.pem;

    root NEXTCLOUD_PATH_PLACEHOLDER;

    # Security Headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Robots-Tag "noindex, nofollow" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;
    add_header X-Download-Options "noopen" always;
    add_header X-Permitted-Cross-Domain-Policies "none" always;

    # Rate limiting
    limit_req zone=nextcloud_rate burst=20 nodelay;

    # Logging
    access_log /var/log/nginx/nextcloud-access.log;
    error_log /var/log/nginx/nextcloud-error.log;

    # File size limits
    client_max_body_size 16G;
    client_body_timeout 300s;
    fastcgi_buffers 64 4K;

    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_comp_level 4;
    gzip_min_length 256;
    gzip_proxied expired no-cache no-store private no_last_modified no_etag auth;
    gzip_types application/atom+xml application/javascript application/json application/ld+json application/manifest+json application/rss+xml application/vnd.geo+json application/vnd.ms-fontobject application/wasm application/x-font-ttf application/x-web-app-manifest+json application/xhtml+xml application/xml font/opentype image/bmp image/svg+xml image/x-icon text/cache-manifest text/css text/plain text/vcard text/vnd.rim.location.xloc text/vtt text/x-component text/x-cross-domain-policy;

    # Pagespeed disabled
    pagespeed off;

    # HTTP response headers for static content
    location = /robots.txt {
        allow all;
        log_not_found off;
        access_log off;
    }

    # The following 2 rules are only needed for the user_webfinger app
    location ^~ /.well-known/webfinger {
        return 301 $scheme://$host/index.php/.well-known/webfinger;
    }
    location ^~ /.well-known/nodeinfo {
        return 301 $scheme://$host/index.php/.well-known/nodeinfo;
    }

    location = /.well-known/carddav {
        return 301 $scheme://$host/remote.php/dav;
    }
    location = /.well-known/caldav {
        return 301 $scheme://$host/remote.php/dav;
    }

    location /.well-known/acme-challenge {
        try_files $uri $uri/ =404;
    }

    # Set max upload size and increase upload timeout
    client_body_buffer_size 512k;

    # Deny access to sensitive directories
    location ~ ^/(?:build|tests|config|lib|3rdparty|templates|data)(?:$|/) {
        return 404;
    }
    location ~ ^/(?:\.|autotest|occ|issue|indie|db_|console) {
        return 404;
    }

    # Cache static files
    location ~* \.(?:css|js|woff2?|svg|gif|map|png|html|ttf|ico|jpg|jpeg|bcmap|mp4|webm)$ {
        try_files $uri /index.php$request_uri;
        add_header Cache-Control "public, max-age=15778463, immutable";
        access_log off;
    }

    location ~ \.php(?:$|/) {
        # Required for legacy support
        rewrite ^/(?!index|remote|public|cron|core\/ajax\/update|status|ocs\/v[12]|updater\/.+|ocs-provider\/.+|.+\/richdocumentscode\/proxy) /index.php$request_uri;

        fastcgi_split_path_info ^(.+?\.php)(/.*)$;
        set $path_info $fastcgi_path_info;

        try_files $fastcgi_script_name =404;

        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param PATH_INFO $path_info;
        fastcgi_param HTTPS on;
        fastcgi_param modHeadersAvailable true;
        fastcgi_param front_controller_active true;

        fastcgi_pass php-handler;

        fastcgi_intercept_errors on;
        fastcgi_request_buffering off;

        fastcgi_read_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_connect_timeout 300;
    }

    location ~ \.(?:css|js|svg|gif|png|html|ttf|woff2?|ico|jpg|jpeg|mp4|webm)$ {
        try_files $uri /index.php$request_uri;
        access_log off;
    }

    location ~ \.woff2?$ {
        try_files $uri /index.php$request_uri;
        expires 7d;
        access_log off;
    }

    location / {
        rewrite ^ /index.php;
    }
}
NGINX_EOF

    # Replace placeholders
    sed -i "s|DOMAIN_PLACEHOLDER|${DOMAIN}|g" /etc/nginx/sites-available/nextcloud
    sed -i "s|NEXTCLOUD_PATH_PLACEHOLDER|${NEXTCLOUD_PATH}|g" /etc/nginx/sites-available/nextcloud
    sed -i "s|PHP_VERSION_PLACEHOLDER|${PHP_VERSION}|g" /etc/nginx/sites-available/nextcloud
    
    # Enable site
    ln -sf /etc/nginx/sites-available/nextcloud /etc/nginx/sites-enabled/
    
    # Nginx performance tuning
    cat > /etc/nginx/conf.d/nextcloud-tuning.conf << EOF
# Nextcloud performance tuning

# Note: worker_rlimit_nofile and events must be configured in main nginx.conf

# Buffer sizes
proxy_buffer_size 128k;
proxy_buffers 4 256k;
proxy_busy_buffers_size 256k;

# Timeouts
proxy_connect_timeout 300;
proxy_send_timeout 300;
proxy_read_timeout 300;
send_timeout 300;

# File descriptor cache
open_file_cache max=200000 inactive=20s;
open_file_cache_valid 30s;
open_file_cache_min_uses 2;
open_file_cache_errors on;
EOF

    # Test configuration
    nginx -t
    
    # Restart Nginx
    systemctl restart nginx
    
    log_success "Nginx configured successfully"
}
