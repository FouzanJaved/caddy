#!/bin/bash
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

# Step 1: Check current web server
echo "=== Checking current setup ==="
echo "Current IP: $THIS_VM_IP"
echo "Gateway: $GATEWAY_IP"
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
sudo cp -r /etc/apache2 $BACKUP_DIR/apache2-backup 2>/dev/null
sudo cp -r /etc/nginx $BACKUP_DIR/nginx-backup 2>/dev/null
sudo cp -r /var/www/html $BACKUP_DIR/html-backup 2>/dev/null
sudo cp /etc/hosts $BACKUP_DIR/hosts-backup
sudo cp /etc/network/interfaces $BACKUP_DIR/interfaces-backup 2>/dev/null
echo "Backups created in $BACKUP_DIR"
echo ""

# Step 3: Update system and install Caddy
echo "=== Updating system and installing Caddy ==="
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl wget net-tools ufw

# Install Caddy
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update
sudo apt install caddy -y
echo "Caddy installed successfully!"
echo ""

# Step 4: Stop old web servers
echo "=== Stopping old web servers ==="
sudo systemctl stop apache2 2>/dev/null
sudo systemctl stop nginx 2>/dev/null
sudo systemctl disable apache2 2>/dev/null
sudo systemctl disable nginx 2>/dev/null
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
    echo "Setting IP address to $THIS_VM_IP..."
    sudo ip addr add $THIS_VM_IP/24 dev eth0 2>/dev/null || true
fi
echo ""

# Step 8: Create Caddyfile with mail subdomain
echo "=== Creating Caddyfile ==="
sudo tee /etc/caddy/Caddyfile > /dev/null << EOF
# Auto-generated Caddy configuration for $DOMAIN
# Generated on: $(date)
# This VM: $THIS_VM_IP
# Gateway: $GATEWAY_IP

# Global options
{
    email admin@$DOMAIN
    admin off
    auto_https disable_redirects
    
    # Logging
    log {
        output file /var/log/caddy/access.log {
            roll_size 100mb
            roll_keep 5
        }
        level INFO
    }
}

# Main WordPress site (on this VM: $THIS_VM_IP)
$DOMAIN, www.$DOMAIN {
    # WordPress directory - adjust if different
    root * /var/www/html
    
    # Try to find WordPress
    @wordpress {
        file {
            try_files {path} {path}/ /index.php?{query}
        }
    }
    
    # Handle PHP requests
    @php {
        path *.php
    }
    
    # Use PHP-FPM if available
    handle @php {
        try_files {path} =404
        php_fastcgi {
            transport unix
            resolve_root_symlink
        }
    }
    
    # Handle static files
    handle @wordpress {
        file_server
    }
    
    # Fallback
    handle {
        try_files {path} {path}/ /index.php?{query}
        file_server
    }
    
    # Security headers
    header {
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        X-XSS-Protection "1; mode=block"
        Referrer-Policy "strict-origin-when-cross-origin"
        -Server
    }
    
    # Compression
    encode gzip
    
    # Logging
    log {
        output file /var/log/caddy/wordpress.log
    }
}

# ERP Service (Windows VM: $ERP_IP)
erp.$DOMAIN {
    reverse_proxy $ERP_IP:$ERP_PORT
    
    # Headers for ERP/Odoo
    header_up Host {host}
    header_up X-Forwarded-Host {host}
    header_up X-Forwarded-Proto {scheme}
    header_up X-Real-IP {remote}
    header_up X-Forwarded-For {remote}
    
    # Timeouts for ERP
    reverse_proxy {
        to $ERP_IP:$ERP_PORT
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
    reverse_proxy $DOCS_IP:$DOCS_PORT
    
    header_up Host {host}
    header_up X-Forwarded-Proto {scheme}
    
    log {
        output file /var/log/caddy/docs.log
    }
}

# Mail Service ($MAIL_IP) - Changed from api to mail
mail.$DOMAIN {
    reverse_proxy $MAIL_IP:$MAIL_PORT
    
    # Mail-specific headers
    header_up Host {host}
    header_up X-Forwarded-Proto {scheme}
    header_up X-Forwarded-For {remote}
    
    # Mail server may need WebSocket support
    reverse_proxy {
        to $MAIL_IP:$MAIL_PORT
        transport http {
            tls
        }
    }
    
    # Logging
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
EOF

echo "Caddyfile created at /etc/caddy/Caddyfile"
echo ""

# Step 9: Configure WordPress if exists
echo "=== Configuring WordPress ==="
WP_PATH="/var/www/html"
WP_CONFIG="$WP_PATH/wp-config.php"

if [ -d "$WP_PATH" ]; then
    echo "Found WordPress at $WP_PATH"
    
    # Backup WordPress config
    if [ -f "$WP_CONFIG" ]; then
        sudo cp "$WP_CONFIG" "${WP_CONFIG}.backup-$(date +%Y%m%d)"
        echo "Backed up wp-config.php"
        
        # Update WordPress URLs for Caddy
        echo "Updating WordPress configuration..."
        
        # Create temporary config update script
        sudo tee /tmp/update-wp-config.php > /dev/null << 'WPSCRIPT'
<?php
// Update WordPress configuration for reverse proxy
\$wp_config = file_get_contents('/var/www/html/wp-config.php');

// Add or update WP_HOME and WP_SITEURL
if (!strpos(\$wp_config, "WP_HOME")) {
    \$new_config = preg_replace(
        '/define\\(\\s*[\'"]WP_DEBUG[\'"]\\s*,/',
        "define('WP_HOME', 'https://sahmcore.com.sa');\n" .
        "define('WP_SITEURL', 'https://sahmcore.com.sa');\n" .
        "define('WP_DEBUG',",
        \$wp_config
    );
    file_put_contents('/var/www/html/wp-config.php', \$new_config);
    echo "Added WP_HOME and WP_SITEURL constants\n";
}

// Add reverse proxy handling
if (!strpos(\$wp_config, "HTTP_X_FORWARDED_HOST")) {
    \$append = "\n\n" . '// Handle reverse proxy headers from Caddy' . "\n" .
              'if (isset($_SERVER[\'HTTP_X_FORWARDED_HOST\'])) {' . "\n" .
              '    $_SERVER[\'HTTP_HOST\'] = $_SERVER[\'HTTP_X_FORWARDED_HOST\'];' . "\n" .
              '}' . "\n" .
              'if (isset($_SERVER[\'HTTP_X_FORWARDED_PROTO\']) && $_SERVER[\'HTTP_X_FORWARDED_PROTO\'] === \'https\') {' . "\n" .
              '    $_SERVER[\'HTTPS\'] = \'on\';' . "\n" .
              '}';
    
    file_put_contents('/var/www/html/wp-config.php', \$append, FILE_APPEND);
    echo "Added reverse proxy handling\n";
}
?>
WPSCRIPT

        sudo php /tmp/update-wp-config.php
        sudo rm /tmp/update-wp-config.php
    fi
    
    # Fix permissions
    sudo chown -R www-data:www-data $WP_PATH
    sudo find $WP_PATH -type d -exec chmod 755 {} \;
    sudo find $WP_PATH -type f -exec chmod 644 {} \;
    echo "WordPress permissions updated"
else
    echo "WordPress not found at $WP_PATH"
    echo "Creating placeholder..."
    sudo mkdir -p /var/www/html
    sudo tee /var/www/html/index.html > /dev/null << HTML
<!DOCTYPE html>
<html>
<head>
    <title>Welcome to $DOMAIN</title>
</head>
<body>
    <h1>Welcome to $DOMAIN</h1>
    <p>Server IP: $THIS_VM_IP</p>
    <p>Caddy reverse proxy is running.</p>
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

# Step 10: Setup logging
echo "=== Setting up logging ==="
sudo mkdir -p /var/log/caddy
sudo touch /var/log/caddy/{access,wordpress,erp,docs,mail}.log
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
        [ ! -f /var/run/caddy/caddy.pid ] || kill -USR1 `cat /var/run/caddy/caddy.pid`
    endscript
}
LOGROTATE
echo "Logging configured"
echo ""

# Step 11: Configure firewall
echo "=== Configuring Firewall ==="
echo "Setting up UFW firewall rules..."

# Reset and enable UFW
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing

# Allow SSH (adjust port if needed)
sudo ufw allow 22/tcp

# Allow HTTP/HTTPS
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp

# Allow internal network
sudo ufw allow from 192.168.116.0/24

# Enable UFW
echo "y" | sudo ufw enable
sudo ufw status verbose
echo ""

# Step 12: Start and enable Caddy
echo "=== Starting Caddy ==="
# Validate config first
sudo caddy validate --config /etc/caddy/Caddyfile

# Stop if running
sudo systemctl stop caddy 2>/dev/null

# Reload systemd and start
sudo systemctl daemon-reload
sudo systemctl start caddy
sudo systemctl enable caddy

# Check status
echo "Caddy service status:"
sudo systemctl status caddy --no-pager -l | head -20
echo ""

# Step 13: Test services
echo "=== Testing Services Locally ==="
echo "Testing HTTP service on port 80..."
if curl -s -o /dev/null -w "%{http_code}" http://localhost > /dev/null 2>&1; then
    echo "✓ HTTP service is running"
else
    echo "✗ HTTP service failed"
fi

echo ""
echo "Testing reverse proxy configuration..."
echo "You can test locally with:"
echo "  curl -H 'Host: erp.$DOMAIN' http://localhost"
echo "  curl -H 'Host: docs.$DOMAIN' http://localhost"
echo "  curl -H 'Host: mail.$DOMAIN' http://localhost"
echo ""

# Step 14: Show final configuration
echo "=== FINAL CONFIGURATION ==="
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
echo "  Network:       192.168.116.0/24"
echo ""
echo "CADDY INFO:"
echo "  Config file:   /etc/caddy/Caddyfile"
echo "  Logs:          /var/log/caddy/"
echo "  Status:        sudo systemctl status caddy"
echo "  Reload:        sudo systemctl reload caddy"
echo ""
echo "DNS CONFIGURATION REQUIRED:"
echo "Add these A records in your DNS provider:"
echo "  @      → $THIS_VM_IP"
echo "  erp    → $THIS_VM_IP"
echo "  docs   → $THIS_VM_IP"
echo "  mail   → $THIS_VM_IP"
echo ""
echo "TEST COMMANDS:"
echo "  # Test WordPress"
echo "  curl -I https://$DOMAIN"
echo ""
echo "  # Test ERP service"
echo "  curl -H 'Host: erp.$DOMAIN' -I http://$THIS_VM_IP"
echo ""
echo "  # Test Mail service"
echo "  curl -H 'Host: mail.$DOMAIN' -I http://$THIS_VM_IP"
echo ""
echo "  # View Caddy logs"
echo "  sudo tail -f /var/log/caddy/access.log"
echo ""
echo "  # Check SSL certificates"
echo "  sudo caddy list-certificates"
echo ""
echo "==============================================="
echo "  SETUP COMPLETE!"
echo "  Caddy is now running on $THIS_VM_IP"
echo "  All traffic routes through this VM"
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
echo "4. Monitor logs: sudo tail -f /var/log/caddy/*.log"
