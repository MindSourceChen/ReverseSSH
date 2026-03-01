#!/bin/bash
# ============================================================
# VPS (Ubuntu) Setup Script
# Configures SSH server to support reverse tunnels
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/vps-config.json"

# Read config
SSH_PORT=22
TUNNEL_PORTS=()
if [ -f "$CONFIG_FILE" ]; then
    PORT_VAL=$(grep '"VPS_SSH_PORT"' "$CONFIG_FILE" | grep -o '[0-9]\+')
    if [ -n "$PORT_VAL" ]; then
        SSH_PORT=$PORT_VAL
    fi
    # Parse PC_PORTS: extract all "NAME": "PORT" entries inside PC_PORTS block
    # Use python if available, otherwise grep
    if command -v python3 > /dev/null 2>&1; then
        TUNNEL_PORTS=($(python3 -c "
import json,sys
with open('$CONFIG_FILE') as f:
    d=json.load(f)
for name,port in d.get('PC_PORTS',{}).items():
    print(name+':'+str(port))
" 2>/dev/null))
    elif command -v python > /dev/null 2>&1; then
        TUNNEL_PORTS=($(python -c "
import json,sys
with open('$CONFIG_FILE') as f:
    d=json.load(f)
for name,port in d.get('PC_PORTS',{}).items():
    print(name+':'+str(port))
" 2>/dev/null))
    fi
fi

# If no PC_PORTS found, default to port 2222
if [ ${#TUNNEL_PORTS[@]} -eq 0 ]; then
    TUNNEL_PORTS=("DEFAULT:2222")
fi

echo "=========================================="
echo " Reverse SSH Tunnel - VPS Setup"
echo " SSH Port: $SSH_PORT"
echo " Registered PCs:"
for entry in "${TUNNEL_PORTS[@]}"; do
    PC_NAME="${entry%%:*}"
    PC_PORT="${entry##*:}"
    echo "   $PC_NAME -> port $PC_PORT"
done
echo "=========================================="

# ---------- 1. Update system and install OpenSSH Server ----------
echo "[1/6] Updating system and installing OpenSSH Server..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y openssh-server

# ---------- 2. Create dedicated tunnel user ----------
TUNNEL_USER="tunnel"
echo "[2/6] Creating tunnel user: $TUNNEL_USER ..."

if id "$TUNNEL_USER" &>/dev/null; then
    echo "  User $TUNNEL_USER already exists, skipping."
else
    sudo useradd -m -s /bin/bash "$TUNNEL_USER"
    echo "  User $TUNNEL_USER created."
fi

# Set password (can switch to key-only later)
echo "  Please set password for $TUNNEL_USER:"
sudo passwd "$TUNNEL_USER"

# ---------- 3. Configure SSH key directory ----------
echo "[3/6] Configuring SSH key directory..."
TUNNEL_HOME=$(eval echo "~$TUNNEL_USER")
sudo mkdir -p "$TUNNEL_HOME/.ssh"
sudo chmod 700 "$TUNNEL_HOME/.ssh"
sudo touch "$TUNNEL_HOME/.ssh/authorized_keys"
sudo chmod 600 "$TUNNEL_HOME/.ssh/authorized_keys"
sudo chown -R "$TUNNEL_USER:$TUNNEL_USER" "$TUNNEL_HOME/.ssh"

echo "  Key directory ready: $TUNNEL_HOME/.ssh/"

# ---------- 4. Backup and configure sshd_config ----------
echo "[4/6] Configuring SSH server..."
SSHD_CONFIG="/etc/ssh/sshd_config"

# Backup original config
if [ ! -f "${SSHD_CONFIG}.bak" ]; then
    sudo cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak"
    echo "  Original config backed up to ${SSHD_CONFIG}.bak"
fi

# Append or fix reverse tunnel config
MARKER="# === REVERSE-SSH-TUNNEL CONFIG ==="
NEED_RESTART=0

if ! grep -q "$MARKER" "$SSHD_CONFIG"; then
    sudo tee -a "$SSHD_CONFIG" > /dev/null <<EOF

$MARKER
# Allow remote port forwarding (core reverse tunnel setting)
GatewayPorts yes
# Keep connections alive to prevent tunnel disconnect
ClientAliveInterval 30
ClientAliveCountMax 3
# Allow TCP forwarding
AllowTcpForwarding yes
EOF
    echo "  SSH config added."
    NEED_RESTART=1
else
    echo "  SSH config already contains tunnel settings, checking..."
    # Ensure GatewayPorts is yes (fix clientspecified or no)
    if grep -q "GatewayPorts clientspecified\|GatewayPorts no" "$SSHD_CONFIG"; then
        sudo sed -i 's/GatewayPorts clientspecified/GatewayPorts yes/' "$SSHD_CONFIG"
        sudo sed -i 's/GatewayPorts no/GatewayPorts yes/' "$SSHD_CONFIG"
        echo "  [FIX] GatewayPorts corrected to yes"
        NEED_RESTART=1
    else
        echo "  GatewayPorts yes - OK"
    fi
    # Ensure AllowTcpForwarding is yes
    if grep -q "AllowTcpForwarding no" "$SSHD_CONFIG"; then
        sudo sed -i 's/AllowTcpForwarding no/AllowTcpForwarding yes/' "$SSHD_CONFIG"
        echo "  [FIX] AllowTcpForwarding corrected to yes"
        NEED_RESTART=1
    else
        echo "  AllowTcpForwarding yes - OK"
    fi
fi

# ---------- 5. Configure firewall ----------
echo "[5/6] Configuring firewall rules..."

# Open ports for all registered PCs
for entry in "${TUNNEL_PORTS[@]}"; do
    PC_NAME="${entry%%:*}"
    P="${entry##*:}"
    if command -v ufw > /dev/null 2>&1; then
        sudo ufw allow $SSH_PORT/tcp comment "SSH" 2>/dev/null || true
        sudo ufw allow $P/tcp comment "Reverse SSH Tunnel $PC_NAME"
    elif command -v firewall-cmd > /dev/null 2>&1; then
        sudo firewall-cmd --permanent --add-port=$SSH_PORT/tcp 2>/dev/null || true
        sudo firewall-cmd --permanent --add-port=$P/tcp
    else
        echo "    sudo iptables -A INPUT -p tcp --dport $P -j ACCEPT"
    fi
    echo "  Port $P opened ($PC_NAME)"
done

if command -v ufw > /dev/null 2>&1; then
    sudo ufw --force enable
    sudo ufw status verbose
elif command -v firewall-cmd > /dev/null 2>&1; then
    sudo firewall-cmd --reload
    sudo firewall-cmd --list-ports
else
    echo "  No firewall tool (ufw/firewalld) found. Run iptables commands above manually."
fi

# ---------- 6. Restart SSH service ----------
echo "[6/6] Restarting SSH service..."
if systemctl list-unit-files ssh.service | grep -q ssh.service; then
    sudo systemctl restart ssh
    sudo systemctl enable ssh
else
    sudo systemctl restart sshd
    sudo systemctl enable sshd
fi

echo ""
echo "=========================================="
echo " VPS Setup Complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "  1. After generating keys on Windows, add the public key to:"
echo "     $TUNNEL_HOME/.ssh/authorized_keys"
echo ""
echo "  2. PC-Port mapping:"
for entry in "${TUNNEL_PORTS[@]}"; do
    PC_NAME="${entry%%:*}"
    PC_PORT="${entry##*:}"
    echo "     $PC_NAME -> VPS_IP:$PC_PORT"
done
echo ""
