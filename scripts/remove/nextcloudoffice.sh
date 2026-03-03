#!/bin/bash
#
# Nextcloud Office remover for swizzin
#
# Licensed under GNU General Public License v3.0 GPL-3

. /etc/swizzin/sources/functions/nextcloud

if [[ ! -f /install/.nextcloudoffice.lock ]]; then
    echo_error "Nextcloud Office is not installed"
    exit 1
fi

echo_info "Removing Nextcloud Office"

suite=$(swizdb get nextcloud/office_suite 2>/dev/null)
office_domain=$(swizdb get nextcloud/office_domain 2>/dev/null)

# --- Stop and remove Docker container ---

echo_progress_start "Removing Docker container"

if [[ "$suite" == "collabora" ]]; then
    docker stop collabora >> $log 2>&1 || true
    docker rm collabora >> $log 2>&1 || true
    docker network rm nextcloud-office >> $log 2>&1 || true
elif [[ "$suite" == "onlyoffice" ]]; then
    docker stop onlyoffice >> $log 2>&1 || true
    docker rm onlyoffice >> $log 2>&1 || true
fi

echo_progress_done "Docker container removed"

# --- Remove nginx config ---

echo_progress_start "Removing nginx configuration"
rm -f /etc/nginx/conf.d/nextcloud-office.conf

if [[ -n "$office_domain" ]]; then
    rm -rf "/etc/nginx/ssl/${office_domain}"
fi

systemctl reload nginx >> $log 2>&1
echo_progress_done "Nginx config removed"

# --- Disable Nextcloud apps ---

echo_progress_start "Disabling Nextcloud Office apps"

if [[ -d "${NEXTCLOUD_PATH}" ]]; then
    cd "${NEXTCLOUD_PATH}"
    if [[ "$suite" == "collabora" ]]; then
        nc_occ app:disable richdocuments >> $log 2>&1 || true
    elif [[ "$suite" == "onlyoffice" ]]; then
        nc_occ app:disable onlyoffice >> $log 2>&1 || true
    fi
fi

echo_progress_done "Apps disabled"

# --- Remove OnlyOffice data ---

if [[ "$suite" == "onlyoffice" ]]; then
    if ask "Remove OnlyOffice data directory /var/lib/onlyoffice?" N; then
        rm -rf /var/lib/onlyoffice
        echo_info "OnlyOffice data removed"
    fi
fi

# --- Clean swizdb ---

for key in office_suite office_domain onlyoffice_jwt; do
    swizdb clear "nextcloud/${key}" 2>/dev/null || true
done

# --- Remove lock ---

rm -f /install/.nextcloudoffice.lock

echo_success "Nextcloud Office removed"
