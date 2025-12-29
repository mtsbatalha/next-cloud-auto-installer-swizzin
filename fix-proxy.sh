#!/bin/bash
#===============================================================================
# fix-proxy.sh - Fix Nextcloud behind proxy/Cloudflare (403 errors)
# Run this when localhost works but external access fails
#===============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

NEXTCLOUD_PATH="/var/www/nextcloud"

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
echo "  Nextcloud Proxy/Cloudflare Fix"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Get domain from nginx config
NGINX_CONF="/etc/nginx/sites-available/nextcloud"
DOMAIN=$(grep "server_name" "$NGINX_CONF" 2>/dev/null | head -1 | awk '{print $2}' | tr -d ';')

if [[ -z "$DOMAIN" ]]; then
    read -p "Enter your domain: " DOMAIN
fi

log_info "Domain: $DOMAIN"

cd "$NEXTCLOUD_PATH"

# 1. Configure overwriteprotocol (required for Cloudflare/proxy)
log_info "Setting overwriteprotocol to https..."
sudo -u www-data php occ config:system:set overwriteprotocol --value="https"
log_success "overwriteprotocol set to https"

# 2. Configure overwrite.cli.url
log_info "Setting overwrite.cli.url..."
sudo -u www-data php occ config:system:set overwrite.cli.url --value="https://$DOMAIN"
log_success "overwrite.cli.url set"

# 3. Configure trusted_proxies for Cloudflare
log_info "Configuring trusted_proxies for Cloudflare..."

# Cloudflare IP ranges (as of 2024)
CLOUDFLARE_IPS=(
    "173.245.48.0/20"
    "103.21.244.0/22"
    "103.22.200.0/22"
    "103.31.4.0/22"
    "141.101.64.0/18"
    "108.162.192.0/18"
    "190.93.240.0/20"
    "188.114.96.0/20"
    "197.234.240.0/22"
    "198.41.128.0/17"
    "162.158.0.0/15"
    "104.16.0.0/13"
    "104.24.0.0/14"
    "172.64.0.0/13"
    "131.0.72.0/22"
)

INDEX=0
for IP in "${CLOUDFLARE_IPS[@]}"; do
    sudo -u www-data php occ config:system:set trusted_proxies $INDEX --value="$IP"
    ((INDEX++))
done
log_success "Cloudflare IPs added to trusted_proxies ($INDEX ranges)"

# 4. Set forwarded_for_headers
log_info "Configuring forwarded_for_headers..."
sudo -u www-data php occ config:system:set forwarded_for_headers 0 --value="HTTP_X_FORWARDED_FOR"
sudo -u www-data php occ config:system:set forwarded_for_headers 1 --value="HTTP_CF_CONNECTING_IP"
log_success "forwarded_for_headers configured"

# 5. Re-check trusted_domains
log_info "Verifying trusted_domains..."
TRUSTED=$(sudo -u www-data php occ config:system:get trusted_domains 2>/dev/null || echo "")
if ! echo "$TRUSTED" | grep -q "$DOMAIN"; then
    INDEX=0
    while sudo -u www-data php occ config:system:get trusted_domains $INDEX 2>/dev/null > /dev/null; do
        ((INDEX++))
    done
    sudo -u www-data php occ config:system:set trusted_domains $INDEX --value="$DOMAIN"
    log_success "Added $DOMAIN to trusted_domains"
else
    log_success "$DOMAIN already in trusted_domains"
fi

# 6. Disable maintenance mode if active
log_info "Checking maintenance mode..."
sudo -u www-data php occ maintenance:mode --off 2>/dev/null || true
log_success "Maintenance mode disabled"

# 7. Clear all caches
log_info "Clearing all caches..."
sudo -u www-data php occ maintenance:repair --include-expensive 2>/dev/null || true
sudo -u www-data php occ files:cleanup 2>/dev/null || true

# Clear OPcache
if [[ -d "/tmp/opcache" ]]; then
    rm -rf /tmp/opcache/*
    log_success "OPcache cleared"
fi

# Restart PHP-FPM
PHP_VERSION=$(php -v | head -1 | grep -oP '[0-9]+\.[0-9]+')
systemctl restart "php${PHP_VERSION}-fpm" 2>/dev/null || true
log_success "PHP-FPM restarted"

# Restart Nginx
systemctl restart nginx
log_success "Nginx restarted"

# 8. Show current config
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Current Nextcloud Configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  overwriteprotocol: $(sudo -u www-data php occ config:system:get overwriteprotocol)"
echo "  overwrite.cli.url: $(sudo -u www-data php occ config:system:get overwrite.cli.url)"
echo "  trusted_domains:"
INDEX=0
while sudo -u www-data php occ config:system:get trusted_domains $INDEX 2>/dev/null; do
    ((INDEX++))
done
echo ""

# 9. Test access
log_info "Testing external access..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -k "https://$DOMAIN/" --max-time 10 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "302" || "$HTTP_CODE" == "303" ]]; then
    log_success "External access working! HTTP $HTTP_CODE"
elif [[ "$HTTP_CODE" == "403" ]]; then
    log_warning "Still getting 403 - checking Nginx error log..."
    echo ""
    echo "Last 20 lines of error log:"
    tail -20 /var/log/nginx/nextcloud-error.log 2>/dev/null || tail -20 /var/log/nginx/error.log
    echo ""
    echo "Check if Cloudflare is in 'Full (Strict)' SSL mode."
    echo "Also verify that your domain DNS is pointing through Cloudflare."
else
    log_warning "Got HTTP $HTTP_CODE"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Additional Steps for Cloudflare"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  1. Go to Cloudflare Dashboard > SSL/TLS"
echo "  2. Set encryption mode to 'Full (Strict)'"
echo "  3. Under 'Edge Certificates', ensure 'Always Use HTTPS' is ON"
echo "  4. Clear browser cache (Ctrl+Shift+R)"
echo ""
