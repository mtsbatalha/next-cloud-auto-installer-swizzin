#!/bin/bash
#===============================================================================
# Backup Script - Nextcloud + Aplicacoes
# Suporte: Nextcloud, ruTorrent, qBittorrent, Deluge, Plex
#===============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load configuration
[[ -f "${SCRIPT_DIR}/.install-config" ]] && source "${SCRIPT_DIR}/.install-config"

# Auto-detect Nextcloud path if not set
if [[ -z "$NEXTCLOUD_PATH" || ! -f "${NEXTCLOUD_PATH}/occ" ]]; then
    NEXTCLOUD_PATH=""
    for _p in /var/www/nextcloud /srv/nextcloud /var/www/html/nextcloud /opt/nextcloud; do
        if [[ -f "${_p}/occ" ]]; then
            NEXTCLOUD_PATH="$_p"
            break
        fi
    done
    NEXTCLOUD_PATH="${NEXTCLOUD_PATH:-/var/www/nextcloud}"
fi

# Read missing values from config.php
if [[ -f "${NEXTCLOUD_PATH}/config/config.php" ]]; then
    [[ -z "$DATA_PATH" ]] && DATA_PATH=$(grep -oP "'datadirectory'\s*=>\s*'\K[^']+" "${NEXTCLOUD_PATH}/config/config.php" 2>/dev/null || true)
    [[ -z "$DB_NAME" ]] && DB_NAME=$(grep -oP "'dbname'\s*=>\s*'\K[^']+" "${NEXTCLOUD_PATH}/config/config.php" 2>/dev/null || true)
    [[ -z "$DB_USER" ]] && DB_USER=$(grep -oP "'dbuser'\s*=>\s*'\K[^']+" "${NEXTCLOUD_PATH}/config/config.php" 2>/dev/null || true)
fi

# Defaults
DATA_PATH="${DATA_PATH:-/var/nextcloud-data}"
BACKUP_PATH="${BACKUP_PATH:-/var/backups/nextcloud}"
DB_NAME="${DB_NAME:-nextcloud}"
DB_USER="${DB_USER:-nextcloud}"

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[AVISO]${NC} $1"; }
log_error() { echo -e "${RED}[ERRO]${NC} $1"; }
log_step() { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $1"; }

#===============================================================================
# Configuration
#===============================================================================

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="${BACKUP_PATH}/${TIMESTAMP}"
BACKUP_ARCHIVE="${BACKUP_PATH}/backup-${TIMESTAMP}.tar.gz"
RETENTION_DAYS=7

# Nextcloud components
BACKUP_NC=false
BACKUP_NC_DATA=false
BACKUP_NC_CONFIG=false
BACKUP_NC_APPS=false
BACKUP_NC_THEMES=false
BACKUP_NC_DATABASE=false

# Applications
BACKUP_RUTORRENT=false
BACKUP_QBITTORRENT=false
BACKUP_DELUGE=false
BACKUP_PLEX=false
BACKUP_PLEX_META=false   # Plex metadata (can be huge)

# Flags
UPLOAD_REMOTE=false
INTERACTIVE=false

# Detected services
DETECTED_NC=false
DETECTED_RUTORRENT=false
DETECTED_QBITTORRENT=false
DETECTED_DELUGE=false
DETECTED_PLEX=false

# Swizzin user
SWIZZIN_USER=""

#===============================================================================
# Utility
#===============================================================================

format_size() {
    local bytes=$1
    if [[ $bytes -ge 1073741824 ]]; then
        awk "BEGIN {printf \"%.1fGB\", $bytes/1073741824}"
    elif [[ $bytes -ge 1048576 ]]; then
        awk "BEGIN {printf \"%.1fMB\", $bytes/1048576}"
    elif [[ $bytes -ge 1024 ]]; then
        awk "BEGIN {printf \"%.1fKB\", $bytes/1024}"
    else
        echo "${bytes}B"
    fi
}

dir_size_bytes() {
    local path="$1"
    if [[ -d "$path" ]]; then
        du -sb "$path" 2>/dev/null | cut -f1 || echo "0"
    else
        echo "0"
    fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Este script precisa ser executado como root"
        exit 1
    fi
}

#===============================================================================
# Service Detection
#===============================================================================

detect_swizzin_user() {
    # Swizzin master user
    if [[ -f /root/.master.info ]]; then
        SWIZZIN_USER=$(cut -d: -f1 /root/.master.info)
    elif [[ -d /etc/swizzin/users ]]; then
        SWIZZIN_USER=$(ls /etc/swizzin/users/ 2>/dev/null | head -1)
    fi

    # Fallback: find user with torrent services
    if [[ -z "$SWIZZIN_USER" ]]; then
        SWIZZIN_USER=$(systemctl list-units --type=service --all 2>/dev/null \
            | grep -oP '(rtorrent|qbittorrent|deluged)@\K[^.]+' | head -1)
    fi

    # Fallback: first non-root user with home dir
    if [[ -z "$SWIZZIN_USER" ]]; then
        SWIZZIN_USER=$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}' /etc/passwd)
    fi
}

detect_services() {
    log_info "Detectando servicos instalados..."

    # Nextcloud
    if [[ -f "${NEXTCLOUD_PATH}/occ" ]]; then
        DETECTED_NC=true
    fi

    detect_swizzin_user

    # ruTorrent / rTorrent
    if systemctl list-unit-files "rtorrent@*.service" 2>/dev/null | grep -q enabled \
        || [[ -d /srv/rutorrent ]] || [[ -d /var/www/rutorrent ]]; then
        DETECTED_RUTORRENT=true
    fi

    # qBittorrent
    if systemctl list-unit-files "qbittorrent@*.service" 2>/dev/null | grep -q enabled \
        || [[ -n "$SWIZZIN_USER" && -d "/home/${SWIZZIN_USER}/.config/qBittorrent" ]]; then
        DETECTED_QBITTORRENT=true
    fi

    # Deluge
    if systemctl list-unit-files "deluged@*.service" 2>/dev/null | grep -q enabled \
        || [[ -n "$SWIZZIN_USER" && -d "/home/${SWIZZIN_USER}/.config/deluge" ]]; then
        DETECTED_DELUGE=true
    fi

    # Plex
    if systemctl list-unit-files plexmediaserver.service 2>/dev/null | grep -q enabled \
        || [[ -d "/var/lib/plexmediaserver/Library/Application Support/Plex Media Server" ]]; then
        DETECTED_PLEX=true
    fi
}

show_detected() {
    echo ""
    echo -e "${BOLD}Servicos detectados:${NC}"

    if [[ "$DETECTED_NC" == "true" ]]; then
        echo -e "  ${GREEN}●${NC} Nextcloud        ${DIM}${NEXTCLOUD_PATH}${NC}"
    else
        echo -e "  ${RED}○${NC} Nextcloud        ${DIM}(nao encontrado)${NC}"
    fi

    if [[ "$DETECTED_RUTORRENT" == "true" ]]; then
        echo -e "  ${GREEN}●${NC} ruTorrent        ${DIM}rTorrent + Web UI${NC}"
    else
        echo -e "  ${RED}○${NC} ruTorrent        ${DIM}(nao encontrado)${NC}"
    fi

    if [[ "$DETECTED_QBITTORRENT" == "true" ]]; then
        echo -e "  ${GREEN}●${NC} qBittorrent      ${DIM}/home/${SWIZZIN_USER}/.config/qBittorrent${NC}"
    else
        echo -e "  ${RED}○${NC} qBittorrent      ${DIM}(nao encontrado)${NC}"
    fi

    if [[ "$DETECTED_DELUGE" == "true" ]]; then
        echo -e "  ${GREEN}●${NC} Deluge           ${DIM}/home/${SWIZZIN_USER}/.config/deluge${NC}"
    else
        echo -e "  ${RED}○${NC} Deluge           ${DIM}(nao encontrado)${NC}"
    fi

    if [[ "$DETECTED_PLEX" == "true" ]]; then
        echo -e "  ${GREEN}●${NC} Plex             ${DIM}/var/lib/plexmediaserver${NC}"
    else
        echo -e "  ${RED}○${NC} Plex             ${DIM}(nao encontrado)${NC}"
    fi
}

#===============================================================================
# Size Estimation
#===============================================================================

estimate_all_sizes() {
    local nc_db=0
    local nc_data=0
    local nc_config=0
    local rt_size=0
    local qbt_size=0
    local de_size=0
    local plex_size=0
    local plex_meta=0

    # Nextcloud DB
    if [[ "$DETECTED_NC" == "true" ]]; then
        if [[ -z "$DB_PASS" ]]; then
            DB_PASS=$(grep -oP "'dbpassword'\s*=>\s*'\K[^']+" "${NEXTCLOUD_PATH}/config/config.php" 2>/dev/null || echo "")
        fi
        if [[ -n "$DB_PASS" ]]; then
            nc_db=$(mysql -u "${DB_USER}" -p"${DB_PASS}" -N -e \
                "SELECT COALESCE(SUM(data_length + index_length),0) FROM information_schema.tables WHERE table_schema='${DB_NAME}';" 2>/dev/null || echo "0")
            nc_db=${nc_db:-0}
        fi
        nc_data=$(dir_size_bytes "${DATA_PATH}")
        nc_config=$(dir_size_bytes "${NEXTCLOUD_PATH}/config")
    fi

    # ruTorrent
    if [[ "$DETECTED_RUTORRENT" == "true" && -n "$SWIZZIN_USER" ]]; then
        local rt_conf
        rt_conf=$(dir_size_bytes "/home/${SWIZZIN_USER}/.sessions")
        local rt_web=0
        for d in /srv/rutorrent /var/www/rutorrent; do
            if [[ -d "$d" ]]; then
                rt_web=$(dir_size_bytes "$d/conf")
                break
            fi
        done
        rt_size=$((rt_conf + rt_web))
    fi

    # qBittorrent
    if [[ "$DETECTED_QBITTORRENT" == "true" && -n "$SWIZZIN_USER" ]]; then
        qbt_size=$(dir_size_bytes "/home/${SWIZZIN_USER}/.config/qBittorrent")
        local qbt_data
        qbt_data=$(dir_size_bytes "/home/${SWIZZIN_USER}/.local/share/qBittorrent/BT_backup")
        qbt_size=$((qbt_size + qbt_data))
    fi

    # Deluge
    if [[ "$DETECTED_DELUGE" == "true" && -n "$SWIZZIN_USER" ]]; then
        de_size=$(dir_size_bytes "/home/${SWIZZIN_USER}/.config/deluge")
    fi

    # Plex
    if [[ "$DETECTED_PLEX" == "true" ]]; then
        local plex_base="/var/lib/plexmediaserver/Library/Application Support/Plex Media Server"
        plex_size=$(dir_size_bytes "${plex_base}/Plug-in Support/Databases")
        local plex_pref=0
        if [[ -f "${plex_base}/Preferences.xml" ]]; then
            plex_pref=$(stat -c%s "${plex_base}/Preferences.xml" 2>/dev/null || echo "0")
        fi
        plex_size=$((plex_size + plex_pref))
        plex_meta=$(dir_size_bytes "${plex_base}/Metadata")
    fi

    echo "${nc_db}:${nc_data}:${nc_config}:${rt_size}:${qbt_size}:${de_size}:${plex_size}:${plex_meta}"
}

#===============================================================================
# Interactive Menu
#===============================================================================

show_interactive_menu() {
    local sizes
    sizes=$(estimate_all_sizes)

    local nc_db nc_data nc_config rt_size qbt_size de_size plex_size plex_meta
    nc_db=$(echo "$sizes" | cut -d: -f1)
    nc_data=$(echo "$sizes" | cut -d: -f2)
    nc_config=$(echo "$sizes" | cut -d: -f3)
    rt_size=$(echo "$sizes" | cut -d: -f4)
    qbt_size=$(echo "$sizes" | cut -d: -f5)
    de_size=$(echo "$sizes" | cut -d: -f6)
    plex_size=$(echo "$sizes" | cut -d: -f7)
    plex_meta=$(echo "$sizes" | cut -d: -f8)

    local nc_full=$((nc_db + nc_data + nc_config))
    local nc_no_data=$((nc_db + nc_config))
    local apps_total=$((rt_size + qbt_size + de_size + plex_size))
    local everything=$((nc_full + apps_total))

    echo ""
    echo -e "${BOLD}Tamanhos estimados:${NC}"
    if [[ "$DETECTED_NC" == "true" ]]; then
        echo -e "  Nextcloud DB:       ${CYAN}~$(format_size "$nc_db")${NC}"
        echo -e "  Nextcloud dados:    ${CYAN}~$(format_size "$nc_data")${NC}"
        echo -e "  Nextcloud config:   ${CYAN}~$(format_size "$nc_config")${NC}"
    fi
    [[ "$DETECTED_RUTORRENT" == "true" ]]   && echo -e "  ruTorrent:          ${CYAN}~$(format_size "$rt_size")${NC}"
    [[ "$DETECTED_QBITTORRENT" == "true" ]] && echo -e "  qBittorrent:        ${CYAN}~$(format_size "$qbt_size")${NC}"
    [[ "$DETECTED_DELUGE" == "true" ]]      && echo -e "  Deluge:             ${CYAN}~$(format_size "$de_size")${NC}"
    [[ "$DETECTED_PLEX" == "true" ]]        && echo -e "  Plex (essencial):   ${CYAN}~$(format_size "$plex_size")${NC}"
    [[ "$DETECTED_PLEX" == "true" ]]        && echo -e "  Plex (metadata):    ${CYAN}~$(format_size "$plex_meta")${NC}"

    echo ""
    echo -e "${BOLD}Escolha o tipo de backup:${NC}"
    echo ""

    local opt=1

    # === Completo ===
    echo -e "  ${BOLD}--- Completo ---${NC}"
    echo -e "  ${GREEN}${opt})${NC} Tudo (Nextcloud completo + todas as apps)         ${DIM}~$(format_size "$everything")${NC}"
    local OPT_EVERYTHING=$opt; ((opt++))

    # === Nextcloud ===
    if [[ "$DETECTED_NC" == "true" ]]; then
        echo ""
        echo -e "  ${BOLD}--- Nextcloud ---${NC}"
        echo -e "  ${GREEN}${opt})${NC} Nextcloud completo (banco + config + dados)       ${DIM}~$(format_size "$nc_full")${NC}"
        local OPT_NC_FULL=$opt; ((opt++))

        echo -e "  ${GREEN}${opt})${NC} Nextcloud sem dados (banco + config)               ${DIM}~$(format_size "$nc_no_data")${NC}"
        local OPT_NC_NO_DATA=$opt; ((opt++))

        echo -e "  ${GREEN}${opt})${NC} Somente banco de dados Nextcloud                   ${DIM}~$(format_size "$nc_db")${NC}"
        local OPT_NC_DB=$opt; ((opt++))
    fi

    # === Aplicacoes ===
    local has_any_app=false
    if [[ "$DETECTED_RUTORRENT" == "true" || "$DETECTED_QBITTORRENT" == "true" \
        || "$DETECTED_DELUGE" == "true" || "$DETECTED_PLEX" == "true" ]]; then
        has_any_app=true
        echo ""
        echo -e "  ${BOLD}--- Aplicacoes ---${NC}"

        echo -e "  ${GREEN}${opt})${NC} Todas as aplicacoes detectadas                     ${DIM}~$(format_size "$apps_total")${NC}"
        local OPT_ALL_APPS=$opt; ((opt++))
    fi

    if [[ "$DETECTED_RUTORRENT" == "true" ]]; then
        echo -e "  ${GREEN}${opt})${NC} Somente ruTorrent                                  ${DIM}~$(format_size "$rt_size")${NC}"
        local OPT_RT=$opt; ((opt++))
    fi

    if [[ "$DETECTED_QBITTORRENT" == "true" ]]; then
        echo -e "  ${GREEN}${opt})${NC} Somente qBittorrent                                ${DIM}~$(format_size "$qbt_size")${NC}"
        local OPT_QBT=$opt; ((opt++))
    fi

    if [[ "$DETECTED_DELUGE" == "true" ]]; then
        echo -e "  ${GREEN}${opt})${NC} Somente Deluge                                     ${DIM}~$(format_size "$de_size")${NC}"
        local OPT_DE=$opt; ((opt++))
    fi

    if [[ "$DETECTED_PLEX" == "true" ]]; then
        echo -e "  ${GREEN}${opt})${NC} Somente Plex (essencial: DB + prefs)               ${DIM}~$(format_size "$plex_size")${NC}"
        local OPT_PLEX=$opt; ((opt++))

        echo -e "  ${GREEN}${opt})${NC} Somente Plex (completo com metadata)               ${DIM}~$(format_size "$((plex_size + plex_meta))")${NC}"
        local OPT_PLEX_FULL=$opt; ((opt++))
    fi

    echo ""
    echo -e "  ${RED}0)${NC} Cancelar"
    echo ""

    local max_opt=$((opt - 1))

    while true; do
        read -rp "Opcao [1-${max_opt}, 0 para cancelar]: " choice

        if [[ "$choice" == "0" ]]; then
            log_info "Backup cancelado."
            exit 0
        fi

        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 || "$choice" -gt "$max_opt" ]]; then
            echo -e "${RED}Opcao invalida.${NC}"
            continue
        fi

        # Enable everything first
        if [[ "$choice" -eq "$OPT_EVERYTHING" ]]; then
            set_nextcloud_full
            set_all_apps
            break
        fi

        # Nextcloud options
        if [[ "$DETECTED_NC" == "true" ]]; then
            if [[ "$choice" -eq "${OPT_NC_FULL:-0}" ]]; then
                set_nextcloud_full; break
            elif [[ "$choice" -eq "${OPT_NC_NO_DATA:-0}" ]]; then
                set_nextcloud_no_data; break
            elif [[ "$choice" -eq "${OPT_NC_DB:-0}" ]]; then
                BACKUP_NC=true; BACKUP_NC_DATABASE=true; break
            fi
        fi

        # All apps
        if [[ "$has_any_app" == "true" && "$choice" -eq "${OPT_ALL_APPS:-0}" ]]; then
            set_all_apps; break
        fi

        # Individual apps
        if [[ "$DETECTED_RUTORRENT" == "true" && "$choice" -eq "${OPT_RT:-0}" ]]; then
            BACKUP_RUTORRENT=true; break
        fi
        if [[ "$DETECTED_QBITTORRENT" == "true" && "$choice" -eq "${OPT_QBT:-0}" ]]; then
            BACKUP_QBITTORRENT=true; break
        fi
        if [[ "$DETECTED_DELUGE" == "true" && "$choice" -eq "${OPT_DE:-0}" ]]; then
            BACKUP_DELUGE=true; break
        fi
        if [[ "$DETECTED_PLEX" == "true" ]]; then
            if [[ "$choice" -eq "${OPT_PLEX:-0}" ]]; then
                BACKUP_PLEX=true; break
            elif [[ "$choice" -eq "${OPT_PLEX_FULL:-0}" ]]; then
                BACKUP_PLEX=true; BACKUP_PLEX_META=true; break
            fi
        fi

        echo -e "${RED}Opcao invalida.${NC}"
    done

    # Ask about remote upload
    echo ""
    read -rp "Enviar backup para storage remoto (rclone)? [s/N]: " remote_choice
    case $remote_choice in
        [sS]|[sS][iI][mM]) UPLOAD_REMOTE=true ;;
    esac

    # Ask about custom output directory
    echo ""
    read -rp "Diretorio de saida [${BACKUP_PATH}]: " custom_path
    if [[ -n "$custom_path" ]]; then
        BACKUP_PATH="$custom_path"
        BACKUP_DIR="${BACKUP_PATH}/${TIMESTAMP}"
        BACKUP_ARCHIVE="${BACKUP_PATH}/backup-${TIMESTAMP}.tar.gz"
    fi
}

set_nextcloud_full() {
    BACKUP_NC=true
    BACKUP_NC_DATA=true
    BACKUP_NC_CONFIG=true
    BACKUP_NC_APPS=true
    BACKUP_NC_THEMES=true
    BACKUP_NC_DATABASE=true
}

set_nextcloud_no_data() {
    BACKUP_NC=true
    BACKUP_NC_DATA=false
    BACKUP_NC_CONFIG=true
    BACKUP_NC_APPS=true
    BACKUP_NC_THEMES=true
    BACKUP_NC_DATABASE=true
}

set_all_apps() {
    [[ "$DETECTED_RUTORRENT" == "true" ]]   && BACKUP_RUTORRENT=true   || true
    [[ "$DETECTED_QBITTORRENT" == "true" ]] && BACKUP_QBITTORRENT=true || true
    [[ "$DETECTED_DELUGE" == "true" ]]      && BACKUP_DELUGE=true      || true
    [[ "$DETECTED_PLEX" == "true" ]]        && BACKUP_PLEX=true        || true
}

#===============================================================================
# CLI Arguments
#===============================================================================

show_usage() {
    cat << 'EOF'
Backup Script - Nextcloud + Aplicacoes

Uso: backup.sh [OPCOES]

Sem argumentos: menu interativo

Nextcloud:
    --full              Tudo (Nextcloud + todas as apps detectadas)
    --nc-full           Nextcloud completo (banco + config + dados)
    --nc-no-data        Nextcloud sem diretorio de dados
    --db-only           Somente banco de dados Nextcloud
    --data-only         Somente diretorio de dados Nextcloud
    --config-only       Somente configuracao Nextcloud

Aplicacoes (podem ser combinadas):
    --rutorrent         Incluir ruTorrent/rTorrent
    --qbittorrent       Incluir qBittorrent
    --deluge            Incluir Deluge
    --plex              Incluir Plex (essencial)
    --plex-full         Incluir Plex (com metadata)
    --all-apps          Incluir todas as apps detectadas
    --apps-only         Somente apps (sem Nextcloud)

Geral:
    --output DIR        Diretorio de saida personalizado
    --remote            Upload para storage remoto (rclone)
    --retention DIAS    Dias de retencao (padrao: 7)
    --help              Mostra esta ajuda

Exemplos:
    sudo ./backup.sh                          # Menu interativo
    sudo ./backup.sh --full                   # Tudo
    sudo ./backup.sh --db-only --rutorrent    # NC database + ruTorrent
    sudo ./backup.sh --apps-only              # Somente apps

EOF
    exit 0
}

parse_args() {
    if [[ $# -eq 0 ]]; then
        INTERACTIVE=true
        return
    fi

    while [[ $# -gt 0 ]]; do
        case $1 in
            --full)
                set_nextcloud_full
                BACKUP_RUTORRENT=true
                BACKUP_QBITTORRENT=true
                BACKUP_DELUGE=true
                BACKUP_PLEX=true
                shift ;;
            --nc-full)
                set_nextcloud_full; shift ;;
            --nc-no-data)
                set_nextcloud_no_data; shift ;;
            --db-only)
                BACKUP_NC=true; BACKUP_NC_DATABASE=true; shift ;;
            --data-only)
                BACKUP_NC=true; BACKUP_NC_DATA=true; shift ;;
            --config-only)
                BACKUP_NC=true; BACKUP_NC_CONFIG=true; shift ;;
            --rutorrent)
                BACKUP_RUTORRENT=true; shift ;;
            --qbittorrent)
                BACKUP_QBITTORRENT=true; shift ;;
            --deluge)
                BACKUP_DELUGE=true; shift ;;
            --plex)
                BACKUP_PLEX=true; shift ;;
            --plex-full)
                BACKUP_PLEX=true; BACKUP_PLEX_META=true; shift ;;
            --all-apps)
                BACKUP_RUTORRENT=true; BACKUP_QBITTORRENT=true
                BACKUP_DELUGE=true; BACKUP_PLEX=true
                shift ;;
            --apps-only)
                BACKUP_RUTORRENT=true; BACKUP_QBITTORRENT=true
                BACKUP_DELUGE=true; BACKUP_PLEX=true
                shift ;;
            --output)
                BACKUP_PATH="$2"
                BACKUP_DIR="${BACKUP_PATH}/${TIMESTAMP}"
                BACKUP_ARCHIVE="${BACKUP_PATH}/backup-${TIMESTAMP}.tar.gz"
                shift 2 ;;
            --remote)
                UPLOAD_REMOTE=true; shift ;;
            --retention)
                RETENTION_DAYS="$2"; shift 2 ;;
            --help|-h)
                show_usage ;;
            *)
                log_error "Opcao desconhecida: $1"
                show_usage ;;
        esac
    done
}

#===============================================================================
# Nextcloud Backup Functions
#===============================================================================

nc_enable_maintenance() {
    if [[ "$BACKUP_NC" != "true" ]]; then return; fi
    log_step "Ativando modo de manutencao do Nextcloud..."
    cd "${NEXTCLOUD_PATH}"
    sudo -u www-data php occ maintenance:mode --on 2>/dev/null || true
}

nc_disable_maintenance() {
    if [[ "$BACKUP_NC" != "true" ]]; then return; fi
    log_step "Desativando modo de manutencao do Nextcloud..."
    cd "${NEXTCLOUD_PATH}"
    sudo -u www-data php occ maintenance:mode --off 2>/dev/null || true
}

backup_nc_database() {
    if [[ "$BACKUP_NC_DATABASE" != "true" ]]; then return; fi

    log_step "Nextcloud: backup do banco de dados..."
    mkdir -p "${BACKUP_DIR}/nextcloud/database"

    if [[ -z "$DB_PASS" ]]; then
        DB_PASS=$(grep -oP "'dbpassword'\s*=>\s*'\K[^']+" "${NEXTCLOUD_PATH}/config/config.php")
    fi

    mysqldump --single-transaction \
        --default-character-set=utf8mb4 \
        --routines --triggers \
        -u "${DB_USER}" -p"${DB_PASS}" \
        "${DB_NAME}" | gzip > "${BACKUP_DIR}/nextcloud/database/nextcloud.sql.gz"

    local dump_size
    dump_size=$(du -h "${BACKUP_DIR}/nextcloud/database/nextcloud.sql.gz" | cut -f1)
    log_success "Nextcloud DB: ${dump_size} (comprimido)"
}

backup_nc_data() {
    if [[ "$BACKUP_NC_DATA" != "true" ]]; then return; fi

    log_step "Nextcloud: backup do diretorio de dados..."
    log_warning "Isso pode demorar para instalacoes grandes..."
    mkdir -p "${BACKUP_DIR}/nextcloud/data"

    rsync -aAX --info=progress2 \
        --exclude "*.part" \
        --exclude "*.ocTransferId*" \
        --exclude "updater-*" \
        "${DATA_PATH}/" "${BACKUP_DIR}/nextcloud/data/"

    local size
    size=$(du -sh "${BACKUP_DIR}/nextcloud/data" | cut -f1)
    log_success "Nextcloud dados: ${size}"
}

backup_nc_config() {
    if [[ "$BACKUP_NC_CONFIG" != "true" ]]; then return; fi

    log_step "Nextcloud: backup da configuracao..."
    mkdir -p "${BACKUP_DIR}/nextcloud/config"

    cp "${NEXTCLOUD_PATH}/config/config.php" "${BACKUP_DIR}/nextcloud/config/"
    cp "${NEXTCLOUD_PATH}/config/"*.config.php "${BACKUP_DIR}/nextcloud/config/" 2>/dev/null || true

    [[ -f "${SCRIPT_DIR}/.install-config" ]] && \
        cp "${SCRIPT_DIR}/.install-config" "${BACKUP_DIR}/nextcloud/config/"

    # PHP-FPM
    local php_ver
    php_ver=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "8.2")
    [[ -f "/etc/php/${php_ver}/fpm/pool.d/nextcloud.conf" ]] && \
        cp "/etc/php/${php_ver}/fpm/pool.d/nextcloud.conf" "${BACKUP_DIR}/nextcloud/config/php-fpm-nextcloud.conf"

    # MariaDB tuning
    [[ -f "/etc/mysql/mariadb.conf.d/99-nextcloud.cnf" ]] && \
        cp "/etc/mysql/mariadb.conf.d/99-nextcloud.cnf" "${BACKUP_DIR}/nextcloud/config/"

    # Nginx
    for f in /etc/nginx/sites-available/nextcloud /etc/nginx/conf.d/nextcloud.conf; do
        if [[ -f "$f" ]]; then
            cp "$f" "${BACKUP_DIR}/nextcloud/config/nginx-nextcloud.conf"
            break
        fi
    done

    log_success "Nextcloud config salva"
}

backup_nc_apps() {
    if [[ "$BACKUP_NC_APPS" != "true" ]]; then return; fi

    log_step "Nextcloud: backup dos apps..."
    mkdir -p "${BACKUP_DIR}/nextcloud/apps"

    [[ -d "${NEXTCLOUD_PATH}/apps-extra" ]] && \
        cp -r "${NEXTCLOUD_PATH}/apps-extra" "${BACKUP_DIR}/nextcloud/apps/"

    cd "${NEXTCLOUD_PATH}"
    sudo -u www-data php occ app:list --output=json 2>/dev/null | tee "${BACKUP_DIR}/nextcloud/apps/installed-apps.json" > /dev/null || true

    log_success "Nextcloud apps salvos"
}

backup_nc_themes() {
    if [[ "$BACKUP_NC_THEMES" != "true" ]]; then return; fi

    log_step "Nextcloud: backup dos temas..."
    mkdir -p "${BACKUP_DIR}/nextcloud/themes"

    [[ -d "${NEXTCLOUD_PATH}/themes" ]] && \
        cp -r "${NEXTCLOUD_PATH}/themes/"* "${BACKUP_DIR}/nextcloud/themes/" 2>/dev/null || true

    log_success "Nextcloud temas salvos"
}

#===============================================================================
# ruTorrent / rTorrent Backup
#===============================================================================

backup_rutorrent() {
    if [[ "$BACKUP_RUTORRENT" != "true" || "$DETECTED_RUTORRENT" != "true" ]]; then return; fi
    if [[ -z "$SWIZZIN_USER" ]]; then
        log_warning "ruTorrent: usuario nao detectado, pulando..."
        return
    fi

    log_step "ruTorrent: fazendo backup..."
    mkdir -p "${BACKUP_DIR}/rutorrent"

    local user_home="/home/${SWIZZIN_USER}"

    # Stop rTorrent for consistent backup
    systemctl stop "rtorrent@${SWIZZIN_USER}" 2>/dev/null || true

    # rTorrent config
    for rc in "${user_home}/.rtorrent.rc" "${user_home}/.config/rtorrent/rtorrent.rc"; do
        if [[ -f "$rc" ]]; then
            cp "$rc" "${BACKUP_DIR}/rutorrent/"
            break
        fi
    done

    # Session files (torrent resume data)
    if [[ -d "${user_home}/.sessions" ]]; then
        mkdir -p "${BACKUP_DIR}/rutorrent/sessions"
        cp -r "${user_home}/.sessions/"* "${BACKUP_DIR}/rutorrent/sessions/" 2>/dev/null || true
    fi

    # ruTorrent web UI config
    for d in /srv/rutorrent /var/www/rutorrent; do
        if [[ -d "$d/conf" ]]; then
            mkdir -p "${BACKUP_DIR}/rutorrent/webui-conf"
            cp -r "$d/conf/"* "${BACKUP_DIR}/rutorrent/webui-conf/" 2>/dev/null || true
            # User-specific settings
            if [[ -d "$d/share/users/${SWIZZIN_USER}" ]]; then
                mkdir -p "${BACKUP_DIR}/rutorrent/webui-user"
                cp -r "$d/share/users/${SWIZZIN_USER}/"* "${BACKUP_DIR}/rutorrent/webui-user/" 2>/dev/null || true
            fi
            break
        fi
    done

    # Restart rTorrent
    systemctl start "rtorrent@${SWIZZIN_USER}" 2>/dev/null || true

    local size
    size=$(du -sh "${BACKUP_DIR}/rutorrent" | cut -f1)
    log_success "ruTorrent: ${size}"
}

#===============================================================================
# qBittorrent Backup
#===============================================================================

backup_qbittorrent() {
    if [[ "$BACKUP_QBITTORRENT" != "true" || "$DETECTED_QBITTORRENT" != "true" ]]; then return; fi
    if [[ -z "$SWIZZIN_USER" ]]; then
        log_warning "qBittorrent: usuario nao detectado, pulando..."
        return
    fi

    log_step "qBittorrent: fazendo backup..."
    mkdir -p "${BACKUP_DIR}/qbittorrent"

    local user_home="/home/${SWIZZIN_USER}"

    # Stop qBittorrent for consistent backup
    systemctl stop "qbittorrent@${SWIZZIN_USER}" 2>/dev/null || true

    # Config file
    if [[ -f "${user_home}/.config/qBittorrent/qBittorrent.conf" ]]; then
        cp "${user_home}/.config/qBittorrent/qBittorrent.conf" "${BACKUP_DIR}/qbittorrent/"
    fi

    # qBittorrent config directory (contains categories, RSS, etc.)
    if [[ -d "${user_home}/.config/qBittorrent" ]]; then
        mkdir -p "${BACKUP_DIR}/qbittorrent/config"
        cp -r "${user_home}/.config/qBittorrent/"* "${BACKUP_DIR}/qbittorrent/config/" 2>/dev/null || true
    fi

    # BT_backup (resume data / .torrent files)
    if [[ -d "${user_home}/.local/share/qBittorrent/BT_backup" ]]; then
        mkdir -p "${BACKUP_DIR}/qbittorrent/BT_backup"
        cp -r "${user_home}/.local/share/qBittorrent/BT_backup/"* "${BACKUP_DIR}/qbittorrent/BT_backup/" 2>/dev/null || true
    # Alternative path (newer versions)
    elif [[ -d "${user_home}/.local/share/data/qBittorrent/BT_backup" ]]; then
        mkdir -p "${BACKUP_DIR}/qbittorrent/BT_backup"
        cp -r "${user_home}/.local/share/data/qBittorrent/BT_backup/"* "${BACKUP_DIR}/qbittorrent/BT_backup/" 2>/dev/null || true
    fi

    # Restart qBittorrent
    systemctl start "qbittorrent@${SWIZZIN_USER}" 2>/dev/null || true

    local size
    size=$(du -sh "${BACKUP_DIR}/qbittorrent" | cut -f1)
    log_success "qBittorrent: ${size}"
}

#===============================================================================
# Deluge Backup
#===============================================================================

backup_deluge() {
    if [[ "$BACKUP_DELUGE" != "true" || "$DETECTED_DELUGE" != "true" ]]; then return; fi
    if [[ -z "$SWIZZIN_USER" ]]; then
        log_warning "Deluge: usuario nao detectado, pulando..."
        return
    fi

    log_step "Deluge: fazendo backup..."
    mkdir -p "${BACKUP_DIR}/deluge"

    local user_home="/home/${SWIZZIN_USER}"
    local deluge_dir="${user_home}/.config/deluge"

    # Stop Deluge for consistent backup
    systemctl stop "deluged@${SWIZZIN_USER}" 2>/dev/null || true
    systemctl stop "deluge-web@${SWIZZIN_USER}" 2>/dev/null || true

    # Full deluge config (core.conf, web.conf, auth, state/, plugins/, etc.)
    if [[ -d "$deluge_dir" ]]; then
        cp -r "$deluge_dir/"* "${BACKUP_DIR}/deluge/" 2>/dev/null || true
    fi

    # Restart Deluge
    systemctl start "deluged@${SWIZZIN_USER}" 2>/dev/null || true
    systemctl start "deluge-web@${SWIZZIN_USER}" 2>/dev/null || true

    local size
    size=$(du -sh "${BACKUP_DIR}/deluge" | cut -f1)
    log_success "Deluge: ${size}"
}

#===============================================================================
# Plex Backup
#===============================================================================

backup_plex() {
    if [[ "$BACKUP_PLEX" != "true" || "$DETECTED_PLEX" != "true" ]]; then return; fi

    log_step "Plex: fazendo backup..."
    mkdir -p "${BACKUP_DIR}/plex"

    local plex_base="/var/lib/plexmediaserver/Library/Application Support/Plex Media Server"

    # Stop Plex for consistent DB backup
    systemctl stop plexmediaserver 2>/dev/null || true

    # Preferences.xml (server identity, token, settings)
    if [[ -f "${plex_base}/Preferences.xml" ]]; then
        cp "${plex_base}/Preferences.xml" "${BACKUP_DIR}/plex/"
    fi

    # Databases (metadata DB - essential for restore)
    if [[ -d "${plex_base}/Plug-in Support/Databases" ]]; then
        mkdir -p "${BACKUP_DIR}/plex/databases"
        cp -r "${plex_base}/Plug-in Support/Databases/"* "${BACKUP_DIR}/plex/databases/" 2>/dev/null || true
    fi

    # Plugin preferences
    if [[ -d "${plex_base}/Plug-in Support/Preferences" ]]; then
        mkdir -p "${BACKUP_DIR}/plex/plugin-preferences"
        cp -r "${plex_base}/Plug-in Support/Preferences/"* "${BACKUP_DIR}/plex/plugin-preferences/" 2>/dev/null || true
    fi

    # Metadata (posters, art, etc. - optional, can be huge)
    if [[ "$BACKUP_PLEX_META" == "true" && -d "${plex_base}/Metadata" ]]; then
        log_warning "Plex: copiando metadata (pode demorar)..."
        mkdir -p "${BACKUP_DIR}/plex/metadata"
        rsync -aAX --info=progress2 \
            "${plex_base}/Metadata/" "${BACKUP_DIR}/plex/metadata/"
    fi

    # Restart Plex
    systemctl start plexmediaserver 2>/dev/null || true

    local size
    size=$(du -sh "${BACKUP_DIR}/plex" | cut -f1)
    log_success "Plex: ${size}"
}

#===============================================================================
# Archive & Remote
#===============================================================================

create_archive() {
    log_step "Criando arquivo comprimido..."

    cd "${BACKUP_PATH}"
    tar -czf "${BACKUP_ARCHIVE}" "${TIMESTAMP}"

    rm -rf "${BACKUP_DIR}"
    log_success "Arquivo criado: ${BACKUP_ARCHIVE}"
}

upload_to_remote() {
    if [[ "$UPLOAD_REMOTE" != "true" ]]; then return; fi

    log_step "Enviando para storage remoto..."

    if ! command -v rclone &> /dev/null; then
        log_warning "rclone nao instalado. Pulando upload remoto."
        return
    fi

    if rclone lsd nextcloud-backup: &> /dev/null; then
        rclone copy "${BACKUP_ARCHIVE}" nextcloud-backup:backups/ --progress
        log_success "Enviado para storage remoto"
    else
        log_warning "Remote 'nextcloud-backup' do rclone nao configurado"
    fi
}

cleanup_old_backups() {
    log_step "Removendo backups antigos (mais de ${RETENTION_DAYS} dias)..."

    local count
    count=$(find "${BACKUP_PATH}" -name "backup-*.tar.gz" -mtime +"${RETENTION_DAYS}" 2>/dev/null | wc -l)

    if [[ $count -gt 0 ]]; then
        find "${BACKUP_PATH}" -name "backup-*.tar.gz" -mtime +"${RETENTION_DAYS}" -delete 2>/dev/null || true
        log_success "${count} backup(s) antigo(s) removido(s)"
    else
        log_info "Nenhum backup antigo para remover"
    fi
}

#===============================================================================
# Manifest
#===============================================================================

create_manifest() {
    mkdir -p "${BACKUP_DIR}"

    cat > "${BACKUP_DIR}/manifest.json" << EOF
{
    "version": "2.0",
    "timestamp": "${TIMESTAMP}",
    "date": "$(date -Iseconds)",
    "hostname": "$(hostname)",
    "swizzin_user": "${SWIZZIN_USER}",
    "nextcloud": {
        "enabled": ${BACKUP_NC},
        "database": ${BACKUP_NC_DATABASE},
        "data": ${BACKUP_NC_DATA},
        "config": ${BACKUP_NC_CONFIG},
        "apps": ${BACKUP_NC_APPS},
        "themes": ${BACKUP_NC_THEMES},
        "version": "$(cd "${NEXTCLOUD_PATH}" 2>/dev/null && sudo -u www-data php occ -V 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo 'N/A')",
        "path": "${NEXTCLOUD_PATH}",
        "data_path": "${DATA_PATH}"
    },
    "apps": {
        "rutorrent": ${BACKUP_RUTORRENT},
        "qbittorrent": ${BACKUP_QBITTORRENT},
        "deluge": ${BACKUP_DELUGE},
        "plex": ${BACKUP_PLEX},
        "plex_metadata": ${BACKUP_PLEX_META}
    },
    "retention_days": ${RETENTION_DAYS}
}
EOF
}

#===============================================================================
# Summary
#===============================================================================

show_summary() {
    local archive_size
    archive_size=$(du -h "${BACKUP_ARCHIVE}" | cut -f1)

    local disk_free
    disk_free=$(df -h "${BACKUP_PATH}" | awk 'NR==2 {print $4}')

    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              Backup Concluido com Sucesso!                    ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}Arquivo:${NC}     ${BACKUP_ARCHIVE}"
    echo -e "  ${BOLD}Tamanho:${NC}     ${archive_size}"
    echo -e "  ${BOLD}Disco livre:${NC} ${disk_free}"
    echo ""
    echo -e "  ${BOLD}Conteudo do backup:${NC}"

    if [[ "$BACKUP_NC" == "true" ]]; then
        echo -e "    ${BOLD}Nextcloud:${NC}"
        [[ "$BACKUP_NC_DATABASE" == "true" ]] && echo -e "      ${GREEN}+${NC} Banco de dados"
        [[ "$BACKUP_NC_CONFIG" == "true" ]]   && echo -e "      ${GREEN}+${NC} Configuracao"
        [[ "$BACKUP_NC_APPS" == "true" ]]     && echo -e "      ${GREEN}+${NC} Apps"
        [[ "$BACKUP_NC_THEMES" == "true" ]]   && echo -e "      ${GREEN}+${NC} Temas"
        [[ "$BACKUP_NC_DATA" == "true" ]]     && echo -e "      ${GREEN}+${NC} Diretorio de dados"
    fi

    [[ "$BACKUP_RUTORRENT" == "true" && "$DETECTED_RUTORRENT" == "true" ]]     && echo -e "    ${GREEN}+${NC} ruTorrent/rTorrent"
    [[ "$BACKUP_QBITTORRENT" == "true" && "$DETECTED_QBITTORRENT" == "true" ]] && echo -e "    ${GREEN}+${NC} qBittorrent"
    [[ "$BACKUP_DELUGE" == "true" && "$DETECTED_DELUGE" == "true" ]]           && echo -e "    ${GREEN}+${NC} Deluge"
    [[ "$BACKUP_PLEX" == "true" && "$DETECTED_PLEX" == "true" ]]              && echo -e "    ${GREEN}+${NC} Plex${BACKUP_PLEX_META:+ (com metadata)}"

    echo ""
    local backup_count
    backup_count=$(find "${BACKUP_PATH}" -name "backup-*.tar.gz" 2>/dev/null | wc -l)
    echo -e "  ${BOLD}Backups armazenados:${NC} ${backup_count} (retencao: ${RETENTION_DAYS} dias)"
    echo ""
    echo -e "  ${DIM}Para restaurar:${NC}"
    echo -e "    sudo ${SCRIPT_DIR}/restore.sh ${BACKUP_ARCHIVE}"
    echo ""
}

#===============================================================================
# Main
#===============================================================================

main() {
    echo ""
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║          Backup - Nextcloud + Aplicacoes                      ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"

    check_root
    parse_args "$@"
    detect_services

    # Interactive mode
    if [[ "$INTERACTIVE" == "true" ]]; then
        show_detected
        show_interactive_menu
    fi

    # Validate: at least something to backup
    if [[ "$BACKUP_NC" != "true" && "$BACKUP_NC_DATABASE" != "true" && \
          "$BACKUP_RUTORRENT" != "true" && "$BACKUP_QBITTORRENT" != "true" && \
          "$BACKUP_DELUGE" != "true" && "$BACKUP_PLEX" != "true" ]]; then
        log_error "Nenhum componente selecionado para backup."
        exit 1
    fi

    # Show what will be backed up
    echo ""
    echo -e "${BOLD}Componentes selecionados:${NC}"
    [[ "$BACKUP_NC_DATABASE" == "true" ]]                                        && echo -e "  ${GREEN}+${NC} Nextcloud DB"
    [[ "$BACKUP_NC_CONFIG" == "true" ]]                                          && echo -e "  ${GREEN}+${NC} Nextcloud config"
    [[ "$BACKUP_NC_APPS" == "true" ]]                                            && echo -e "  ${GREEN}+${NC} Nextcloud apps"
    [[ "$BACKUP_NC_THEMES" == "true" ]]                                          && echo -e "  ${GREEN}+${NC} Nextcloud temas"
    [[ "$BACKUP_NC_DATA" == "true" ]]                                            && echo -e "  ${GREEN}+${NC} Nextcloud dados"
    [[ "$BACKUP_RUTORRENT" == "true" && "$DETECTED_RUTORRENT" == "true" ]]       && echo -e "  ${GREEN}+${NC} ruTorrent"
    [[ "$BACKUP_QBITTORRENT" == "true" && "$DETECTED_QBITTORRENT" == "true" ]]   && echo -e "  ${GREEN}+${NC} qBittorrent"
    [[ "$BACKUP_DELUGE" == "true" && "$DETECTED_DELUGE" == "true" ]]             && echo -e "  ${GREEN}+${NC} Deluge"
    [[ "$BACKUP_PLEX" == "true" && "$DETECTED_PLEX" == "true" ]]                 && echo -e "  ${GREEN}+${NC} Plex"
    echo -e "  ${DIM}Destino: ${BACKUP_PATH}${NC}"
    echo ""

    # Create backup directory
    mkdir -p "${BACKUP_DIR}"

    local start_time
    start_time=$(date +%s)

    # Trap for cleanup
    trap 'nc_disable_maintenance; log_error "Backup interrompido por erro!"' ERR

    # === Nextcloud ===
    nc_enable_maintenance
    create_manifest
    backup_nc_database
    backup_nc_config
    backup_nc_apps
    backup_nc_themes
    backup_nc_data
    nc_disable_maintenance

    # === Aplicacoes ===
    backup_rutorrent
    backup_qbittorrent
    backup_deluge
    backup_plex

    # === Archive ===
    create_archive
    upload_to_remote
    cleanup_old_backups

    # Time
    local end_time elapsed_min elapsed_sec
    end_time=$(date +%s)
    elapsed_sec=$((end_time - start_time))
    elapsed_min=$((elapsed_sec / 60))
    elapsed_sec=$((elapsed_sec % 60))

    show_summary
    echo -e "  ${DIM}Tempo total: ${elapsed_min}m ${elapsed_sec}s${NC}"
    echo ""
}

main "$@"
