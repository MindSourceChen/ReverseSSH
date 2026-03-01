# ============================================================
# Reverse SSH Tunnel - One-Click Management (PC)
# Run PowerShell as Administrator
# ============================================================

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigFile = Join-Path $ScriptDir "vps-config.json"
$TaskName = "ReverseSSHTunnel"
$KeyPath = Join-Path $env:USERPROFILE ".ssh\id_ed25519_tunnel"

# ==================== Helper Functions ====================

function Load-Config {
    $script:VPS_IP = ""
    $script:VPS_SSH_PORT = ""
    $script:REMOTE_PORT = "2222"
    $script:PC_PORTS = @{}
    if (Test-Path $ConfigFile) {
        $saved = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        if ($saved.VPS_IP) { $script:VPS_IP = $saved.VPS_IP }
        if ($saved.VPS_SSH_PORT) { $script:VPS_SSH_PORT = [string]$saved.VPS_SSH_PORT }
        if ($saved.PC_PORTS) {
            $saved.PC_PORTS.PSObject.Properties | ForEach-Object { $script:PC_PORTS[$_.Name] = [string]$_.Value }
            $myPort = $saved.PC_PORTS.($env:COMPUTERNAME)
            if ($myPort) { $script:REMOTE_PORT = [string]$myPort }
        }
    }
}

function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "  ==========================================" -ForegroundColor Cyan
    Write-Host "   Reverse SSH Tunnel Manager" -ForegroundColor Cyan
    Write-Host "  ==========================================" -ForegroundColor Cyan
    Write-Host ""
}

function Show-Status {
    Load-Config

    # VPS Config
    if ($script:VPS_IP) {
        Write-Host ("  VPS            : " + $script:VPS_IP + ":" + $script:VPS_SSH_PORT) -ForegroundColor White
        Write-Host ("  This PC        : " + $env:COMPUTERNAME + " -> port " + $script:REMOTE_PORT) -ForegroundColor White
        if ($script:PC_PORTS.Count -gt 1) {
            Write-Host ("  Total PCs      : " + $script:PC_PORTS.Count) -ForegroundColor DarkGray
        }
    } else {
        Write-Host "  VPS            : Not Configured" -ForegroundColor Red
    }

    # SSH Key
    if (Test-Path $KeyPath) {
        Write-Host "  Tunnel Key     : OK" -ForegroundColor Green
    } else {
        Write-Host "  Tunnel Key     : Not Generated" -ForegroundColor Red
    }

    # Scheduled Task
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        $state = $task.State
        if ($state -eq "Running") {
            Write-Host ("  Scheduled Task : " + $state) -ForegroundColor Green
        } else {
            Write-Host ("  Scheduled Task : " + $state) -ForegroundColor Yellow
        }
    } else {
        Write-Host "  Scheduled Task : Not Installed" -ForegroundColor Red
    }

    # SSH Process
    $sshProc = Get-Process -Name "ssh" -ErrorAction SilentlyContinue
    if ($sshProc) {
        foreach ($p in $sshProc) {
            Write-Host ("  SSH Tunnel     : Running (PID: " + $p.Id + ")") -ForegroundColor Green
        }
    } else {
        Write-Host "  SSH Tunnel     : Not Running" -ForegroundColor Red
    }

    # Keepalive Script
    $keepaliveProc = Get-WmiObject Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine -like "*tunnel-keepalive*" }
    if ($keepaliveProc) {
        Write-Host ("  Keepalive      : Running (PID: " + $keepaliveProc.ProcessId + ")") -ForegroundColor Green
    } else {
        Write-Host "  Keepalive      : Not Running" -ForegroundColor Red
    }

    # Windows OpenSSH Server
    $sshdSvc = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if ($sshdSvc) {
        if ($sshdSvc.Status -eq "Running") {
            Write-Host ("  OpenSSH Server : " + $sshdSvc.Status) -ForegroundColor Green
        } else {
            Write-Host ("  OpenSSH Server : " + $sshdSvc.Status) -ForegroundColor Yellow
        }
    } else {
        Write-Host "  OpenSSH Server : Not Installed" -ForegroundColor Red
    }

    # Password Auth
    $sshdConfig = "C:\ProgramData\ssh\sshd_config"
    if (Test-Path $sshdConfig) {
        $match = Select-String -Path $sshdConfig -Pattern '^\s*PasswordAuthentication\s+(yes|no)' | Select-Object -First 1
        if ($match -and $match.Line -match "no") {
            Write-Host "  Password Auth  : Disabled" -ForegroundColor Yellow
        } else {
            Write-Host "  Password Auth  : Enabled" -ForegroundColor Green
        }
    }

    # Log tail
    $logFile = Join-Path $ScriptDir "tunnel.log"
    if (Test-Path $logFile) {
        Write-Host ""
        Write-Host "  Recent log:" -ForegroundColor DarkGray
        Get-Content $logFile -Tail 3 | ForEach-Object { Write-Host ("    " + $_) -ForegroundColor DarkGray }
    }
    Write-Host ""
}

function Show-VPSGuide {
    Write-Host ""
    Write-Host "  ==========================================" -ForegroundColor Yellow
    Write-Host "   VPS Setup Guide (Ubuntu)" -ForegroundColor Yellow
    Write-Host "  ==========================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Option A: Use the script (recommended)" -ForegroundColor Cyan
    Write-Host "  -----------------------------------------" -ForegroundColor DarkGray
    Write-Host "  1. From this menu, select [6] Sync VPS scripts" -ForegroundColor White
    Write-Host "  2. SSH to VPS (select [5]), then run:" -ForegroundColor White
    Write-Host "       cd /root/reverse-ssh" -ForegroundColor Green
    Write-Host "       sudo ./vps-setup.sh" -ForegroundColor Green
    Write-Host "       sudo ./vps-security.sh  # optional" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Option B: Manual setup" -ForegroundColor Cyan
    Write-Host "  -----------------------------------------" -ForegroundColor DarkGray
    Write-Host "  1. Create tunnel user:" -ForegroundColor White
    Write-Host "       sudo useradd -m -s /bin/bash tunnel" -ForegroundColor Green
    Write-Host "       sudo passwd tunnel" -ForegroundColor Green
    Write-Host ""
    Write-Host "  2. Edit /etc/ssh/sshd_config, add:" -ForegroundColor White
    Write-Host "       GatewayPorts yes" -ForegroundColor Green
    Write-Host "       ClientAliveInterval 30" -ForegroundColor Green
    Write-Host "       ClientAliveCountMax 3" -ForegroundColor Green
    Write-Host "       AllowTcpForwarding yes" -ForegroundColor Green
    Write-Host ""
    Write-Host "  3. Restart SSH:" -ForegroundColor White
    Write-Host "       sudo systemctl restart ssh" -ForegroundColor Green
    Write-Host ""
    Write-Host ("  4. Open firewall ports:") -ForegroundColor White
    if ($script:PC_PORTS.Count -gt 0) {
        foreach ($key in ($script:PC_PORTS.Keys | Sort-Object)) {
            Write-Host ("       sudo ufw allow " + $script:PC_PORTS[$key] + "/tcp  # " + $key) -ForegroundColor Green
        }
    } else {
        Write-Host ("       sudo ufw allow " + $script:REMOTE_PORT + "/tcp") -ForegroundColor Green
    }
    Write-Host ""
    Write-Host "  IMPORTANT: GatewayPorts must be 'yes' (not 'clientspecified')" -ForegroundColor Red
    Write-Host "  Verify: grep GatewayPorts /etc/ssh/sshd_config" -ForegroundColor DarkGray
    Write-Host ""
}

# ==================== Main Menu Loop ====================

while ($true) {
    Show-Banner
    Show-Status

    $sshProc = Get-Process -Name "ssh" -ErrorAction SilentlyContinue
    $isRunning = $null -ne $sshProc

    Write-Host "  ---- Actions ----" -ForegroundColor Yellow
    if ($isRunning) {
        Write-Host "  [1] Stop tunnel" -ForegroundColor White
    } else {
        Write-Host "  [1] Start tunnel" -ForegroundColor White
    }
    Write-Host "  [2] Restart tunnel" -ForegroundColor White
    Write-Host "  [3] Toggle password auth" -ForegroundColor White
    Write-Host "  [4] Initial setup (first time)" -ForegroundColor White
    Write-Host "  [5] SSH to VPS" -ForegroundColor White
    Write-Host "  [6] Sync VPS scripts" -ForegroundColor White
    Write-Host "  [7] VPS setup guide" -ForegroundColor White
    Write-Host "  [q] Quit" -ForegroundColor White
    Write-Host ""
    $choice = Read-Host "  Select"

    switch ($choice) {
        "1" {
            if ($isRunning) {
                & (Join-Path $ScriptDir "tunnel-service.ps1") -Action stop
            } else {
                & (Join-Path $ScriptDir "tunnel-service.ps1") -Action start
            }
            Start-Sleep -Seconds 1
        }
        "2" {
            & (Join-Path $ScriptDir "tunnel-service.ps1") -Action restart
            Start-Sleep -Seconds 1
        }
        "3" {
            & (Join-Path $ScriptDir "win-password-auth.ps1")
            Start-Sleep -Seconds 1
        }
        "4" {
            Write-Host ""
            Write-Host "  [Step 1/2] Windows setup..." -ForegroundColor Yellow
            & (Join-Path $ScriptDir "windows-setup.ps1")
            Write-Host ""
            Write-Host "  [Step 2/2] Install tunnel service..." -ForegroundColor Yellow
            & (Join-Path $ScriptDir "install-tunnel-service.ps1")
            Read-Host "  Press Enter to continue"
        }
        "5" {
            & (Join-Path $ScriptDir "ssh-vps.ps1")
        }
        "6" {
            & (Join-Path $ScriptDir "sync-to-vps.ps1")
            Read-Host "  Press Enter to continue"
        }
        "7" {
            Show-VPSGuide
            Read-Host "  Press Enter to continue"
        }
        "q" { exit 0 }
        default { }
    }
}
