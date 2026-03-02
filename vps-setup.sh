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

# Default hardening: disable password login for tunnel user
sudo passwd -l "$TUNNEL_USER" >/dev/null 2>&1 || true
echo "  Password login locked for $TUNNEL_USER (key-only)."

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

ensure_sshd_option() {
    key="$1"
    value="$2"
    if sudo grep -Eq "^[[:space:]]*#?[[:space:]]*$key[[:space:]]+" "$SSHD_CONFIG"; then
        sudo sed -i -E "s|^[[:space:]]*#?[[:space:]]*$key[[:space:]].*|$key $value|g" "$SSHD_CONFIG"
    else
        echo "$key $value" | sudo tee -a "$SSHD_CONFIG" >/dev/null
    fi
}

# Keep secure global defaults and only allow forwarding for tunnel user.
ensure_sshd_option "ClientAliveInterval" "30"
ensure_sshd_option "ClientAliveCountMax" "3"
ensure_sshd_option "PubkeyAuthentication" "yes"
ensure_sshd_option "GatewayPorts" "no"
ensure_sshd_option "AllowTcpForwarding" "no"

# Clean up legacy tunnel-user block if it exists.
if sudo grep -q "# === TUNNEL USER RESTRICTION ===" "$SSHD_CONFIG"; then
    sudo sed -i '/# === TUNNEL USER RESTRICTION ===/,/ForceCommand \/bin\/false/d' "$SSHD_CONFIG"
fi

MATCH_START="# === REVERSE-SSH-TUNNEL USER POLICY START ==="
MATCH_END="# === REVERSE-SSH-TUNNEL USER POLICY END ==="
TMP_FILE=$(mktemp)

sudo awk -v start="$MATCH_START" -v end="$MATCH_END" '
    $0 == start { skip = 1; next }
    $0 == end { skip = 0; next }
    !skip { print }
' "$SSHD_CONFIG" > "$TMP_FILE"

cat >> "$TMP_FILE" <<EOF

$MATCH_START
Match User $TUNNEL_USER
    PubkeyAuthentication yes
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AuthenticationMethods publickey
    AllowTcpForwarding remote
    GatewayPorts yes
    X11Forwarding no
    PermitTunnel no
    AllowAgentForwarding no
    PermitTTY no
    ForceCommand /bin/false
$MATCH_END
EOF

sudo cp "$TMP_FILE" "$SSHD_CONFIG"
rm -f "$TMP_FILE"
echo "  SSH config hardened (forwarding restricted to user $TUNNEL_USER)."

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
echo "  2. Tunnel user is key-only by default (password login disabled)."
echo ""
echo "  3. PC-Port mapping:"
for entry in "${TUNNEL_PORTS[@]}"; do
    PC_NAME="${entry%%:*}"
    PC_PORT="${entry##*:}"
    echo "     $PC_NAME -> VPS_IP:$PC_PORT"
done
echo ""
