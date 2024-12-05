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
    echo -e "${RED}Cleaning up...${NC}"
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
}

# Set trap to call cleanup function on error
trap cleanup ERR

# Function to Check and Update system packages
check_update_system() {
    color_echo "Checking for system updates..."
    
    # Check for updates
    if sudo apt-get update 2>&1 | grep -q 'packages can be upgraded'; then
        color_echo "Updates are available. Updating system packages..."
        sudo apt-get update -y
        sudo apt-get upgrade -y
    else
        color_echo "No updates available. System is up to date."
    fi
}

# Function to check and install nginx
check_install_nginx() {
    if ! command -v nginx &> /dev/null; then
        color_echo "Nginx not found. Installing nginx..."
        sudo apt-get install -y nginx
    else
        color_echo "Nginx is already installed."
    fi
    
    color_echo "Starting nginx..."
    sudo systemctl start nginx
}

# Function to check and install python3-venv
check_install_python_venv() {
    if ! dpkg -s python3-venv &> /dev/null; then
        color_echo "Python3-venv not found. Installing python3-venv..."
        sudo apt-get install -y python3-venv
    else
        color_echo "Python3-venv is already installed."
    fi
}

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
        # Choose mode
    while true; do
        read -p "Choose mode (Install/Uninstall): " MODE
        if [[ $MODE =~ ^(Install|Uninstall)$ ]]; then
            break
        else
            echo "Invalid input. Please enter 'Install' or 'Uninstall'."
        fi
    done

    if [ "$MODE" = "Uninstall" ]; then
        read -p "Enter the app code name to uninstall: " APP_CODE_NAME
        cleanup
        echo -e "${GREEN}Uninstallation complete for '$APP_CODE_NAME'${NC}"
        exit 0
    fi

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
    NGINX_GZIP_COMP_LEVEL=6
    
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
    
    # Get NGINX configuration inputs
    get_input "Enter NGINX gzip compression level (1-9): " NGINX_GZIP_COMP_LEVEL validate_integer "" $NGINX_GZIP_COMP_LEVEL

    # Update system packages
    check_update_system

    # Check and install nginx
    check_install_nginx

    # Check and install python3-venv
    check_install_python_venv
    
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
        cleanup
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
        cleanup
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
    server {
        listen 80;
        server_name $DOMAIN_NAME;

        # Security headers
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-XSS-Protection "1; mode=block" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header Referrer-Policy "no-referrer-when-downgrade" always;
        add_header Content-Security-Policy "default-src 'self' http: https: data: blob: 'unsafe-inline'" always;
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;

        # . files
        location ~ /\.(?!well-known) {
            deny all;
        }

        location / {
            proxy_pass http://127.0.0.1:$APP_PORT;
            proxy_set_header Host \$host;
            proxy_cache_bypass \$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header X-Forwarded-Port \$server_port;

            # Enable keepalive connections
            proxy_http_version 1.1;
            proxy_set_header Connection "";

            # Increase timeouts if needed
            proxy_connect_timeout 60s;
            proxy_send_timeout 60s;
            proxy_read_timeout 60s;

            # Gzip compression
            gzip on;
            gzip_vary on;
            gzip_proxied any;
            gzip_comp_level $NGINX_GZIP_COMP_LEVEL;
            gzip_types text/plain text/css text/xml application/json application/javascript application/rss+xml application/atom+xml image/svg+xml;
        }

        # Optimize client-side caching
        location ~* \.(jpg|jpeg|png|gif|ico|css|js)$ {
            expires 30d;
            add_header Cache-Control "public, no-transform";
        }
    }
EOL
    then
        echo -e "${RED}Failed to create Nginx configuration${NC}"
        cleanup
        exit 1
    fi
    color_echo "Nginx configuration created"

    # Enable the Nginx configuration and restart Nginx
    color_echo "Enabling Nginx configuration..."
    sudo ln -s /etc/nginx/sites-available/$APP_CODE_NAME /etc/nginx/sites-enabled/
    color_echo "Testing Nginx configuration..."
    if ! sudo nginx -t; then
        echo -e "${RED}Nginx configuration test failed${NC}"
        cleanup
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
