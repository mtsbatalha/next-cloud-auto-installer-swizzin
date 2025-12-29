#!/bin/bash
#===============================================================================
# Nextcloud Auto-Installer for Linux (Ubuntu/Debian)
# Author: Nextcloud Installer Project
# Description: Automated installation of Nextcloud with Office, security,
#              performance optimization, and backup support
#===============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/scripts"
CONFIG_DIR="${SCRIPT_DIR}/config"

# Default values
NEXTCLOUD_VERSION="latest"
WEBSERVER="apache"
OFFICE_SUITE="collabora"
PHP_VERSION="8.2"

# Installation paths
NEXTCLOUD_PATH="/var/www/nextcloud"
DATA_PATH="/var/nextcloud-data"
BACKUP_PATH="/var/backups/nextcloud"

#===============================================================================
# Helper Functions
#===============================================================================

print_banner() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║                                                                   ║"
    echo "║     ███╗   ██╗███████╗██╗  ██╗████████╗ ██████╗██╗      ██████╗   ║"
    echo "║     ████╗  ██║██╔════╝╚██╗██╔╝╚══██╔══╝██╔════╝██║     ██╔═══██╗  ║"
    echo "║     ██╔██╗ ██║█████╗   ╚███╔╝    ██║   ██║     ██║     ██║   ██║  ║"
    echo "║     ██║╚██╗██║██╔══╝   ██╔██╗    ██║   ██║     ██║     ██║   ██║  ║"
    echo "║     ██║ ╚████║███████╗██╔╝ ██╗   ██║   ╚██████╗███████╗╚██████╔╝  ║"
    echo "║     ╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝   ╚═╝    ╚═════╝╚══════╝ ╚═════╝   ║"
    echo "║                                                                   ║"
    echo "║              Auto-Installer with Office & Security                ║"
    echo "║                                                                   ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

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

log_step() {
    echo -e "${PURPLE}[STEP]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

check_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
        OS_CODENAME=$VERSION_CODENAME
        
        case $OS in
            ubuntu)
                if [[ "$OS_VERSION" < "22.04" ]]; then
                    log_error "Ubuntu 22.04 or higher is required"
                    exit 1
                fi
                log_success "Detected Ubuntu $OS_VERSION ($OS_CODENAME)"
                ;;
            debian)
                if [[ "$OS_VERSION" < "11" ]]; then
                    log_error "Debian 11 or higher is required"
                    exit 1
                fi
                log_success "Detected Debian $OS_VERSION ($OS_CODENAME)"
                ;;
            *)
                log_error "Unsupported OS: $OS. Only Ubuntu and Debian are supported."
                exit 1
                ;;
        esac
    else
        log_error "Cannot detect OS. /etc/os-release not found."
        exit 1
    fi
}

check_resources() {
    log_step "Checking system resources..."
    
    # Check RAM (minimum 2GB, recommended 4GB)
    TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
    if [ "$TOTAL_RAM" -lt 2048 ]; then
        log_error "Minimum 2GB RAM required. Found: ${TOTAL_RAM}MB"
        exit 1
    elif [ "$TOTAL_RAM" -lt 4096 ]; then
        log_warning "4GB+ RAM recommended for Office support. Found: ${TOTAL_RAM}MB"
    else
        log_success "RAM: ${TOTAL_RAM}MB"
    fi
    
    # Check disk space (minimum 20GB)
    FREE_DISK=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')
    if [ "$FREE_DISK" -lt 20 ]; then
        log_error "Minimum 20GB free disk space required. Found: ${FREE_DISK}GB"
        exit 1
    else
        log_success "Free disk space: ${FREE_DISK}GB"
    fi
    
    # Check CPU cores
    CPU_CORES=$(nproc)
    if [ "$CPU_CORES" -lt 2 ]; then
        log_warning "2+ CPU cores recommended. Found: $CPU_CORES"
    else
        log_success "CPU cores: $CPU_CORES"
    fi
}

generate_password() {
    openssl rand -base64 32 | tr -d '/+=' | cut -c1-24
}

#===============================================================================
# Configuration Collection
#===============================================================================

collect_configuration() {
    echo ""
    log_step "Configuration Setup"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Domain
    while true; do
        read -p "Enter your domain name (e.g., cloud.example.com): " DOMAIN
        if [[ -n "$DOMAIN" ]]; then
            break
        fi
        log_error "Domain cannot be empty"
    done
    
    # Admin username
    read -p "Enter Nextcloud admin username [admin]: " ADMIN_USER
    ADMIN_USER=${ADMIN_USER:-admin}
    
    # Admin password
    while true; do
        read -s -p "Enter Nextcloud admin password (min 10 chars): " ADMIN_PASS
        echo ""
        if [[ ${#ADMIN_PASS} -lt 10 ]]; then
            log_error "Password must be at least 10 characters"
            continue
        fi
        
        read -s -p "Confirm admin password: " ADMIN_PASS_CONFIRM
        echo ""
        
        if [[ "$ADMIN_PASS" == "$ADMIN_PASS_CONFIRM" ]]; then
            break
        else
            log_error "Passwords do not match. Please try again."
        fi
    done
    
    # Admin email
    read -p "Enter admin email (for SSL certificate): " ADMIN_EMAIL
    
    # Web server selection
    echo ""
    echo "Select web server:"
    echo "  1) Apache (recommended for beginners)"
    echo "  2) Nginx (better performance)"
    read -p "Choice [1]: " WS_CHOICE
    case $WS_CHOICE in
        2) WEBSERVER="nginx" ;;
        *) WEBSERVER="apache" ;;
    esac
    
    # Office suite selection
    echo ""
    echo "Select Office suite:"
    echo "  1) Collabora Online (LibreOffice-based)"
    echo "  2) OnlyOffice (MS Office compatible)"
    echo "  3) None (skip Office installation)"
    read -p "Choice [1]: " OFFICE_CHOICE
    case $OFFICE_CHOICE in
        2) OFFICE_SUITE="onlyoffice" ;;
        3) OFFICE_SUITE="none" ;;
        *) OFFICE_SUITE="collabora" ;;
    esac
    
    # Office subdomain
    if [[ "$OFFICE_SUITE" != "none" ]]; then
        read -p "Enter Office subdomain [office.${DOMAIN}]: " OFFICE_DOMAIN
        OFFICE_DOMAIN=${OFFICE_DOMAIN:-office.${DOMAIN}}
    fi
    
    # Generate database password
    DB_PASS=$(generate_password)
    DB_NAME="nextcloud"
    DB_USER="nextcloud"
    
    # Generate Redis password
    REDIS_PASS=$(generate_password)
    
    # Save configuration
    save_configuration
    
    # Display summary
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Configuration Summary:"
    echo "  Domain:        $DOMAIN"
    echo "  Admin User:    $ADMIN_USER"
    echo "  Web Server:    $WEBSERVER"
    echo "  Office Suite:  $OFFICE_SUITE"
    [[ "$OFFICE_SUITE" != "none" ]] && echo "  Office Domain: $OFFICE_DOMAIN"
    echo "  Database:      MariaDB"
    echo "  Caching:       Redis + APCu"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    read -p "Continue with installation? [Y/n]: " CONFIRM
    if [[ "$CONFIRM" =~ ^[Nn] ]]; then
        log_info "Installation cancelled by user"
        exit 0
    fi
}

save_configuration() {
    # Save configuration for backup/restore scripts
    cat > "${SCRIPT_DIR}/.install-config" << EOF
# Nextcloud Installation Configuration
# Generated: $(date)
DOMAIN="${DOMAIN}"
ADMIN_USER="${ADMIN_USER}"
ADMIN_EMAIL="${ADMIN_EMAIL}"
WEBSERVER="${WEBSERVER}"
OFFICE_SUITE="${OFFICE_SUITE}"
OFFICE_DOMAIN="${OFFICE_DOMAIN}"
DB_NAME="${DB_NAME}"
DB_USER="${DB_USER}"
DB_PASS="${DB_PASS}"
REDIS_PASS="${REDIS_PASS}"
NEXTCLOUD_PATH="${NEXTCLOUD_PATH}"
DATA_PATH="${DATA_PATH}"
BACKUP_PATH="${BACKUP_PATH}"
PHP_VERSION="${PHP_VERSION}"
EOF
    chmod 600 "${SCRIPT_DIR}/.install-config"
}

#===============================================================================
# Main Installation Flow
#===============================================================================

run_installation() {
    log_step "Starting Nextcloud installation..."
    echo ""
    
    # Export variables for sub-scripts
    export DOMAIN ADMIN_USER ADMIN_PASS ADMIN_EMAIL WEBSERVER OFFICE_SUITE OFFICE_DOMAIN
    export DB_NAME DB_USER DB_PASS REDIS_PASS
    export NEXTCLOUD_PATH DATA_PATH BACKUP_PATH PHP_VERSION
    export OS OS_VERSION OS_CODENAME
    
    # Step 1: Install dependencies
    log_step "[1/8] Installing dependencies..."
    source "${SCRIPTS_DIR}/01-dependencies.sh"
    install_dependencies
    
    # Step 2: Configure database
    log_step "[2/8] Configuring database..."
    source "${SCRIPTS_DIR}/02-database.sh"
    configure_database
    
    # Step 3: Install Nextcloud
    log_step "[3/8] Installing Nextcloud..."
    source "${SCRIPTS_DIR}/03-nextcloud.sh"
    install_nextcloud
    
    # Step 4: Configure web server
    log_step "[4/8] Configuring web server..."
    source "${SCRIPTS_DIR}/04-webserver.sh"
    configure_webserver
    
    # Step 5: Configure SSL
    log_step "[5/8] Configuring SSL certificate..."
    source "${SCRIPTS_DIR}/05-ssl.sh"
    configure_ssl
    
    # Step 6: Install Office suite (if selected)
    if [[ "$OFFICE_SUITE" != "none" ]]; then
        log_step "[6/8] Installing Office suite..."
        source "${SCRIPTS_DIR}/06-office.sh"
        install_office
    else
        log_info "[6/8] Skipping Office installation..."
    fi
    
    # Step 7: Configure security
    log_step "[7/8] Applying security hardening..."
    source "${SCRIPTS_DIR}/07-security.sh"
    configure_security
    
    # Step 8: Configure performance/caching
    log_step "[8/8] Optimizing performance..."
    source "${SCRIPTS_DIR}/08-performance.sh"
    configure_performance
    
    # Final configuration
    finalize_installation
}

finalize_installation() {
    log_step "Finalizing installation..."
    
    # Set correct permissions
    chown -R www-data:www-data "${NEXTCLOUD_PATH}"
    chown -R www-data:www-data "${DATA_PATH}"
    
    # Run Nextcloud maintenance commands
    cd "${NEXTCLOUD_PATH}"
    sudo -u www-data php occ maintenance:mode --off
    sudo -u www-data php occ db:add-missing-indices
    sudo -u www-data php occ db:convert-filecache-bigint --no-interaction
    sudo -u www-data php occ maintenance:repair
    
    # Restart services
    systemctl restart php${PHP_VERSION}-fpm
    systemctl restart redis-server
    
    if [[ "$WEBSERVER" == "apache" ]]; then
        systemctl restart apache2
    else
        systemctl restart nginx
    fi
}

print_summary() {
    echo ""
    echo -e "${GREEN}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║              Installation Completed Successfully!                 ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
    log_success "Nextcloud is now available at: https://${DOMAIN}"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Login Credentials:"
    echo "    Username: ${ADMIN_USER}"
    echo "    Password: (the password you entered)"
    echo ""
    echo "  Important Paths:"
    echo "    Nextcloud:      ${NEXTCLOUD_PATH}"
    echo "    Data Directory: ${DATA_PATH}"
    echo "    Backups:        ${BACKUP_PATH}"
    echo "    Config:         ${NEXTCLOUD_PATH}/config/config.php"
    echo ""
    echo "  Useful Commands:"
    echo "    Backup:   ${SCRIPT_DIR}/backup.sh"
    echo "    Restore:  ${SCRIPT_DIR}/restore.sh"
    echo "    OCC CLI:  sudo -u www-data php ${NEXTCLOUD_PATH}/occ"
    echo ""
    if [[ "$OFFICE_SUITE" != "none" ]]; then
        echo "  Office Suite:"
        echo "    ${OFFICE_SUITE^} available at: https://${OFFICE_DOMAIN}"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    log_info "Configuration saved to: ${SCRIPT_DIR}/.install-config"
    log_warning "Keep this file secure - it contains database passwords!"
    echo ""
}

#===============================================================================
# Main Entry Point
#===============================================================================

main() {
    print_banner
    
    log_step "Pre-installation checks..."
    check_root
    check_os
    check_resources
    
    collect_configuration
    run_installation
    print_summary
    
    log_success "Nextcloud installation complete!"
}

# Run main function
main "$@"
