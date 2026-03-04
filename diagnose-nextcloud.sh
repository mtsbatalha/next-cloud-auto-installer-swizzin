#!/bin/bash
#===============================================================================
# diagnose-nextcloud.sh - Diagnose and fix common Nextcloud issues
# Run this on the server to identify and fix 403/500 errors
#===============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Auto-detect Nextcloud path
NEXTCLOUD_PATH=""
for _p in /var/www/nextcloud /srv/nextcloud /var/www/html/nextcloud /opt/nextcloud; do
    if [[ -f "${_p}/occ" ]]; then
        NEXTCLOUD_PATH="$_p"
        break
    fi
done
NEXTCLOUD_PATH="${NEXTCLOUD_PATH:-/var/www/nextcloud}"
NGINX_CONF="/etc/nginx/sites-available/nextcloud"

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check root
if [[ $EUID -ne 0 ]]; then
    log_error "Run as root: sudo bash $0"
    exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Nextcloud Diagnostic and Repair Tool"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 1. Check Nextcloud path
log_info "Checking Nextcloud installation..."
if [[ ! -d "$NEXTCLOUD_PATH" ]]; then
    log_error "Nextcloud not found at $NEXTCLOUD_PATH"
    read -p "Enter correct path: " NEXTCLOUD_PATH
fi

if [[ ! -f "$NEXTCLOUD_PATH/index.php" ]]; then
    log_error "index.php not found in $NEXTCLOUD_PATH - installation appears broken"
    exit 1
fi
log_success "Nextcloud found at $NEXTCLOUD_PATH"

# 2. Check and fix file permissions
log_info "Checking file permissions..."

OWNER=$(stat -c '%U' "$NEXTCLOUD_PATH")
if [[ "$OWNER" != "www-data" ]]; then
    log_warning "Wrong owner: $OWNER (should be www-data)"
    log_info "Fixing permissions..."
    chown -R www-data:www-data "$NEXTCLOUD_PATH"
    log_success "Permissions fixed"
else
    log_success "File ownership is correct (www-data)"
fi

# Check data directory
DATA_PATH=$(sudo -u www-data php "$NEXTCLOUD_PATH/occ" config:system:get datadirectory 2>/dev/null || echo "/var/nextcloud-data")
if [[ -d "$DATA_PATH" ]]; then
    DATA_OWNER=$(stat -c '%U' "$DATA_PATH")
    if [[ "$DATA_OWNER" != "www-data" ]]; then
        log_warning "Data directory wrong owner: $DATA_OWNER"
        chown -R www-data:www-data "$DATA_PATH"
        log_success "Data directory permissions fixed"
    else
        log_success "Data directory ownership is correct"
    fi
fi

# 3. Check trusted_domains
log_info "Checking trusted_domains configuration..."
DOMAIN=$(grep "server_name" "$NGINX_CONF" 2>/dev/null | head -1 | awk '{print $2}' | tr -d ';')

if [[ -n "$DOMAIN" ]]; then
    TRUSTED=$(sudo -u www-data php "$NEXTCLOUD_PATH/occ" config:system:get trusted_domains 2>/dev/null || echo "")
    if ! echo "$TRUSTED" | grep -q "$DOMAIN"; then
        log_warning "Domain $DOMAIN not in trusted_domains"
        log_info "Adding $DOMAIN to trusted_domains..."
        
        # Get the next available index
        INDEX=0
        while sudo -u www-data php "$NEXTCLOUD_PATH/occ" config:system:get trusted_domains $INDEX 2>/dev/null; do
            ((INDEX++))
        done
        
        sudo -u www-data php "$NEXTCLOUD_PATH/occ" config:system:set trusted_domains $INDEX --value="$DOMAIN"
        log_success "Added $DOMAIN to trusted_domains"
    else
        log_success "Domain $DOMAIN is in trusted_domains"
    fi
fi

# 4. Check and fix overwrite.cli.url
log_info "Checking overwrite.cli.url..."
OVERWRITE_URL=$(sudo -u www-data php "$NEXTCLOUD_PATH/occ" config:system:get overwrite.cli.url 2>/dev/null || echo "")
if [[ -z "$OVERWRITE_URL" || "$OVERWRITE_URL" != "https://$DOMAIN" ]]; then
    log_warning "overwrite.cli.url incorrect: $OVERWRITE_URL"
    sudo -u www-data php "$NEXTCLOUD_PATH/occ" config:system:set overwrite.cli.url --value="https://$DOMAIN"
    log_success "Fixed overwrite.cli.url to https://$DOMAIN"
else
    log_success "overwrite.cli.url is correct"
fi

# 5. Check maintenance mode
log_info "Checking maintenance mode..."
MAINTENANCE=$(sudo -u www-data php "$NEXTCLOUD_PATH/occ" config:system:get maintenance 2>/dev/null || echo "false")
if [[ "$MAINTENANCE" == "true" ]]; then
    log_warning "Maintenance mode is ON!"
    sudo -u www-data php "$NEXTCLOUD_PATH/occ" maintenance:mode --off
    log_success "Maintenance mode disabled"
else
    log_success "Maintenance mode is off"
fi

# 6. Check PHP-FPM
log_info "Checking PHP-FPM..."
PHP_VERSION=$(php -v | head -1 | grep -oP '[0-9]+\.[0-9]+')
PHP_FPM_SOCK="/var/run/php/php${PHP_VERSION}-fpm.sock"

if [[ ! -S "$PHP_FPM_SOCK" ]]; then
    log_error "PHP-FPM socket not found at $PHP_FPM_SOCK"
    log_info "Restarting PHP-FPM..."
    systemctl restart "php${PHP_VERSION}-fpm"
    sleep 2
    if [[ -S "$PHP_FPM_SOCK" ]]; then
        log_success "PHP-FPM socket restored"
    else
        log_error "Failed to restore PHP-FPM socket"
    fi
else
    log_success "PHP-FPM socket exists"
fi

# Check socket permissions
if [[ -S "$PHP_FPM_SOCK" ]]; then
    SOCK_PERMS=$(stat -c '%a' "$PHP_FPM_SOCK")
    if [[ "$SOCK_PERMS" != "660" && "$SOCK_PERMS" != "666" ]]; then
        log_warning "PHP-FPM socket permissions: $SOCK_PERMS (should be 660)"
    else
        log_success "PHP-FPM socket permissions OK"
    fi
fi

# 7. Run Nextcloud repair
log_info "Running Nextcloud maintenance repair..."
cd "$NEXTCLOUD_PATH"
sudo -u www-data php occ maintenance:repair 2>/dev/null || true
sudo -u www-data php occ db:add-missing-indices 2>/dev/null || true
sudo -u www-data php occ maintenance:update:htaccess 2>/dev/null || true
log_success "Maintenance tasks completed"

# 8. Check Nginx configuration
log_info "Testing Nginx configuration..."
if nginx -t 2>&1 | grep -q "successful"; then
    log_success "Nginx configuration is valid"
else
    log_error "Nginx configuration has errors:"
    nginx -t
fi

# 9. Restart services
log_info "Restarting services..."
systemctl restart "php${PHP_VERSION}-fpm"
systemctl restart nginx
log_success "Services restarted"

# 10. Test access
log_info "Testing Nextcloud access..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -k "https://localhost/" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "302" || "$HTTP_CODE" == "303" ]]; then
    log_success "Nextcloud responded with HTTP $HTTP_CODE"
elif [[ "$HTTP_CODE" == "403" ]]; then
    log_error "Still getting 403 - checking logs..."
    echo ""
    echo "Last 10 lines of Nginx error log:"
    tail -10 /var/log/nginx/nextcloud-error.log 2>/dev/null || tail -10 /var/log/nginx/error.log
    echo ""
    echo "Last 10 lines of Nextcloud log:"
    tail -10 "$DATA_PATH/nextcloud.log" 2>/dev/null || echo "Nextcloud log not found"
else
    log_warning "Nextcloud responded with HTTP $HTTP_CODE"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Diagnostic Complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Try accessing: https://$DOMAIN"
echo "  If still failing, check the logs above for details."
echo ""
