#!/bin/bash
#===============================================================================
# Nextcloud Management Script
# Start, stop, restart, and manage all Nextcloud services
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
    WEBSERVER="apache"
    OFFICE_SUITE="none"
fi

#===============================================================================
# Helper Functions
#===============================================================================

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

print_banner() {
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║           Nextcloud Service Management                        ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

show_usage() {
    cat << EOF
Nextcloud Service Management Script

Usage: $0 COMMAND [OPTIONS]

Commands:
    start       Start all Nextcloud services
    stop        Stop all Nextcloud services
    restart     Restart all Nextcloud services
    status      Show quick status of all services
    enable      Enable services to start on boot
    disable     Disable services from starting on boot
    logs        Show recent logs
    help        Show this help message

Options:
    --web-only      Only affect web server
    --db-only       Only affect database
    --cache-only    Only affect caching services
    --office-only   Only affect office suite

Examples:
    $0 restart
    $0 stop --web-only
    $0 logs
    $0 enable

EOF
    exit 0
}

#===============================================================================
# Service Management
#===============================================================================

manage_webserver() {
    local action=$1
    
    if [[ "$WEBSERVER" == "apache" ]]; then
        if systemctl list-units --full -all | grep -q apache2.service; then
            systemctl $action apache2
            log_info "Apache: $action"
        fi
    else
        if systemctl list-units --full -all | grep -q nginx.service; then
            systemctl $action nginx
            log_info "Nginx: $action"
        fi
    fi
}

manage_php() {
    local action=$1
    
    # Detect PHP version
    PHP_VERSIONS=("8.2" "8.1" "8.0" "7.4")
    
    for version in "${PHP_VERSIONS[@]}"; do
        if systemctl list-units --full -all | grep -q "php${version}-fpm.service"; then
            systemctl $action "php${version}-fpm"
            log_info "PHP-FPM ${version}: $action"
            return
        fi
    done
    
    log_warning "No PHP-FPM service found"
}

manage_database() {
    local action=$1
    
    if systemctl list-units --full -all | grep -q mariadb.service; then
        systemctl $action mariadb
        log_info "MariaDB: $action"
    elif systemctl list-units --full -all | grep -q mysql.service; then
        systemctl $action mysql
        log_info "MySQL: $action"
    else
        log_warning "No database service found"
    fi
}

manage_redis() {
    local action=$1
    
    if systemctl list-units --full -all | grep -q redis-server.service; then
        systemctl $action redis-server
        log_info "Redis: $action"
    else
        log_warning "Redis service not found"
    fi
}

manage_fail2ban() {
    local action=$1
    
    if systemctl list-units --full -all | grep -q fail2ban.service; then
        systemctl $action fail2ban
        log_info "Fail2ban: $action"
    fi
}

manage_docker_office() {
    local action=$1
    
    if ! command -v docker &> /dev/null; then
        return
    fi
    
    # Find office containers
    COLLABORA=$(docker ps -a -q -f name=collabora 2>/dev/null)
    ONLYOFFICE=$(docker ps -a -q -f name=onlyoffice 2>/dev/null)
    
    if [[ -n "$COLLABORA" ]]; then
        case $action in
            start)
                docker start collabora
                log_info "Collabora: started"
                ;;
            stop)
                docker stop collabora
                log_info "Collabora: stopped"
                ;;
            restart)
                docker restart collabora
                log_info "Collabora: restarted"
                ;;
        esac
    fi
    
    if [[ -n "$ONLYOFFICE" ]]; then
        case $action in
            start)
                docker start onlyoffice
                log_info "OnlyOffice: started"
                ;;
            stop)
                docker stop onlyoffice
                log_info "OnlyOffice: stopped"
                ;;
            restart)
                docker restart onlyoffice
                log_info "OnlyOffice: restarted"
                ;;
        esac
    fi
}

#===============================================================================
# Main Commands
#===============================================================================

start_services() {
    log_info "Starting Nextcloud services..."
    echo ""
    
    if [[ "$DB_ONLY" == "true" ]]; then
        manage_database start
    elif [[ "$CACHE_ONLY" == "true" ]]; then
        manage_redis start
    elif [[ "$WEB_ONLY" == "true" ]]; then
        manage_php start
        manage_webserver start
    elif [[ "$OFFICE_ONLY" == "true" ]]; then
        manage_docker_office start
    else
        # Start all services in order
        manage_database start
        manage_redis start
        manage_php start
        manage_webserver start
        manage_fail2ban start
        manage_docker_office start
    fi
    
    echo ""
    log_success "Services started"
}

stop_services() {
    log_info "Stopping Nextcloud services..."
    echo ""
    
    if [[ "$DB_ONLY" == "true" ]]; then
        manage_database stop
    elif [[ "$CACHE_ONLY" == "true" ]]; then
        manage_redis stop
    elif [[ "$WEB_ONLY" == "true" ]]; then
        manage_webserver stop
        manage_php stop
    elif [[ "$OFFICE_ONLY" == "true" ]]; then
        manage_docker_office stop
    else
        # Stop all services in reverse order
        manage_docker_office stop
        manage_fail2ban stop
        manage_webserver stop
        manage_php stop
        manage_redis stop
        manage_database stop
    fi
    
    echo ""
    log_success "Services stopped"
}

restart_services() {
    log_info "Restarting Nextcloud services..."
    echo ""
    
    if [[ "$DB_ONLY" == "true" ]]; then
        manage_database restart
    elif [[ "$CACHE_ONLY" == "true" ]]; then
        manage_redis restart
    elif [[ "$WEB_ONLY" == "true" ]]; then
        manage_php restart
        manage_webserver restart
    elif [[ "$OFFICE_ONLY" == "true" ]]; then
        manage_docker_office restart
    else
        # Restart all services
        manage_database restart
        manage_redis restart
        manage_php restart
        manage_webserver restart
        manage_fail2ban restart
        manage_docker_office restart
    fi
    
    echo ""
    log_success "Services restarted"
}

show_status() {
    log_info "Checking service status..."
    echo ""
    
    printf "%-20s %s\n" "Service" "Status"
    printf "%-20s %s\n" "────────────────────" "──────────────"
    
    # Check each service
    for service in mariadb redis-server php8.2-fpm apache2 nginx fail2ban docker; do
        if systemctl list-units --full -all | grep -q "${service}.service"; then
            if systemctl is-active --quiet "$service"; then
                printf "%-20s ${GREEN}running${NC}\n" "$service"
            else
                printf "%-20s ${RED}stopped${NC}\n" "$service"
            fi
        fi
    done
    
    # Check Docker containers
    if command -v docker &> /dev/null; then
        if docker ps -q -f name=collabora &>/dev/null; then
            STATUS=$(docker inspect -f '{{.State.Status}}' collabora 2>/dev/null)
            if [[ "$STATUS" == "running" ]]; then
                printf "%-20s ${GREEN}running${NC}\n" "collabora"
            else
                printf "%-20s ${RED}stopped${NC}\n" "collabora"
            fi
        fi
        
        if docker ps -q -f name=onlyoffice &>/dev/null; then
            STATUS=$(docker inspect -f '{{.State.Status}}' onlyoffice 2>/dev/null)
            if [[ "$STATUS" == "running" ]]; then
                printf "%-20s ${GREEN}running${NC}\n" "onlyoffice"
            else
                printf "%-20s ${RED}stopped${NC}\n" "onlyoffice"
            fi
        fi
    fi
    
    echo ""
    log_info "For detailed status, run: ./status.sh"
}

enable_services() {
    log_info "Enabling services to start on boot..."
    echo ""
    
    manage_database enable
    manage_redis enable
    manage_php enable
    manage_webserver enable
    manage_fail2ban enable
    
    # Enable Docker containers to restart automatically
    if command -v docker &> /dev/null; then
        if docker ps -a -q -f name=collabora &>/dev/null; then
            docker update --restart=always collabora
            log_info "Collabora: enabled auto-restart"
        fi
        
        if docker ps -a -q -f name=onlyoffice &>/dev/null; then
            docker update --restart=always onlyoffice
            log_info "OnlyOffice: enabled auto-restart"
        fi
    fi
    
    echo ""
    log_success "Services enabled"
}

disable_services() {
    log_info "Disabling services from starting on boot..."
    echo ""
    
    manage_database disable
    manage_redis disable
    manage_php disable
    manage_webserver disable
    manage_fail2ban disable
    
    # Disable Docker containers auto-restart
    if command -v docker &> /dev/null; then
        if docker ps -a -q -f name=collabora &>/dev/null; then
            docker update --restart=no collabora
            log_info "Collabora: disabled auto-restart"
        fi
        
        if docker ps -a -q -f name=onlyoffice &>/dev/null; then
            docker update --restart=no onlyoffice
            log_info "OnlyOffice: disabled auto-restart"
        fi
    fi
    
    echo ""
    log_success "Services disabled"
}

show_logs() {
    log_info "Recent logs:"
    echo ""
    
    echo -e "${CYAN}=== Nextcloud Logs ===${NC}"
    if [[ -f "/var/nextcloud-data/nextcloud.log" ]]; then
        tail -20 /var/nextcloud-data/nextcloud.log
    fi
    
    echo ""
    echo -e "${CYAN}=== Web Server Logs ===${NC}"
    if [[ "$WEBSERVER" == "apache" ]]; then
        tail -20 /var/log/apache2/nextcloud-error.log 2>/dev/null || echo "No logs found"
    else
        tail -20 /var/log/nginx/nextcloud-error.log 2>/dev/null || echo "No logs found"
    fi
    
    echo ""
    echo -e "${CYAN}=== PHP-FPM Logs ===${NC}"
    journalctl -u php8.2-fpm -n 20 --no-pager 2>/dev/null || echo "No logs found"
}

#===============================================================================
# Main
#===============================================================================

main() {
    print_banner
    check_root
    
    # Parse command
    COMMAND="${1:-help}"
    shift || true
    
    # Parse options
    WEB_ONLY=false
    DB_ONLY=false
    CACHE_ONLY=false
    OFFICE_ONLY=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --web-only)
                WEB_ONLY=true
                shift
                ;;
            --db-only)
                DB_ONLY=true
                shift
                ;;
            --cache-only)
                CACHE_ONLY=true
                shift
                ;;
            --office-only)
                OFFICE_ONLY=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                ;;
        esac
    done
    
    # Execute command
    case $COMMAND in
        start)
            start_services
            ;;
        stop)
            stop_services
            ;;
        restart)
            restart_services
            ;;
        status)
            show_status
            ;;
        enable)
            enable_services
            ;;
        disable)
            disable_services
            ;;
        logs)
            show_logs
            ;;
        help|--help|-h)
            show_usage
            ;;
        *)
            log_error "Unknown command: $COMMAND"
            show_usage
            ;;
    esac
}

main "$@"
