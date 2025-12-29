#!/bin/bash
#===============================================================================
# Fix Database Connection Issue
# Run this if you're getting database authentication errors
#===============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Load config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/.install-config" ]]; then
    source "${SCRIPT_DIR}/.install-config"
else
    log_error ".install-config not found!"
    exit 1
fi

echo "========================================"
echo "Database Connection Fix"
echo "========================================"
echo ""
echo "Database: $DB_NAME"
echo "User: $DB_USER"
echo ""

log_info "Fixing database user and permissions..."

# Completely remove old user
mysql -e "DROP USER IF EXISTS '${DB_USER}'@'localhost';" 2>/dev/null || true
mysql -e "DROP USER IF EXISTS '${DB_USER}'@'%';" 2>/dev/null || true

# Recreate database
mysql -e "DROP DATABASE IF EXISTS ${DB_NAME};"
mysql -e "CREATE DATABASE ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"

# Create fresh user
mysql -e "CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
mysql -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost' WITH GRANT OPTION;"
mysql -e "FLUSH PRIVILEGES;"

# Test connection
log_info "Testing database connection..."
if mysql -u "${DB_USER}" -p"${DB_PASS}" -e "USE ${DB_NAME}; SELECT 1;" &>/dev/null; then
    log_success "✓ Database connection successful!"
    echo ""
    echo "You can now continue installation:"
    echo "  sudo ./install.sh"
else
    log_error "✗ Database connection still failing!"
    echo ""
    echo "Manual fix required:"
    echo "1. sudo mysql"
    echo "2. DROP USER IF EXISTS '${DB_USER}'@'localhost';"
    echo "3. CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY 'YOUR_PASSWORD';"
    echo "4. GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';"
    echo "5. FLUSH PRIVILEGES;"
    exit 1
fi
