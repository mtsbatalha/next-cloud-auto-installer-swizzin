#!/bin/bash
#
# Nextcloud remover for swizzin
#
# Licensed under GNU General Public License v3.0 GPL-3

#shellcheck source=sources/functions/php
. /etc/swizzin/sources/functions/php
. /etc/swizzin/sources/functions/nextcloud

echo_info "Removing Nextcloud"

# Get MySQL root password
password=""
if ! mysql -e "SELECT 1;" >> $log 2>&1; then
    echo_query "Enter MySQL root password to drop Nextcloud database" "hidden"
    read -rs password
    echo
fi

mysql_auth=""
if [[ -n "$password" ]]; then
    mysql_auth="--password=${password}"
fi

phpv=$(php_service_version)

# --- Stop services ---

echo_progress_start "Stopping services"
systemctl stop "php${phpv}-fpm" >> $log 2>&1 || true
echo_progress_done

# --- Remove Nextcloud files ---

echo_progress_start "Removing Nextcloud files"
rm -rf /srv/nextcloud
rm -rf /srv/nextcloud-data
echo_progress_done "Nextcloud files removed"

# --- Remove nginx config ---

echo_progress_start "Removing nginx configuration"
rm -f /etc/nginx/conf.d/nextcloud.conf

domain=$(swizdb get nextcloud/domain 2>/dev/null)
if [[ -n "$domain" ]]; then
    rm -rf "/etc/nginx/ssl/${domain}"
fi

systemctl reload nginx >> $log 2>&1
echo_progress_done "Nginx config removed"

# --- Drop database ---

echo_progress_start "Dropping database"
db_host=$(mysql ${mysql_auth} -e "SELECT host FROM mysql.user WHERE user = 'nextcloud';" 2>/dev/null | grep -E "localhost|127.0.0.1" | head -1)
db_host=${db_host:-localhost}

mysql ${mysql_auth} -e "DROP DATABASE IF EXISTS nextcloud;" >> $log 2>&1
mysql ${mysql_auth} -e "DROP USER IF EXISTS 'nextcloud'@'${db_host}';" >> $log 2>&1
mysql ${mysql_auth} -e "FLUSH PRIVILEGES;" >> $log 2>&1

rm -f /etc/mysql/mariadb.conf.d/99-nextcloud.cnf
systemctl restart mariadb >> $log 2>&1 || true
echo_progress_done "Database dropped"

# --- Remove PHP configs ---

echo_progress_start "Removing PHP configuration"
rm -f "/etc/php/${phpv}/fpm/conf.d/99-nextcloud-security.ini"
rm -f "/etc/php/${phpv}/mods-available/opcache-nextcloud.ini"
rm -f "/etc/php/${phpv}/fpm/conf.d/10-opcache-nextcloud.ini"
rm -f "/etc/php/${phpv}/cli/conf.d/10-opcache-nextcloud.ini"
rm -f "/etc/php/${phpv}/mods-available/apcu-nextcloud.ini"
rm -f "/etc/php/${phpv}/fpm/conf.d/20-apcu-nextcloud.ini"
rm -f "/etc/php/${phpv}/cli/conf.d/20-apcu-nextcloud.ini"
rm -f "/etc/php/${phpv}/fpm/pool.d/nextcloud.conf"
rm -f "/var/log/php${phpv}-fpm-nextcloud.log"
echo_progress_done "PHP configs removed"

# --- Remove Fail2ban config ---

echo_progress_start "Removing Fail2ban configuration"
rm -f /etc/fail2ban/filter.d/nextcloud.conf
rm -f /etc/fail2ban/jail.d/nextcloud.conf
systemctl restart fail2ban >> $log 2>&1 || true
echo_progress_done "Fail2ban config removed"

# --- Remove cron ---

rm -f /etc/cron.d/nextcloud
systemctl reload cron >> $log 2>&1 || systemctl reload crond >> $log 2>&1 || true

# --- Backups ---

if [[ -d /var/backups/nextcloud ]]; then
    if ask "Remove backup directory /var/backups/nextcloud?" N; then
        rm -rf /var/backups/nextcloud
        echo_info "Backups removed"
    else
        echo_info "Backups preserved at /var/backups/nextcloud"
    fi
fi

# --- Clean swizdb ---

echo_progress_start "Cleaning configuration database"
for key in domain admin_user admin_email db_name db_user db_pass redis_pass redis_dbindex; do
    swizdb clear "nextcloud/${key}" 2>/dev/null || true
done
echo_progress_done

# --- Restart PHP-FPM ---

restart_php_fpm >> $log 2>&1

# --- Remove lock ---

rm -f /install/.nextcloud.lock

echo_success "Nextcloud removed"
