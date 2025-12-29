#!/bin/bash
#===============================================================================
# fix-nginx.sh - Fix duplicate location blocks in Nginx configuration
# Run this script on the server to fix the broken Nextcloud interface
#===============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

NGINX_CONF="/etc/nginx/sites-available/nextcloud"
NEXTCLOUD_PATH="/var/www/nextcloud"

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

# Check if Nginx config exists
if [[ ! -f "$NGINX_CONF" ]]; then
    log_error "Nginx configuration not found at $NGINX_CONF"
    exit 1
fi

log_info "Creating backup of current Nginx configuration..."
cp "$NGINX_CONF" "${NGINX_CONF}.bak.$(date +%Y%m%d%H%M%S)"

log_info "Collecting current configuration..."

# Try to get values from .install-config if it exists in the same directory or parent
if [[ -f ".install-config" ]]; then
    source .install-config
elif [[ -f "../.install-config" ]]; then
    source ../.install-config
fi

# Fallback: extract from existing Nginx config if not in .install-config
[[ -z "$DOMAIN" ]] && DOMAIN=$(grep "server_name" "$NGINX_CONF" | head -1 | awk '{print $2}' | tr -d ';')
[[ -z "$NEXTCLOUD_PATH" ]] && NEXTCLOUD_PATH=$(grep "root" "$NGINX_CONF" | head -1 | awk '{print $2}' | tr -d ';')
[[ -z "$PHP_VERSION" ]] && PHP_VERSION=$(grep -oP 'php[0-9.]+-fpm' "$NGINX_CONF" | head -1 | sed 's/php//;s/-fpm//')

# Absolute fallback for PHP_VERSION if detection failed
[[ -z "$PHP_VERSION" ]] && PHP_VERSION=$(ls /var/run/php/php*-fpm.sock | head -1 | grep -oP '[0-9.]+')

if [[ -z "$DOMAIN" || -z "$NEXTCLOUD_PATH" || -z "$PHP_VERSION" ]]; then
    log_error "Could not detect configuration (Domain: $DOMAIN, Path: $NEXTCLOUD_PATH, PHP: $PHP_VERSION)"
    exit 1
fi

log_info "Detected: Domain=$DOMAIN, Path=$NEXTCLOUD_PATH, PHP=$PHP_VERSION"

log_info "Applying robust Nginx configuration..."

cat > "$NGINX_CONF" << EOF
upstream php-handler {
    server unix:/var/run/php/php${PHP_VERSION}-fpm.sock;
}

server {
    listen 80;
    server_name ${DOMAIN};

    root ${NEXTCLOUD_PATH};

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

    # Logging
    access_log /var/log/nginx/nextcloud-access.log;
    error_log /var/log/nginx/nextcloud-error.log;

    # File size limits
    client_max_body_size 16G;
    client_body_timeout 300s;

    # FastCGI settings (Optimized for Nextcloud)
    fastcgi_buffers 64 16k;
    fastcgi_buffer_size 32k;
    fastcgi_read_timeout 300;
    fastcgi_send_timeout 300;
    fastcgi_connect_timeout 300;

    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_comp_level 4;
    gzip_min_length 256;
    gzip_proxied expired no-cache no-store private no_last_modified no_etag auth;
    gzip_types application/atom+xml application/javascript application/json application/ld+json application/manifest+json application/rss+xml application/vnd.geo+json application/vnd.ms-fontobject application/wasm application/x-font-ttf application/x-web-app-manifest+json application/xhtml+xml application/xml font/opentype image/bmp image/svg+xml image/x-icon text/cache-manifest text/css text/plain text/vcard text/vnd.rim.location.xloc text/vtt text/x-component text/x-cross-domain-policy;

    # HTTP response headers for static content
    location = /robots.txt {
        allow all;
        log_not_found off;
        access_log off;
    }

    # The following 2 rules are only needed for the user_webfinger app
    location ^~ /.well-known/webfinger {
        return 301 \$scheme://\$host/index.php/.well-known/webfinger;
    }
    location ^~ /.well-known/nodeinfo {
        return 301 \$scheme://\$host/index.php/.well-known/nodeinfo;
    }

    location = /.well-known/carddav {
        return 301 \$scheme://\$host/remote.php/dav;
    }
    location = /.well-known/caldav {
        return 301 \$scheme://\$host/remote.php/dav;
    }

    location /.well-known/acme-challenge {
        try_files \$uri \$uri/ =404;
    }

    # Deny access to sensitive directories
    location ~ ^/(?:build|tests|config|lib|3rdparty|templates|data)(?:$|/) {
        return 404;
    }
    location ~ ^/(?:\.|autotest|occ|issue|indie|db_|console) {
        return 404;
    }

    # Cache static files (including .mjs)
    location ~* \.(?:css|js|mjs|woff2?|svg|gif|map|png|html|ttf|ico|jpg|jpeg|bcmap|mp4|webm)$ {
        try_files \$uri /index.php\$request_uri;
        add_header Cache-Control "public, max-age=15778463, immutable";
        add_header X-Content-Type-Options "nosniff" always;
        access_log off;
    }

    location ~ \.php(?:$|/) {
        fastcgi_split_path_info ^(.+?\.php)(/.*)$;
        set \$path_info \$fastcgi_path_info;

        try_files \$fastcgi_script_name =404;

        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$path_info;
        fastcgi_param HTTPS on;
        fastcgi_param modHeadersAvailable true;
        fastcgi_param front_controller_active true;

        fastcgi_pass php-handler;
        fastcgi_intercept_errors on;
        fastcgi_request_buffering off;
    }

    location / {
        try_files \$uri \$uri/ /index.php\$request_uri;
    }
}
EOF

log_info "Testing Nginx configuration..."
if nginx -t 2>&1; then
    log_success "Nginx configuration is valid"
else
    log_error "Nginx configuration test failed!"
    log_info "Restoring backup..."
    LATEST_BACKUP=$(ls -t ${NGINX_CONF}.bak.* 2>/dev/null | head -1)
    if [[ -n "$LATEST_BACKUP" ]]; then
        cp "$LATEST_BACKUP" "$NGINX_CONF"
        log_info "Backup restored from $LATEST_BACKUP"
    fi
    exit 1
fi

log_info "Restarting Nginx..."
systemctl restart nginx

log_info "Clearing Nextcloud cache..."
if [[ -d "$NEXTCLOUD_PATH" ]]; then
    cd "$NEXTCLOUD_PATH"
    sudo -u www-data php occ maintenance:repair --include-expensive 2>/dev/null || true
    sudo -u www-data php occ files:scan --all 2>/dev/null || true
    sudo -u www-data php occ maintenance:update:htaccess 2>/dev/null || true
    log_success "Nextcloud cache cleared and htaccess updated"
else
    log_warning "Nextcloud path not found at $NEXTCLOUD_PATH, skipping cache clear"
fi

log_info "Restarting PHP-FPM..."
# Try to find and restart PHP-FPM
PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"
if systemctl is-active --quiet "$PHP_FPM_SERVICE"; then
    systemctl restart "$PHP_FPM_SERVICE"
    log_success "Restarted $PHP_FPM_SERVICE"
else
    # Fallback to detection if specific version failed
    PHP_FPM_SERVICE=$(systemctl list-units --type=service --state=running | grep -oP 'php[0-9.]+\-fpm' | head -1)
    if [[ -n "$PHP_FPM_SERVICE" ]]; then
        systemctl restart "$PHP_FPM_SERVICE"
        log_success "Restarted $PHP_FPM_SERVICE"
    else
        log_warning "Could not detect PHP-FPM service"
    fi
fi

echo ""
log_success "Fix applied successfully!"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Please refresh your Nextcloud page (Ctrl+Shift+R to hard refresh)"
echo "  The interface should now display correctly with all icons and styles."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
