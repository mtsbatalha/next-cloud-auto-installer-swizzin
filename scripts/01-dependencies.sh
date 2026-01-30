#!/bin/bash
#===============================================================================
# 01-dependencies.sh - Install system dependencies
#===============================================================================

install_dependencies() {
    log_info "Updating system packages..."
    apt-get update -qq
    apt-get upgrade -y -qq
    
    log_info "Installing common dependencies..."
    apt-get install -y -qq \
        curl \
        wget \
        gnupg2 \
        ca-certificates \
        lsb-release \
        apt-transport-https \
        software-properties-common \
        unzip \
        bzip2 \
        imagemagick \
        ffmpeg \
        libmagickcore-6.q16-6-extra \
        openssl
    
    # Install PHP repository for latest PHP versions
    if [[ "$OS" == "ubuntu" ]]; then
        log_info "Adding PHP repository for Ubuntu..."
        add-apt-repository -y ppa:ondrej/php
    elif [[ "$OS" == "debian" ]]; then
        log_info "Adding PHP repository for Debian..."
        curl -sSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /usr/share/keyrings/php-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/php-archive-keyring.gpg] https://packages.sury.org/php/ ${OS_CODENAME} main" > /etc/apt/sources.list.d/php.list
    fi
    
    apt-get update -qq
    
    # Install PHP and extensions
    log_info "Installing PHP ${PHP_VERSION} and extensions..."
    apt-get install -y -qq \
        php${PHP_VERSION} \
        php${PHP_VERSION}-fpm \
        php${PHP_VERSION}-gd \
        php${PHP_VERSION}-mysql \
        php${PHP_VERSION}-curl \
        php${PHP_VERSION}-mbstring \
        php${PHP_VERSION}-intl \
        php${PHP_VERSION}-gmp \
        php${PHP_VERSION}-bcmath \
        php${PHP_VERSION}-xml \
        php${PHP_VERSION}-zip \
        php${PHP_VERSION}-bz2 \
        php${PHP_VERSION}-redis \
        php${PHP_VERSION}-apcu \
        php${PHP_VERSION}-imagick \
        php${PHP_VERSION}-opcache \
        php${PHP_VERSION}-ldap \
        php${PHP_VERSION}-smbclient \
        libapache2-mod-php${PHP_VERSION}
    
    # Install web server
    if [[ "$WEBSERVER" == "apache" ]]; then
        log_info "Installing Apache..."
        apt-get install -y -qq apache2
        a2enmod rewrite headers env dir mime ssl proxy proxy_http proxy_wstunnel
        a2enmod php${PHP_VERSION}
    else
        log_info "Installing Nginx..."
        apt-get install -y -qq nginx
    fi
    
    # Install MariaDB
    log_info "Installing MariaDB..."
    apt-get install -y -qq mariadb-server mariadb-client
    
    # Install Redis
    log_info "Installing Redis..."
    apt-get install -y -qq redis-server
    
    # Install Certbot
    log_info "Installing Certbot for SSL..."
    apt-get install -y -qq certbot
    if [[ "$WEBSERVER" == "apache" ]]; then
        apt-get install -y -qq python3-certbot-apache
    else
        apt-get install -y -qq python3-certbot-nginx
    fi
    
    # Install Docker for Office suite
    if [[ "$OFFICE_SUITE" != "none" ]]; then
        log_info "Installing Docker for Office suite..."
        install_docker
    fi
    
    # Install Fail2ban
    log_info "Installing Fail2ban..."
    apt-get install -y -qq fail2ban
    
    # Install UFW
    log_info "Installing UFW firewall..."
    apt-get install -y -qq ufw
    
    log_success "Dependencies installed successfully"
}

install_docker() {
    # Check if Docker is already installed
    if command -v docker &> /dev/null; then
        log_info "Docker is already installed"
        return
    fi
    
    # Install Docker
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
    rm /tmp/get-docker.sh
    
    # Start and enable Docker
    systemctl start docker
    systemctl enable docker
    
    log_success "Docker installed successfully"
}
