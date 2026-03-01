#!/bin/bash
# ============================================================
# VPS Security Hardening Script (optional)
# Run after base setup to improve security
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

SSHD_CONFIG="/etc/ssh/sshd_config"
TUNNEL_USER="tunnel"

# ---------- 1. Restrict tunnel user permissions ----------
echo "[1/4] Restricting tunnel user permissions..."

# Add restricted config for tunnel user
MARKER="# === TUNNEL USER RESTRICTION ==="
if ! grep -q "$MARKER" "$SSHD_CONFIG"; then
    sudo tee -a "$SSHD_CONFIG" > /dev/null <<EOF

$MARKER
Match User $TUNNEL_USER
    AllowTcpForwarding yes
    X11Forwarding no
    PermitTunnel no
    AllowAgentForwarding no
    PasswordAuthentication no
    ForceCommand /bin/false
EOF
    echo "  Tunnel user restricted to port forwarding only."
else
    echo "  Tunnel user restriction already configured, skipping."
fi

# ---------- 2. Disable password login for tunnel user (key-only) ----------
echo "[2/4] Configuring authentication..."

# Ensure pubkey auth is globally enabled
sudo sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSHD_CONFIG"

# Password disabled in Match User block (created in step 1)
echo "  Root password login unchanged. Tunnel user key-only."

# ---------- 3. Install fail2ban ----------
echo "[3/4] Installing fail2ban..."

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

# ---------- 4. Restart SSH service ----------
echo "[4/4] Restarting SSH service..."
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
echo "  - Password login disabled for tunnel user. Ensure keys work before disconnecting."
echo "  - fail2ban enabled: 5 failed attempts = 1 hour ban"
echo "  - Tunnel user can only do port forwarding, no command execution"
echo ""
