#!/bin/bash
#===============================================================================
# Install Nextcloud Talk
# Includes Talk app, High-Performance Backend (HPB), and Coturn (TURN/STUN)
#===============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"

# Load configuration
if [[ -f "${SCRIPT_DIR}/.install-config" ]]; then
    source "${SCRIPT_DIR}/.install-config"
else
    # Auto-detect Nextcloud path
    NEXTCLOUD_PATH=""
    for _p in /var/www/nextcloud /srv/nextcloud /var/www/html/nextcloud /opt/nextcloud; do
        if [[ -f "${_p}/occ" ]]; then
            NEXTCLOUD_PATH="$_p"
            break
        fi
    done
    NEXTCLOUD_PATH="${NEXTCLOUD_PATH:-/var/www/nextcloud}"
    DOMAIN="localhost"
fi

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

print_banner() {
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║          Nextcloud Talk Installation                          ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

#===============================================================================
# Installation Functions
#===============================================================================

install_talk_app() {
    log_info "Installing Nextcloud Talk app..."
    
    cd "${NEXTCLOUD_PATH}"
    
    # Try to install Talk from appstore
    if sudo -u www-data php occ app:install spreed 2>&1 | grep -q "not found"; then
        log_warning "Talk not available in appstore for this Nextcloud version"
        log_info "Installing manually from GitHub..."
        
        # Download latest compatible version
        TALK_VERSION=$(curl -s https://api.github.com/repos/nextcloud/spreed/releases/latest | grep -oP '"tag_name": "v\K[^"]+')
        
        wget "https://github.com/nextcloud/spreed/releases/download/v${TALK_VERSION}/spreed-v${TALK_VERSION}.tar.gz" -O /tmp/spreed.tar.gz
        tar -xzf /tmp/spreed.tar.gz -C "${NEXTCLOUD_PATH}/apps/"
        rm /tmp/spreed.tar.gz
        
        chown -R www-data:www-data "${NEXTCLOUD_PATH}/apps/spreed"
    fi
    
    # Enable Talk
    sudo -u www-data php occ app:enable spreed
    
    log_success "Talk app installed"
}

install_coturn() {
    log_info "Installing Coturn (TURN/STUN server)..."
    
    apt-get update
    apt-get install -y coturn
    
    # Generate random secrets
    TURN_SECRET=$(openssl rand -hex 32)
    
    # Configure Coturn
    cat > /etc/turnserver.conf << EOF
# Coturn configuration for Nextcloud Talk

# Listening ports
listening-port=3478
tls-listening-port=5349

# Relay ports
min-port=49152
max-port=65535

# Authentication
use-auth-secret
static-auth-secret=${TURN_SECRET}
realm=${DOMAIN}

# Logging
verbose
log-file=/var/log/turnserver.log

# Performance
total-quota=100
bps-capacity=0

# SSL certificates (will use Let's Encrypt)
cert=/etc/letsencrypt/live/${DOMAIN}/fullchain.pem
pkey=/etc/letsencrypt/live/${DOMAIN}/privkey.pem

# Other options
no-multicast-peers
no-cli
EOF

    # Enable Coturn
    sed -i 's/#TURNSERVER_ENABLED=1/TURNSERVER_ENABLED=1/' /etc/default/coturn
    
    # Configure firewall
    log_info "Opening firewall ports for Coturn..."
    ufw allow 3478/tcp comment 'Coturn TURN'
    ufw allow 3478/udp comment 'Coturn TURN'
    ufw allow 5349/tcp comment 'Coturn TURN TLS'
    ufw allow 5349/udp comment 'Coturn TURN TLS'
    ufw allow 49152:65535/udp comment 'Coturn relay ports'
    
    # Start Coturn
    systemctl enable coturn
    systemctl restart coturn
    
    # Save secret for Nextcloud configuration
    echo "TURN_SECRET=\"${TURN_SECRET}\"" >> "${SCRIPT_DIR}/.install-config"
    
    log_success "Coturn installed and configured"
}

install_talk_hpb() {
    log_info "Installing Talk High-Performance Backend (HPB)..."
    
    # Install dependencies
    apt-get install -y golang-go make git
    
    # Clone HPB repository
    cd /opt
    if [[ ! -d "nextcloud-spreed-signaling" ]]; then
        git clone https://github.com/strukturag/nextcloud-spreed-signaling.git
    fi
    
    cd nextcloud-spreed-signaling
    
    # Build HPB
    log_info "Building HPB (this may take a while)..."
    make
    
    # Create configuration directory
    mkdir -p /etc/nextcloud-spreed-signaling
    
    # Generate secrets
    HPB_SECRET=$(openssl rand -hex 32)
    HPB_HASH_KEY=$(openssl rand -hex 32)
    HPB_BLOCK_KEY=$(openssl rand -hex 16)
    
    # Create configuration
    cat > /etc/nextcloud-spreed-signaling/server.conf << EOF
[http]
listen = 127.0.0.1:8080

[app]
debug = false

[sessions]
hashkey = ${HPB_HASH_KEY}
blockkey = ${HPB_BLOCK_KEY}

[clients]
internalsecret = ${HPB_SECRET}

[backend]
backends = backend-1

[backend-1]
url = https://${DOMAIN}
secret = ${HPB_SECRET}
EOF

    # Create systemd service
    cat > /etc/systemd/system/talk-hpb.service << EOF
[Unit]
Description=Nextcloud Talk High-Performance Backend
After=network.target

[Service]
Type=simple
User=www-data
WorkingDirectory=/opt/nextcloud-spreed-signaling
ExecStart=/opt/nextcloud-spreed-signaling/bin/signaling -config /etc/nextcloud-spreed-signaling/server.conf
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    # Enable and start HPB
    systemctl daemon-reload
    systemctl enable talk-hpb
    systemctl start talk-hpb
    
    # Save secret for Nextcloud configuration
    echo "HPB_SECRET=\"${HPB_SECRET}\"" >> "${SCRIPT_DIR}/.install-config"
    
    log_success "HPB installed and running"
}

configure_talk_in_nextcloud() {
    log_info "Configuring Talk in Nextcloud..."
    
    cd "${NEXTCLOUD_PATH}"
    
    # Load secrets
    source "${SCRIPT_DIR}/.install-config"
    
    # Configure TURN server
    sudo -u www-data php occ talk:turn:add "turn:${DOMAIN}:3478" udp "${TURN_SECRET}"
    sudo -u www-data php occ talk:turn:add "turn:${DOMAIN}:3478" tcp "${TURN_SECRET}"
    sudo -u www-data php occ talk:turn:add "turns:${DOMAIN}:5349" tcp "${TURN_SECRET}"
    
    # Configure STUN server
    sudo -u www-data php occ talk:stun:add "${DOMAIN}:3478"
    
    # Configure HPB
    sudo -u www-data php occ talk:signaling:add "https://${DOMAIN}:8080" "${HPB_SECRET}"
    
    log_success "Talk configured in Nextcloud"
}

configure_nginx_for_hpb() {
    if [[ "$WEBSERVER" != "nginx" ]]; then
        log_warning "HPB proxy configuration only available for Nginx"
        return
    fi
    
    log_info "Configuring Nginx proxy for HPB..."
    
    # Add HPB proxy to Nextcloud site
    cat > /etc/nginx/conf.d/talk-hpb-proxy.conf << 'EOF'
# Talk HPB proxy configuration
upstream talk-hpb {
    server 127.0.0.1:8080;
}

server {
    listen 8080 ssl http2;
    server_name DOMAIN_PLACEHOLDER;

    ssl_certificate /etc/letsencrypt/live/DOMAIN_PLACEHOLDER/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/DOMAIN_PLACEHOLDER/privkey.pem;

    location / {
        proxy_pass http://talk-hpb;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOF

    sed -i "s/DOMAIN_PLACEHOLDER/${DOMAIN}/g" /etc/nginx/conf.d/talk-hpb-proxy.conf
    
    # Open firewall for HPB
    ufw allow 8080/tcp comment 'Talk HPB'
    
    nginx -t && systemctl reload nginx
    
    log_success "Nginx configured for HPB"
}

#===============================================================================
# Main
#===============================================================================

main() {
    print_banner
    check_root
    
    log_warning "This will install:"
    echo "  - Nextcloud Talk app (Spreed)"
    echo "  - Coturn TURN/STUN server"
    echo "  - Talk High-Performance Backend (HPB)"
    echo ""
    
    read -p "Continue? [y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
        log_info "Installation cancelled"
        exit 0
    fi
    
    echo ""
    
    install_talk_app
    install_coturn
    install_talk_hpb
    configure_nginx_for_hpb
    configure_talk_in_nextcloud
    
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║        Nextcloud Talk Installed Successfully!                 ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  Talk is now available in your Nextcloud!"
    echo ""
    echo "  Ports opened:"
    echo "    3478 (UDP/TCP)  - TURN"
    echo "    5349 (TCP)      - TURN over TLS"
    echo "    8080 (TCP)      - HPB signaling"
    echo "    49152-65535     - Relay ports"
    echo ""
    log_info "Test your Talk installation at: https://${DOMAIN}"
    echo ""
}

main "$@"
