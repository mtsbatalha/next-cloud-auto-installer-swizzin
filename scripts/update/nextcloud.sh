#!/bin/bash
#
# Nextcloud updater for swizzin
# Runs on `box update` to refresh configs and update Nextcloud
#
# Licensed under GNU General Public License v3.0 GPL-3

if [[ ! -f /install/.nextcloud.lock ]]; then
    exit 0
fi

#shellcheck source=sources/functions/php
. /etc/swizzin/sources/functions/php
. /etc/swizzin/sources/functions/nextcloud

echo_progress_start "Updating Nextcloud"

phpv=$(php_service_version)
sock="php${phpv}-fpm-nextcloud"
domain=$(swizdb get nextcloud/domain 2>/dev/null)
redis_pass=$(swizdb get nextcloud/redis_pass 2>/dev/null)
redis_dbindex=$(swizdb get nextcloud/redis_dbindex 2>/dev/null || echo "0")

# --- Update nginx config with current PHP version ---

if [[ -f /etc/nginx/conf.d/nextcloud.conf ]]; then
    # Check if PHP socket path needs updating
    current_sock=$(grep -oP 'server unix:/var/run/php/\K[^.]+' /etc/nginx/conf.d/nextcloud.conf 2>/dev/null | head -1)
    if [[ "$current_sock" != "$sock" && -n "$current_sock" ]]; then
        echo_info "Updating nginx PHP socket: ${current_sock} -> ${sock}"
        sed -i "s|${current_sock}|${sock}|g" /etc/nginx/conf.d/nextcloud.conf
        systemctl reload nginx >> $log 2>&1
    fi
fi

# --- Update PHP-FPM pool if PHP version changed ---

if [[ -f "/etc/php/${phpv}/fpm/pool.d/nextcloud.conf" ]]; then
    # Check if socket path matches current PHP version
    current_pool_sock=$(grep -oP 'listen = /var/run/php/\K[^.]+' "/etc/php/${phpv}/fpm/pool.d/nextcloud.conf" 2>/dev/null)
    if [[ "$current_pool_sock" != "php${phpv}-fpm-nextcloud" ]]; then
        echo_info "Updating PHP-FPM pool socket for PHP ${phpv}"
        sed -i "s|listen = /var/run/php/.*\.sock|listen = /var/run/php/php${phpv}-fpm-nextcloud.sock|g" \
            "/etc/php/${phpv}/fpm/pool.d/nextcloud.conf"
        restart_php_fpm >> $log 2>&1
    fi
else
    # Pool config missing for current PHP version, check for old versions
    for old_conf in /etc/php/*/fpm/pool.d/nextcloud.conf; do
        if [[ -f "$old_conf" && "$old_conf" != "/etc/php/${phpv}/fpm/pool.d/nextcloud.conf" ]]; then
            echo_info "Migrating PHP-FPM pool from old PHP version"
            # Read old config and recreate for new version
            total_ram_mb=$(free -m | awk '/^Mem:/{print $2}')
            max_children=$(( (total_ram_mb * 70 / 100) / 80 ))
            [[ $max_children -lt 5 ]] && max_children=5
            [[ $max_children -gt 100 ]] && max_children=100
            start_servers=$(( max_children / 4 ))
            min_spare=$(( max_children / 4 ))
            max_spare=$(( max_children / 2 ))

            cat > "/etc/php/${phpv}/fpm/pool.d/nextcloud.conf" << EOF
[nextcloud]
user = www-data
group = www-data
listen = /var/run/php/php${phpv}-fpm-nextcloud.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = dynamic
pm.max_children = ${max_children}
pm.start_servers = ${start_servers}
pm.min_spare_servers = ${min_spare}
pm.max_spare_servers = ${max_spare}
pm.max_requests = 500
pm.process_idle_timeout = 10s
pm.status_path = /nc-status
env[HOSTNAME] = \$HOSTNAME
env[PATH] = /usr/local/bin:/usr/bin:/bin
env[TMP] = /tmp
env[TMPDIR] = /tmp
env[TEMP] = /tmp
php_admin_value[error_log] = /var/log/php${phpv}-fpm-nextcloud.log
php_admin_flag[log_errors] = on
php_admin_value[memory_limit] = 512M
php_admin_value[upload_max_filesize] = 16G
php_admin_value[post_max_size] = 16G
php_admin_value[max_execution_time] = 3600
php_admin_value[max_input_time] = 3600
php_admin_value[output_buffering] = Off
EOF
            rm -f "$old_conf"
            restart_php_fpm >> $log 2>&1
            break
        fi
    done
fi

# --- Migrate PHP module configs if PHP version changed ---

for ini_type in opcache-nextcloud apcu-nextcloud; do
    if [[ -f "/etc/php/${phpv}/mods-available/${ini_type}.ini" ]]; then
        # Ensure symlinks exist for current PHP version
        case "$ini_type" in
            opcache-nextcloud)
                ln -sf "/etc/php/${phpv}/mods-available/${ini_type}.ini" \
                    "/etc/php/${phpv}/fpm/conf.d/10-${ini_type}.ini" 2>/dev/null
                ln -sf "/etc/php/${phpv}/mods-available/${ini_type}.ini" \
                    "/etc/php/${phpv}/cli/conf.d/10-${ini_type}.ini" 2>/dev/null
                ;;
            apcu-nextcloud)
                ln -sf "/etc/php/${phpv}/mods-available/${ini_type}.ini" \
                    "/etc/php/${phpv}/fpm/conf.d/20-${ini_type}.ini" 2>/dev/null
                ln -sf "/etc/php/${phpv}/mods-available/${ini_type}.ini" \
                    "/etc/php/${phpv}/cli/conf.d/20-${ini_type}.ini" 2>/dev/null
                ;;
        esac
    fi
done

# --- Run Nextcloud updates ---

if [[ -d "${NEXTCLOUD_PATH}" ]]; then
    echo_info "Checking for Nextcloud updates"
    cd "${NEXTCLOUD_PATH}"

    nc_occ update:check >> $log 2>&1 || true
    nc_occ upgrade >> $log 2>&1 || true
    nc_occ db:add-missing-indices >> $log 2>&1 || true
    nc_occ db:convert-filecache-bigint --no-interaction >> $log 2>&1 || true
    nc_occ maintenance:repair >> $log 2>&1 || true
    nc_maintenance_off

    echo_info "Nextcloud version: $(nc_get_version)"
fi

# --- Restart services ---

restart_php_fpm >> $log 2>&1
systemctl reload nginx >> $log 2>&1

echo_progress_done "Nextcloud updated"
