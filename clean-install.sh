#!/bin/bash
#===============================================================================
# Clean Installation - Reset Everything
# Use this when database auth keeps failing
#===============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================"
echo "        CLEAN INSTALLATION"
echo "========================================"
echo ""
log_warning "This will DELETE:"
echo "  - /var/www/nextcloud (entire installation)"
echo "  - Nextcloud database and user"
echo "  - Configuration file (.install-config)"
echo ""
read -p "Are you sure? Type 'yes' to continue: " CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
    echo "Cancelled."
    exit 0
fi

echo ""
log_info "Stopping services..."
systemctl stop nginx 2>/dev/null || true
systemctl stop apache2 2>/dev/null || true

log_info "Removing Nextcloud files..."
rm -rf /var/www/nextcloud
rm -rf /var/nextcloud-data

log_info "Removing database..."
mysql -e "DROP DATABASE IF EXISTS nextcloud;" 2>/dev/null || true
mysql -e "DROP USER IF EXISTS 'nextcloud'@'localhost';" 2>/dev/null || true
mysql -e "DROP USER IF EXISTS 'nextcloud'@'%';" 2>/dev/null || true
mysql -e "FLUSH PRIVILEGES;"

log_info "Removing configuration..."
rm -f "${SCRIPT_DIR}/.install-config"

log_info "Restarting MariaDB..."
systemctl restart mariadb
sleep 2

echo ""
log_success "========================================"
log_success "  CLEANUP COMPLETE!"
log_success "========================================"
echo ""
echo "Now run a fresh installation:"
echo "  sudo ./install.sh"
echo ""
