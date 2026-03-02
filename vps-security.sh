#!/bin/bash
# ============================================================
# VPS Additional Security Script (optional)
# Base hardening is already applied by vps-setup.sh.
# This script adds extra protections (e.g. fail2ban).
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/vps-config.json"

# Read SSH port from config
SSH_PORT=22
if [ -f "$CONFIG_FILE" ]; then
    PORT_VAL=$(grep '"VPS_SSH_PORT"' "$CONFIG_FILE" | grep -o '[0-9]\+')
    if [ -n "$PORT_VAL" ]; then
        SSH_PORT=$PORT_VAL
    fi
fi

echo "=========================================="
echo " VPS Security Hardening (SSH Port: $SSH_PORT)"
echo "=========================================="

# ---------- 1. Install fail2ban ----------
echo "[1/2] Installing fail2ban..."

sudo apt install -y fail2ban

sudo tee /etc/fail2ban/jail.local > /dev/null <<EOF
[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 3600
findtime = 600
EOF

sudo systemctl enable fail2ban
sudo systemctl restart fail2ban

echo "  fail2ban installed and configured."

# ---------- 2. Restart SSH service ----------
echo "[2/2] Restarting SSH service..."
if systemctl list-unit-files ssh.service | grep -q ssh.service; then
    sudo systemctl restart ssh
else
    sudo systemctl restart sshd
fi

echo ""
echo "=========================================="
echo " Security Hardening Complete!"
echo "=========================================="
echo ""
echo "Notes:"
echo "  - Tunnel user restrictions are now managed by vps-setup.sh by default."
echo "  - fail2ban enabled: 5 failed attempts = 1 hour ban"
echo ""
