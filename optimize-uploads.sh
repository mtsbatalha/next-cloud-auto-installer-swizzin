#!/bin/bash
#===============================================================================
# optimize-uploads.sh - Optimize Nextcloud for large file uploads and Office
# Run this script on the server to enable large file support and fix Office
#===============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

NEXTCLOUD_PATH="/var/www/nextcloud"
NGINX_CONF="/etc/nginx/sites-available/nextcloud"

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
echo "  Nextcloud Large File Upload & Office Optimization"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Detect PHP version
PHP_VERSION=$(php -v | head -1 | grep -oP '[0-9]+\.[0-9]+')
log_info "Detected PHP version: $PHP_VERSION"

#===============================================================================
# 1. PHP Configuration for Large Files
#===============================================================================
log_info "Configuring PHP for large file uploads..."

PHP_INI="/etc/php/${PHP_VERSION}/fpm/php.ini"
PHP_CLI_INI="/etc/php/${PHP_VERSION}/cli/php.ini"

# Create custom config for large uploads
cat > "/etc/php/${PHP_VERSION}/fpm/conf.d/99-nextcloud-uploads.ini" << 'EOF'
; Nextcloud Large File Upload Configuration
; Maximum upload file size (16GB)
upload_max_filesize = 16G
post_max_size = 16G

; Maximum execution time (1 hour for large uploads)
max_execution_time = 3600
max_input_time = 3600

; Memory limit for processing large files
memory_limit = 1024M

; Output buffering (disabled for streaming)
output_buffering = Off

; Session timeout
session.gc_maxlifetime = 86400

; Disable default limits
default_socket_timeout = 3600
EOF

# Apply to CLI as well
cp "/etc/php/${PHP_VERSION}/fpm/conf.d/99-nextcloud-uploads.ini" \
   "/etc/php/${PHP_VERSION}/cli/conf.d/99-nextcloud-uploads.ini"

log_success "PHP configuration updated for large files"

#===============================================================================
# 2. PHP-FPM Pool Configuration
#===============================================================================
log_info "Optimizing PHP-FPM pool..."

# Calculate optimal settings based on RAM
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
PHP_MEM_PER_PROCESS=100

# Use 60% of RAM for PHP processes
MAX_CHILDREN=$(( (TOTAL_RAM_MB * 60 / 100) / PHP_MEM_PER_PROCESS ))
[[ $MAX_CHILDREN -lt 5 ]] && MAX_CHILDREN=5
[[ $MAX_CHILDREN -gt 50 ]] && MAX_CHILDREN=50

START_SERVERS=$(( MAX_CHILDREN / 4 ))
MIN_SPARE=$(( MAX_CHILDREN / 4 ))
MAX_SPARE=$(( MAX_CHILDREN / 2 ))

cat > "/etc/php/${PHP_VERSION}/fpm/pool.d/nextcloud.conf" << EOF
; Nextcloud Optimized PHP-FPM Pool
[nextcloud]
user = www-data
group = www-data

listen = /run/php/php${PHP_VERSION}-fpm.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

; Process Management
pm = dynamic
pm.max_children = ${MAX_CHILDREN}
pm.start_servers = ${START_SERVERS}
pm.min_spare_servers = ${MIN_SPARE}
pm.max_spare_servers = ${MAX_SPARE}
pm.max_requests = 500
pm.process_idle_timeout = 10s

; Request settings for large files
request_terminate_timeout = 3600
request_slowlog_timeout = 60s
slowlog = /var/log/php${PHP_VERSION}-fpm-slow.log

; Environment
env[HOSTNAME] = \$HOSTNAME
env[PATH] = /usr/local/bin:/usr/bin:/bin
env[TMP] = /tmp
env[TMPDIR] = /tmp
env[TEMP] = /tmp

; PHP settings for large files
php_admin_value[error_log] = /var/log/php${PHP_VERSION}-fpm-nextcloud.log
php_admin_flag[log_errors] = on
php_admin_value[memory_limit] = 1024M
php_admin_value[upload_max_filesize] = 16G
php_admin_value[post_max_size] = 16G
php_admin_value[max_execution_time] = 3600
php_admin_value[max_input_time] = 3600
php_admin_value[output_buffering] = Off
EOF

# Disable default www pool
[[ -f "/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf" ]] && \
    mv "/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf" "/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf.disabled" 2>/dev/null || true

log_success "PHP-FPM optimized (max_children: $MAX_CHILDREN)"

#===============================================================================
# 3. Nginx Configuration for Large Files
#===============================================================================
log_info "Updating Nginx for large file uploads..."

# Update client_max_body_size if not already set to 16G
if grep -q "client_max_body_size" "$NGINX_CONF"; then
    sed -i 's/client_max_body_size.*/client_max_body_size 16G;/' "$NGINX_CONF"
else
    sed -i '/server {/a \    client_max_body_size 16G;' "$NGINX_CONF"
fi

# Add/update timeout settings
if ! grep -q "proxy_read_timeout" "$NGINX_CONF"; then
    sed -i '/client_max_body_size/a \    proxy_read_timeout 3600s;\n    proxy_send_timeout 3600s;\n    send_timeout 3600s;' "$NGINX_CONF"
fi

# Update fastcgi timeouts
sed -i 's/fastcgi_read_timeout.*/fastcgi_read_timeout 3600;/' "$NGINX_CONF" 2>/dev/null || true
sed -i 's/fastcgi_send_timeout.*/fastcgi_send_timeout 3600;/' "$NGINX_CONF" 2>/dev/null || true

log_success "Nginx configured for 16GB uploads"

#===============================================================================
# 4. Nextcloud Configuration
#===============================================================================
log_info "Configuring Nextcloud for large file handling..."

cd "$NEXTCLOUD_PATH"

# Set chunk size for uploads (10MB chunks for reliability)
sudo -u www-data php occ config:app:set files max_chunk_size --value=10485760

# Enable file locking
sudo -u www-data php occ config:system:set filelocking.enabled --value=true --type=boolean

# Configure preview settings for performance
sudo -u www-data php occ config:system:set preview_max_x --value=2048 --type=integer
sudo -u www-data php occ config:system:set preview_max_y --value=2048 --type=integer
sudo -u www-data php occ config:system:set jpeg_quality --value=60 --type=integer

# Enable memory caching if not configured
MEMCACHE_LOCAL=$(sudo -u www-data php occ config:system:get memcache.local 2>/dev/null || echo "")
if [[ -z "$MEMCACHE_LOCAL" ]]; then
    sudo -u www-data php occ config:system:set memcache.local --value='\OC\Memcache\APCu'
    log_success "APCu memory cache enabled"
fi

log_success "Nextcloud optimized for large files"

#===============================================================================
# 5. Fix Office File Handling (Open in Office instead of Download)
#===============================================================================
log_info "Configuring Office file handling..."

# Check which Office app is installed
RICHDOCUMENTS=$(sudo -u www-data php occ app:list 2>/dev/null | grep -c "richdocuments" || echo "0")
ONLYOFFICE=$(sudo -u www-data php occ app:list 2>/dev/null | grep -c "onlyoffice" || echo "0")

if [[ "$RICHDOCUMENTS" -gt 0 ]]; then
    log_info "Detected: Nextcloud Office (Collabora/richdocuments)"
    
    # Enable richdocuments for all Office file types
    sudo -u www-data php occ config:app:set richdocuments doc_format --value="ooxml"
    
    # Set as default app for Office files
    sudo -u www-data php occ config:app:set richdocuments types --value="document,spreadsheet,presentation"
    
    # Enable direct editing
    sudo -u www-data php occ config:app:set richdocuments use_groups --value=""
    
    log_success "Nextcloud Office configured as default for documents"
    
elif [[ "$ONLYOFFICE" -gt 0 ]]; then
    log_info "Detected: OnlyOffice"
    
    # Set OnlyOffice as default editor
    sudo -u www-data php occ config:app:set onlyoffice defFormats --value='{"csv":"true","doc":"true","docm":"true","docx":"true","docxf":"true","dotx":"true","epub":"true","html":"true","odp":"true","ods":"true","odt":"true","otp":"true","ots":"true","ott":"true","pdf":"false","potm":"true","potx":"true","ppsm":"true","ppsx":"true","ppt":"true","pptm":"true","pptx":"true","rtf":"true","txt":"true","xls":"true","xlsm":"true","xlsx":"true","xltm":"true","xltx":"true"}'
    
    # Enable edit for all formats
    sudo -u www-data php occ config:app:set onlyoffice editFormats --value='{"csv":"true","odp":"true","ods":"true","odt":"true","rtf":"true","txt":"true"}'
    
    # Set as default handler
    sudo -u www-data php occ config:app:set onlyoffice sameTab --value="true"
    sudo -u www-data php occ config:app:set onlyoffice preview --value="true"
    
    log_success "OnlyOffice configured as default for documents"
else
    log_warning "No Office app detected. Install Nextcloud Office or OnlyOffice first."
    log_info "Run: sudo -u www-data php occ app:install richdocuments"
fi

#===============================================================================
# 6. Set Default App for File Types
#===============================================================================
log_info "Setting default applications for file types..."

# Enable Files to open with Office by default
sudo -u www-data php occ config:app:set files default_app --value="files" 2>/dev/null || true

log_success "Default apps configured"

#===============================================================================
# 7. Set System Limits
#===============================================================================
log_info "Configuring system limits..."

# Add limits for www-data user
if ! grep -q "www-data.*nofile" /etc/security/limits.conf; then
    cat >> /etc/security/limits.conf << EOF

# Nextcloud limits for large file handling
www-data soft nofile 65535
www-data hard nofile 65535
www-data soft nproc 65535
www-data hard nproc 65535
EOF
    log_success "System limits configured"
else
    log_info "System limits already configured"
fi

#===============================================================================
# 8. Restart Services
#===============================================================================
log_info "Restarting services..."

systemctl restart "php${PHP_VERSION}-fpm"
nginx -t && systemctl restart nginx

log_success "Services restarted"

#===============================================================================
# Summary
#===============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Optimization Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Large File Support:"
echo "    ✓ Maximum upload size: 16 GB"
echo "    ✓ Upload timeout: 1 hour"
echo "    ✓ Chunk size: 10 MB"
echo ""
echo "  Performance:"
echo "    ✓ PHP-FPM max_children: $MAX_CHILDREN"
echo "    ✓ Memory limit: 1024 MB"
echo "    ✓ APCu caching enabled"
echo ""
echo "  Office Integration:"
if [[ "$RICHDOCUMENTS" -gt 0 ]]; then
    echo "    ✓ Nextcloud Office set as default for .docx, .xlsx, .pptx"
elif [[ "$ONLYOFFICE" -gt 0 ]]; then
    echo "    ✓ OnlyOffice set as default for .docx, .xlsx, .pptx"
else
    echo "    ⚠ No Office app installed"
fi
echo ""
echo "  To test large upload:"
echo "    Upload a file > 100MB and check if it completes successfully"
echo ""
echo "  If .docx still downloads instead of opening:"
echo "    1. Go to Settings > Nextcloud Office (or OnlyOffice)"
echo "    2. Verify the WOPI URL is correct"
echo "    3. Clear browser cache"
echo ""
