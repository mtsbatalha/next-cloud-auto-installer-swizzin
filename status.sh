#!/bin/bash
#===============================================================================
# Nextcloud Status Script
# Shows status of all services, ports, and health checks
#===============================================================================

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
fi

# Default ports if not in config
HTTP_PORT="${HTTP_PORT:-80}"
HTTPS_PORT="${HTTPS_PORT:-443}"

#===============================================================================
# Helper Functions
#===============================================================================

print_header() {
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              Nextcloud Status Dashboard                       ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_section() {
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${PURPLE}  $1${NC}"
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

status_icon() {
    if [[ "$1" == "running" ]] || [[ "$1" == "active" ]] || [[ "$1" == "ok" ]]; then
        echo -e "${GREEN}●${NC}"
    elif [[ "$1" == "stopped" ]] || [[ "$1" == "inactive" ]] || [[ "$1" == "failed" ]]; then
        echo -e "${RED}●${NC}"
    else
        echo -e "${YELLOW}●${NC}"
    fi
}

get_service_status() {
    local service=$1
    if systemctl is-active --quiet "$service"; then
        echo "running"
    else
        echo "stopped"
    fi
}

get_port_status() {
    local port=$1
    if netstat -tuln 2>/dev/null | grep -q ":$port "; then
        echo "listening"
    else
        echo "closed"
    fi
}

#===============================================================================
# Status Checks
#===============================================================================

check_system_info() {
    print_section "System Information"
    
    echo -e "  Hostname:        $(hostname)"
    echo -e "  OS:              $(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
    echo -e "  Kernel:          $(uname -r)"
    echo -e "  Uptime:          $(uptime -p)"
    
    # CPU
    CPU_CORES=$(nproc)
    CPU_LOAD=$(uptime | awk -F'load average:' '{print $2}' | xargs)
    echo -e "  CPU Cores:       $CPU_CORES"
    echo -e "  Load Average:    $CPU_LOAD"
    
    # Memory
    TOTAL_RAM=$(free -h | awk '/^Mem:/{print $2}')
    USED_RAM=$(free -h | awk '/^Mem:/{print $3}')
    FREE_RAM=$(free -h | awk '/^Mem:/{print $4}')
    RAM_PERCENT=$(free | awk '/^Mem:/{printf "%.1f", $3/$2 * 100}')
    echo -e "  Memory:          ${USED_RAM} / ${TOTAL_RAM} (${RAM_PERCENT}% used)"
    
    # Disk
    DISK_USAGE=$(df -h / | awk 'NR==2 {print $3 " / " $2 " (" $5 " used)"}')
    echo -e "  Disk (root):     $DISK_USAGE"
    
    if [[ -d "$DATA_PATH" ]]; then
        DATA_USAGE=$(df -h "$DATA_PATH" | awk 'NR==2 {print $3 " / " $2 " (" $5 " used)"}')
        echo -e "  Disk (data):     $DATA_USAGE"
    fi
    
    echo ""
}

check_services() {
    print_section "Services Status"
    
    declare -A SERVICES=(
        ["mariadb"]="MariaDB Database"
        ["redis-server"]="Redis Cache"
        ["apache2"]="Apache Web Server"
        ["nginx"]="Nginx Web Server"
        ["php8.2-fpm"]="PHP-FPM 8.2"
        ["fail2ban"]="Fail2ban"
        ["docker"]="Docker"
    )
    
    printf "  %-30s %-15s %s\n" "Service" "Status" "PID"
    echo "  ────────────────────────────────────────────────────────────"
    
    for service in "${!SERVICES[@]}"; do
        STATUS=$(get_service_status "$service")
        ICON=$(status_icon "$STATUS")
        
        if [[ "$STATUS" == "running" ]]; then
            PID=$(systemctl show -p MainPID --value "$service" 2>/dev/null)
            printf "  $ICON %-28s ${GREEN}%-15s${NC} %s\n" "${SERVICES[$service]}" "$STATUS" "$PID"
        else
            printf "  $ICON %-28s ${RED}%-15s${NC} %s\n" "${SERVICES[$service]}" "$STATUS" "-"
        fi
    done
    
    echo ""
}

check_ports() {
    print_section "Network Ports"
    
    declare -A PORTS=(
        ["${HTTP_PORT}"]="HTTP"
        ["${HTTPS_PORT}"]="HTTPS"
        ["3306"]="MariaDB"
        ["9980"]="Office Suite"
    )
    
    printf "  %-10s %-20s %s\n" "Port" "Service" "Status"
    echo "  ────────────────────────────────────────────────────"
    
    for port in "${!PORTS[@]}"; do
        PORT_STATUS=$(get_port_status "$port")
        ICON=$(status_icon "$PORT_STATUS")
        
        if [[ "$PORT_STATUS" == "listening" ]]; then
            # Get process using the port
            PROCESS=$(netstat -tulnp 2>/dev/null | grep ":$port " | awk '{print $7}' | cut -d'/' -f2 | head -1)
            printf "  $ICON %-8s %-20s ${GREEN}listening${NC} (%s)\n" "$port" "${PORTS[$port]}" "$PROCESS"
        else
            printf "  $ICON %-8s %-20s ${RED}closed${NC}\n" "$port" "${PORTS[$port]}"
        fi
    done
    
    echo ""
}

check_docker_containers() {
    print_section "Docker Containers"
    
    if ! command -v docker &> /dev/null; then
        echo -e "  ${YELLOW}Docker not installed${NC}"
        echo ""
        return
    fi
    
    if ! docker ps &> /dev/null; then
        echo -e "  ${RED}Docker daemon not running${NC}"
        echo ""
        return
    fi
    
    CONTAINERS=$(docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "collabora|onlyoffice" || echo "")
    
    if [[ -z "$CONTAINERS" ]]; then
        echo -e "  ${YELLOW}No Office containers found${NC}"
    else
        echo "$CONTAINERS" | awk '{print "  "$0}'
    fi
    
    echo ""
}

check_nextcloud() {
    print_section "Nextcloud Status"
    
    if [[ ! -d "$NEXTCLOUD_PATH" ]]; then
        echo -e "  ${RED}Nextcloud not found at: $NEXTCLOUD_PATH${NC}"
        echo ""
        return
    fi
    
    cd "$NEXTCLOUD_PATH"
    
    # Version
    NC_VERSION=$(sudo -u www-data php occ -V 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo "unknown")
    echo -e "  Version:         $NC_VERSION"
    
    # Maintenance mode
    MAINTENANCE=$(sudo -u www-data php occ config:system:get maintenance 2>/dev/null || echo "false")
    if [[ "$MAINTENANCE" == "true" ]]; then
        echo -e "  Maintenance:     ${YELLOW}ENABLED${NC}"
    else
        echo -e "  Maintenance:     ${GREEN}DISABLED${NC}"
    fi
    
    # Status
    STATUS_OUTPUT=$(sudo -u www-data php occ status --output=json 2>/dev/null)
    if [[ $? -eq 0 ]]; then
        INSTALLED=$(echo "$STATUS_OUTPUT" | grep -oP '"installed":\K\w+')
        if [[ "$INSTALLED" == "true" ]]; then
            echo -e "  Installation:    ${GREEN}OK${NC}"
        else
            echo -e "  Installation:    ${RED}NOT INSTALLED${NC}"
        fi
    fi
    
    # Database
    DB_TYPE=$(sudo -u www-data php occ config:system:get dbtype 2>/dev/null || echo "unknown")
    echo -e "  Database:        $DB_TYPE"
    
    # Cache
    CACHE_LOCAL=$(sudo -u www-data php occ config:system:get memcache.local 2>/dev/null || echo "none")
    CACHE_DIST=$(sudo -u www-data php occ config:system:get memcache.distributed 2>/dev/null || echo "none")
    echo -e "  Cache (local):   ${CACHE_LOCAL##*\\\\}"
    echo -e "  Cache (dist):    ${CACHE_DIST##*\\\\}"
    
    # Users
    USER_COUNT=$(sudo -u www-data php occ user:list --output=json 2>/dev/null | grep -o '"' | wc -l)
    USER_COUNT=$((USER_COUNT / 2))
    echo -e "  Users:           $USER_COUNT"
    
    # Apps
    APP_COUNT=$(sudo -u www-data php occ app:list --output=json 2>/dev/null | grep -c '"enabled"')
    echo -e "  Enabled Apps:    $APP_COUNT"
    
    echo ""
}

check_redis() {
    print_section "Redis Cache"
    
    if ! systemctl is-active --quiet redis-server; then
        echo -e "  ${RED}Redis is not running${NC}"
        echo ""
        return
    fi
    
    # Try socket connection
    if [[ -S /var/run/redis/redis-server.sock ]]; then
        REDIS_INFO=$(redis-cli -s /var/run/redis/redis-server.sock info 2>/dev/null || echo "")
        if [[ -n "$REDIS_INFO" ]]; then
            REDIS_VERSION=$(echo "$REDIS_INFO" | grep "redis_version:" | cut -d':' -f2 | tr -d '\r')
            REDIS_UPTIME=$(echo "$REDIS_INFO" | grep "uptime_in_days:" | cut -d':' -f2 | tr -d '\r')
            REDIS_MEMORY=$(echo "$REDIS_INFO" | grep "used_memory_human:" | cut -d':' -f2 | tr -d '\r')
            REDIS_KEYS=$(echo "$REDIS_INFO" | grep "keys=" | grep -oP 'keys=\K\d+' | head -1)
            
            echo -e "  Version:         $REDIS_VERSION"
            echo -e "  Uptime:          $REDIS_UPTIME days"
            echo -e "  Memory Used:     $REDIS_MEMORY"
            echo -e "  Keys:            ${REDIS_KEYS:-0}"
            echo -e "  Connection:      ${GREEN}Socket (optimal)${NC}"
        fi
    else
        echo -e "  ${YELLOW}Socket not found, trying TCP...${NC}"
        REDIS_PING=$(redis-cli ping 2>/dev/null || echo "FAIL")
        if [[ "$REDIS_PING" == "PONG" ]]; then
            echo -e "  Connection:      ${YELLOW}TCP (not optimal)${NC}"
        else
            echo -e "  Connection:      ${RED}FAILED${NC}"
        fi
    fi
    
    echo ""
}

check_php() {
    print_section "PHP Configuration"
    
    PHP_VERSION=$(php -v 2>/dev/null | head -1 | awk '{print $2}')
    echo -e "  Version:         $PHP_VERSION"
    
    # PHP-FPM status
    FPM_STATUS=$(get_service_status "php8.2-fpm")
    if [[ "$FPM_STATUS" == "running" ]]; then
        echo -e "  PHP-FPM:         ${GREEN}running${NC}"
        
        # Get pool info
        POOL_INFO=$(systemctl status php8.2-fpm 2>/dev/null | grep -oP 'pool www|pool nextcloud' | head -1)
        if [[ -n "$POOL_INFO" ]]; then
            echo -e "  Active Pool:     $POOL_INFO"
        fi
    else
        echo -e "  PHP-FPM:         ${RED}stopped${NC}"
    fi
    
    # Memory limit
    MEMORY_LIMIT=$(php -i 2>/dev/null | grep "memory_limit" | head -1 | awk '{print $3}')
    echo -e "  Memory Limit:    $MEMORY_LIMIT"
    
    # Upload size
    UPLOAD_SIZE=$(php -i 2>/dev/null | grep "upload_max_filesize" | head -1 | awk '{print $3}')
    echo -e "  Max Upload:      $UPLOAD_SIZE"
    
    # OPcache
    OPCACHE_STATUS=$(php -i 2>/dev/null | grep "opcache.enable" | head -1 | awk '{print $3}')
    if [[ "$OPCACHE_STATUS" == "On" ]]; then
        echo -e "  OPcache:         ${GREEN}enabled${NC}"
    else
        echo -e "  OPcache:         ${RED}disabled${NC}"
    fi
    
    echo ""
}

check_ssl() {
    print_section "SSL Certificates"
    
    if [[ -n "$DOMAIN" && -d "/etc/letsencrypt/live/$DOMAIN" ]]; then
        CERT_FILE="/etc/letsencrypt/live/$DOMAIN/cert.pem"
        
        if [[ -f "$CERT_FILE" ]]; then
            EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_FILE" | cut -d'=' -f2)
            EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s)
            NOW_EPOCH=$(date +%s)
            DAYS_LEFT=$(( ($EXPIRY_EPOCH - $NOW_EPOCH) / 86400 ))
            
            echo -e "  Domain:          $DOMAIN"
            echo -e "  Expires:         $EXPIRY"
            
            if [[ $DAYS_LEFT -lt 30 ]]; then
                echo -e "  Days Left:       ${YELLOW}$DAYS_LEFT days${NC}"
            else
                echo -e "  Days Left:       ${GREEN}$DAYS_LEFT days${NC}"
            fi
        fi
    else
        echo -e "  ${YELLOW}No SSL certificate found${NC}"
    fi
    
    echo ""
}

check_backups() {
    print_section "Recent Backups"
    
    BACKUP_PATH="${BACKUP_PATH:-/var/backups/nextcloud}"
    
    if [[ -d "$BACKUP_PATH" ]]; then
        BACKUPS=$(find "$BACKUP_PATH" -name "nextcloud-backup-*.tar.gz" -type f -printf "%T@ %p\n" 2>/dev/null | sort -rn | head -5)
        
        if [[ -n "$BACKUPS" ]]; then
            printf "  %-30s %s\n" "Date" "Size"
            echo "  ────────────────────────────────────────────────────"
            
            while IFS= read -r line; do
                TIMESTAMP=$(echo "$line" | awk '{print $1}')
                FILEPATH=$(echo "$line" | awk '{print $2}')
                DATE=$(date -d "@$TIMESTAMP" "+%Y-%m-%d %H:%M:%S")
                SIZE=$(du -h "$FILEPATH" | cut -f1)
                printf "  %-30s %s\n" "$DATE" "$SIZE"
            done <<< "$BACKUPS"
        else
            echo -e "  ${YELLOW}No backups found${NC}"
        fi
    else
        echo -e "  ${YELLOW}Backup directory not found${NC}"
    fi
    
    echo ""
}

#===============================================================================
# Main
#===============================================================================

main() {
    clear
    print_header
    
    check_system_info
    check_services
    check_ports
    check_docker_containers
    check_nextcloud
    check_redis
    check_php
    check_ssl
    check_backups
    
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Run './manage.sh' to start/stop/restart services${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

main "$@"
