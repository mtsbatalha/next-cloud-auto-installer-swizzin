#!/bin/bash
#===============================================================================
# Restore Script - Nextcloud + Aplicacoes
# Restaura backup criado pelo backup.sh
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
# shellcheck source=/dev/null
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
DATA_PATH="${DATA_PATH:-/var/nextcloud-data}"
BACKUP_PATH="${BACKUP_PATH:-/var/backups/nextcloud}"

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[AVISO]${NC} $1"; }
log_error() { echo -e "${RED}[ERRO]${NC} $1"; }
log_step() { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $1"; }

#===============================================================================
# Configuration
#===============================================================================

BACKUP_FILE=""
TEMP_DIR=""
BACKUP_DIR=""
INTERACTIVE=false

# What to restore (defaults: everything found)
RESTORE_NC_DATABASE=true
RESTORE_NC_DATA=true
RESTORE_NC_CONFIG=true
RESTORE_NC_APPS=true
RESTORE_NC_THEMES=true
RESTORE_RUTORRENT=true
RESTORE_QBITTORRENT=true
RESTORE_DELUGE=true
RESTORE_PLEX=true

# Migration
NEW_DOMAIN=""

# Swizzin user
SWIZZIN_USER=""

# Contents found in backup
HAS_NC_DATABASE=false
HAS_NC_DATA=false
HAS_NC_CONFIG=false
HAS_NC_APPS=false
HAS_NC_THEMES=false
HAS_RUTORRENT=false
HAS_QBITTORRENT=false
HAS_DELUGE=false
HAS_PLEX=false

#===============================================================================
# Utility
#===============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Este script precisa ser executado como root"
        exit 1
    fi
}

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

detect_swizzin_user() {
    if [[ -f /root/.master.info ]]; then
        SWIZZIN_USER=$(cut -d: -f1 /root/.master.info)
    elif [[ -d /etc/swizzin/users ]]; then
        SWIZZIN_USER=$(find /etc/swizzin/users -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | head -1)
    fi
    if [[ -z "$SWIZZIN_USER" ]]; then
        SWIZZIN_USER=$(systemctl list-units --type=service --all 2>/dev/null \
            | grep -oP '(rtorrent|qbittorrent|deluged)@\K[^.]+' | head -1)
    fi
    if [[ -z "$SWIZZIN_USER" ]]; then
        SWIZZIN_USER=$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}' /etc/passwd)
    fi
}

cleanup() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        log_info "Limpando arquivos temporarios..."
        rm -rf "$TEMP_DIR"
    fi
}

#===============================================================================
# CLI Arguments
#===============================================================================

show_usage() {
    cat << 'EOF'
Restore Script - Nextcloud + Aplicacoes

Uso: restore.sh [ARQUIVO_BACKUP] [OPCOES]

Se nenhum arquivo for informado, lista os backups disponiveis.

Argumentos:
    ARQUIVO_BACKUP      Caminho do arquivo .tar.gz de backup

Nextcloud:
    --target DIR        Caminho customizado do Nextcloud
    --data-dir DIR      Caminho customizado do diretorio de dados
    --new-domain NOME   Atualizar dominio (para migracao)
    --no-database       Nao restaurar banco de dados
    --no-data           Nao restaurar diretorio de dados
    --no-config         Nao restaurar configuracao
    --nc-only           Restaurar somente Nextcloud
    --db-only           Restaurar somente banco de dados

Aplicacoes:
    --no-rutorrent      Nao restaurar ruTorrent
    --no-qbittorrent    Nao restaurar qBittorrent
    --no-deluge         Nao restaurar Deluge
    --no-plex           Nao restaurar Plex
    --apps-only         Restaurar somente aplicacoes

Geral:
    --help              Mostra esta ajuda

Exemplos:
    sudo ./restore.sh                                    # Listar backups
    sudo ./restore.sh /var/backups/nextcloud/backup.tar.gz
    sudo ./restore.sh backup.tar.gz --new-domain new.example.com
    sudo ./restore.sh backup.tar.gz --db-only
    sudo ./restore.sh backup.tar.gz --apps-only

EOF
    exit 0
}

parse_args() {
    if [[ $# -eq 0 ]]; then
        INTERACTIVE=true
        return
    fi

    # First non-flag argument is the backup file
    if [[ ! "$1" =~ ^-- ]]; then
        BACKUP_FILE="$1"
        shift
    else
        INTERACTIVE=true
    fi

    while [[ $# -gt 0 ]]; do
        case $1 in
            --target)
                NEXTCLOUD_PATH="$2"; shift 2 ;;
            --data-dir)
                DATA_PATH="$2"; shift 2 ;;
            --new-domain)
                NEW_DOMAIN="$2"; shift 2 ;;
            --no-database)
                RESTORE_NC_DATABASE=false; shift ;;
            --no-data)
                RESTORE_NC_DATA=false; shift ;;
            --no-config)
                RESTORE_NC_CONFIG=false; shift ;;
            --nc-only)
                RESTORE_RUTORRENT=false; RESTORE_QBITTORRENT=false
                RESTORE_DELUGE=false; RESTORE_PLEX=false; shift ;;
            --db-only)
                RESTORE_NC_DATA=false; RESTORE_NC_CONFIG=false
                RESTORE_NC_APPS=false; RESTORE_NC_THEMES=false
                RESTORE_RUTORRENT=false; RESTORE_QBITTORRENT=false
                RESTORE_DELUGE=false; RESTORE_PLEX=false; shift ;;
            --no-rutorrent)
                RESTORE_RUTORRENT=false; shift ;;
            --no-qbittorrent)
                RESTORE_QBITTORRENT=false; shift ;;
            --no-deluge)
                RESTORE_DELUGE=false; shift ;;
            --no-plex)
                RESTORE_PLEX=false; shift ;;
            --apps-only)
                RESTORE_NC_DATABASE=false; RESTORE_NC_DATA=false
                RESTORE_NC_CONFIG=false; RESTORE_NC_APPS=false
                RESTORE_NC_THEMES=false; shift ;;
            --help|-h)
                show_usage ;;
            *)
                log_error "Opcao desconhecida: $1"
                show_usage ;;
        esac
    done
}

#===============================================================================
# Backup Selection
#===============================================================================

list_available_backups() {
    local backups=()
    local i=1

    echo ""
    echo -e "${BOLD}Backups disponiveis em ${BACKUP_PATH}:${NC}"
    echo ""

    if [[ ! -d "$BACKUP_PATH" ]]; then
        log_error "Diretorio de backup nao encontrado: ${BACKUP_PATH}"
        exit 1
    fi

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        local fname
        fname=$(basename "$file")
        local fsize
        fsize=$(du -h "$file" | cut -f1)
        local fdate
        fdate=$(date -r "$file" '+%Y-%m-%d %H:%M')

        backups+=("$file")
        echo -e "  ${GREEN}${i})${NC} ${fname}  ${DIM}${fsize}  ${fdate}${NC}"
        ((i++))
    done < <(find "$BACKUP_PATH" -maxdepth 1 -name "backup-*.tar.gz" -type f 2>/dev/null | sort -r)

    # Also look for old-format backups
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        local fname
        fname=$(basename "$file")
        local fsize
        fsize=$(du -h "$file" | cut -f1)
        local fdate
        fdate=$(date -r "$file" '+%Y-%m-%d %H:%M')

        backups+=("$file")
        echo -e "  ${GREEN}${i})${NC} ${fname}  ${DIM}${fsize}  ${fdate}${NC}"
        ((i++))
    done < <(find "$BACKUP_PATH" -maxdepth 1 -name "nextcloud-backup-*.tar.gz" -type f 2>/dev/null | sort -r)

    if [[ ${#backups[@]} -eq 0 ]]; then
        log_error "Nenhum backup encontrado em ${BACKUP_PATH}"
        log_info "Especifique o caminho do arquivo: sudo ./restore.sh /caminho/backup.tar.gz"
        exit 1
    fi

    echo ""
    echo -e "  ${RED}0)${NC} Cancelar"
    echo ""

    local max=$((${#backups[@]}))

    while true; do
        read -rp "Escolha o backup [1-${max}, 0 para cancelar]: " choice

        if [[ "$choice" == "0" ]]; then
            log_info "Restauracao cancelada."
            exit 0
        fi

        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 && "$choice" -le "$max" ]]; then
            BACKUP_FILE="${backups[$((choice - 1))]}"
            break
        fi

        echo -e "${RED}Opcao invalida.${NC}"
    done
}

#===============================================================================
# Extract & Detect Contents
#===============================================================================

extract_backup() {
    log_step "Extraindo backup..."

    TEMP_DIR=$(mktemp -d)
    tar -xzf "${BACKUP_FILE}" -C "${TEMP_DIR}"

    # Find the backup directory (timestamp-named)
    BACKUP_DIR=$(find "${TEMP_DIR}" -maxdepth 1 -mindepth 1 -type d | head -1)
    if [[ -z "$BACKUP_DIR" ]]; then
        BACKUP_DIR="${TEMP_DIR}"
    fi

    log_success "Backup extraido"
}

detect_backup_contents() {
    log_info "Analisando conteudo do backup..."

    # Read manifest if exists
    if [[ -f "${BACKUP_DIR}/manifest.json" ]]; then
        echo ""
        echo -e "${BOLD}Manifest do backup:${NC}"

        local manifest_date
        manifest_date=$(grep -oP '"date"\s*:\s*"\K[^"]+' "${BACKUP_DIR}/manifest.json" 2>/dev/null || echo "N/A")
        local manifest_host
        manifest_host=$(grep -oP '"hostname"\s*:\s*"\K[^"]+' "${BACKUP_DIR}/manifest.json" 2>/dev/null || echo "N/A")
        local manifest_user
        manifest_user=$(grep -oP '"swizzin_user"\s*:\s*"\K[^"]+' "${BACKUP_DIR}/manifest.json" 2>/dev/null || echo "")

        echo -e "  Data:     ${CYAN}${manifest_date}${NC}"
        echo -e "  Host:     ${CYAN}${manifest_host}${NC}"
        [[ -n "$manifest_user" ]] && echo -e "  Usuario:  ${CYAN}${manifest_user}${NC}"
    fi

    # Detect what's in the backup (v2 format: nextcloud/ subdirectory)
    [[ -f "${BACKUP_DIR}/nextcloud/database/nextcloud.sql.gz" ]] && HAS_NC_DATABASE=true
    [[ -d "${BACKUP_DIR}/nextcloud/data" ]]                      && HAS_NC_DATA=true
    [[ -d "${BACKUP_DIR}/nextcloud/config" ]]                    && HAS_NC_CONFIG=true
    [[ -d "${BACKUP_DIR}/nextcloud/apps" ]]                      && HAS_NC_APPS=true
    [[ -d "${BACKUP_DIR}/nextcloud/themes" ]]                    && HAS_NC_THEMES=true

    # Fallback: v1 format (flat structure)
    if [[ "$HAS_NC_DATABASE" == "false" && -f "${BACKUP_DIR}/database/nextcloud.sql.gz" ]]; then
        HAS_NC_DATABASE=true
    fi
    if [[ "$HAS_NC_DATA" == "false" && -d "${BACKUP_DIR}/data" ]]; then
        HAS_NC_DATA=true
    fi
    if [[ "$HAS_NC_CONFIG" == "false" && -d "${BACKUP_DIR}/config" ]]; then
        HAS_NC_CONFIG=true
    fi
    if [[ "$HAS_NC_APPS" == "false" && -d "${BACKUP_DIR}/apps" ]]; then
        HAS_NC_APPS=true
    fi
    if [[ "$HAS_NC_THEMES" == "false" && -d "${BACKUP_DIR}/themes" ]]; then
        HAS_NC_THEMES=true
    fi

    # Applications
    [[ -d "${BACKUP_DIR}/rutorrent" ]]    && HAS_RUTORRENT=true
    [[ -d "${BACKUP_DIR}/qbittorrent" ]]  && HAS_QBITTORRENT=true
    [[ -d "${BACKUP_DIR}/deluge" ]]       && HAS_DELUGE=true
    [[ -d "${BACKUP_DIR}/plex" ]]         && HAS_PLEX=true

    echo ""
    echo -e "${BOLD}Conteudo encontrado:${NC}"

    local has_anything=false

    if [[ "$HAS_NC_DATABASE" == "true" || "$HAS_NC_DATA" == "true" || "$HAS_NC_CONFIG" == "true" ]]; then
        echo -e "  ${BOLD}Nextcloud:${NC}"
        [[ "$HAS_NC_DATABASE" == "true" ]] && echo -e "    ${GREEN}●${NC} Banco de dados"
        [[ "$HAS_NC_CONFIG" == "true" ]]   && echo -e "    ${GREEN}●${NC} Configuracao"
        [[ "$HAS_NC_APPS" == "true" ]]     && echo -e "    ${GREEN}●${NC} Apps"
        [[ "$HAS_NC_THEMES" == "true" ]]   && echo -e "    ${GREEN}●${NC} Temas"
        [[ "$HAS_NC_DATA" == "true" ]]     && echo -e "    ${GREEN}●${NC} Diretorio de dados"
        has_anything=true
    fi

    if [[ "$HAS_RUTORRENT" == "true" || "$HAS_QBITTORRENT" == "true" || \
          "$HAS_DELUGE" == "true" || "$HAS_PLEX" == "true" ]]; then
        echo -e "  ${BOLD}Aplicacoes:${NC}"
        [[ "$HAS_RUTORRENT" == "true" ]]    && echo -e "    ${GREEN}●${NC} ruTorrent/rTorrent"
        [[ "$HAS_QBITTORRENT" == "true" ]]  && echo -e "    ${GREEN}●${NC} qBittorrent"
        [[ "$HAS_DELUGE" == "true" ]]       && echo -e "    ${GREEN}●${NC} Deluge"
        [[ "$HAS_PLEX" == "true" ]]         && echo -e "    ${GREEN}●${NC} Plex"
        has_anything=true
    fi

    if [[ "$has_anything" == "false" ]]; then
        log_error "Nenhum conteudo reconhecido no backup."
        exit 1
    fi
}

#===============================================================================
# Interactive Restore Menu
#===============================================================================

show_restore_menu() {
    echo ""
    echo -e "${BOLD}Escolha o que restaurar:${NC}"
    echo ""

    local opt=1

    echo -e "  ${GREEN}${opt})${NC} Tudo que estiver no backup"
    local OPT_ALL=$opt; ((opt++))

    # Nextcloud options
    local has_nc=false
    if [[ "$HAS_NC_DATABASE" == "true" || "$HAS_NC_DATA" == "true" || "$HAS_NC_CONFIG" == "true" ]]; then
        has_nc=true
        echo ""
        echo -e "  ${BOLD}--- Nextcloud ---${NC}"

        if [[ "$HAS_NC_DATABASE" == "true" && "$HAS_NC_CONFIG" == "true" && "$HAS_NC_DATA" == "true" ]]; then
            echo -e "  ${GREEN}${opt})${NC} Nextcloud completo (banco + config + dados)"
            local OPT_NC_FULL=$opt; ((opt++))
        fi

        if [[ "$HAS_NC_DATABASE" == "true" && "$HAS_NC_CONFIG" == "true" ]]; then
            echo -e "  ${GREEN}${opt})${NC} Nextcloud sem dados (banco + config)"
            local OPT_NC_NO_DATA=$opt; ((opt++))
        fi

        if [[ "$HAS_NC_DATABASE" == "true" ]]; then
            echo -e "  ${GREEN}${opt})${NC} Somente banco de dados Nextcloud"
            local OPT_NC_DB=$opt; ((opt++))
        fi
    fi

    # App options
    local has_apps=false
    if [[ "$HAS_RUTORRENT" == "true" || "$HAS_QBITTORRENT" == "true" || \
          "$HAS_DELUGE" == "true" || "$HAS_PLEX" == "true" ]]; then
        has_apps=true
        echo ""
        echo -e "  ${BOLD}--- Aplicacoes ---${NC}"

        local app_count=0
        [[ "$HAS_RUTORRENT" == "true" ]]    && ((app_count++))
        [[ "$HAS_QBITTORRENT" == "true" ]]  && ((app_count++))
        [[ "$HAS_DELUGE" == "true" ]]       && ((app_count++))
        [[ "$HAS_PLEX" == "true" ]]         && ((app_count++))

        if [[ $app_count -gt 1 ]]; then
            echo -e "  ${GREEN}${opt})${NC} Todas as aplicacoes do backup"
            local OPT_ALL_APPS=$opt; ((opt++))
        fi

        if [[ "$HAS_RUTORRENT" == "true" ]]; then
            echo -e "  ${GREEN}${opt})${NC} Somente ruTorrent"
            local OPT_RT=$opt; ((opt++))
        fi

        if [[ "$HAS_QBITTORRENT" == "true" ]]; then
            echo -e "  ${GREEN}${opt})${NC} Somente qBittorrent"
            local OPT_QBT=$opt; ((opt++))
        fi

        if [[ "$HAS_DELUGE" == "true" ]]; then
            echo -e "  ${GREEN}${opt})${NC} Somente Deluge"
            local OPT_DE=$opt; ((opt++))
        fi

        if [[ "$HAS_PLEX" == "true" ]]; then
            echo -e "  ${GREEN}${opt})${NC} Somente Plex"
            local OPT_PLEX=$opt; ((opt++))
        fi
    fi

    echo ""
    echo -e "  ${RED}0)${NC} Cancelar"
    echo ""

    local max_opt=$((opt - 1))

    while true; do
        read -rp "Opcao [1-${max_opt}, 0 para cancelar]: " choice

        if [[ "$choice" == "0" ]]; then
            log_info "Restauracao cancelada."
            cleanup
            exit 0
        fi

        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 || "$choice" -gt "$max_opt" ]]; then
            echo -e "${RED}Opcao invalida.${NC}"
            continue
        fi

        # Reset all to false first, then enable selected
        RESTORE_NC_DATABASE=false; RESTORE_NC_DATA=false; RESTORE_NC_CONFIG=false
        RESTORE_NC_APPS=false; RESTORE_NC_THEMES=false
        RESTORE_RUTORRENT=false; RESTORE_QBITTORRENT=false
        RESTORE_DELUGE=false; RESTORE_PLEX=false

        if [[ "$choice" -eq "$OPT_ALL" ]]; then
            RESTORE_NC_DATABASE=true; RESTORE_NC_DATA=true; RESTORE_NC_CONFIG=true
            RESTORE_NC_APPS=true; RESTORE_NC_THEMES=true
            RESTORE_RUTORRENT=true; RESTORE_QBITTORRENT=true
            RESTORE_DELUGE=true; RESTORE_PLEX=true
            break
        fi

        if [[ "$has_nc" == "true" ]]; then
            if [[ "$choice" -eq "${OPT_NC_FULL:-0}" ]]; then
                RESTORE_NC_DATABASE=true; RESTORE_NC_DATA=true; RESTORE_NC_CONFIG=true
                RESTORE_NC_APPS=true; RESTORE_NC_THEMES=true
                break
            elif [[ "$choice" -eq "${OPT_NC_NO_DATA:-0}" ]]; then
                RESTORE_NC_DATABASE=true; RESTORE_NC_CONFIG=true
                RESTORE_NC_APPS=true; RESTORE_NC_THEMES=true
                break
            elif [[ "$choice" -eq "${OPT_NC_DB:-0}" ]]; then
                RESTORE_NC_DATABASE=true
                break
            fi
        fi

        if [[ "$has_apps" == "true" ]]; then
            if [[ "$choice" -eq "${OPT_ALL_APPS:-0}" ]]; then
                RESTORE_RUTORRENT=true; RESTORE_QBITTORRENT=true
                RESTORE_DELUGE=true; RESTORE_PLEX=true
                break
            fi
            if [[ "$choice" -eq "${OPT_RT:-0}" ]]; then
                RESTORE_RUTORRENT=true; break
            fi
            if [[ "$choice" -eq "${OPT_QBT:-0}" ]]; then
                RESTORE_QBITTORRENT=true; break
            fi
            if [[ "$choice" -eq "${OPT_DE:-0}" ]]; then
                RESTORE_DELUGE=true; break
            fi
            if [[ "$choice" -eq "${OPT_PLEX:-0}" ]]; then
                RESTORE_PLEX=true; break
            fi
        fi

        echo -e "${RED}Opcao invalida.${NC}"
    done

    # Ask about domain migration (if restoring NC config)
    if [[ "$RESTORE_NC_CONFIG" == "true" ]]; then
        echo ""
        read -rp "Deseja alterar o dominio? (migracao) [s/N]: " domain_choice
        case $domain_choice in
            [sS]|[sS][iI][mM])
                read -rp "Novo dominio: " NEW_DOMAIN
                ;;
        esac
    fi
}

#===============================================================================
# Resolve Backup Paths (v1 vs v2 format)
#===============================================================================

resolve_nc_path() {
    local component="$1"
    # v2 format (nextcloud/ subdirectory)
    if [[ -e "${BACKUP_DIR}/nextcloud/${component}" ]]; then
        echo "${BACKUP_DIR}/nextcloud/${component}"
    # v1 format (flat)
    elif [[ -e "${BACKUP_DIR}/${component}" ]]; then
        echo "${BACKUP_DIR}/${component}"
    fi
}

#===============================================================================
# Nextcloud Restore Functions
#===============================================================================

nc_enable_maintenance() {
    if [[ -d "${NEXTCLOUD_PATH}" && -f "${NEXTCLOUD_PATH}/occ" ]]; then
        log_step "Ativando modo de manutencao do Nextcloud..."
        cd "${NEXTCLOUD_PATH}"
        sudo -u www-data php occ maintenance:mode --on 2>/dev/null || true
    fi
}

nc_disable_maintenance() {
    if [[ -d "${NEXTCLOUD_PATH}" && -f "${NEXTCLOUD_PATH}/occ" ]]; then
        log_step "Desativando modo de manutencao do Nextcloud..."
        cd "${NEXTCLOUD_PATH}"
        sudo -u www-data php occ maintenance:mode --off 2>/dev/null || true
    fi
}

restore_nc_database() {
    if [[ "$RESTORE_NC_DATABASE" != "true" || "$HAS_NC_DATABASE" != "true" ]]; then return; fi

    local db_dump
    db_dump=$(resolve_nc_path "database/nextcloud.sql.gz")
    if [[ -z "$db_dump" || ! -f "$db_dump" ]]; then
        log_warning "Dump do banco nao encontrado, pulando..."
        return
    fi

    log_step "Nextcloud: restaurando banco de dados..."

    # Get database credentials
    local db_name="" db_user="" db_pass=""

    if [[ -f "${NEXTCLOUD_PATH}/config/config.php" ]]; then
        db_name=$(grep -oP "'dbname'\s*=>\s*'\K[^']+" "${NEXTCLOUD_PATH}/config/config.php")
        db_user=$(grep -oP "'dbuser'\s*=>\s*'\K[^']+" "${NEXTCLOUD_PATH}/config/config.php")
        db_pass=$(grep -oP "'dbpassword'\s*=>\s*'\K[^']+" "${NEXTCLOUD_PATH}/config/config.php")
    fi

    # Try from backup config
    local bkp_config
    bkp_config=$(resolve_nc_path "config/config.php")
    if [[ -z "$db_name" && -n "$bkp_config" && -f "$bkp_config" ]]; then
        db_name=$(grep -oP "'dbname'\s*=>\s*'\K[^']+" "$bkp_config")
        db_user=$(grep -oP "'dbuser'\s*=>\s*'\K[^']+" "$bkp_config")
        db_pass=$(grep -oP "'dbpassword'\s*=>\s*'\K[^']+" "$bkp_config")
    fi

    if [[ -z "$db_name" || -z "$db_user" || -z "$db_pass" ]]; then
        log_error "Nao foi possivel obter credenciais do banco de dados."
        log_info "Verifique se o Nextcloud esta instalado ou se o backup contém config.php"
        return
    fi

    # Drop and recreate database
    mysql -e "DROP DATABASE IF EXISTS \`${db_name}\`;"
    mysql -e "CREATE DATABASE \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
    mysql -e "GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';"
    mysql -e "FLUSH PRIVILEGES;"

    # Restore
    gunzip -c "$db_dump" | mysql -u "${db_user}" -p"${db_pass}" "${db_name}"

    log_success "Nextcloud DB restaurado"
}

restore_nc_config() {
    if [[ "$RESTORE_NC_CONFIG" != "true" || "$HAS_NC_CONFIG" != "true" ]]; then return; fi

    local config_dir
    config_dir=$(resolve_nc_path "config")
    if [[ -z "$config_dir" || ! -d "$config_dir" ]]; then
        log_warning "Config nao encontrada no backup, pulando..."
        return
    fi

    log_step "Nextcloud: restaurando configuracao..."

    # Backup current config
    if [[ -f "${NEXTCLOUD_PATH}/config/config.php" ]]; then
        cp "${NEXTCLOUD_PATH}/config/config.php" "${NEXTCLOUD_PATH}/config/config.php.pre-restore"
    fi

    # Restore PHP config files
    cp "${config_dir}/"*.php "${NEXTCLOUD_PATH}/config/" 2>/dev/null || true

    # Restore .install-config
    if [[ -f "${config_dir}/.install-config" ]]; then
        cp "${config_dir}/.install-config" "${SCRIPT_DIR}/"
    fi

    # Update domain if migrating
    if [[ -n "$NEW_DOMAIN" && -f "${NEXTCLOUD_PATH}/occ" ]]; then
        log_info "Atualizando dominio para: ${NEW_DOMAIN}"
        cd "${NEXTCLOUD_PATH}"
        sudo -u www-data php occ config:system:set trusted_domains 0 --value="${NEW_DOMAIN}" 2>/dev/null || true
        sudo -u www-data php occ config:system:set overwrite.cli.url --value="https://${NEW_DOMAIN}" 2>/dev/null || true
    fi

    # Fix permissions
    chown www-data:www-data "${NEXTCLOUD_PATH}/config/config.php"
    chmod 600 "${NEXTCLOUD_PATH}/config/config.php"

    log_success "Nextcloud config restaurada"
}

restore_nc_data() {
    if [[ "$RESTORE_NC_DATA" != "true" || "$HAS_NC_DATA" != "true" ]]; then return; fi

    local data_dir
    data_dir=$(resolve_nc_path "data")
    if [[ -z "$data_dir" || ! -d "$data_dir" ]]; then
        log_warning "Diretorio de dados nao encontrado no backup, pulando..."
        return
    fi

    log_step "Nextcloud: restaurando diretorio de dados..."
    log_warning "Isso pode demorar para backups grandes..."

    mkdir -p "${DATA_PATH}"

    rsync -aAX --info=progress2 \
        "${data_dir}/" "${DATA_PATH}/"

    chown -R www-data:www-data "${DATA_PATH}"
    chmod 750 "${DATA_PATH}"

    log_success "Nextcloud dados restaurados"
}

restore_nc_apps() {
    if [[ "$RESTORE_NC_APPS" != "true" || "$HAS_NC_APPS" != "true" ]]; then return; fi

    local apps_dir
    apps_dir=$(resolve_nc_path "apps")
    if [[ -z "$apps_dir" || ! -d "$apps_dir" ]]; then return; fi

    log_step "Nextcloud: restaurando apps..."

    # Restore apps-extra
    if [[ -d "${apps_dir}/apps-extra" ]]; then
        cp -r "${apps_dir}/apps-extra" "${NEXTCLOUD_PATH}/"
        chown -R www-data:www-data "${NEXTCLOUD_PATH}/apps-extra"
    fi

    # Re-install apps from list
    if [[ -f "${apps_dir}/installed-apps.json" && -f "${NEXTCLOUD_PATH}/occ" ]]; then
        log_info "Reinstalando apps do backup..."
        cd "${NEXTCLOUD_PATH}"

        local enabled_apps
        enabled_apps=$(python3 -c "
import sys, json
with open('${apps_dir}/installed-apps.json') as f:
    apps = json.load(f)
for app in apps.get('enabled', {}):
    print(app)
" 2>/dev/null || true)

        for app in $enabled_apps; do
            sudo -u www-data php occ app:install "$app" 2>/dev/null || true
            sudo -u www-data php occ app:enable "$app" 2>/dev/null || true
        done
    fi

    log_success "Nextcloud apps restaurados"
}

restore_nc_themes() {
    if [[ "$RESTORE_NC_THEMES" != "true" || "$HAS_NC_THEMES" != "true" ]]; then return; fi

    local themes_dir
    themes_dir=$(resolve_nc_path "themes")
    if [[ -z "$themes_dir" || ! -d "$themes_dir" ]]; then return; fi

    log_step "Nextcloud: restaurando temas..."

    mkdir -p "${NEXTCLOUD_PATH}/themes"
    cp -r "${themes_dir}/"* "${NEXTCLOUD_PATH}/themes/" 2>/dev/null || true
    chown -R www-data:www-data "${NEXTCLOUD_PATH}/themes"

    log_success "Nextcloud temas restaurados"
}

nc_run_maintenance() {
    local should_run=false
    [[ "$RESTORE_NC_DATABASE" == "true" && "$HAS_NC_DATABASE" == "true" ]] && should_run=true
    [[ "$RESTORE_NC_DATA" == "true" && "$HAS_NC_DATA" == "true" ]] && should_run=true

    if [[ "$should_run" != "true" || ! -f "${NEXTCLOUD_PATH}/occ" ]]; then return; fi

    log_step "Nextcloud: executando tarefas de manutencao..."
    cd "${NEXTCLOUD_PATH}"

    sudo -u www-data php occ db:add-missing-indices 2>/dev/null || true
    sudo -u www-data php occ db:convert-filecache-bigint --no-interaction 2>/dev/null || true
    sudo -u www-data php occ maintenance:repair 2>/dev/null || true

    if [[ "$RESTORE_NC_DATA" == "true" ]]; then
        log_info "Reindexando arquivos (pode demorar)..."
        sudo -u www-data php occ files:scan --all 2>/dev/null || true
    fi

    sudo -u www-data php occ maintenance:update:htaccess 2>/dev/null || true

    log_success "Manutencao concluida"
}

#===============================================================================
# ruTorrent Restore
#===============================================================================

restore_rutorrent() {
    if [[ "$RESTORE_RUTORRENT" != "true" || "$HAS_RUTORRENT" != "true" ]]; then return; fi
    if [[ -z "$SWIZZIN_USER" ]]; then
        log_warning "ruTorrent: usuario nao detectado, pulando..."
        return
    fi

    log_step "ruTorrent: restaurando..."

    local user_home="/home/${SWIZZIN_USER}"
    local bkp="${BACKUP_DIR}/rutorrent"

    # Stop rTorrent
    systemctl stop "rtorrent@${SWIZZIN_USER}" 2>/dev/null || true

    # Restore .rtorrent.rc
    if [[ -f "${bkp}/rtorrent.rc" || -f "${bkp}/.rtorrent.rc" ]]; then
        local rc_file
        rc_file=$(ls "${bkp}/"*rtorrent.rc 2>/dev/null | head -1)
        if [[ -n "$rc_file" ]]; then
            # Detect destination
            if [[ -f "${user_home}/.rtorrent.rc" ]]; then
                cp "$rc_file" "${user_home}/.rtorrent.rc"
            elif [[ -d "${user_home}/.config/rtorrent" ]]; then
                cp "$rc_file" "${user_home}/.config/rtorrent/rtorrent.rc"
            else
                cp "$rc_file" "${user_home}/.rtorrent.rc"
            fi
        fi
    fi

    # Restore session files
    if [[ -d "${bkp}/sessions" ]]; then
        mkdir -p "${user_home}/.sessions"
        cp -r "${bkp}/sessions/"* "${user_home}/.sessions/" 2>/dev/null || true
        chown -R "${SWIZZIN_USER}:${SWIZZIN_USER}" "${user_home}/.sessions"
    fi

    # Restore ruTorrent web UI config
    if [[ -d "${bkp}/webui-conf" ]]; then
        for d in /srv/rutorrent /var/www/rutorrent; do
            if [[ -d "$d/conf" ]]; then
                cp -r "${bkp}/webui-conf/"* "$d/conf/" 2>/dev/null || true
                chown -R www-data:www-data "$d/conf"
                break
            fi
        done
    fi

    # Restore user-specific settings
    if [[ -d "${bkp}/webui-user" ]]; then
        for d in /srv/rutorrent /var/www/rutorrent; do
            if [[ -d "$d/share" ]]; then
                mkdir -p "$d/share/users/${SWIZZIN_USER}"
                cp -r "${bkp}/webui-user/"* "$d/share/users/${SWIZZIN_USER}/" 2>/dev/null || true
                chown -R www-data:www-data "$d/share/users/${SWIZZIN_USER}"
                break
            fi
        done
    fi

    # Fix ownership
    chown -R "${SWIZZIN_USER}:${SWIZZIN_USER}" "${user_home}/.rtorrent.rc" 2>/dev/null || true
    chown -R "${SWIZZIN_USER}:${SWIZZIN_USER}" "${user_home}/.config/rtorrent" 2>/dev/null || true

    # Restart rTorrent
    systemctl start "rtorrent@${SWIZZIN_USER}" 2>/dev/null || true

    log_success "ruTorrent restaurado"
}

#===============================================================================
# qBittorrent Restore
#===============================================================================

restore_qbittorrent() {
    if [[ "$RESTORE_QBITTORRENT" != "true" || "$HAS_QBITTORRENT" != "true" ]]; then return; fi
    if [[ -z "$SWIZZIN_USER" ]]; then
        log_warning "qBittorrent: usuario nao detectado, pulando..."
        return
    fi

    log_step "qBittorrent: restaurando..."

    local user_home="/home/${SWIZZIN_USER}"
    local bkp="${BACKUP_DIR}/qbittorrent"

    # Stop qBittorrent
    systemctl stop "qbittorrent@${SWIZZIN_USER}" 2>/dev/null || true

    # Restore config directory
    if [[ -d "${bkp}/config" ]]; then
        mkdir -p "${user_home}/.config/qBittorrent"
        cp -r "${bkp}/config/"* "${user_home}/.config/qBittorrent/" 2>/dev/null || true
    elif [[ -f "${bkp}/qBittorrent.conf" ]]; then
        mkdir -p "${user_home}/.config/qBittorrent"
        cp "${bkp}/qBittorrent.conf" "${user_home}/.config/qBittorrent/"
    fi

    # Restore BT_backup (resume data)
    if [[ -d "${bkp}/BT_backup" ]]; then
        # Try standard path first
        local bt_dest="${user_home}/.local/share/qBittorrent/BT_backup"
        if [[ -d "${user_home}/.local/share/data/qBittorrent" ]]; then
            bt_dest="${user_home}/.local/share/data/qBittorrent/BT_backup"
        fi
        mkdir -p "$bt_dest"
        cp -r "${bkp}/BT_backup/"* "$bt_dest/" 2>/dev/null || true
    fi

    # Fix ownership
    chown -R "${SWIZZIN_USER}:${SWIZZIN_USER}" "${user_home}/.config/qBittorrent" 2>/dev/null || true
    chown -R "${SWIZZIN_USER}:${SWIZZIN_USER}" "${user_home}/.local/share/qBittorrent" 2>/dev/null || true
    chown -R "${SWIZZIN_USER}:${SWIZZIN_USER}" "${user_home}/.local/share/data/qBittorrent" 2>/dev/null || true

    # Restart qBittorrent
    systemctl start "qbittorrent@${SWIZZIN_USER}" 2>/dev/null || true

    log_success "qBittorrent restaurado"
}

#===============================================================================
# Deluge Restore
#===============================================================================

restore_deluge() {
    if [[ "$RESTORE_DELUGE" != "true" || "$HAS_DELUGE" != "true" ]]; then return; fi
    if [[ -z "$SWIZZIN_USER" ]]; then
        log_warning "Deluge: usuario nao detectado, pulando..."
        return
    fi

    log_step "Deluge: restaurando..."

    local user_home="/home/${SWIZZIN_USER}"
    local deluge_dir="${user_home}/.config/deluge"
    local bkp="${BACKUP_DIR}/deluge"

    # Stop Deluge
    systemctl stop "deluged@${SWIZZIN_USER}" 2>/dev/null || true
    systemctl stop "deluge-web@${SWIZZIN_USER}" 2>/dev/null || true

    # Restore full config
    mkdir -p "$deluge_dir"
    cp -r "${bkp}/"* "$deluge_dir/" 2>/dev/null || true

    # Fix ownership
    chown -R "${SWIZZIN_USER}:${SWIZZIN_USER}" "$deluge_dir"

    # Restart Deluge
    systemctl start "deluged@${SWIZZIN_USER}" 2>/dev/null || true
    systemctl start "deluge-web@${SWIZZIN_USER}" 2>/dev/null || true

    log_success "Deluge restaurado"
}

#===============================================================================
# Plex Restore
#===============================================================================

restore_plex() {
    if [[ "$RESTORE_PLEX" != "true" || "$HAS_PLEX" != "true" ]]; then return; fi

    log_step "Plex: restaurando..."

    local plex_base="/var/lib/plexmediaserver/Library/Application Support/Plex Media Server"
    local bkp="${BACKUP_DIR}/plex"

    # Stop Plex
    systemctl stop plexmediaserver 2>/dev/null || true

    # Restore Preferences.xml
    if [[ -f "${bkp}/Preferences.xml" ]]; then
        cp "${bkp}/Preferences.xml" "${plex_base}/Preferences.xml"
    fi

    # Restore databases
    if [[ -d "${bkp}/databases" ]]; then
        mkdir -p "${plex_base}/Plug-in Support/Databases"
        cp -r "${bkp}/databases/"* "${plex_base}/Plug-in Support/Databases/" 2>/dev/null || true
    fi

    # Restore plugin preferences
    if [[ -d "${bkp}/plugin-preferences" ]]; then
        mkdir -p "${plex_base}/Plug-in Support/Preferences"
        cp -r "${bkp}/plugin-preferences/"* "${plex_base}/Plug-in Support/Preferences/" 2>/dev/null || true
    fi

    # Restore metadata (if present)
    if [[ -d "${bkp}/metadata" ]]; then
        log_warning "Plex: restaurando metadata (pode demorar)..."
        mkdir -p "${plex_base}/Metadata"
        rsync -aAX --info=progress2 \
            "${bkp}/metadata/" "${plex_base}/Metadata/"
    fi

    # Fix ownership
    chown -R plex:plex "${plex_base}" 2>/dev/null || \
        chown -R plexmediaserver:plexmediaserver "${plex_base}" 2>/dev/null || true

    # Restart Plex
    systemctl start plexmediaserver 2>/dev/null || true

    log_success "Plex restaurado"
}

#===============================================================================
# Summary
#===============================================================================

show_summary() {
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║            Restauracao Concluida com Sucesso!                 ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}Componentes restaurados:${NC}"

    local has_nc_restore=false
    if [[ ("$RESTORE_NC_DATABASE" == "true" && "$HAS_NC_DATABASE" == "true") || \
          ("$RESTORE_NC_CONFIG" == "true" && "$HAS_NC_CONFIG" == "true") || \
          ("$RESTORE_NC_DATA" == "true" && "$HAS_NC_DATA" == "true") ]]; then
        has_nc_restore=true
        echo -e "    ${BOLD}Nextcloud:${NC}"
        [[ "$RESTORE_NC_DATABASE" == "true" && "$HAS_NC_DATABASE" == "true" ]] && echo -e "      ${GREEN}+${NC} Banco de dados"
        [[ "$RESTORE_NC_CONFIG" == "true" && "$HAS_NC_CONFIG" == "true" ]]     && echo -e "      ${GREEN}+${NC} Configuracao"
        [[ "$RESTORE_NC_APPS" == "true" && "$HAS_NC_APPS" == "true" ]]         && echo -e "      ${GREEN}+${NC} Apps"
        [[ "$RESTORE_NC_THEMES" == "true" && "$HAS_NC_THEMES" == "true" ]]     && echo -e "      ${GREEN}+${NC} Temas"
        [[ "$RESTORE_NC_DATA" == "true" && "$HAS_NC_DATA" == "true" ]]         && echo -e "      ${GREEN}+${NC} Diretorio de dados"
    fi

    [[ "$RESTORE_RUTORRENT" == "true" && "$HAS_RUTORRENT" == "true" ]]       && echo -e "    ${GREEN}+${NC} ruTorrent/rTorrent"
    [[ "$RESTORE_QBITTORRENT" == "true" && "$HAS_QBITTORRENT" == "true" ]]   && echo -e "    ${GREEN}+${NC} qBittorrent"
    [[ "$RESTORE_DELUGE" == "true" && "$HAS_DELUGE" == "true" ]]             && echo -e "    ${GREEN}+${NC} Deluge"
    [[ "$RESTORE_PLEX" == "true" && "$HAS_PLEX" == "true" ]]                 && echo -e "    ${GREEN}+${NC} Plex"
    echo ""

    if [[ "$has_nc_restore" == "true" ]]; then
        echo -e "  ${BOLD}Nextcloud:${NC} ${NEXTCLOUD_PATH}"
        echo -e "  ${BOLD}Dados:${NC}     ${DATA_PATH}"
        echo ""
    fi

    if [[ -n "$NEW_DOMAIN" ]]; then
        echo -e "  ${BOLD}Novo dominio:${NC} ${NEW_DOMAIN}"
        echo ""
        echo -e "  ${YELLOW}Lembre-se de:${NC}"
        echo -e "    1. Atualizar DNS para ${NEW_DOMAIN}"
        echo -e "    2. Obter certificado SSL: certbot --nginx -d ${NEW_DOMAIN}"
        echo -e "    3. Atualizar configuracao do web server se necessario"
        echo ""
    fi
}

#===============================================================================
# Main
#===============================================================================

main() {
    echo ""
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║          Restore - Nextcloud + Aplicacoes                     ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"

    check_root
    parse_args "$@"
    detect_swizzin_user

    # Trap for cleanup
    trap cleanup EXIT

    # Select backup file if not provided
    if [[ -z "$BACKUP_FILE" ]]; then
        list_available_backups
    fi

    # Validate backup file
    if [[ ! -f "$BACKUP_FILE" ]]; then
        log_error "Arquivo de backup nao encontrado: ${BACKUP_FILE}"
        exit 1
    fi

    echo ""
    log_info "Arquivo: ${BACKUP_FILE}"
    local file_size
    file_size=$(du -h "$BACKUP_FILE" | cut -f1)
    log_info "Tamanho: ${file_size}"

    # Extract and analyze
    extract_backup
    detect_backup_contents

    # Interactive menu
    if [[ "$INTERACTIVE" == "true" ]]; then
        show_restore_menu
    fi

    # Confirmation
    echo ""
    echo -e "${YELLOW}${BOLD}ATENCAO: Dados existentes podem ser sobrescritos!${NC}"
    echo ""
    read -rp "Confirma a restauracao? [s/N]: " confirm
    case $confirm in
        [sS]|[sS][iI][mM]) ;;
        *)
            log_info "Restauracao cancelada."
            exit 0 ;;
    esac

    echo ""
    local start_time
    start_time=$(date +%s)

    # === Nextcloud ===
    nc_enable_maintenance
    restore_nc_database
    restore_nc_config
    restore_nc_apps
    restore_nc_themes
    restore_nc_data
    nc_run_maintenance
    nc_disable_maintenance

    # === Aplicacoes ===
    restore_rutorrent
    restore_qbittorrent
    restore_deluge
    restore_plex

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
