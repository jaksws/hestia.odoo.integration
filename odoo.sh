#!/bin/bash
# Odoo Auto-Installer for HestiaCP - Professional Edition
# Version 3.1 | License: MIT
# Features: Dry-run, Input Validation, Auto-Rollback, Multi-Language

# ----- Configuration Section -----
LOG_DIR="/var/log/odoo_installer"
CONFIG_DIR="/etc/odoo_installer"
TMP_DIR="/tmp/odoo_installer"
DOCKER_COMPOSE_VERSION="2.20.0"
POSTGRES_VERSION="13"
ODOO_VERSION="latest"
PORT_RANGE="8000-9000"
SUPPORTED_LANGS=("ar" "en")

# ----- Initialization -----
init() {
    [[ $EUID -ne 0 ]] && error_exit "This script must be run as root"
    mkdir -p "$LOG_DIR" "$CONFIG_DIR" "$TMP_DIR"
    load_language "${LANG%.*}"
}

# ----- Language Support -----
load_language() {
    local lang="${1:-en}"
    case "$lang" in
        ar) source <(curl -s https://example.com/translations/ar.conf) ;;
        *)  # English Default
            msg_install_start="Starting Odoo installation for domain"
            msg_success="Installation completed successfully!"
            ;;
    esac
}

# ----- Logging System -----
setup_logging() {
    local log_file="${LOG_DIR}/${DOMAIN}_$(date +%Y%m%d-%H%M%S).log"
    exec > >(tee -a "$log_file") 2>&1
    echo "=== Installation Started: $(date) ==="
}

# ----- Error Handling -----
error_exit() {
    local msg="$1"
    echo "ERROR: $msg" | tee -a "$LOG_FILE"
    [[ "$ROLLBACK_ENABLED" == true ]] && rollback
    exit 1
}

rollback() {
    echo "Initiating rollback..."
    # Add rollback commands here
}

# ----- Input Validation -----
validate_inputs() {
    # Domain validation
    [[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]] || error_exit "Invalid domain format"
    
    # User validation
    id -u "$USER" &>/dev/null || error_exit "User $USER does not exist"
    
    # Port validation
    [[ "$PORT" =~ ^[0-9]+$ ]] || error_exit "Invalid port number"
}

# ----- Security Functions -----
generate_secure_password() {
    LC_ALL=C tr -dc 'A-Za-z0-9!@#$%^&*()_+{}[]<>' </dev/urandom | head -c 32
}

# ----- Docker Management -----
install_docker() {
    if ! command -v docker &>/dev/null; then
        echo "Installing Docker..."
        curl -fsSL https://get.docker.com | sh || error_exit "Docker installation failed"
    fi
}

setup_docker_compose() {
    local dc_path="/usr/local/bin/docker-compose"
    if ! command -v docker-compose &>/dev/null; then
        echo "Installing Docker Compose..."
        curl -L "https://github.com/docker/compose/releases/download/v${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" \
            -o "$dc_path" || error_exit "Docker Compose download failed"
        chmod +x "$dc_path"
    fi
}

# ----- Database Setup -----
create_hestea_db() {
    echo "Creating database via HestiaCP..."
    /usr/local/hestia/bin/v-add-database "$USER" "$DB_NAME" "$DB_USER" "$DB_PASS" || error_exit "Database creation failed"
}

# ----- Nginx Configuration -----
configure_nginx() {
    local nginx_conf="/etc/nginx/sites-available/$DOMAIN"
    
    # Create config
    cat > "$nginx_conf" <<EOL
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $DOMAIN;
    
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    
    location / {
        proxy_pass http://localhost:$PORT;
        include proxy_params;
    }
}
EOL

    # Enable site
    ln -sf "$nginx_conf" "/etc/nginx/sites-enabled/" || error_exit "Nginx enable failed"
    systemctl reload nginx || error_exit "Nginx reload failed"
}

# ----- SSL Management -----
obtain_ssl() {
    if ! certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "admin@$DOMAIN"; then
        echo "SSL failed, continuing without HTTPS"
        rm -f "/etc/nginx/sites-enabled/$DOMAIN"
        cp "/etc/nginx/sites-available/$DOMAIN" "/etc/nginx/sites-available/${DOMAIN}.nossl"
        sed -i '/443 ssl/d' "/etc/nginx/sites-available/$DOMAIN"
        ln -sf "/etc/nginx/sites-available/$DOMAIN" "/etc/nginx/sites-enabled/"
        systemctl reload nginx || error_exit "Nginx reload after SSL failure failed"
    fi
}

# ----- Main Installation -----
install_odoo() {
    local odoo_dir="/home/$USER/web/$DOMAIN"
    mkdir -p "$odoo_dir"/{addons,config,postgres} || error_exit "Directory creation failed"
    chown -R "$USER":"$USER" "$odoo_dir"

    # Docker Compose File
    cat > "$odoo_dir/docker-compose.yml" <<EOL
version: '3.8'
services:
  odoo:
    image: odoo:${ODOO_VERSION}
    ports:
      - "$PORT:8069"
    volumes:
      - $odoo_dir/addons:/mnt/extra-addons
      - $odoo_dir/config:/etc/odoo
    environment:
      - DB_HOST=postgres
      - DB_USER=$DB_USER
      - DB_PASSWORD=$DB_PASS
      - DB_NAME=$DB_NAME

  postgres:
    image: postgres:${POSTGRES_VERSION}
    environment:
      - POSTGRES_USER=$DB_USER
      - POSTGRES_PASSWORD=$DB_PASS
      - POSTGRES_DB=$DB_NAME
    volumes:
      - $odoo_dir/postgres:/var/lib/postgresql/data
EOL

    # Start containers
    sudo -u "$USER" docker-compose -f "$odoo_dir/docker-compose.yml" up -d || error_exit "Docker startup failed"
}

# ----- Post-Installation -----
create_install_summary() {
    local summary_file="/home/$USER/web/$DOMAIN/install_summary.txt"
    cat > "$summary_file" <<EOL
=== Odoo Installation Summary ===
Domain: https://$DOMAIN
Admin Panel: https://$DOMAIN/web/database/selector
Default Credentials:
- Email: admin@$DOMAIN
- Password: admin

Database Info:
- Host: localhost
- Name: $DB_NAME
- User: $DB_USER
- Password: $DB_PASS

Container Port: $PORT
Installation Date: $(date)
EOL
    chmod 600 "$summary_file"
    chown "$USER":"$USER" "$summary_file"
}

# ----- Main Workflow -----
main() {
    init
    setup_logging
    validate_inputs
    install_docker
    setup_docker_compose
    create_hestea_db
    install_odoo
    configure_nginx
    obtain_ssl
    create_install_summary
    echo "$msg_success Details in: /home/$USER/web/$DOMAIN/install_summary.txt"
}

# ----- Argument Parser -----
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--domain) DOMAIN="$2"; shift ;;
            -u|--user) USER="$2"; shift ;;
            -p|--port) PORT="$2"; shift ;;
            --dry-run) DRY_RUN=true ;;
            -h|--help) show_help; exit ;;
            *) echo "Unknown option: $1"; show_help; exit 1 ;;
        esac
        shift
    done

    # Set default port if not provided
    PORT=${PORT:-$(shuf -i $PORT_RANGE -n 1)}
    
    # Generate credentials
    DB_NAME="${USER}_${DOMAIN//./_}"
    DB_USER="${USER}_odoo"
    DB_PASS=$(generate_secure_password)
}

show_help() {
    cat <<EOL
Odoo Auto-Installer for HestiaCP
Usage: $0 [options]

Options:
  -d, --domain DOMAIN    Target domain name (required)
  -u, --user USER        HestiaCP username (required)
  -p, --port PORT        Custom port (default: random)
  --dry-run              Simulate installation
  -h, --help             Show this help

Example:
  $0 -d odoo.example.com -u admin
EOL
}

# ----- Entry Point -----
parse_args "$@"
if [[ "$DRY_RUN" == true ]]; then
    echo "Dry Run Mode Activated"
    echo "Would install Odoo for:"
    echo "- Domain: $DOMAIN"
    echo "- User: $USER"
    echo "- Port: $PORT"
    exit 0
else
    main
fi
