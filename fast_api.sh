#!/bin/bash

set -e

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
    local prompt="$1"
    local var_name="$2"
    local validation_func="$3"
    local explanation="$4"
    local default_value="$5"
    
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
get_input "Enter the domain name: " DOMAIN_NAME "" "The domain name where your application will be accessible."
get_input "Enter the port to run the app on: " APP_PORT validate_port "The port number on which your application will listen (between 1024 and 65535)."
get_input "Enter the number of workers (recommended: $recommended_workers): " NUM_WORKERS validate_integer "" $recommended_workers "The number of worker processes to spawn (integer)."
get_input "Enter the concurrency limit (default: $DEFAULT_CONCURRENCY_LIMIT): " CONCURRENCY_LIMIT validate_integer "" $DEFAULT_CONCURRENCY_LIMIT "The maximum number of concurrent connections (integer)."
get_input "Enter the backlog size (default: $DEFAULT_BACKLOG_SIZE):" BACKLOG_SIZE validate_integer "" $DEFAULT_BACKLOG_SIZE "The maximum number of pending connections (integer)."
get_input "Enter the Nice value (-20 to 19) (default: $DEFAULT_NICE_VALUE):" NICE_VALUE validate_nice_value "" $DEFAULT_NICE_VALUE "The Nice value for process priority (-20 to 19, lower is higher priority)."
get_input "Enter the CPU quota (e.g., 50%) (default: $DEFAULT_CPU_QUOTA):" CPU_QUOTA validate_percentage "" $DEFAULT_CPU_QUOTA "The maximum CPU usage allowed for the application (percentage)."
get_input "Enter the maximum memory usage (e.g., 1G) (default: $DEFAULT_MEMORY_MAX):" MEMORY_MAX "" "" $DEFAULT_MEMORY_MAX "The maximum memory usage allowed for the application (e.g., 0.5G, 1G)."

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

# Add prompts for GitHub credentials
get_input "Enter your GitHub username (leave blank for public repos): " GITHUB_USERNAME
get_input "Enter your GitHub Personal Access Token (leave blank for public repos): " GITHUB_PAT

# Create the app directory and clone the repository
sudo adduser --system --group --home /var/www/$APP_CODE_NAME $APP_CODE_NAME
sudo mkdir -p /var/www/$APP_CODE_NAME
sudo chown $USER:$USER /var/www/$APP_CODE_NAME
cd /var/www/$APP_CODE_NAME

if [ -n "$GITHUB_USERNAME" ] && [ -n "$GITHUB_PAT" ]; then
    # For private repositories
    REPO_URL=$(echo $GITHUB_REPO | sed "s/https:\/\//https:\/\/$GITHUB_USERNAME:$GITHUB_PAT@/")
    sudo -u $APP_CODE_NAME git clone $REPO_URL .
else
    # For public repositories
    sudo -u $APP_CODE_NAME git clone $GITHUB_REPO .
fi

# Set up the virtual environment and install dependencies
sudo -u $APP_CODE_NAME python3 -m venv venv
sudo -u $APP_CODE_NAME bash -c "source venv/bin/activate && pip install --no-cache-dir -r requirements.txt && pip install --no-cache-dir uvloop httptools"

# Set correct permissions
sudo chown -R $APP_CODE_NAME:$APP_CODE_NAME /var/www/$APP_CODE_NAME

# Create the systemd service file
sudo tee /etc/systemd/system/$APP_CODE_NAME.service > /dev/null << EOL
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

# Reload systemd, enable and start the service
sudo systemctl daemon-reload
sudo systemctl enable $APP_CODE_NAME.service
sudo systemctl start $APP_CODE_NAME.service

# Create Nginx configuration
sudo tee /etc/nginx/sites-available/$APP_CODE_NAME > /dev/null << EOL
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

# Enable the Nginx configuration and restart Nginx
sudo ln -s /etc/nginx/sites-available/$APP_CODE_NAME /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl restart nginx

echo "Installation complete. Your FastAPI app '$APP_NICE_NAME' is now running on $DOMAIN_NAME"

# Display Nice values of other installed apps by the user
echo "Nice values of other installed apps by the user:"
ps -eo nice,comm,user | grep "^-\|^ [0-9]" | grep -v "root" | sort -n | uniq
