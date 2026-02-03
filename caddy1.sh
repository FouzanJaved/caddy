#!/bin/bash
# Exit on error
set -e

echo "==============================================="
echo "  WordPress + Caddy Reverse Proxy Setup"
echo "  for sahmcore.com.sa"
echo "==============================================="
echo ""
echo "Your Network Configuration:"
echo "  Gateway:      192.168.116.1"
echo "  This VM:      192.168.116.37 (WordPress)"
echo "  Target VMs:   Will be prompted"
echo ""
read -p "Press Enter to continue or Ctrl+C to cancel..."

# Configuration
GATEWAY_IP="192.168.116.1"
THIS_VM_IP="192.168.116.37"
DOMAIN="sahmcore.com.sa"

# Detect primary interface
PRIMARY_IF=$(ip route | grep default | awk '{print $5}' | head -1)
if [ -z "$PRIMARY_IF" ]; then
    PRIMARY_IF="eth0"
    echo "Warning: Could not detect primary interface, using $PRIMARY_IF as default"
fi

# Step 1: Check current web server
echo "=== Checking current setup ==="
echo "Current IP: $THIS_VM_IP"
echo "Gateway: $GATEWAY_IP"
echo "Primary Interface: $PRIMARY_IF"
echo ""
echo "Services on port 80:"
sudo lsof -i :80 2>/dev/null || echo "Nothing found on port 80"
echo ""
echo "Checking Apache..."
sudo systemctl is-active apache2 2>/dev/null && echo "Apache is running"
echo "Checking Nginx..."
sudo systemctl is-active nginx 2>/dev/null && echo "Nginx is running"
echo ""

# Step 2: Backup current configuration
echo "=== Creating backups ==="
BACKUP_DIR="/root/backup-$(date +%Y%m%d-%H%M%S)"
sudo mkdir -p $BACKUP_DIR
echo "Backup directory: $BACKUP_DIR"

# Backup web configs
sudo cp -r /etc/apache2 $BACKUP_DIR/apache2-backup 2>/dev/null || true
sudo cp -r /etc/nginx $BACKUP_DIR/nginx-backup 2>/dev/null || true
sudo cp -r /var/www/html $BACKUP_DIR/html-backup 2>/dev/null || true
sudo cp /etc/hosts $BACKUP_DIR/hosts-backup
sudo cp /etc/network/interfaces $BACKUP_DIR/interfaces-backup 2>/dev/null || true
echo "Backups created in $BACKUP_DIR"
echo ""

# Step 3: Update system and install Caddy
echo "=== Updating system and installing Caddy ==="
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl wget net-tools ufw dnsutils php-cli

# Check if PHP-FPM is installed for WordPress
if ! dpkg -l | grep -q php-fpm; then
    echo "Installing PHP-FPM for WordPress..."
    sudo apt install -y php-fpm php-mysql php-curl php-gd php-mbstring php-xml php-xmlrpc
fi

# Install Caddy
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update
sudo apt install caddy -y
echo "Caddy installed successfully!"
echo ""

# Step 4: Stop old web servers
echo "=== Stopping old web servers ==="
sudo systemctl stop apache2 2>/dev/null || true
sudo systemctl stop nginx 2>/dev/null || true
sudo systemctl disable apache2 2>/dev/null || true
sudo systemctl disable nginx 2>/dev/null || true
echo "Old web servers stopped and disabled"
echo ""

# Step 5: Get other VM IP addresses
echo "=== Network Configuration ==="
echo "Please enter the internal IP addresses of your other VMs:"
echo ""
read -p "ERP Windows Server IP (e.g., 192.168.116.38): " ERP_IP
read -p "ERP Port (default 8069): " ERP_PORT
ERP_PORT=${ERP_PORT:-8069}

read -p "Documentation Server IP (e.g., 192.168.116.39): " DOCS_IP
read -p "Documentation Port (default 8080): " DOCS_PORT
DOCS_PORT=${DOCS_PORT:-8080}

read -p "Mail Server IP (e.g., 192.168.116.40): " MAIL_IP
read -p "Mail Server Port (default 8025): " MAIL_PORT
MAIL_PORT=${MAIL_PORT:-8025}

# Validate inputs
if [ -z "$ERP_IP" ] || [ -z "$DOCS_IP" ] || [ -z "$MAIL_IP" ]; then
    echo "Error: All VM IP addresses are required!"
    exit 1
fi

echo ""
echo "Summary:"
echo "  ERP:        $ERP_IP:$ERP_PORT"
echo "  Docs:       $DOCS_IP:$DOCS_PORT"
echo "  Mail:       $MAIL_IP:$MAIL_PORT"
echo "  Gateway:    $GATEWAY_IP"
echo "  This VM:    $THIS_VM_IP"
echo ""

# Step 6: Test network connectivity
echo "=== Testing Network Connectivity ==="
echo "Testing connection to gateway and other VMs..."

echo -n "Pinging gateway ($GATEWAY_IP)... "
if ping -c 2 -W 2 $GATEWAY_IP > /dev/null 2>&1; then
    echo "✓ Success"
else
    echo "✗ Failed - Check gateway connectivity"
fi

for host in "$ERP_IP" "$DOCS_IP" "$MAIL_IP"; do
    if [ ! -z "$host" ]; then
        echo -n "Pinging $host... "
        if ping -c 2 -W 2 "$host" > /dev/null 2>&1; then
            echo "✓ Success"
        else
            echo "✗ Failed - Check VM network settings"
        fi
    fi
done
echo ""

# Step 7: Configure network if needed
echo "=== Configuring Network ==="
echo "Current network configuration:"
ip addr show
echo ""
echo "Checking if $THIS_VM_IP is configured..."
if ! ip addr show | grep -q $THIS_VM_IP; then
    echo "Setting IP address to $THIS_VM_IP on $PRIMARY_IF..."
    sudo ip addr add $THIS_VM_IP/24 dev $PRIMARY_IF 2>/dev/null || echo "Note: IP might already be configured via DHCP"
fi
echo ""

# Step 8: Check DNS resolution
echo "=== Checking DNS Configuration ==="
echo "Checking DNS resolution for $DOMAIN..."
DNS_RESULT=$(dig +short $DOMAIN 2>/dev/null || nslookup $DOMAIN 2>/dev/null | grep Address | tail -1 | awk '{print $2}')
if [ -n "$DNS_RESULT" ]; then
    echo "DNS resolves $DOMAIN to: $DNS_RESULT"
    if [ "$DNS_RESULT" != "$THIS_VM_IP" ]; then
        echo "Warning: $DOMAIN resolves to $DNS_RESULT but should point to $THIS_VM_IP"
    fi
else
    echo "Warning: $DOMAIN does not resolve in DNS. Let's Encrypt will fail unless DNS is configured."
fi
echo ""

# Step 9: Create Caddyfile with Let's Encrypt SSL
echo "=== Creating Caddyfile with Let's Encrypt SSL ==="

# Ask for admin email for Let's Encrypt
read -p "Enter email for Let's Encrypt SSL certificates (admin@$DOMAIN): " ADMIN_EMAIL
ADMIN_EMAIL=${ADMIN_EMAIL:-"admin@$DOMAIN"}

echo ""
echo "=== SSL Configuration ==="
echo "Using HTTP challenge method (port 80 is publicly accessible)"
echo "Let's Encrypt will verify domain ownership via HTTP on port 80"
echo ""

# Detect PHP-FPM socket
PHP_SOCKET="/run/php/php8.1-fpm.sock"
if [ ! -S "$PHP_SOCKET" ]; then
    PHP_SOCKET="/run/php/php8.0-fpm.sock"
fi
if [ ! -S "$PHP_SOCKET" ]; then
    PHP_SOCKET="/run/php/php7.4-fpm.sock"
fi
if [ ! -S "$PHP_SOCKET" ]; then
    PHP_SOCKET="/var/run/php/php-fpm.sock"
fi

echo "Using PHP-FPM socket: $PHP_SOCKET"

# Backup existing Caddyfile
sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.backup-$(date +%Y%m%d)" 2>/dev/null || true

# Create new Caddyfile with HTTP challenge
sudo tee /etc/caddy/Caddyfile > /dev/null << EOF
# Auto-generated Caddy configuration for $DOMAIN
# Generated on: $(date)
# This VM: $THIS_VM_IP
# Gateway: $GATEWAY_IP

# Global options with Let's Encrypt HTTP challenge
{
    email $ADMIN_EMAIL
    admin off
    
    # Automatic HTTPS with Let's Encrypt using HTTP challenge
    # Requires port 80 to be publicly accessible
    acme_ca https://acme-v02.api.letsencrypt.org/directory
    
    # Security headers
    security {
        # Enable HSTS
        hsts {
            max_age 31536000
            include_subdomains
            preload
        }
        
        # Frame options
        frame_deny
        content_type_nosniff
        xss_protection
        referrer_policy strict-origin-when-cross-origin
    }
    
    # Logging
    log {
        output file /var/log/caddy/access.log {
            roll_size 100mb
            roll_keep 5
        }
        level INFO
    }
    
    # Default servers block
    servers {
        protocols h1 h2 h3
        strict_sni_host on
    }
}

# Main WordPress site (on this VM: $THIS_VM_IP)
$DOMAIN, www.$DOMAIN {
    # WordPress directory
    root * /var/www/html
    
    # Enable PHP-FPM for WordPress
    php_fastcgi unix:$PHP_SOCKET {
        resolve_root_symlink
        split .php
        index index.php
    }
    
    # Handle static files
    file_server {
        hide .php
    }
    
    # WordPress specific rewrite rules
    try_files {path} {path}/ /index.php?{query}
    
    # Security headers
    header {
        X-Frame-Options "SAMEORIGIN"
        X-Content-Type-Options "nosniff"
        X-XSS-Protection "1; mode=block"
        Referrer-Policy "strict-origin-when-cross-origin"
        -Server
        X-Powered-By "Caddy"
    }
    
    # Compression
    encode gzip zstd
    
    # Logging
    log {
        output file /var/log/caddy/wordpress.log
        level INFO
    }
    
    # Error handling
    handle_errors {
        @404 {
            expression {http.error.status_code} == 404
        }
        rewrite @404 /404.html
        file_server
    }
}

# ERP Service (Windows VM: $ERP_IP)
erp.$DOMAIN {
    reverse_proxy http://$ERP_IP:$ERP_PORT {
        # Headers for ERP/Odoo
        header_up Host {host}
        header_up X-Forwarded-Host {host}
        header_up X-Forwarded-Proto {scheme}
        header_up X-Real-IP {remote}
        header_up X-Forwarded-For {remote}
        
        # Timeouts for ERP
        transport http {
            dial_timeout 30s
            response_header_timeout 60s
        }
    }
    
    # Logging
    log {
        output file /var/log/caddy/erp.log
    }
}

# Documentation Service ($DOCS_IP)
docs.$DOMAIN {
    reverse_proxy http://$DOCS_IP:$DOCS_PORT {
        header_up Host {host}
        header_up X-Forwarded-Proto {scheme}
    }
    
    log {
        output file /var/log/caddy/docs.log
    }
}

# Mail Service ($MAIL_IP)
mail.$DOMAIN {
    reverse_proxy http://$MAIL_IP:$MAIL_PORT {
        # Mail-specific headers
        header_up Host {host}
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-For {remote}
        
        # WebSocket support if needed
        header_up Connection {>Connection}
        header_up Upgrade {>Upgrade}
    }
    
    log {
        output file /var/log/caddy/mail.log
    }
}

# Additional subdomains for future use
cloud.$DOMAIN {
    respond "Coming soon - Cloud service" 200
}

api.$DOMAIN {
    respond "Coming soon - API service" 200
}

# Health check endpoint
health.$DOMAIN {
    respond "OK from $THIS_VM_IP" 200
    header Content-Type "text/plain"
}

# Default catch-all for any other subdomain
*.${DOMAIN} {
    redir https://${DOMAIN}{uri}
}

# HTTP to HTTPS redirect for all domains
# Important: This handles the Let's Encrypt HTTP challenge
http://${DOMAIN}, http://www.${DOMAIN}, http://erp.${DOMAIN}, http://docs.${DOMAIN}, http://mail.${DOMAIN} {
    # Let's Encrypt HTTP challenge endpoint
    @acme {
        path /.well-known/acme-challenge/*
    }
    handle @acme {
        reverse_proxy unix//run/caddy.sock
    }
    
    # Redirect everything else to HTTPS
    redir https://{host}{uri} permanent
}
EOF

echo "Caddyfile created at /etc/caddy/Caddyfile"
echo ""

# Step 10: Configure WordPress for reverse proxy
echo "=== Configuring WordPress for Reverse Proxy ==="
WP_PATH="/var/www/html"
WP_CONFIG="$WP_PATH/wp-config.php"

if [ -d "$WP_PATH" ]; then
    echo "Found WordPress at $WP_PATH"
    
    # Backup WordPress config
    if [ -f "$WP_CONFIG" ]; then
        sudo cp "$WP_CONFIG" "${WP_CONFIG}.backup-$(date +%Y%m%d)"
        echo "Backed up wp-config.php"
        
        # Update WordPress URLs for Caddy using wp-cli if available
        if command -v wp &> /dev/null; then
            echo "Using wp-cli to update WordPress configuration..."
            cd "$WP_PATH"
            
            # Update site URLs
            sudo -u www-data wp option update home "https://$DOMAIN" 2>/dev/null || true
            sudo -u www-data wp option update siteurl "https://$DOMAIN" 2>/dev/null || true
            
            # Update any hardcoded URLs in database
            sudo -u www-data wp search-replace "http://$DOMAIN" "https://$DOMAIN" --all-tables 2>/dev/null || true
            sudo -u www-data wp search-replace "http://www.$DOMAIN" "https://$DOMAIN" --all-tables 2>/dev/null || true
            
            echo "WordPress URLs updated via wp-cli"
        else
            echo "Installing wp-cli..."
            curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
            chmod +x wp-cli.phar
            sudo mv wp-cli.phar /usr/local/bin/wp
            
            cd "$WP_PATH"
            wp option update home "https://$DOMAIN" 2>/dev/null || echo "Could not update home URL"
            wp option update siteurl "https://$DOMAIN" 2>/dev/null || echo "Could not update site URL"
        fi
        
        # Add reverse proxy handling to wp-config.php
        if ! grep -q "HTTP_X_FORWARDED_PROTO" "$WP_CONFIG"; then
            echo "Adding reverse proxy support to wp-config.php..."
            sudo tee -a "$WP_CONFIG" > /dev/null << 'WP_CONFIG_ADDON'

// Added by Caddy reverse proxy setup
if (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] == 'https') {
    $_SERVER['HTTPS'] = 'on';
    $_SERVER['SERVER_PORT'] = 443;
}
if (isset($_SERVER['HTTP_X_FORWARDED_HOST'])) {
    $_SERVER['HTTP_HOST'] = $_SERVER['HTTP_X_FORWARDED_HOST'];
}
// End Caddy configuration
WP_CONFIG_ADDON
            echo "Reverse proxy handling added to wp-config.php"
        fi
    else
        echo "Warning: wp-config.php not found. WordPress may need manual configuration."
    fi
    
    # Fix permissions for WordPress
    echo "Setting proper WordPress permissions..."
    sudo chown -R www-data:www-data "$WP_PATH"
    
    # Directory permissions
    sudo find "$WP_PATH" -type d -exec chmod 755 {} \;
    sudo find "$WP_PATH" -type f -exec chmod 644 {} \;
    
    # Special permissions for uploads and cache
    WP_UPLOADS="$WP_PATH/wp-content/uploads"
    if [ -d "$WP_UPLOADS" ]; then
        sudo chmod 775 "$WP_UPLOADS"
        sudo chown -R www-data:www-data "$WP_UPLOADS"
    fi
    
    # wp-content directory
    WP_CONTENT="$WP_PATH/wp-content"
    if [ -d "$WP_CONTENT" ]; then
        sudo chmod 775 "$WP_CONTENT"
    fi
    
    echo "WordPress permissions updated"
else
    echo "WordPress not found at $WP_PATH"
    echo "Creating placeholder index page..."
    sudo mkdir -p /var/www/html
    sudo tee /var/www/html/index.html > /dev/null << HTML
<!DOCTYPE html>
<html>
<head>
    <title>Welcome to $DOMAIN</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; }
        h1 { color: #333; }
        ul { list-style-type: none; padding: 0; }
        li { margin: 10px 0; }
        a { text-decoration: none; color: #0066cc; }
        a:hover { text-decoration: underline; }
    </style>
</head>
<body>
    <h1>Welcome to $DOMAIN</h1>
    <p>Server IP: $THIS_VM_IP</p>
    <p>Caddy reverse proxy with Let's Encrypt SSL is running.</p>
    <p>Configured services:</p>
    <ul>
        <li><a href="https://$DOMAIN">Main Website</a></li>
        <li><a href="https://erp.$DOMAIN">ERP Service</a> ($ERP_IP:$ERP_PORT)</li>
        <li><a href="https://docs.$DOMAIN">Documentation</a> ($DOCS_IP:$DOCS_PORT)</li>
        <li><a href="https://mail.$DOMAIN">Mail Service</a> ($MAIL_IP:$MAIL_PORT)</li>
    </ul>
</body>
</html>
HTML
fi
echo ""

# Step 11: Setup logging
echo "=== Setting up logging ==="
sudo mkdir -p /var/log/caddy
sudo touch /var/log/caddy/{access,error,wordpress,erp,docs,mail}.log
sudo chown -R caddy:caddy /var/log/caddy
sudo chmod 755 /var/log/caddy

# Create logrotate config
sudo tee /etc/logrotate.d/caddy > /dev/null << 'LOGROTATE'
/var/log/caddy/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 caddy caddy
    sharedscripts
    postrotate
        systemctl reload caddy 2>/dev/null || true
    endscript
}
LOGROTATE
echo "Logging configured"
echo ""

# Step 12: Configure firewall
echo "=== Configuring Firewall ==="
echo "Setting up UFW firewall rules..."

# Reset and enable UFW
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing

# Allow SSH
sudo ufw allow 22/tcp

# Allow HTTP/HTTPS for Let's Encrypt
sudo ufw allow 80/tcp comment 'HTTP for Let\'s Encrypt'
sudo ufw allow 443/tcp comment 'HTTPS'

# Allow internal network
sudo ufw allow from 192.168.116.0/24 comment 'Internal network'

# Allow PHP-FPM if running locally
if systemctl is-active --quiet php*-fpm; then
    sudo ufw allow from 127.0.0.1 to any port 9000 comment 'PHP-FPM'
fi

# Enable UFW
echo "y" | sudo ufw enable
echo ""
sudo ufw status verbose
echo ""

# Step 13: Validate and start Caddy
echo "=== Validating Caddy Configuration ==="
if sudo caddy validate --config /etc/caddy/Caddyfile; then
    echo "✓ Caddyfile is valid"
else
    echo "✗ Caddyfile validation failed!"
    echo "Please check the configuration and try again."
    exit 1
fi

echo ""
echo "=== Starting Caddy Service ==="
# Stop if running
sudo systemctl stop caddy 2>/dev/null || true

# Reload systemd and start
sudo systemctl daemon-reload
sudo systemctl start caddy
sudo systemctl enable caddy

# Wait a moment for Caddy to start
sleep 3

# Check status
echo "Caddy service status:"
sudo systemctl status caddy --no-pager -l | head -30

# Check if Caddy is running
if sudo systemctl is-active --quiet caddy; then
    echo "✓ Caddy is running successfully"
else
    echo "✗ Caddy failed to start. Check logs: sudo journalctl -u caddy"
    exit 1
fi
echo ""

# Step 14: Test services
echo "=== Testing Services Locally ==="
echo "Testing HTTP service on port 80..."
if curl -s -o /dev/null -w "%{http_code}" http://localhost > /dev/null 2>&1; then
    echo "✓ HTTP service is running"
else
    echo "✗ HTTP service failed"
fi

echo ""
echo "Testing HTTPS service on port 443..."
if curl -s -k -o /dev/null -w "%{http_code}" https://localhost > /dev/null 2>&1; then
    echo "✓ HTTPS service is running"
else
    echo "✗ HTTPS service failed"
fi

echo ""
echo "Testing WordPress PHP-FPM..."
if [ -S "$PHP_SOCKET" ]; then
    echo "✓ PHP-FPM socket exists: $PHP_SOCKET"
else
    echo "✗ PHP-FPM socket not found. WordPress may not work properly."
    echo "  Start PHP-FPM: sudo systemctl start php$(php -r "echo PHP_MAJOR_VERSION;")-fpm"
fi

echo ""
echo "Testing reverse proxy configuration..."
echo "You can test locally with:"
echo "  curl -H 'Host: erp.$DOMAIN' http://localhost"
echo "  curl -H 'Host: docs.$DOMAIN' http://localhost"
echo "  curl -H 'Host: mail.$DOMAIN' http://localhost"
echo ""

# Step 15: Check Let's Encrypt certificate status
echo "=== Checking SSL Certificate Status ==="
echo "Waiting for certificate issuance (may take up to 60 seconds)..."
sleep 10

if sudo caddy list-certificates 2>/dev/null | grep -q "$DOMAIN"; then
    echo "✓ SSL certificate obtained for $DOMAIN"
    
    # Show certificate details
    echo "Certificate details:"
    sudo caddy list-certificates 2>/dev/null | grep -A2 "$DOMAIN" || true
else
    echo "✗ SSL certificate not yet issued for $DOMAIN"
    echo "  Check logs: sudo journalctl -u caddy"
    echo "  Make sure DNS points to $THIS_VM_IP and port 80 is open to internet"
fi
echo ""

# Step 16: Show final configuration
echo "=== FINAL CONFIGURATION ==="
echo ""
echo "SSL CONFIGURATION:"
echo "  Let's Encrypt:  Enabled"
echo "  Admin Email:    $ADMIN_EMAIL"
echo "  Auto-renew:     Yes"
echo ""
echo "SUBDOMAIN CONFIGURATION:"
echo "  Main site:     https://$DOMAIN"
echo "  ERP:           https://erp.$DOMAIN  → $ERP_IP:$ERP_PORT"
echo "  Documentation: https://docs.$DOMAIN → $DOCS_IP:$DOCS_PORT"
echo "  Mail:          https://mail.$DOMAIN → $MAIL_IP:$MAIL_PORT"
echo ""
echo "NETWORK INFO:"
echo "  This VM IP:    $THIS_VM_IP"
echo "  Gateway:       $GATEWAY_IP"
echo "  Interface:     $PRIMARY_IF"
echo "  Network:       192.168.116.0/24"
echo ""
echo "WORDPRESS INFO:"
echo "  Path:          $WP_PATH"
echo "  PHP Socket:    $PHP_SOCKET"
echo "  Admin:         https://$DOMAIN/wp-admin"
echo ""
echo "CADDY INFO:"
echo "  Config file:   /etc/caddy/Caddyfile"
echo "  Backups:       /etc/caddy/Caddyfile.backup-*"
echo "  Logs:          /var/log/caddy/"
echo "  Status:        sudo systemctl status caddy"
echo "  Reload:        sudo systemctl reload caddy"
echo "  Validate:      sudo caddy validate --config /etc/caddy/Caddyfile"
echo ""
echo "DNS CONFIGURATION REQUIRED:"
echo "Add these A records in your DNS provider pointing to $THIS_VM_IP:"
echo "  @      → $THIS_VM_IP  (sahmcore.com.sa)"
echo "  www    → $THIS_VM_IP  (www.sahmcore.com.sa)"
echo "  erp    → $THIS_VM_IP  (erp.sahmcore.com.sa)"
echo "  docs   → $THIS_VM_IP  (docs.sahmcore.com.sa)"
echo "  mail   → $THIS_VM_IP  (mail.sahmcore.com.sa)"
echo ""
echo "IMPORTANT FOR LET'S ENCRYPT:"
echo "1. DNS records must propagate before SSL certificates can be issued"
echo "2. Port 80 must be accessible from the internet for HTTP challenge"
echo "3. If using Cloudflare, set DNS proxy to 'DNS Only' during issuance"
echo ""
echo "TEST COMMANDS:"
echo "  # Test WordPress with SSL"
echo "  curl -I https://$DOMAIN"
echo ""
echo "  # Test ERP service"
echo "  curl -H 'Host: erp.$DOMAIN' -I http://$THIS_VM_IP"
echo "  curl -k -H 'Host: erp.$DOMAIN' -I https://$THIS_VM_IP"
echo ""
echo "  # Test Mail service"
echo "  curl -H 'Host: mail.$DOMAIN' -I http://$THIS_VM_IP"
echo ""
echo "  # View Caddy logs"
echo "  sudo tail -f /var/log/caddy/access.log"
echo "  sudo journalctl -u caddy -f"
echo ""
echo "  # Check SSL certificates"
echo "  sudo caddy list-certificates"
echo ""
echo "  # Renew certificates manually"
echo "  sudo caddy reload --force"
echo ""
echo "  # Check PHP-FPM status"
echo "  sudo systemctl status php$(php -r "echo PHP_MAJOR_VERSION;")-fpm"
echo ""
echo "TROUBLESHOOTING:"
echo "1. If SSL fails: Check DNS resolution and port 80 accessibility"
echo "2. If WordPress shows mixed content: Clear WordPress cache"
echo "3. If services unavailable: Check backend VMs are running"
echo "4. Check logs: sudo journalctl -u caddy --since '5 minutes ago'"
echo ""
echo "==============================================="
echo "  SETUP COMPLETE!"
echo "  Caddy with Let's Encrypt SSL is now running"
echo "  All traffic routes through $THIS_VM_IP"
echo "==============================================="
echo ""
echo "Next steps:"
echo "1. Update DNS records as shown above"
echo "2. Wait for DNS propagation (5-60 minutes)"
echo "3. Test from browser:"
echo "   - https://$DOMAIN"
echo "   - https://erp.$DOMAIN"
echo "   - https://docs.$DOMAIN"
echo "   - https://mail.$DOMAIN"
echo "4. Monitor SSL issuance: sudo journalctl -u caddy -f"
echo "5. Configure WordPress plugins/themes as needed"
echo "6. Set up regular backups"
echo ""
echo "Backup directory: $BACKUP_DIR"
echo "Caddyfile backup: /etc/caddy/Caddyfile.backup-*"
echo ""
read -p "Press Enter to exit..."
