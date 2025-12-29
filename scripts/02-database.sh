#!/bin/bash
#===============================================================================
# 02-database.sh - Configure MariaDB database
#===============================================================================

configure_database() {
    log_info "Configuring MariaDB..."
    
    # Start MariaDB if not running
    systemctl start mariadb
    systemctl enable mariadb
    
    # Secure MariaDB installation (non-interactive)
    log_info "Securing MariaDB installation..."
    mysql -e "DELETE FROM mysql.user WHERE User='';"
    mysql -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
    mysql -e "DROP DATABASE IF EXISTS test;"
    mysql -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
    mysql -e "FLUSH PRIVILEGES;"
    
    # Create Nextcloud database and user
    log_info "Creating Nextcloud database..."
    mysql -e "CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
    mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
    mysql -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"
    
    # Optimize MariaDB configuration
    log_info "Optimizing MariaDB configuration..."
    
    # Calculate innodb_buffer_pool_size based on available RAM
    TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
    BUFFER_POOL_SIZE=$((TOTAL_RAM_MB / 4))M
    
    cat > /etc/mysql/mariadb.conf.d/99-nextcloud.cnf << EOF
# Nextcloud optimized MariaDB configuration

[mysqld]
# InnoDB settings
innodb_buffer_pool_size = ${BUFFER_POOL_SIZE}
innodb_log_file_size = 256M
innodb_flush_log_at_trx_commit = 2
innodb_flush_method = O_DIRECT

# Query cache (disabled for InnoDB)
query_cache_type = 0
query_cache_size = 0

# Connection settings
max_connections = 200
wait_timeout = 600
interactive_timeout = 600

# Character set
character-set-server = utf8mb4
collation-server = utf8mb4_general_ci

# File formats
innodb_file_per_table = 1
innodb_large_prefix = 1
innodb_file_format = Barracuda

# Logging
slow_query_log = 1
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 2

# Temporary tables
tmp_table_size = 64M
max_heap_table_size = 64M

[client]
default-character-set = utf8mb4
EOF
    
    # Restart MariaDB
    systemctl restart mariadb
    
    log_success "Database configured successfully"
}
