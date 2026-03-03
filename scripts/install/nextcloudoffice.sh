#!/bin/bash
#
# Nextcloud Office installer for swizzin
# Installs Collabora Online or OnlyOffice as a Docker container
# Depends on: nextcloud
#
# Licensed under GNU General Public License v3.0 GPL-3

. /etc/swizzin/sources/functions/nextcloud

#--- Prerequisites -----------------------------------------------------------

if [[ ! -f /install/.nextcloud.lock ]]; then
    echo_error "Nextcloud must be installed first: box install nextcloud"
    exit 1
fi

if [[ -f /install/.nextcloudoffice.lock ]]; then
    echo_error "Nextcloud Office is already installed"
    exit 1
fi

#--- Docker installation -----------------------------------------------------

_nco_install_docker() {
    if command -v docker &>/dev/null; then
        echo_info "Docker already installed"
        return
    fi

    echo_progress_start "Installing Docker"
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh >> $log 2>&1
    sh /tmp/get-docker.sh >> $log 2>&1
    rm -f /tmp/get-docker.sh
    systemctl start docker >> $log 2>&1
    systemctl enable docker >> $log 2>&1
    echo_progress_done "Docker installed"
}

#--- Collabora ---------------------------------------------------------------

_nco_install_collabora() {
    echo_progress_start "Installing Collabora Online"

    local nc_domain office_domain
    nc_domain=$(swizdb get nextcloud/domain)
    office_domain=$(swizdb get nextcloud/office_domain)

    docker pull collabora/code:latest >> $log 2>&1

    docker network create nextcloud-office >> $log 2>&1 || true

    docker run -d \
        --name collabora \
        --restart always \
        --network nextcloud-office \
        -p 9980:9980 \
        -e "aliasgroup1=https://${nc_domain}:443" \
        -e "username=admin" \
        -e "password=$(nc_generate_password)" \
        -e "extra_params=--o:ssl.enable=false --o:ssl.termination=true" \
        --cap-add MKNOD \
        collabora/code >> $log 2>&1

    # Wait for container to start
    sleep 10

    # Install Nextcloud app
    cd "${NEXTCLOUD_PATH}"
    nc_occ app:install richdocuments >> $log 2>&1 || true
    nc_occ app:enable richdocuments >> $log 2>&1

    # Configure WOPI
    nc_occ config:app:set richdocuments wopi_url --value="https://${office_domain}" >> $log 2>&1
    nc_occ config:app:set richdocuments public_wopi_url --value="https://${office_domain}" >> $log 2>&1

    echo_progress_done "Collabora installed"
}

#--- OnlyOffice --------------------------------------------------------------

_nco_install_onlyoffice() {
    echo_progress_start "Installing OnlyOffice"

    local nc_domain office_domain jwt_secret
    nc_domain=$(swizdb get nextcloud/domain)
    office_domain=$(swizdb get nextcloud/office_domain)
    jwt_secret=$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-32)

    swizdb set nextcloud/onlyoffice_jwt "$jwt_secret"

    # Create data directories
    mkdir -p /var/lib/onlyoffice/data
    mkdir -p /var/lib/onlyoffice/logs
    mkdir -p /var/lib/onlyoffice/fonts

    docker pull onlyoffice/documentserver:latest >> $log 2>&1

    docker run -d \
        --name onlyoffice \
        --restart always \
        -p 9980:80 \
        -v /var/lib/onlyoffice/data:/var/www/onlyoffice/Data \
        -v /var/lib/onlyoffice/logs:/var/log/onlyoffice \
        -v /var/lib/onlyoffice/fonts:/usr/share/fonts/truetype/custom \
        -e JWT_ENABLED=true \
        -e JWT_SECRET="${jwt_secret}" \
        onlyoffice/documentserver >> $log 2>&1

    # Wait for container to start
    sleep 15

    # Install Nextcloud app
    cd "${NEXTCLOUD_PATH}"
    nc_occ app:install onlyoffice >> $log 2>&1 || true
    nc_occ app:enable onlyoffice >> $log 2>&1

    # Configure OnlyOffice
    nc_occ config:app:set onlyoffice DocumentServerUrl --value="https://${office_domain}/" >> $log 2>&1
    nc_occ config:app:set onlyoffice DocumentServerInternalUrl --value="http://127.0.0.1:9980/" >> $log 2>&1
    nc_occ config:app:set onlyoffice StorageUrl --value="https://${nc_domain}/" >> $log 2>&1
    nc_occ config:app:set onlyoffice jwt_secret --value="${jwt_secret}" >> $log 2>&1
    nc_occ config:app:set onlyoffice jwt_header --value="Authorization" >> $log 2>&1
    nc_occ config:app:set onlyoffice verify_peer_off --value="true" >> $log 2>&1

    # Default file formats
    nc_occ config:app:set onlyoffice defFormats \
        --value='{"csv":"true","doc":"true","docm":"true","docx":"true","dotx":"true","epub":"true","html":"true","odp":"true","ods":"true","odt":"true","pdf":"false","potm":"true","potx":"true","ppsm":"true","ppsx":"true","ppt":"true","pptm":"true","pptx":"true","rtf":"true","txt":"true","xls":"true","xlsm":"true","xlsx":"true","xltm":"true","xltx":"true"}' >> $log 2>&1

    nc_occ config:app:set onlyoffice sameTab --value="true" >> $log 2>&1

    echo_progress_done "OnlyOffice installed"
}

#--- Nginx reverse proxy for Office ------------------------------------------

_nco_configure_nginx() {
    echo_progress_start "Configuring nginx for Office"

    local office_domain suite
    office_domain=$(swizdb get nextcloud/office_domain)
    suite=$(swizdb get nextcloud/office_suite)

    cat > /etc/nginx/conf.d/nextcloud-office.conf << NGINXEOF
# Nextcloud Office reverse proxy (swizzin)
# Suite: ${suite}

server {
    listen 80;
    listen [::]:80;
    server_name ${office_domain};
    server_tokens off;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${office_domain};

    server_tokens off;

NGINXEOF

    # SSL params: Collabora uses shared snippet, OnlyOffice inlines them
    # to avoid inheriting X-Frame-Options from the shared snippet
    if [[ "$suite" == "onlyoffice" ]]; then
        cat >> /etc/nginx/conf.d/nextcloud-office.conf << 'NGINXEOF'
    # SSL params (inlined to avoid X-Frame-Options from shared snippet)
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'HIGH:!aNULL:!MD5:!3DES';
    ssl_prefer_server_ciphers on;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:50m;
    ssl_session_tickets off;
NGINXEOF
    else
        cat >> /etc/nginx/conf.d/nextcloud-office.conf << 'NGINXEOF'
    include /etc/nginx/snippets/ssl-params.conf;
NGINXEOF
    fi

    # Use existing SSL cert for office domain, or fall back to nextcloud domain cert
    local nc_domain
    nc_domain=$(swizdb get nextcloud/domain)

    if [[ -d "/etc/nginx/ssl/${office_domain}" ]]; then
        cat >> /etc/nginx/conf.d/nextcloud-office.conf << NGINXEOF
    ssl_certificate /etc/nginx/ssl/${office_domain}/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/${office_domain}/key.pem;
NGINXEOF
    else
        # Generate self-signed cert for office domain
        mkdir -p "/etc/nginx/ssl/${office_domain}"
        openssl req -x509 -nodes -days 3650 \
            -newkey rsa:2048 \
            -keyout "/etc/nginx/ssl/${office_domain}/key.pem" \
            -out "/etc/nginx/ssl/${office_domain}/fullchain.pem" \
            -subj "/CN=${office_domain}" >> $log 2>&1

        cat >> /etc/nginx/conf.d/nextcloud-office.conf << NGINXEOF
    ssl_certificate /etc/nginx/ssl/${office_domain}/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/${office_domain}/key.pem;
NGINXEOF
    fi

    if [[ "$suite" == "collabora" ]]; then
        cat >> /etc/nginx/conf.d/nextcloud-office.conf << 'NGINXEOF'

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    # Static files
    location ^~ /browser {
        proxy_pass http://127.0.0.1:9980;
        proxy_set_header Host $http_host;
    }

    # WOPI discovery
    location ^~ /hosting/discovery {
        proxy_pass http://127.0.0.1:9980;
        proxy_set_header Host $http_host;
    }

    location ^~ /hosting/capabilities {
        proxy_pass http://127.0.0.1:9980;
        proxy_set_header Host $http_host;
    }

    # WebSocket
    location ~ ^/cool/(.*)/ws$ {
        proxy_pass http://127.0.0.1:9980;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_set_header Host $http_host;
        proxy_read_timeout 36000s;
    }

    # COOL/LOOL endpoints
    location ~ ^/(c|l)ool {
        proxy_pass http://127.0.0.1:9980;
        proxy_set_header Host $http_host;
    }

    # Admin console websocket
    location ^~ /cool/adminws {
        proxy_pass http://127.0.0.1:9980;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_set_header Host $http_host;
        proxy_read_timeout 36000s;
    }
}
NGINXEOF
    else
        # OnlyOffice
        cat >> /etc/nginx/conf.d/nextcloud-office.conf << 'NGINXEOF'

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    # Remove X-Frame-Options from OnlyOffice responses to allow iframe embedding
    proxy_hide_header X-Frame-Options;

    location / {
        proxy_pass http://127.0.0.1:9980;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 36000s;
    }
}
NGINXEOF
    fi

    nginx -t >> $log 2>&1 || {
        echo_error "Nginx configuration test failed"
        exit 1
    }

    systemctl reload nginx >> $log 2>&1

    echo_progress_done "Nginx configured for Office"
}

#--- Configuration collection ------------------------------------------------

_nco_collect_config() {
    local suite office_domain

    suite=${NEXTCLOUD_OFFICE:-}
    office_domain=${NEXTCLOUD_OFFICE_DOMAIN:-}

    if [[ -z "$suite" ]]; then
        echo_query "Select Office suite: 1) Collabora Online  2) OnlyOffice"
        read -r choice
        case $choice in
            1) suite="collabora" ;;
            2|*) suite="onlyoffice" ;;
        esac
    fi

    local nc_domain
    nc_domain=$(swizdb get nextcloud/domain)

    if [[ -z "$office_domain" ]]; then
        echo_query "Enter Office subdomain (default: office.${nc_domain})"
        read -r office_domain
        office_domain=${office_domain:-office.${nc_domain}}
    fi

    swizdb set nextcloud/office_suite "$suite"
    swizdb set nextcloud/office_domain "$office_domain"

    export NCO_SUITE="$suite"
}

#--- Main execution ----------------------------------------------------------

echo_info "Starting Nextcloud Office installation"

_nco_collect_config
_nco_install_docker

if [[ "$NCO_SUITE" == "collabora" ]]; then
    _nco_install_collabora
else
    _nco_install_onlyoffice
fi

_nco_configure_nginx

touch /install/.nextcloudoffice.lock

echo_success "Nextcloud Office (${NCO_SUITE}) installed"
echo_info "Office available at: https://$(swizdb get nextcloud/office_domain)"
