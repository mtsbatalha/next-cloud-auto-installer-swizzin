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

log_info "Fixing duplicate location blocks..."

# Create a temporary file with the fixed configuration
# Remove the duplicate location blocks for static files
sed -i '/location ~ \\\.(\?:css|js|svg|gif|png|html|ttf|woff2\?|ico|jpg|jpeg|mp4|webm)\$/{
N
N
N
d
}' "$NGINX_CONF"

# Remove the duplicate woff location block
sed -i '/location ~ \\\.woff2\?\$/{
N
N
N
N
d
}' "$NGINX_CONF"

# Alternative approach: use awk to remove specific blocks
# This is more reliable for multi-line patterns
cat "$NGINX_CONF" | awk '
BEGIN { skip = 0; buffer = "" }
/location ~ \\\.\(\?:css\|js\|svg\|gif\|png\|html\|ttf\|woff2\?\|ico\|jpg\|jpeg\|mp4\|webm\)\$/ {
    skip = 1
    next
}
/location ~ \\\.\woff2\?\$/ {
    skip = 1
    next
}
skip == 1 && /^[[:space:]]*\}/ {
    skip = 0
    next
}
skip == 0 { print }
' > "${NGINX_CONF}.tmp"

# Only replace if the temp file is not empty and valid
if [[ -s "${NGINX_CONF}.tmp" ]]; then
    mv "${NGINX_CONF}.tmp" "$NGINX_CONF"
else
    rm -f "${NGINX_CONF}.tmp"
    log_warning "AWK processing did not produce valid output, using sed-based fix"
fi

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
    log_success "Nextcloud cache cleared"
else
    log_warning "Nextcloud path not found at $NEXTCLOUD_PATH, skipping cache clear"
fi

log_info "Restarting PHP-FPM..."
# Try to find and restart PHP-FPM
PHP_FPM_SERVICE=$(systemctl list-units --type=service --state=running | grep -oP 'php[0-9.]+\-fpm' | head -1)
if [[ -n "$PHP_FPM_SERVICE" ]]; then
    systemctl restart "$PHP_FPM_SERVICE"
    log_success "Restarted $PHP_FPM_SERVICE"
else
    log_warning "Could not detect PHP-FPM service"
fi

echo ""
log_success "Fix applied successfully!"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Please refresh your Nextcloud page (Ctrl+Shift+R to hard refresh)"
echo "  The interface should now display correctly with all icons and styles."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
