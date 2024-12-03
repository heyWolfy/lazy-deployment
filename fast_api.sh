#!/bin/bash

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function for colored echo
color_echo() {
    echo -e "${YELLOW}[INFO] $1${NC}"
}

# Cleanup function
cleanup() {
    echo -e "${RED}An error occurred. Cleaning up...${NC}"
    # Add commands to undo changes here, for example:
    sudo systemctl stop $APP_CODE_NAME.service 2>/dev/null || true
    sudo systemctl disable $APP_CODE_NAME.service 2>/dev/null || true
    sudo rm -f /etc/systemd/system/$APP_CODE_NAME.service
    sudo rm -f /etc/nginx/sites-available/$APP_CODE_NAME
    sudo rm -f /etc/nginx/sites-enabled/$APP_CODE_NAME
    sudo systemctl reload nginx
    sudo userdel -r $APP_CODE_NAME 2>/dev/null || true
    sudo rm -rf /var/www/$APP_CODE_NAME
    echo -e "${RED}Cleanup completed.${NC}"
    exit 1
}

# Set trap to call cleanup function on error
trap cleanup ERR

# Main function
main() {
    # Function to check if a port is in use
    check_port() {
        if lsof -Pi :$1 -sTCP:LISTEN -t >/dev/null ; then
            return 0
        else
            return 1
        fi
    }
    
    # Function to get user input with validation and default values
    get_input() {
        local prompt="${1:-}"
        local var_name="${2:-}"
        local validation_func="${3:-}"
        local explanation="${4:-}"
        local default_value="${5:-}"
        
        if [ "$INSTALLATION_MODE" = "Easy" ] && [ -n "$default_value" ]; then
            eval "$var_name='$default_value'"
            echo "Using default value for $var_name: $default_value"
        else
            echo "$explanation"
            if [ -n "$default_value" ]; then
                read -p "Use default value ($default_value)? [Y/n]: " use_default
                if [[ $use_default =~ ^[Nn]$ ]]; then
                    while true; do
                        read -p "$prompt" input
                        if [ -n "$validation_func" ]; then
                            if $validation_func "$input"; then
                                eval "$var_name='$input'"
                                break
                            else
                                echo "Invalid input. Please try again."
                            fi
                        else
                            eval "$var_name='$input'"
                            break
                        fi
                    done
                else
                    eval "$var_name='$default_value'"
                fi
            else
                while true; do
                    read -p "$prompt" input
                    if [ -n "$validation_func" ]; then
                        if $validation_func "$input"; then
                            eval "$var_name='$input'"
                            break
                        else
                            echo "Invalid input. Please try again."
                        fi
                    else
                        eval "$var_name='$input'"
                        break
                    fi
                done
            fi
        fi
        echo
    }
    
    # Validation functions
    validate_port() {
        [[ $1 =~ ^[0-9]+$ ]] && [ "$1" -ge 1024 ] && [ "$1" -le 65535 ]
    }
    
    validate_integer() {
        [[ $1 =~ ^[0-9]+$ ]]
    }
    
    validate_percentage() {
        [[ $1 =~ ^[0-9]+%$ ]] && [ "${1%\%}" -le 100 ]
    }
    
    validate_nice_value() {
        [[ $1 =~ ^-?[0-9]+$ ]] && [ "$1" -ge -20 ] && [ "$1" -le 19 ]
    }
    
    # Get installation mode
    while true; do
        read -p "Choose Installation Mode (Easy/Advanced): " INSTALLATION_MODE
        if [[ $INSTALLATION_MODE =~ ^(Easy|Advanced)$ ]]; then
            break
        else
            echo "Invalid input. Please enter 'Easy' or 'Advanced'."
        fi
    done
    
    # Calculate recommended number of workers
    recommended_workers=$(($(nproc) * 2 + 1))
    
    # Default values
    DEFAULT_CONCURRENCY_LIMIT=1000
    DEFAULT_BACKLOG_SIZE=2048
    DEFAULT_NICE_VALUE=0
    DEFAULT_CPU_QUOTA="50%"
    DEFAULT_MEMORY_MAX="1G"
    
    # Get user inputs
    get_input "Enter the Nice name of the app: " APP_NICE_NAME "" "This is a human-readable name for your application."
    get_input "Enter the code name of the app: " APP_CODE_NAME "" "This is the name used for system files and directories."
    get_input "Enter the GitHub repo URL: " GITHUB_REPO "" "The URL of the GitHub repository containing your application code."
    get_input "Enter your GitHub username (leave blank for public repos): " GITHUB_USERNAME
    get_input "Enter your GitHub Personal Access Token (leave blank for public repos): " GITHUB_PAT
    get_input "Enter the domain name: " DOMAIN_NAME "" "The domain name where your application will be accessible."
    get_input "Enter the port to run the app on: " APP_PORT validate_port "The port number on which your application will listen (between 1024 and 65535)."
    get_input "Enter the number of workers (recommended: $recommended_workers): " NUM_WORKERS validate_integer "" $recommended_workers
    get_input "Enter the concurrency limit: " CONCURRENCY_LIMIT validate_integer "" $DEFAULT_CONCURRENCY_LIMIT
    get_input "Enter the backlog size:" BACKLOG_SIZE validate_integer "" $DEFAULT_BACKLOG_SIZE
    get_input "Enter the Nice value (-20 to 19):" NICE_VALUE validate_nice_value "" $DEFAULT_NICE_VALUE
    get_input "Enter the CPU quota (e.g., 50%):" CPU_QUOTA validate_percentage "" $DEFAULT_CPU_QUOTA
    get_input "Enter the maximum memory usage (e.g., 1G):" MEMORY_MAX "" "" $DEFAULT_MEMORY_MAX
    
    # NGINX configuration defaults
    NGINX_WORKER_CONNECTIONS=1024
    NGINX_KEEPALIVE_TIMEOUT=65
    NGINX_GZIP_COMP_LEVEL=6
    
    # Get NGINX configuration inputs
    get_input "Enter NGINX worker connections: " NGINX_WORKER_CONNECTIONS validate_integer "" $NGINX_WORKER_CONNECTIONS
    get_input "Enter NGINX keepalive timeout: " NGINX_KEEPALIVE_TIMEOUT validate_integer "" $NGINX_KEEPALIVE_TIMEOUT
    get_input "Enter NGINX gzip compression level (1-9): " NGINX_GZIP_COMP_LEVEL validate_integer "" $NGINX_GZIP_COMP_LEVEL
    
    # Check if the port is in use
    if check_port "$APP_PORT"; then
        echo "Error: Port $APP_PORT is already in use."
        exit 1
    fi
    
    # Create the app directory and clone the repository
    sudo adduser --system --group --home /var/www/$APP_CODE_NAME $APP_CODE_NAME
    sudo chown $APP_CODE_NAME:$APP_CODE_NAME /var/www/$APP_CODE_NAME
    
    # Clone the repository
    if [ -n "$GITHUB_USERNAME" ] && [ -n "$GITHUB_PAT" ]; then
        # For private repositories
        REPO_URL=$(echo $GITHUB_REPO | sed "s/https:\/\//https:\/\/$GITHUB_USERNAME:$GITHUB_PAT@/")
        sudo -u $APP_CODE_NAME git clone $REPO_URL /var/www/$APP_CODE_NAME
    else
        # For public repositories
        sudo -u $APP_CODE_NAME git clone $GITHUB_REPO /var/www/$APP_CODE_NAME
    fi
    
    # Change to the app directory
    cd /var/www/$APP_CODE_NAME
    color_echo "Changed to app directory"

    # Create the virtual environment
    color_echo "Creating virtual environment..."
    sudo -u $APP_CODE_NAME python3 -m venv venv
    color_echo "Virtual environment created"

    # Install dependencies
    color_echo "Installing dependencies..."
    if ! sudo -u $APP_CODE_NAME bash -c "source venv/bin/activate && pip install --no-cache-dir -r requirements.txt && pip install --no-cache-dir uvloop httptools"; then
        echo -e "${RED}Failed to install dependencies${NC}"
        exit 1
    fi
    color_echo "Dependencies installed successfully"

    # Set correct permissions for the virtual environment
    color_echo "Setting permissions for virtual environment..."
    sudo chown -R $APP_CODE_NAME:$APP_CODE_NAME venv
    color_echo "Permissions set"
    
    # Create the systemd service file
    color_echo "Creating systemd service file..."
    if ! sudo tee /etc/systemd/system/$APP_CODE_NAME.service > /dev/null << EOL
    [Unit]
    Description=$APP_NICE_NAME API Powered by FastAPI
    After=network.target
    Wants=network-online.target
    Documentation=$GITHUB_REPO
    
    [Service]
    Type=simple
    Restart=always
    RestartSec=15
    User=$APP_CODE_NAME
    Group=$APP_CODE_NAME
    Environment="PATH=/var/www/$APP_CODE_NAME/venv/bin:\$PATH"
    WorkingDirectory=/var/www/$APP_CODE_NAME
    ExecStart=/var/www/$APP_CODE_NAME/venv/bin/uvicorn \\
        --host 127.0.0.1 \\
        --port $APP_PORT \\
        --loop uvloop \\
        --http httptools \\
        --proxy-headers \\
        --forwarded-allow-ips='*' \\
        --log-level warning \\
        --access-log \\
        --use-colors \\
        --workers $NUM_WORKERS \\
        --limit-concurrency $CONCURRENCY_LIMIT \\
        --backlog $BACKLOG_SIZE \\
        main:app
    
    # Security enhancements
    PrivateTmp=true
    ProtectSystem=full
    NoNewPrivileges=true
    ProtectHome=true
    ProtectKernelTunables=true
    ProtectKernelModules=true
    ProtectControlGroups=true
    
    # Resource management
    Nice=$NICE_VALUE
    CPUQuota=$CPU_QUOTA
    MemoryMax=$MEMORY_MAX
    
    # Logging
    StandardOutput=journal
    StandardError=journal
    
    # Graceful shutdown
    TimeoutStopSec=20
    KillMode=mixed
    KillSignal=SIGINT
    
    [Install]
    WantedBy=multi-user.target 
EOL
    then
        echo -e "${RED}Failed to create systemd service file${NC}"
        exit 1
    fi
    color_echo "Systemd service file created"

    # Reload systemd, enable and start the service
    color_echo "Reloading systemd..."
    sudo systemctl daemon-reload
    color_echo "Enabling service..."
    sudo systemctl enable $APP_CODE_NAME.service
    color_echo "Starting service..."
    sudo systemctl start $APP_CODE_NAME.service
    
    # Create Nginx configuration
    color_echo "Creating Nginx configuration..."
    if ! sudo tee /etc/nginx/sites-available/$APP_CODE_NAME > /dev/null << EOL
    # Optimize NGINX worker processes
    worker_processes auto;
    worker_rlimit_nofile 65535;
    
    events {
        worker_connections $NGINX_WORKER_CONNECTIONS;
        multi_accept on;
        use epoll;
    }
    
    http {
        # Basic settings
        sendfile on;
        tcp_nopush on;
        tcp_nodelay on;
        keepalive_timeout $NGINX_KEEPALIVE_TIMEOUT;
        types_hash_max_size 2048;
        server_tokens off;
    
        # Optimize file handles
        open_file_cache max=1000 inactive=20s;
        open_file_cache_valid 30s;
        open_file_cache_min_uses 2;
        open_file_cache_errors on;
    
        # Gzip settings
        gzip on;
        gzip_vary on;
        gzip_proxied any;
        gzip_comp_level $NGINX_GZIP_COMP_LEVEL;
        gzip_buffers 16 8k;
        gzip_http_version 1.1;
        gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;
    
        # SSL settings
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_prefer_server_ciphers on;
        ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
        ssl_session_cache shared:SSL:10m;
        ssl_session_timeout 1d;
        ssl_session_tickets off;
    
        server {
            listen 80;
            server_name $DOMAIN_NAME;
    
            # Redirect HTTP to HTTPS (for Cloudflare Flexible SSL)
            if (\$http_x_forwarded_proto != "https") {
                return 301 https://\$server_name\$request_uri;
            }
    
            location / {
                proxy_pass http://127.0.0.1:$APP_PORT;
                proxy_http_version 1.1;
                proxy_set_header Upgrade \$http_upgrade;
                proxy_set_header Connection "upgrade";
                proxy_set_header Host \$host;
                proxy_set_header X-Real-IP \$remote_addr;
                proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto \$scheme;
                proxy_set_header X-Forwarded-Host \$server_name;
    
                # Enable keepalive connections
                proxy_set_header Connection "";
    
                # Proxy buffer optimization
                proxy_buffering on;
                proxy_buffer_size 16k;
                proxy_busy_buffers_size 24k;
                proxy_buffers 32 16k;
    
                # Increase timeouts if needed
                proxy_connect_timeout 60s;
                proxy_send_timeout 60s;
                proxy_read_timeout 60s;
    
                # Caching
                proxy_cache_use_stale error timeout http_500 http_502 http_503 http_504;
                proxy_cache_lock on;
                proxy_cache_valid 200 1m;
                proxy_cache_valid 404 10m;
                proxy_cache_bypass \$http_upgrade;
                add_header X-Cache-Status \$upstream_cache_status;
            }
    
            # Optimize client-side caching for static assets
            location ~* \.(jpg|jpeg|png|gif|ico|css|js)$ {
                expires 30d;
                add_header Cache-Control "public, no-transform";
            }
    
            # Additional security headers
            add_header X-Frame-Options SAMEORIGIN;
            add_header X-Content-Type-Options nosniff;
            add_header X-XSS-Protection "1; mode=block";
            add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    
            # Error pages
            error_page 500 502 503 504 /50x.html;
            location = /50x.html {
                root /usr/share/nginx/html;
            }
        }
    }
EOL
    then
        echo -e "${RED}Failed to create Nginx configuration${NC}"
        exit 1
    fi
    color_echo "Nginx configuration created"

    # Enable the Nginx configuration and restart Nginx
    color_echo "Enabling Nginx configuration..."
    sudo ln -s /etc/nginx/sites-available/$APP_CODE_NAME /etc/nginx/sites-enabled/
    color_echo "Testing Nginx configuration..."
    if ! sudo nginx -t; then
        echo -e "${RED}Nginx configuration test failed${NC}"
        exit 1
    fi
    color_echo "Restarting Nginx..."
    sudo systemctl restart nginx
    
    echo -e "${GREEN}Installation complete. Your FastAPI app '$APP_NICE_NAME' is now running on $DOMAIN_NAME${NC}"
    
    # Display Nice values of other installed apps by the user
    color_echo "Nice values of other installed apps by the user:"
    ps -eo nice,comm,user | grep "^-\|^ [0-9]" | grep -v "root" | sort -n | uniq
}

# Call the main function
main
