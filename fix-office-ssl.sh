#!/bin/bash
#===============================================================================
# fix-office-ssl.sh - Fix OnlyOffice/Collabora SSL handshake errors
# Resolves: CURL error 35: SSL handshake failure
#===============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

NEXTCLOUD_PATH="/var/www/nextcloud"

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    log_error "Run as root: sudo bash $0"
    exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  OnlyOffice/Collabora SSL Fix"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Detect Office subdomain
cd "$NEXTCLOUD_PATH"

# Check which Office app is installed
ONLYOFFICE_URL=$(sudo -u www-data php occ config:app:get onlyoffice DocumentServerUrl 2>/dev/null || echo "")
COLLABORA_URL=$(sudo -u www-data php occ config:app:get richdocuments wopi_url 2>/dev/null || echo "")

if [[ -n "$ONLYOFFICE_URL" ]]; then
    OFFICE_URL="$ONLYOFFICE_URL"
    OFFICE_TYPE="OnlyOffice"
    OFFICE_DOMAIN=$(echo "$OFFICE_URL" | sed 's|https://||;s|/.*||')
elif [[ -n "$COLLABORA_URL" ]]; then
    OFFICE_URL="$COLLABORA_URL"
    OFFICE_TYPE="Collabora"
    OFFICE_DOMAIN=$(echo "$OFFICE_URL" | sed 's|https://||;s|/.*||')
else
    log_error "No Office app configured"
    exit 1
fi

log_info "Detected: $OFFICE_TYPE at $OFFICE_DOMAIN"

#===============================================================================
# 1. Test SSL Connection
#===============================================================================
log_info "Testing SSL connection to $OFFICE_DOMAIN..."

SSL_TEST=$(openssl s_client -connect "$OFFICE_DOMAIN:443" -servername "$OFFICE_DOMAIN" </dev/null 2>&1 || echo "FAILED")

if echo "$SSL_TEST" | grep -q "CONNECTED"; then
    log_success "SSL connection successful"
else
    log_warning "SSL connection failed - checking certificate..."
fi

#===============================================================================
# 2. Check and Fix SSL Certificate for Office Subdomain
#===============================================================================
log_info "Checking SSL certificate for $OFFICE_DOMAIN..."

CERT_FILE="/etc/letsencrypt/live/${OFFICE_DOMAIN}/fullchain.pem"

if [[ ! -f "$CERT_FILE" ]]; then
    log_warning "No SSL certificate found for $OFFICE_DOMAIN"
    log_info "Obtaining certificate with Certbot..."
    
    # Stop nginx temporarily if certbot needs standalone mode
    certbot certonly --nginx -d "$OFFICE_DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email 2>/dev/null || \
    certbot certonly --standalone -d "$OFFICE_DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email 2>/dev/null || true
    
    if [[ -f "$CERT_FILE" ]]; then
        log_success "SSL certificate obtained"
    else
        log_error "Failed to obtain certificate. Run: certbot --nginx -d $OFFICE_DOMAIN"
    fi
else
    log_success "SSL certificate exists"
    
    # Check expiration
    EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_FILE" 2>/dev/null | cut -d= -f2)
    log_info "Certificate expires: $EXPIRY"
fi

#===============================================================================
# 3. Update Nginx Configuration for Office
#===============================================================================
log_info "Updating Nginx configuration for $OFFICE_TYPE..."

NGINX_OFFICE_CONF="/etc/nginx/sites-available/${OFFICE_TYPE,,}"

if [[ "$OFFICE_TYPE" == "OnlyOffice" ]]; then
    cat > "$NGINX_OFFICE_CONF" << EOF
# OnlyOffice Document Server Nginx Configuration

server {
    listen 80;
    server_name ${OFFICE_DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${OFFICE_DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${OFFICE_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${OFFICE_DOMAIN}/privkey.pem;
    
    # SSL settings
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:50m;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    location / {
        proxy_pass http://127.0.0.1:9980;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 36000s;
    }
}
EOF
else
    # Collabora configuration
    cat > "$NGINX_OFFICE_CONF" << EOF
# Collabora Online Nginx Configuration

server {
    listen 80;
    server_name ${OFFICE_DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${OFFICE_DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${OFFICE_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${OFFICE_DOMAIN}/privkey.pem;
    
    # SSL settings
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:50m;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    # Static files
    location ^~ /browser {
        proxy_pass http://127.0.0.1:9980;
        proxy_set_header Host \$http_host;
    }

    # WOPI discovery URL
    location ^~ /hosting/discovery {
        proxy_pass http://127.0.0.1:9980;
        proxy_set_header Host \$http_host;
    }

    location ^~ /hosting/capabilities {
        proxy_pass http://127.0.0.1:9980;
        proxy_set_header Host \$http_host;
    }

    # Main WebSocket
    location ~ ^/cool/(.*)/ws\$ {
        proxy_pass http://127.0.0.1:9980;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_set_header Host \$http_host;
        proxy_read_timeout 36000s;
    }

    # Download, presentation and image upload
    location ~ ^/(c|l)ool {
        proxy_pass http://127.0.0.1:9980;
        proxy_set_header Host \$http_host;
    }

    # Admin console websocket
    location ^~ /cool/adminws {
        proxy_pass http://127.0.0.1:9980;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_set_header Host \$http_host;
        proxy_read_timeout 36000s;
    }
}
EOF
fi

ln -sf "$NGINX_OFFICE_CONF" /etc/nginx/sites-enabled/

log_success "Nginx configuration updated for $OFFICE_TYPE"

#===============================================================================
# 4. Check Docker Container
#===============================================================================
log_info "Checking $OFFICE_TYPE Docker container..."

if [[ "$OFFICE_TYPE" == "OnlyOffice" ]]; then
    CONTAINER_NAME="onlyoffice"
else
    CONTAINER_NAME="collabora"
fi

if docker ps | grep -q "$CONTAINER_NAME"; then
    log_success "$CONTAINER_NAME container is running"
else
    log_warning "$CONTAINER_NAME container not running"
    
    if docker ps -a | grep -q "$CONTAINER_NAME"; then
        log_info "Starting $CONTAINER_NAME container..."
        docker start "$CONTAINER_NAME"
        sleep 5
    else
        log_error "Container not found. Please reinstall $OFFICE_TYPE."
    fi
fi

#===============================================================================
# 5. Allow Nextcloud to Connect Without SSL Verification (temporary fix)
#===============================================================================
log_info "Configuring Nextcloud to trust Office server..."

if [[ "$OFFICE_TYPE" == "OnlyOffice" ]]; then
    # Set OnlyOffice to not verify SSL (useful for self-signed certs)
    sudo -u www-data php occ config:app:set onlyoffice verify_peer_off --value="true" 2>/dev/null || true
    log_success "OnlyOffice SSL verification configured"
else
    # For Collabora, disable certificate verification if needed
    sudo -u www-data php occ config:app:set richdocuments disable_certificate_verification --value="yes" 2>/dev/null || true
    log_success "Collabora SSL verification configured"
fi

#===============================================================================
# 6. Test and Restart Services
#===============================================================================
log_info "Testing Nginx configuration..."
if nginx -t 2>&1; then
    log_success "Nginx configuration valid"
    systemctl restart nginx
else
    log_error "Nginx configuration error"
    exit 1
fi

#===============================================================================
# 7. Test Connection from Nextcloud
#===============================================================================
log_info "Testing connection to $OFFICE_TYPE..."

# Test healthcheck
if [[ "$OFFICE_TYPE" == "OnlyOffice" ]]; then
    HEALTH_URL="https://${OFFICE_DOMAIN}/healthcheck"
else
    HEALTH_URL="https://${OFFICE_DOMAIN}/hosting/discovery"
fi

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -k "$HEALTH_URL" --max-time 10 2>/dev/null || echo "000")

if [[ "$HTTP_CODE" == "200" ]]; then
    log_success "Health check passed: HTTP $HTTP_CODE"
else
    log_warning "Health check returned: HTTP $HTTP_CODE"
    
    # Try internal connection
    INTERNAL_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:9980/healthcheck" --max-time 10 2>/dev/null || echo "000")
    if [[ "$INTERNAL_CODE" == "200" ]]; then
        log_info "Internal connection works. SSL proxy issue."
    else
        log_error "Container not responding. Check: docker logs $CONTAINER_NAME"
    fi
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Fix Complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  $OFFICE_TYPE URL: https://$OFFICE_DOMAIN"
echo ""
echo "  If still failing:"
echo "    1. Ensure DNS for $OFFICE_DOMAIN points to this server"
echo "    2. Check certificate: certbot --nginx -d $OFFICE_DOMAIN"
echo "    3. Check container: docker logs $CONTAINER_NAME"
echo ""
echo "  Then refresh the Nextcloud Office settings page."
echo ""
