# Reverse SSH Tunnel

Access Windows 11 (dynamic IP) remotely from iPhone via a VPS (fixed IP) using reverse SSH tunnels. Supports multiple PCs sharing one VPS.

## Architecture

```
┌──────────────┐         ┌──────────────────┐         ┌──────────────┐
│  Windows PC1 │────────>│   VPS (Ubuntu)   │<────────│  iPhone 14   │
│  (Dynamic IP)│ Reverse │   (Fixed IP)     │ Forward │  Pro         │
│ localhost:22 │========>│ 0.0.0.0:2222     │  SSH    │  Termius App │
├──────────────┤ Tunnel  ├──────────────────┤  Conn   └──────────────┘
│  Windows PC2 │========>│ 0.0.0.0:2223     │
│  (Dynamic IP)│         │   ...            │
└──────────────┘         └──────────────────┘
```

**How it works:**
1. Windows initiates an outbound SSH connection to VPS (bypasses dynamic IP and NAT)
2. VPS opens a dedicated port per PC, reverse-forwarding traffic to Windows port 22
3. iPhone connects to the corresponding VPS port to reach the target Windows PC

## Multi-PC Support

Each PC auto-registers in the config when running `sync-to-vps.ps1`. Ports are assigned starting from 2222:

```json
{
    "VPS_SSH_PORT": "26369",
    "VPS_IP": "x.x.x.x",
    "PC_PORTS": {
        "DESKTOP-HOME": "2222",
        "DESKTOP-OFFICE": "2223"
    }
}
```

- On first sync, the script pulls the latest config from VPS to avoid port conflicts
- Already registered PCs reuse their existing port
- iPhone connects to `VPS_IP:<port>` to reach the corresponding PC

## Files

| File | Platform | Description |
|------|----------|-------------|
| `tunnel.ps1` | Windows | **One-click management script (PC entry point)** |
| `sync-to-vps.ps1` | Windows | Sync scripts to VPS (auto-registers PC port) |
| `vps-setup.sh` | Ubuntu VPS | VPS base configuration script |
| `vps-security.sh` | Ubuntu VPS | Additional hardening (fail2ban, optional) |
| `vps-config.json` | Shared | PC-Port mapping and VPS connection info |

<details>
<summary>Other helper scripts (integrated into tunnel.ps1 menu)</summary>

| File | Description |
|------|-------------|
| `windows-setup.ps1` | Windows OpenSSH installation and key setup |
| `install-tunnel-service.ps1` | Install scheduled task (auto-start + auto-reconnect) |
| `tunnel-service.ps1` | View/start/stop tunnel service |
| `win-password-auth.ps1` | Toggle password authentication |
| `ssh-vps.ps1` | Quick SSH to VPS |

</details>

## Quick Start

Open PowerShell **as Administrator**:

```powershell
cd E:\RevertSSH
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process
.\tunnel.ps1
```

Interactive menu:

```
  ==========================================
   Reverse SSH Tunnel Manager
  ==========================================

  VPS            : 144.34.247.201:26369
  This PC        : DESKTOP-HOME -> port 2222
  Tunnel Key     : OK
  Scheduled Task : Running
  SSH Tunnel     : Running (PID: 12345)
  Keepalive      : Running (PID: 6789)
  OpenSSH Server : Running
  Password Auth  : Disabled

  ---- Actions ----
  [1] Stop tunnel
  [2] Restart tunnel
  [3] Toggle password auth (temporary use only)
  [4] Initial setup (first time)
  [5] SSH to VPS
  [6] Sync VPS scripts
  [7] VPS setup guide
  [q] Quit
```

### First-Time Deployment

1. **Sync scripts to VPS** — Run `.\sync-to-vps.ps1` (auto-registers this PC and assigns a port)
2. **Configure VPS** — SSH to VPS and run `sudo ./vps-setup.sh` (opens firewall ports + applies key-only tunnel hardening)
3. **Run initial setup** — Select `[4]`: installs OpenSSH, generates keys, uploads pubkey, creates scheduled task
4. **Configure iPhone** — In Termius, connect to `VPS_IP:<your_port>` using SSH key authentication

### Adding a New PC

Copy this project to the new PC, then run `.\sync-to-vps.ps1`. The script will:
1. Pull the latest config from VPS
2. Auto-assign the next available port (e.g., 2223)
3. Update config and sync back to VPS
4. Then re-run `sudo ./vps-setup.sh` on VPS to open the new port

## Verification

```bash
# On VPS: check all tunnel ports
ss -tlnp | grep -E '222[0-9]'

# On VPS: test connection to a PC
ssh -p 2222 your_windows_username@localhost
```

## Troubleshooting

### Tunnel not connecting

```powershell
# Windows: check logs
Get-Content .\tunnel.log -Tail 20

# Windows: manual test
ssh -i $env:USERPROFILE\.ssh\id_ed25519_tunnel -v -N -R 2222:localhost:22 -p VPS_SSH_PORT tunnel@VPS_IP
```

```bash
# VPS: check SSH logs
sudo journalctl -u ssh -f

# VPS: check port
ss -tlnp | grep 2222
```

### Tunnel keeps disconnecting

```bash
# VPS: verify keepalive settings
grep -E "ClientAlive|TCPKeepAlive" /etc/ssh/sshd_config
```

```powershell
# Windows: verify keepalive script is running
Get-ScheduledTask -TaskName ReverseSSHTunnel | Select-Object State
```

### Stale connection on port 2222

```bash
# Force clear on VPS
sudo fuser -k 2222/tcp
```

### Windows SSH service not running

```powershell
Get-Service sshd
Start-Service sshd
```

## Port Planning

| Port | Location | Purpose |
|------|----------|---------|
| VPS_SSH_PORT | VPS | VPS SSH management (read from config) |
| 22 | Windows | Windows OpenSSH Server |
| 2222+ | VPS | Reverse tunnel to Windows (iPhone connects here) |

## Security Recommendations

1. **Default is key-only**: Windows OpenSSH is configured with `PasswordAuthentication no` during setup
2. **Tunnel user is restricted by default**: `tunnel` is key-only and limited to reverse forwarding
3. **Keep systems updated**: Regularly update both VPS and Windows
4. **Monitor logs**: Regularly check `tunnel.log` and `/var/log/auth.log` on VPS
5. **Optional extra hardening**: run `vps-security.sh` to enable fail2ban

## Uninstall

### Windows

```powershell
# Stop and remove scheduled task
Stop-ScheduledTask -TaskName ReverseSSHTunnel
Unregister-ScheduledTask -TaskName ReverseSSHTunnel -Confirm:$false

# Kill SSH tunnel processes
Get-Process ssh -ErrorAction SilentlyContinue | Stop-Process -Force
```

### VPS

```bash
# Remove tunnel user
sudo userdel -r tunnel

# Restore SSH config
sudo cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
sudo systemctl restart ssh
```
