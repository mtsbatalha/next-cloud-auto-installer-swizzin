#!/bin/bash
#===============================================================================
# Nextcloud Update Script
# Check for updates and upgrade Nextcloud with automatic backup
#===============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load configuration
if [[ -f "${SCRIPT_DIR}/.install-config" ]]; then
    source "${SCRIPT_DIR}/.install-config"
else
    NEXTCLOUD_PATH="/var/www/nextcloud"
    DATA_PATH="/var/nextcloud-data"
    BACKUP_PATH="/var/backups/nextcloud"
fi

# Update options
AUTO_BACKUP=true
SKIP_BACKUP=false
CHECK_ONLY=false
AUTO_UPDATE=false

#===============================================================================
# Helper Functions
#===============================================================================

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

print_banner() {
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              Nextcloud Update Manager                         ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

show_usage() {
    cat << EOF
Nextcloud Update Script

Usage: $0 [OPTIONS]

Options:
    --check             Check for updates only (don't install)
    --auto              Automatically install updates without confirmation
    --skip-backup       Skip automatic backup before update
    --backup-only       Only create backup, don't update
    --help              Show this help message

Examples:
    $0                  # Check and prompt for update
    $0 --check          # Only check for updates
    $0 --auto           # Auto-update with backup
    $0 --skip-backup    # Update without backup (not recommended)

EOF
    exit 0
}

#===============================================================================
# Update Functions
#===============================================================================

get_current_version() {
    if [[ ! -d "$NEXTCLOUD_PATH" ]]; then
        echo "unknown"
        return
    fi
    
    cd "$NEXTCLOUD_PATH"
    CURRENT_VERSION=$(sudo -u www-data php occ status --output=json 2>/dev/null | grep -oP '"versionstring":"\K[^"]+' || echo "unknown")
    echo "$CURRENT_VERSION"
}

get_latest_version() {
    # Get latest stable version from Nextcloud releases
    LATEST_VERSION=$(curl -s https://download.nextcloud.com/server/releases/ | grep -oP 'nextcloud-\K[0-9]+\.[0-9]+\.[0-9]+(?=\.tar\.bz2)' | sort -V | tail -1)
    
    if [[ -z "$LATEST_VERSION" ]]; then
        log_warning "Could not fetch latest version from server"
        echo "unknown"
    else
        echo "$LATEST_VERSION"
    fi
}

compare_versions() {
    local current=$1
    local latest=$2
    
    if [[ "$current" == "unknown" || "$latest" == "unknown" ]]; then
        return 2  # Unknown
    fi
    
    if [[ "$current" == "$latest" ]]; then
        return 0  # Same
    fi
    
    # Compare versions using sort -V
    if [[ "$(printf '%s\n' "$current" "$latest" | sort -V | head -1)" == "$current" ]]; then
        return 1  # Update available
    else
        return 0  # Current is newer (pre-release?)
    fi
}

check_for_updates() {
    log_info "Checking for updates..."
    
    CURRENT_VERSION=$(get_current_version)
    LATEST_VERSION=$(get_latest_version)
    
    echo ""
    echo "  Current version: ${CYAN}${CURRENT_VERSION}${NC}"
    echo "  Latest version:  ${GREEN}${LATEST_VERSION}${NC}"
    echo ""
    
    compare_versions "$CURRENT_VERSION" "$LATEST_VERSION"
    local result=$?
    
    if [[ $result -eq 0 ]]; then
        log_success "Nextcloud is up to date!"
        return 0
    elif [[ $result -eq 1 ]]; then
        log_warning "Update available: ${CURRENT_VERSION} → ${LATEST_VERSION}"
        return 1
    else
        log_error "Could not determine if update is needed"
        return 2
    fi
}

create_pre_update_backup() {
    log_info "Creating pre-update backup..."
    
    # Call backup script with --no-data for faster backup
    if [[ -f "${SCRIPT_DIR}/backup.sh" ]]; then
        BACKUP_OUTPUT=$(mktemp)
        if "${SCRIPT_DIR}/backup.sh" --no-data 2>&1 | tee "$BACKUP_OUTPUT"; then
            BACKUP_FILE=$(grep "Archive created:" "$BACKUP_OUTPUT" | awk '{print $3}')
            rm "$BACKUP_OUTPUT"
            
            if [[ -n "$BACKUP_FILE" ]]; then
                log_success "Backup created: $BACKUP_FILE"
                echo "$BACKUP_FILE" > /tmp/nextcloud-update-backup
                return 0
            fi
        else
            rm "$BACKUP_OUTPUT"
            log_error "Backup failed!"
            return 1
        fi
    else
        log_warning "backup.sh not found, creating manual backup..."
        
        # Manual quick backup
        TIMESTAMP=$(date +%Y%m%d_%H%M%S)
        BACKUP_DIR="${BACKUP_PATH}/pre-update-${TIMESTAMP}"
        mkdir -p "$BACKUP_DIR"
        
        # Backup config
        cp -r "${NEXTCLOUD_PATH}/config" "$BACKUP_DIR/"
        
        # Backup database
        DB_PASS=$(grep -oP "'dbpassword'\s*=>\s*'\K[^']+" "${NEXTCLOUD_PATH}/config/config.php")
        DB_NAME=$(grep -oP "'dbname'\s*=>\s*'\K[^']+" "${NEXTCLOUD_PATH}/config/config.php")
        DB_USER=$(grep -oP "'dbuser'\s*=>\s*'\K[^']+" "${NEXTCLOUD_PATH}/config/config.php")
        
        mysqldump --single-transaction -u "${DB_USER}" -p"${DB_PASS}" "${DB_NAME}" | gzip > "$BACKUP_DIR/database.sql.gz"
        
        log_success "Manual backup created: $BACKUP_DIR"
        echo "$BACKUP_DIR" > /tmp/nextcloud-update-backup
    fi
}

perform_update() {
    local target_version=$1
    
    log_info "Starting Nextcloud update to version ${target_version}..."
    
    cd "$NEXTCLOUD_PATH"
    
    # Enable maintenance mode
    log_info "Enabling maintenance mode..."
    sudo -u www-data php occ maintenance:mode --on
    
    # Trap to disable maintenance mode on error
    trap 'sudo -u www-data php occ maintenance:mode --off' ERR EXIT
    
    # Use built-in updater
    log_info "Running Nextcloud updater..."
    
    if sudo -u www-data php occ update:check; then
        log_info "Starting update process..."
        
        # Perform update via web updater or manual
        if [[ -f "${NEXTCLOUD_PATH}/updater/updater.phar" ]]; then
            log_info "Using built-in updater..."
            cd "${NEXTCLOUD_PATH}/updater"
            sudo -u www-data php updater.phar --no-interaction
        else
            log_info "Using occ upgrade command..."
            cd "${NEXTCLOUD_PATH}"
            sudo -u www-data php occ upgrade
        fi
        
        # Run additional maintenance
        log_info "Running post-update maintenance..."
        sudo -u www-data php occ db:add-missing-indices
        sudo -u www-data php occ db:convert-filecache-bigint --no-interaction
        sudo -u www-data php occ maintenance:repair
        
        # Disable maintenance mode
        log_info "Disabling maintenance mode..."
        sudo -u www-data php occ maintenance:mode --off
        
        # Remove trap
        trap - ERR EXIT
        
        log_success "Update completed successfully!"
        
        # Show new version
        NEW_VERSION=$(get_current_version)
        echo ""
        echo "  New version: ${GREEN}${NEW_VERSION}${NC}"
        echo ""
        
        return 0
    else
        log_error "Update check failed"
        sudo -u www-data php occ maintenance:mode --off
        trap - ERR EXIT
        return 1
    fi
}

#===============================================================================
# Main
#===============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --check)
                CHECK_ONLY=true
                shift
                ;;
            --auto)
                AUTO_UPDATE=true
                shift
                ;;
            --skip-backup)
                SKIP_BACKUP=true
                shift
                ;;
            --backup-only)
                create_pre_update_backup
                exit 0
                ;;
            --help|-h)
                show_usage
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                ;;
        esac
    done
}

main() {
    print_banner
    check_root
    parse_args "$@"
    
    # Check for updates
    check_for_updates
    UPDATE_STATUS=$?
    
    if [[ $UPDATE_STATUS -eq 0 ]]; then
        # Already up to date
        exit 0
    elif [[ $UPDATE_STATUS -eq 2 ]]; then
        # Error checking
        exit 1
    fi
    
    # Update available
    if [[ "$CHECK_ONLY" == "true" ]]; then
        log_info "Use '$0 --auto' to update automatically"
        exit 0
    fi
    
    LATEST_VERSION=$(get_latest_version)
    
    # Confirm update
    if [[ "$AUTO_UPDATE" != "true" ]]; then
        echo ""
        read -p "Do you want to update to ${LATEST_VERSION}? [y/N]: " CONFIRM
        if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
            log_info "Update cancelled"
            exit 0
        fi
    fi
    
    # Create backup
    if [[ "$SKIP_BACKUP" != "true" ]]; then
        echo ""
        log_warning "Creating backup before update..."
        if ! create_pre_update_backup; then
            log_error "Backup failed! Aborting update."
            log_info "Use --skip-backup to update without backup (not recommended)"
            exit 1
        fi
    else
        log_warning "Skipping backup as requested"
    fi
    
    # Perform update
    echo ""
    if perform_update "$LATEST_VERSION"; then
        echo ""
        echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║           Update Completed Successfully!                      ║${NC}"
        echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        
        if [[ -f /tmp/nextcloud-update-backup ]]; then
            BACKUP_LOCATION=$(cat /tmp/nextcloud-update-backup)
            echo "  Backup location: $BACKUP_LOCATION"
            rm /tmp/nextcloud-update-backup
        fi
        
        echo ""
        log_info "Please verify your Nextcloud installation:"
        log_info "  https://${DOMAIN:-your-domain}"
        echo ""
    else
        log_error "Update failed!"
        echo ""
        log_warning "You can restore from backup using:"
        if [[ -f /tmp/nextcloud-update-backup ]]; then
            BACKUP_LOCATION=$(cat /tmp/nextcloud-update-backup)
            echo "  ${SCRIPT_DIR}/restore.sh $BACKUP_LOCATION"
            rm /tmp/nextcloud-update-backup
        else
            echo "  ${SCRIPT_DIR}/restore.sh <backup-file>"
        fi
        echo ""
        exit 1
    fi
}

main "$@"
