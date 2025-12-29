#!/bin/bash
#===============================================================================
# Install Nginx with PageSpeed Module
# Replaces current Nginx with version compiled with PageSpeed
#===============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

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
    echo -e "${CYAN}║       Install Nginx with PageSpeed Module                     ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

#===============================================================================
# Installation Functions
#===============================================================================

backup_current_nginx() {
    log_info "Backing up current Nginx configuration..."
    
    # Create backup directory
    BACKUP_DIR="/root/nginx-backup-$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    
    # Backup configurations
    cp -r /etc/nginx "$BACKUP_DIR/"
    
    # Get list of enabled sites
    ls -la /etc/nginx/sites-enabled/ > "$BACKUP_DIR/enabled-sites.txt"
    
    log_success "Backup saved to: $BACKUP_DIR"
}

install_build_dependencies() {
    log_info "Installing build dependencies..."
    
    apt-get update
    apt-get install -y \
        build-essential \
        zlib1g-dev \
        libpcre3-dev \
        libssl-dev \
        wget \
        unzip \
        uuid-dev
}

download_and_compile_nginx() {
    log_info "Downloading Nginx and PageSpeed..."
    
    # Versions
    NGINX_VERSION="1.24.0"
    NPS_VERSION="1.14.36.1"
    PSOL_VERSION="1.14.36.1"
    
    cd /tmp
    
    # Download Nginx
    wget "http://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz"
    tar -xzf "nginx-${NGINX_VERSION}.tar.gz"
    
    # Download PageSpeed
    wget "https://github.com/apache/incubator-pagespeed-ngx/archive/v${NPS_VERSION}-stable.zip"
    unzip "v${NPS_VERSION}-stable.zip"
    
    cd "incubator-pagespeed-ngx-${NPS_VERSION}-stable"
    
    # Download PSOL
    wget "https://dl.google.com/dl/page-speed/psol/${PSOL_VERSION}-x64.tar.gz"
    tar -xzf "${PSOL_VERSION}-x64.tar.gz"
    
    cd "/tmp/nginx-${NGINX_VERSION}"
    
    log_info "Compiling Nginx with PageSpeed (this will take several minutes)..."
    
    # Configure with PageSpeed
    ./configure \
        --prefix=/etc/nginx \
        --sbin-path=/usr/sbin/nginx \
        --modules-path=/usr/lib/nginx/modules \
        --conf-path=/etc/nginx/nginx.conf \
        --error-log-path=/var/log/nginx/error.log \
        --http-log-path=/var/log/nginx/access.log \
        --pid-path=/var/run/nginx.pid \
        --lock-path=/var/run/nginx.lock \
        --http-client-body-temp-path=/var/cache/nginx/client_temp \
        --http-proxy-temp-path=/var/cache/nginx/proxy_temp \
        --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
        --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
        --http-scgi-temp-path=/var/cache/nginx/scgi_temp \
        --user=www-data \
        --group=www-data \
        --with-compat \
        --with-file-aio \
        --with-threads \
        --with-http_addition_module \
        --with-http_auth_request_module \
        --with-http_dav_module \
        --with-http_flv_module \
        --with-http_gunzip_module \
        --with-http_gzip_static_module \
        --with-http_mp4_module \
        --with-http_random_index_module \
        --with-http_realip_module \
        --with-http_secure_link_module \
        --with-http_slice_module \
        --with-http_ssl_module \
        --with-http_stub_status_module \
        --with-http_sub_module \
        --with-http_v2_module \
        --with-stream \
        --with-stream_realip_module \
        --with-stream_ssl_module \
        --with-stream_ssl_preread_module \
        --add-module="/tmp/incubator-pagespeed-ngx-${NPS_VERSION}-stable" \
        --with-cc-opt='-g -O2 -fstack-protector-strong -Wformat -Werror=format-security -Wp,-D_FORTIFY_SOURCE=2 -fPIC' \
        --with-ld-opt='-Wl,-Bsymbolic-functions -Wl,-z,relro -Wl,-z,now -Wl,--as-needed -pie'
    
    # Compile
    make -j$(nproc)
    
    log_success "Nginx compiled successfully"
}

install_compiled_nginx() {
    log_info "Installing compiled Nginx..."
    
    # Stop current Nginx
    systemctl stop nginx || true
    
    # Install new Nginx
    cd "/tmp/nginx-${NGINX_VERSION}"
    make install
    
    # Create cache directories
    mkdir -p /var/cache/nginx/client_temp
    mkdir -p /var/cache/nginx/proxy_temp
    mkdir -p /var/cache/nginx/fastcgi_temp
    mkdir -p /var/cache/nginx/uwsgi_temp
    mkdir -p /var/cache/nginx/scgi_temp
    mkdir -p /var/ngx_pagespeed_cache
    
    chown -R www-data:www-data /var/cache/nginx
    chown -R www-data:www-data /var/ngx_pagespeed_cache
    
    log_success "Nginx installed"
}

configure_pagespeed() {
    log_info "Configuring PageSpeed..."
    
    # Add PageSpeed configuration
    cat > /etc/nginx/conf.d/pagespeed.conf << 'EOF'
# PageSpeed configuration

pagespeed on;
pagespeed FileCachePath /var/ngx_pagespeed_cache;

# PageSpeed filters
pagespeed RewriteLevel CoreFilters;
pagespeed EnableFilters collapse_whitespace;
pagespeed EnableFilters combine_css;
pagespeed EnableFilters combine_javascript;
pagespeed EnableFilters remove_comments;
pagespeed EnableFilters rewrite_images;
pagespeed EnableFilters lazyload_images;

# Respect X-Page-Speed header
pagespeed RespectXForwardedProto on;

# Admin pages
pagespeed Statistics on;
pagespeed StatisticsLogging on;
pagespeed LogDir /var/log/pagespeed;

# Ensure requests for pagespeed optimized resources go to the pagespeed handler
location ~ "\.pagespeed\.([a-z]\.)?[a-z]{2}\.[^.]{10}\.[^.]+" {
    add_header "" "";
}

location ~ "^/pagespeed_static/" { }
location ~ "^/ngx_pagespeed_beacon$" { }
EOF

    # Create log directory
    mkdir -p /var/log/pagespeed
    chown www-data:www-data /var/log/pagespeed
    
    # Enable PageSpeed in main Nextcloud site
    if [[ -f /etc/nginx/sites-available/nextcloud ]]; then
        # Remove the pagespeed off directive if exists
        sed -i '/pagespeed off;/d' /etc/nginx/sites-available/nextcloud
        
        log_success "PageSpeed enabled in Nextcloud site"
    fi
}

cleanup() {
    log_info "Cleaning up build files..."
    
    cd /tmp
    rm -rf nginx-* incubator-pagespeed-ngx-* *.tar.gz *.zip
    
    log_success "Cleanup completed"
}

#===============================================================================
# Main
#===============================================================================

main() {
    print_banner
    check_root
    
    log_warning "This will:"
    echo "  - Backup current Nginx configuration"
    echo "  - Download and compile Nginx ${NGINX_VERSION} with PageSpeed"
    echo "  - Replace current Nginx installation"
    echo "  - Configure PageSpeed for Nextcloud"
    echo ""
    log_warning "This process will take 10-30 minutes depending on your server"
    echo ""
    
    read -p "Continue? [y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
        log_info "Installation cancelled"
        exit 0
    fi
    
    echo ""
    
    backup_current_nginx
    install_build_dependencies
    download_and_compile_nginx
    install_compiled_nginx
    configure_pagespeed
    
    # Test and restart
    log_info "Testing Nginx configuration..."
    if nginx -t; then
        systemctl start nginx
        log_success "Nginx restarted successfully"
    else
        log_error "Nginx configuration test failed!"
        log_error "Check configuration and restore from backup if needed"
        exit 1
    fi
    
    cleanup
    
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║      Nginx with PageSpeed Installed Successfully!             ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  Nginx version: $(nginx -v 2>&1 | grep -oP 'nginx/\K[^ ]+')"
    echo "  PageSpeed: Enabled"
    echo ""
    echo "  PageSpeed cache: /var/ngx_pagespeed_cache"
    echo "  PageSpeed logs:  /var/log/pagespeed"
    echo ""
    echo "  Configuration backup: $BACKUP_DIR"
    echo ""
    log_info "Check PageSpeed is working:"
    echo "    curl -I https://your-domain | grep X-Page-Speed"
    echo ""
}

main "$@"
