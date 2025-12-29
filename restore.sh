#!/bin/bash
#===============================================================================
# Nextcloud Restore Script
# Restores backup for migration or disaster recovery
#===============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

#===============================================================================
# Configuration
#===============================================================================

# Default paths (can be overridden)
NEXTCLOUD_PATH="/var/www/nextcloud"
DATA_PATH="/var/nextcloud-data"

# Restore options
RESTORE_DATABASE=true
RESTORE_DATA=true
RESTORE_CONFIG=true
RESTORE_APPS=true
RESTORE_THEMES=true

# New server settings (for migration)
NEW_DOMAIN=""
NEW_DB_PASS=""

#===============================================================================
# Functions
#===============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

show_usage() {
    cat << EOF
Nextcloud Restore Script

Usage: $0 BACKUP_FILE [OPTIONS]

Arguments:
    BACKUP_FILE         Path to the backup archive (.tar.gz)

Options:
    --target DIR        Custom Nextcloud installation path
    --data-dir DIR      Custom data directory path
    --new-domain NAME   Update domain name (for migration)
    --no-database       Skip database restore
    --no-data           Skip data restore
    --no-config         Skip config restore
    --help              Show this help

Examples:
    $0 /var/backups/nextcloud/backup-20231201.tar.gz
    $0 backup.tar.gz --new-domain newcloud.example.com
    $0 backup.tar.gz --target /var/www/nextcloud --data-dir /mnt/data

EOF
    exit 0
}

parse_args() {
    if [[ $# -eq 0 ]]; then
        show_usage
    fi
    
    BACKUP_FILE="$1"
    shift
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --target)
                NEXTCLOUD_PATH="$2"
                shift 2
                ;;
            --data-dir)
                DATA_PATH="$2"
                shift 2
                ;;
            --new-domain)
                NEW_DOMAIN="$2"
                shift 2
                ;;
            --no-database)
                RESTORE_DATABASE=false
                shift
                ;;
            --no-data)
                RESTORE_DATA=false
                shift
                ;;
            --no-config)
                RESTORE_CONFIG=false
                shift
                ;;
            --help)
                show_usage
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                ;;
        esac
    done
    
    # Validate backup file
    if [[ ! -f "$BACKUP_FILE" ]]; then
        log_error "Backup file not found: $BACKUP_FILE"
        exit 1
    fi
}

extract_backup() {
    log_info "Extracting backup archive..."
    
    TEMP_DIR=$(mktemp -d)
    tar -xzf "${BACKUP_FILE}" -C "${TEMP_DIR}"
    
    # Find the backup directory (should be named with timestamp)
    BACKUP_DIR=$(find "${TEMP_DIR}" -maxdepth 1 -type d -name "[0-9]*" | head -1)
    
    if [[ -z "$BACKUP_DIR" ]]; then
        BACKUP_DIR="${TEMP_DIR}"
    fi
    
    log_success "Backup extracted to: ${TEMP_DIR}"
    
    # Read manifest if exists
    if [[ -f "${BACKUP_DIR}/manifest.json" ]]; then
        log_info "Backup manifest found:"
        cat "${BACKUP_DIR}/manifest.json"
        echo ""
    fi
}

enable_maintenance_mode() {
    if [[ -d "${NEXTCLOUD_PATH}" ]]; then
        log_info "Enabling maintenance mode..."
        cd "${NEXTCLOUD_PATH}"
        sudo -u www-data php occ maintenance:mode --on 2>/dev/null || true
    fi
}

disable_maintenance_mode() {
    log_info "Disabling maintenance mode..."
    cd "${NEXTCLOUD_PATH}"
    sudo -u www-data php occ maintenance:mode --off
}

restore_database() {
    if [[ "$RESTORE_DATABASE" != "true" ]]; then
        return
    fi
    
    if [[ ! -f "${BACKUP_DIR}/database/nextcloud.sql.gz" ]]; then
        log_warning "Database backup not found, skipping..."
        return
    fi
    
    log_info "Restoring database..."
    
    # Get database credentials from config
    if [[ -f "${NEXTCLOUD_PATH}/config/config.php" ]]; then
        DB_NAME=$(grep -oP "'dbname'\s*=>\s*'\K[^']+" "${NEXTCLOUD_PATH}/config/config.php")
        DB_USER=$(grep -oP "'dbuser'\s*=>\s*'\K[^']+" "${NEXTCLOUD_PATH}/config/config.php")
        DB_PASS=$(grep -oP "'dbpassword'\s*=>\s*'\K[^']+" "${NEXTCLOUD_PATH}/config/config.php")
    elif [[ -f "${BACKUP_DIR}/config/config.php" ]]; then
        DB_NAME=$(grep -oP "'dbname'\s*=>\s*'\K[^']+" "${BACKUP_DIR}/config/config.php")
        DB_USER=$(grep -oP "'dbuser'\s*=>\s*'\K[^']+" "${BACKUP_DIR}/config/config.php")
        DB_PASS=$(grep -oP "'dbpassword'\s*=>\s*'\K[^']+" "${BACKUP_DIR}/config/config.php")
    else
        log_error "Cannot find database credentials"
        return
    fi
    
    # Drop and recreate database
    mysql -e "DROP DATABASE IF EXISTS ${DB_NAME};"
    mysql -e "CREATE DATABASE ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
    mysql -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"
    
    # Restore database
    gunzip -c "${BACKUP_DIR}/database/nextcloud.sql.gz" | mysql -u "${DB_USER}" -p"${DB_PASS}" "${DB_NAME}"
    
    log_success "Database restored"
}

restore_config() {
    if [[ "$RESTORE_CONFIG" != "true" ]]; then
        return
    fi
    
    if [[ ! -d "${BACKUP_DIR}/config" ]]; then
        log_warning "Configuration backup not found, skipping..."
        return
    fi
    
    log_info "Restoring configuration..."
    
    # Backup current config
    if [[ -f "${NEXTCLOUD_PATH}/config/config.php" ]]; then
        cp "${NEXTCLOUD_PATH}/config/config.php" "${NEXTCLOUD_PATH}/config/config.php.backup"
    fi
    
    # Restore config files
    cp "${BACKUP_DIR}/config/"*.php "${NEXTCLOUD_PATH}/config/" 2>/dev/null || true
    
    # Update domain if specified
    if [[ -n "$NEW_DOMAIN" ]]; then
        log_info "Updating domain to: ${NEW_DOMAIN}"
        
        cd "${NEXTCLOUD_PATH}"
        sudo -u www-data php occ config:system:set trusted_domains 1 --value="${NEW_DOMAIN}"
        sudo -u www-data php occ config:system:set overwrite.cli.url --value="https://${NEW_DOMAIN}"
    fi
    
    # Set correct permissions
    chown www-data:www-data "${NEXTCLOUD_PATH}/config/config.php"
    chmod 600 "${NEXTCLOUD_PATH}/config/config.php"
    
    log_success "Configuration restored"
}

restore_data() {
    if [[ "$RESTORE_DATA" != "true" ]]; then
        return
    fi
    
    if [[ ! -d "${BACKUP_DIR}/data" ]]; then
        log_warning "Data backup not found, skipping..."
        return
    fi
    
    log_info "Restoring data directory..."
    log_warning "This may take a while for large backups..."
    
    # Create data directory if not exists
    mkdir -p "${DATA_PATH}"
    
    # Restore data using rsync
    rsync -aAX --info=progress2 \
        "${BACKUP_DIR}/data/" "${DATA_PATH}/"
    
    # Set permissions
    chown -R www-data:www-data "${DATA_PATH}"
    chmod 750 "${DATA_PATH}"
    
    log_success "Data directory restored"
}

restore_apps() {
    if [[ "$RESTORE_APPS" != "true" ]]; then
        return
    fi
    
    if [[ ! -d "${BACKUP_DIR}/apps" ]]; then
        return
    fi
    
    log_info "Restoring apps..."
    
    # Restore apps-extra if exists
    if [[ -d "${BACKUP_DIR}/apps/apps-extra" ]]; then
        cp -r "${BACKUP_DIR}/apps/apps-extra" "${NEXTCLOUD_PATH}/"
        chown -R www-data:www-data "${NEXTCLOUD_PATH}/apps-extra"
    fi
    
    # Install apps from list
    if [[ -f "${BACKUP_DIR}/apps/installed-apps.json" ]]; then
        log_info "Re-installing apps from backup..."
        cd "${NEXTCLOUD_PATH}"
        
        # Parse enabled apps and install them
        ENABLED_APPS=$(cat "${BACKUP_DIR}/apps/installed-apps.json" | python3 -c "import sys, json; apps=json.load(sys.stdin); print(' '.join(apps.get('enabled', {}).keys()))" 2>/dev/null || true)
        
        for app in $ENABLED_APPS; do
            sudo -u www-data php occ app:install "$app" 2>/dev/null || true
            sudo -u www-data php occ app:enable "$app" 2>/dev/null || true
        done
    fi
    
    log_success "Apps restored"
}

restore_themes() {
    if [[ "$RESTORE_THEMES" != "true" ]]; then
        return
    fi
    
    if [[ ! -d "${BACKUP_DIR}/themes" ]]; then
        return
    fi
    
    log_info "Restoring themes..."
    
    mkdir -p "${NEXTCLOUD_PATH}/themes"
    cp -r "${BACKUP_DIR}/themes/"* "${NEXTCLOUD_PATH}/themes/" 2>/dev/null || true
    chown -R www-data:www-data "${NEXTCLOUD_PATH}/themes"
    
    log_success "Themes restored"
}

run_maintenance() {
    log_info "Running maintenance tasks..."
    
    cd "${NEXTCLOUD_PATH}"
    
    # Update database indices
    sudo -u www-data php occ db:add-missing-indices
    
    # Convert to big int if needed
    sudo -u www-data php occ db:convert-filecache-bigint --no-interaction
    
    # Run maintenance repair
    sudo -u www-data php occ maintenance:repair
    
    # Rescan files
    log_info "Rescanning files (this may take a while)..."
    sudo -u www-data php occ files:scan --all
    
    # Update .htaccess
    sudo -u www-data php occ maintenance:update:htaccess
    
    log_success "Maintenance tasks completed"
}

cleanup() {
    log_info "Cleaning up temporary files..."
    rm -rf "${TEMP_DIR}"
}

#===============================================================================
# Main
#===============================================================================

main() {
    echo ""
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║              Nextcloud Restore Script                         ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    check_root
    parse_args "$@"
    
    echo ""
    log_warning "This will restore Nextcloud from backup."
    log_warning "Current data may be overwritten!"
    echo ""
    read -p "Continue? [y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
        log_info "Restore cancelled"
        exit 0
    fi
    
    # Trap to clean up on error
    trap cleanup EXIT
    
    extract_backup
    enable_maintenance_mode
    
    restore_database
    restore_config
    restore_apps
    restore_themes
    restore_data
    
    run_maintenance
    disable_maintenance_mode
    
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              Restore Completed Successfully!                  ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  Nextcloud path: ${NEXTCLOUD_PATH}"
    echo "  Data path:      ${DATA_PATH}"
    echo ""
    
    if [[ -n "$NEW_DOMAIN" ]]; then
        echo "  New domain: ${NEW_DOMAIN}"
        echo ""
        echo "  Remember to:"
        echo "    1. Update DNS records for ${NEW_DOMAIN}"
        echo "    2. Obtain SSL certificate: certbot --apache -d ${NEW_DOMAIN}"
        echo "    3. Update web server configuration if needed"
        echo ""
    fi
    
    echo "  Please verify your installation at: https://${NEW_DOMAIN:-your-domain}"
    echo ""
}

main "$@"
