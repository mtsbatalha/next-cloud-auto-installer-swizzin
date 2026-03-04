#!/bin/bash
#===============================================================================
# fix-nginx.sh - Apply Official Nextcloud Nginx Configuration
# Based on: https://docs.nextcloud.com/server/latest/admin_manual/installation/nginx.html
# Version: 2025-07-23 (from official docs)
#===============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

NGINX_CONF="/etc/nginx/sites-available/nextcloud"
# Auto-detect Nextcloud path
NEXTCLOUD_PATH=""
for _p in /var/www/nextcloud /srv/nextcloud /var/www/html/nextcloud /opt/nextcloud; do
    if [[ -f "${_p}/occ" ]]; then
        NEXTCLOUD_PATH="$_p"
        break
    fi
done
NEXTCLOUD_PATH="${NEXTCLOUD_PATH:-/var/www/nextcloud}"

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    log_error "Run as root: sudo bash $0"
    exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Official Nextcloud Nginx Configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Backup existing config
if [[ -f "$NGINX_CONF" ]]; then
    log_info "Creating backup..."
    cp "$NGINX_CONF" "${NGINX_CONF}.bak.$(date +%Y%m%d%H%M%S)"
fi

# Detect configuration
log_info "Detecting configuration..."

# Get from existing config or .install-config
[[ -f ".install-config" ]] && source .install-config
[[ -f "../.install-config" ]] && source ../.install-config

# Extract from existing nginx config if needed
if [[ -f "$NGINX_CONF" ]]; then
    [[ -z "$DOMAIN" ]] && DOMAIN=$(grep -m1 "server_name" "$NGINX_CONF" | awk '{print $2}' | tr -d ';')
    [[ -z "$NEXTCLOUD_PATH" ]] && NEXTCLOUD_PATH=$(grep -m1 "root" "$NGINX_CONF" | awk '{print $2}' | tr -d ';')
fi

# Detect PHP version
PHP_VERSION=$(php -v 2>/dev/null | head -1 | grep -oP '[0-9]+\.[0-9]+' || echo "8.2")

# Check for SSL
SSL_CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
SSL_KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"

if [[ -z "$DOMAIN" ]]; then
    read -p "Enter your domain: " DOMAIN
fi

if [[ -z "$NEXTCLOUD_PATH" || ! -d "$NEXTCLOUD_PATH" ]]; then
    NEXTCLOUD_PATH="/var/www/nextcloud"
fi

log_info "Domain: $DOMAIN"
log_info "Path: $NEXTCLOUD_PATH"
log_info "PHP: $PHP_VERSION"

HAS_SSL=false
if [[ -f "$SSL_CERT" && -f "$SSL_KEY" ]]; then
    HAS_SSL=true
    log_info "SSL: Found (Let's Encrypt)"
else
    log_warning "SSL: Not found - configuring HTTP only"
fi

log_info "Writing official Nextcloud Nginx configuration..."

# Write the official Nextcloud configuration
cat > "$NGINX_CONF" << 'NGINXEOF'
# Nextcloud Official Nginx Configuration
# Based on: https://docs.nextcloud.com/server/latest/admin_manual/installation/nginx.html
# Version 2025-07-23

upstream php-handler {
    server unix:/run/php/phpPHP_VERSION_PLACEHOLDER-fpm.sock;
}

# Set the `immutable` cache control options only for assets with a cache busting `v` argument
map $arg_v $asset_immutable {
    "" "";
    default ", immutable";
}

server {
    listen 80;
    listen [::]:80;
    server_name DOMAIN_PLACEHOLDER;

    # Prevent nginx HTTP Server Detection
    server_tokens off;

    # Enforce HTTPS
    return 301 https://$server_name$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name DOMAIN_PLACEHOLDER;

    # Path to the root of your installation
    root NEXTCLOUD_PATH_PLACEHOLDER;

    # SSL Configuration
    ssl_certificate SSL_CERT_PLACEHOLDER;
    ssl_certificate_key SSL_KEY_PLACEHOLDER;

    # Prevent nginx HTTP Server Detection
    server_tokens off;

    # HSTS settings
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;

    # set max upload size and increase upload timeout:
    client_max_body_size 512M;
    client_body_timeout 300s;
    fastcgi_buffers 64 4K;

    # Enable gzip but do not remove ETag headers
    gzip on;
    gzip_vary on;
    gzip_comp_level 4;
    gzip_min_length 256;
    gzip_proxied expired no-cache no-store private no_last_modified no_etag auth;
    gzip_types application/atom+xml text/javascript application/javascript application/json application/ld+json application/manifest+json application/rss+xml application/vnd.geo+json application/vnd.ms-fontobject application/wasm application/x-font-ttf application/x-web-app-manifest+json application/xhtml+xml application/xml font/opentype image/bmp image/svg+xml image/x-icon text/cache-manifest text/css text/plain text/vcard text/vnd.rim.location.xloc text/vtt text/x-component text/x-cross-domain-policy;

    # The settings allows you to optimize the HTTP2 bandwidth.
    client_body_buffer_size 512k;

    # HTTP response headers borrowed from Nextcloud `.htaccess`
    add_header Referrer-Policy "no-referrer" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Permitted-Cross-Domain-Policies "none" always;
    add_header X-Robots-Tag "noindex, nofollow" always;

    # Remove X-Powered-By, which is an information leak
    fastcgi_hide_header X-Powered-By;

    # Set .mjs and .wasm MIME types
    include mime.types;
    types {
        text/javascript mjs;
        application/wasm wasm;
    }

    # Specify how to handle directories -- specifying `/index.php$request_uri`
    # here as the fallback means that Nginx always exhibits the desired behaviour
    # when a client requests a path that corresponds to a directory that exists
    # on the server.
    index index.php index.html /index.php$request_uri;

    # Rule borrowed from `.htaccess` to handle Microsoft DAV clients
    location = / {
        if ( $http_user_agent ~ ^DavClnt ) {
            return 302 /remote.php/webdav/$is_args$args;
        }
    }

    location = /robots.txt {
        allow all;
        log_not_found off;
        access_log off;
    }

    # Make a regex exception for `/.well-known` so that clients can still
    # access it despite the existence of the regex rule
    # `location ~ /(\.|autotest|...)` which would otherwise handle requests
    # for `/.well-known`.
    location ^~ /.well-known {
        # The rules in this block are an adaptation of the rules
        # in `.htaccess` that concern `/.well-known`.

        location = /.well-known/carddav { return 301 /remote.php/dav/; }
        location = /.well-known/caldav  { return 301 /remote.php/dav/; }

        location /.well-known/acme-challenge { try_files $uri $uri/ =404; }
        location /.well-known/pki-validation { try_files $uri $uri/ =404; }

        # Let Nextcloud's API for `/.well-known` URIs handle all other
        # requests by passing them to the front-end controller.
        return 301 /index.php$request_uri;
    }

    # Rules borrowed from `.htaccess` to hide certain paths from clients
    location ~ ^/(?:build|tests|config|lib|3rdparty|templates|data)(?:$|/)  { return 404; }
    location ~ ^/(?:\.|autotest|occ|issue|indie|db_|console)                { return 404; }

    # Ensure this block, which passes PHP files to the PHP process, is above the blocks
    # which handle static assets (as seen below). If this block is not declared first,
    # then Nginx will encounter an infinite rewriting loop when it prepends `/index.php`
    # to the URI, resulting in a HTTP 500 error response.
    location ~ \.php(?:$|/) {
        # Required for legacy support
        rewrite ^/(?!index|remote|public|cron|core\/ajax\/update|status|ocs\/v[12]|updater\/.+|ocs-provider\/.+|.+\/richdocumentscode(_arm64)?\/proxy) /index.php$request_uri;

        fastcgi_split_path_info ^(.+?\.php)(/.*)$;
        set $path_info $fastcgi_path_info;

        try_files $fastcgi_script_name =404;

        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param PATH_INFO $path_info;
        fastcgi_param HTTPS on;

        fastcgi_param modHeadersAvailable true;         # Avoid sending the security headers twice
        fastcgi_param front_controller_active true;     # Enable pretty urls
        fastcgi_pass php-handler;

        fastcgi_intercept_errors on;
        fastcgi_request_buffering on;

        fastcgi_max_temp_file_size 0;
    }

    # Serve static files
    location ~ \.(?:css|js|mjs|svg|gif|ico|jpg|png|webp|wasm|tflite|map|ogg|flac)$ {
        try_files $uri /index.php$request_uri;
        # HTTP response headers borrowed from Nextcloud `.htaccess`
        add_header Cache-Control "public, max-age=15778463$asset_immutable";
        add_header Referrer-Policy "no-referrer" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Permitted-Cross-Domain-Policies "none" always;
        add_header X-Robots-Tag "noindex, nofollow" always;
        access_log off;     # Optional: Don't log access to assets
    }

    location ~ \.(otf|woff2?)$ {
        try_files $uri /index.php$request_uri;
        expires 7d;         # Cache-Control policy borrowed from `.htaccess`
        access_log off;     # Optional: Don't log access to assets
    }

    # Rule borrowed from `.htaccess`
    location /remote {
        return 301 /remote.php$request_uri;
    }

    location / {
        try_files $uri $uri/ /index.php$request_uri;
    }
}
NGINXEOF

# Replace placeholders
sed -i "s|DOMAIN_PLACEHOLDER|${DOMAIN}|g" "$NGINX_CONF"
sed -i "s|NEXTCLOUD_PATH_PLACEHOLDER|${NEXTCLOUD_PATH}|g" "$NGINX_CONF"
sed -i "s|PHP_VERSION_PLACEHOLDER|${PHP_VERSION}|g" "$NGINX_CONF"

if [[ "$HAS_SSL" == "true" ]]; then
    sed -i "s|SSL_CERT_PLACEHOLDER|${SSL_CERT}|g" "$NGINX_CONF"
    sed -i "s|SSL_KEY_PLACEHOLDER|${SSL_KEY}|g" "$NGINX_CONF"
else
    # Remove SSL server block if no SSL
    log_warning "No SSL certificates found. You need to run certbot after this."
    # For now, create a self-signed cert placeholder
    sed -i "s|SSL_CERT_PLACEHOLDER|/etc/ssl/certs/ssl-cert-snakeoil.pem|g" "$NGINX_CONF"
    sed -i "s|SSL_KEY_PLACEHOLDER|/etc/ssl/private/ssl-cert-snakeoil.key|g" "$NGINX_CONF"
fi

# Enable the site
ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/nextcloud

# Test configuration
log_info "Testing Nginx configuration..."
if nginx -t 2>&1; then
    log_success "Nginx configuration is valid"
else
    log_error "Nginx configuration test failed!"
    log_info "Restoring backup..."
    LATEST_BACKUP=$(ls -t ${NGINX_CONF}.bak.* 2>/dev/null | head -1)
    if [[ -n "$LATEST_BACKUP" ]]; then
        cp "$LATEST_BACKUP" "$NGINX_CONF"
    fi
    exit 1
fi

# Restart services
log_info "Restarting Nginx..."
systemctl restart nginx

log_info "Restarting PHP-FPM..."
systemctl restart "php${PHP_VERSION}-fpm" 2>/dev/null || true

# Fix Nextcloud configuration
log_info "Configuring Nextcloud..."
cd "$NEXTCLOUD_PATH"

# Ensure proper permissions
chown -R www-data:www-data "$NEXTCLOUD_PATH"

# Configure Nextcloud for HTTPS
sudo -u www-data php occ config:system:set overwrite.cli.url --value="https://$DOMAIN" 2>/dev/null || true
sudo -u www-data php occ config:system:set overwriteprotocol --value="https" 2>/dev/null || true

# Add domain to trusted_domains if not present
TRUSTED_COUNT=$(sudo -u www-data php occ config:system:get trusted_domains 2>/dev/null | wc -l || echo "0")
sudo -u www-data php occ config:system:set trusted_domains $TRUSTED_COUNT --value="$DOMAIN" 2>/dev/null || true

# Disable maintenance mode
sudo -u www-data php occ maintenance:mode --off 2>/dev/null || true

# Run maintenance tasks
sudo -u www-data php occ maintenance:repair 2>/dev/null || true
sudo -u www-data php occ maintenance:update:htaccess 2>/dev/null || true

log_success "Configuration complete!"

# Test access
echo ""
log_info "Testing access..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -k "https://localhost/" --max-time 10 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "302" || "$HTTP_CODE" == "303" ]]; then
    log_success "Localhost test: HTTP $HTTP_CODE"
else
    log_warning "Localhost test: HTTP $HTTP_CODE"
fi

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -k "https://$DOMAIN/" --max-time 10 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "302" || "$HTTP_CODE" == "303" ]]; then
    log_success "Domain test: HTTP $HTTP_CODE"
else
    log_warning "Domain test: HTTP $HTTP_CODE"
    echo ""
    echo "If access still fails, check:"
    echo "  1. DNS is pointing to this server"
    echo "  2. Firewall allows ports 80 and 443"
    echo "  3. SSL certificates are valid"
    echo ""
    echo "Last 10 lines of error log:"
    tail -10 /var/log/nginx/error.log 2>/dev/null || true
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Access your Nextcloud at: https://$DOMAIN"
echo "  Remember to clear browser cache (Ctrl+Shift+R)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
