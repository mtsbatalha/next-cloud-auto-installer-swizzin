#!/bin/bash
#===============================================================================
# Nextcloud Backup Script
# Creates complete backup for migration or disaster recovery
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

# Load configuration
if [[ -f "${SCRIPT_DIR}/.install-config" ]]; then
    source "${SCRIPT_DIR}/.install-config"
else
    # Default paths
    NEXTCLOUD_PATH="/var/www/nextcloud"
    DATA_PATH="/var/nextcloud-data"
    BACKUP_PATH="/var/backups/nextcloud"
    DB_NAME="nextcloud"
    DB_USER="nextcloud"
fi

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

#===============================================================================
# Backup Configuration
#===============================================================================

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="${BACKUP_PATH}/${TIMESTAMP}"
BACKUP_ARCHIVE="${BACKUP_PATH}/nextcloud-backup-${TIMESTAMP}.tar.gz"

# Retention (days)
RETENTION_DAYS=7

# What to backup
BACKUP_DATA=true
BACKUP_CONFIG=true
BACKUP_APPS=true
BACKUP_THEMES=true
BACKUP_DATABASE=true

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
Nextcloud Backup Script

Usage: $0 [OPTIONS]

Options:
    --full              Full backup (default)
    --data-only         Backup only data directory
    --config-only       Backup only configuration
    --db-only           Backup only database
    --no-data           Exclude data directory (faster)
    --output DIR        Custom output directory
    --remote            Upload to remote storage after backup
    --help              Show this help

Examples:
    $0                  # Full backup
    $0 --no-data        # Quick backup without data files
    $0 --output /mnt/backup  # Custom backup location

EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --full)
                BACKUP_DATA=true
                BACKUP_CONFIG=true
                BACKUP_DATABASE=true
                shift
                ;;
            --data-only)
                BACKUP_DATA=true
                BACKUP_CONFIG=false
                BACKUP_DATABASE=false
                BACKUP_APPS=false
                BACKUP_THEMES=false
                shift
                ;;
            --config-only)
                BACKUP_DATA=false
                BACKUP_CONFIG=true
                BACKUP_DATABASE=false
                shift
                ;;
            --db-only)
                BACKUP_DATA=false
                BACKUP_CONFIG=false
                BACKUP_DATABASE=true
                shift
                ;;
            --no-data)
                BACKUP_DATA=false
                shift
                ;;
            --output)
                BACKUP_PATH="$2"
                BACKUP_DIR="${BACKUP_PATH}/${TIMESTAMP}"
                BACKUP_ARCHIVE="${BACKUP_PATH}/nextcloud-backup-${TIMESTAMP}.tar.gz"
                shift 2
                ;;
            --remote)
                UPLOAD_REMOTE=true
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
}

enable_maintenance_mode() {
    log_info "Enabling maintenance mode..."
    cd "${NEXTCLOUD_PATH}"
    sudo -u www-data php occ maintenance:mode --on
}

disable_maintenance_mode() {
    log_info "Disabling maintenance mode..."
    cd "${NEXTCLOUD_PATH}"
    sudo -u www-data php occ maintenance:mode --off
}

backup_database() {
    if [[ "$BACKUP_DATABASE" != "true" ]]; then
        return
    fi
    
    log_info "Backing up database..."
    mkdir -p "${BACKUP_DIR}/database"
    
    # Get database password from config.php
    if [[ -z "$DB_PASS" ]]; then
        DB_PASS=$(grep -oP "'dbpassword'\s*=>\s*'\K[^']+" "${NEXTCLOUD_PATH}/config/config.php")
    fi
    
    # Dump database
    mysqldump --single-transaction \
        --default-character-set=utf8mb4 \
        -u "${DB_USER}" \
        -p"${DB_PASS}" \
        "${DB_NAME}" > "${BACKUP_DIR}/database/nextcloud.sql"
    
    # Compress
    gzip "${BACKUP_DIR}/database/nextcloud.sql"
    
    log_success "Database backup completed"
}

backup_data() {
    if [[ "$BACKUP_DATA" != "true" ]]; then
        return
    fi
    
    log_info "Backing up data directory..."
    log_warning "This may take a while for large installations..."
    
    mkdir -p "${BACKUP_DIR}/data"
    
    # Use rsync for efficient copying
    rsync -aAX --info=progress2 \
        --exclude "*.part" \
        --exclude "*.ocTransferId*" \
        "${DATA_PATH}/" "${BACKUP_DIR}/data/"
    
    log_success "Data backup completed"
}

backup_config() {
    if [[ "$BACKUP_CONFIG" != "true" ]]; then
        return
    fi
    
    log_info "Backing up configuration..."
    mkdir -p "${BACKUP_DIR}/config"
    
    # Backup config.php
    cp "${NEXTCLOUD_PATH}/config/config.php" "${BACKUP_DIR}/config/"
    
    # Backup other config files
    cp "${NEXTCLOUD_PATH}/config/"*.config.php "${BACKUP_DIR}/config/" 2>/dev/null || true
    
    # Backup install config
    if [[ -f "${SCRIPT_DIR}/.install-config" ]]; then
        cp "${SCRIPT_DIR}/.install-config" "${BACKUP_DIR}/config/"
    fi
    
    log_success "Configuration backup completed"
}

backup_apps() {
    if [[ "$BACKUP_APPS" != "true" ]]; then
        return
    fi
    
    log_info "Backing up custom apps..."
    mkdir -p "${BACKUP_DIR}/apps"
    
    # Backup apps-extra directory if exists
    if [[ -d "${NEXTCLOUD_PATH}/apps-extra" ]]; then
        cp -r "${NEXTCLOUD_PATH}/apps-extra" "${BACKUP_DIR}/apps/"
    fi
    
    # List installed apps
    cd "${NEXTCLOUD_PATH}"
    sudo -u www-data php occ app:list --output=json > "${BACKUP_DIR}/apps/installed-apps.json"
    
    log_success "Apps backup completed"
}

backup_themes() {
    if [[ "$BACKUP_THEMES" != "true" ]]; then
        return
    fi
    
    log_info "Backing up themes..."
    mkdir -p "${BACKUP_DIR}/themes"
    
    if [[ -d "${NEXTCLOUD_PATH}/themes" ]]; then
        cp -r "${NEXTCLOUD_PATH}/themes/"* "${BACKUP_DIR}/themes/" 2>/dev/null || true
    fi
    
    log_success "Themes backup completed"
}

create_archive() {
    log_info "Creating compressed archive..."
    
    cd "${BACKUP_PATH}"
    tar -czf "${BACKUP_ARCHIVE}" "${TIMESTAMP}"
    
    # Calculate size
    ARCHIVE_SIZE=$(du -h "${BACKUP_ARCHIVE}" | cut -f1)
    
    # Remove temporary directory
    rm -rf "${BACKUP_DIR}"
    
    log_success "Archive created: ${BACKUP_ARCHIVE} (${ARCHIVE_SIZE})"
}

upload_to_remote() {
    if [[ "$UPLOAD_REMOTE" != "true" ]]; then
        return
    fi
    
    log_info "Uploading to remote storage..."
    
    # Check for rclone
    if ! command -v rclone &> /dev/null; then
        log_warning "rclone not installed. Skipping remote upload."
        log_info "Install rclone and configure a remote named 'nextcloud-backup'"
        return
    fi
    
    # Upload using rclone
    if rclone lsd nextcloud-backup: &> /dev/null; then
        rclone copy "${BACKUP_ARCHIVE}" nextcloud-backup:backups/
        log_success "Uploaded to remote storage"
    else
        log_warning "rclone remote 'nextcloud-backup' not configured"
    fi
}

cleanup_old_backups() {
    log_info "Cleaning up old backups (older than ${RETENTION_DAYS} days)..."
    
    find "${BACKUP_PATH}" -name "nextcloud-backup-*.tar.gz" -mtime +${RETENTION_DAYS} -delete 2>/dev/null || true
    
    log_success "Cleanup completed"
}

create_backup_manifest() {
    log_info "Creating backup manifest..."
    
    mkdir -p "${BACKUP_DIR}"
    
    cat > "${BACKUP_DIR}/manifest.json" << EOF
{
    "timestamp": "${TIMESTAMP}",
    "date": "$(date -Iseconds)",
    "nextcloud_version": "$(cd ${NEXTCLOUD_PATH} && sudo -u www-data php occ -V 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo 'unknown')",
    "backup_type": {
        "database": ${BACKUP_DATABASE},
        "data": ${BACKUP_DATA},
        "config": ${BACKUP_CONFIG},
        "apps": ${BACKUP_APPS},
        "themes": ${BACKUP_THEMES}
    },
    "paths": {
        "nextcloud": "${NEXTCLOUD_PATH}",
        "data": "${DATA_PATH}"
    }
}
EOF
}

#===============================================================================
# Main
#===============================================================================

main() {
    echo ""
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║              Nextcloud Backup Script                          ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    check_root
    parse_args "$@"
    
    # Create backup directory
    mkdir -p "${BACKUP_DIR}"
    
    # Trap to disable maintenance mode on error
    trap disable_maintenance_mode ERR
    
    enable_maintenance_mode
    
    log_info "Starting backup..."
    log_info "Backup directory: ${BACKUP_DIR}"
    echo ""
    
    create_backup_manifest
    backup_database
    backup_config
    backup_apps
    backup_themes
    backup_data
    
    disable_maintenance_mode
    
    create_archive
    upload_to_remote
    cleanup_old_backups
    
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              Backup Completed Successfully!                   ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  Backup file: ${BACKUP_ARCHIVE}"
    echo ""
    echo "  To restore, run:"
    echo "    ${SCRIPT_DIR}/restore.sh ${BACKUP_ARCHIVE}"
    echo ""
}

main "$@"
