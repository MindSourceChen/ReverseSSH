# ============================================================
# Windows 11 Setup Script (Run PowerShell as Administrator)
# Installs OpenSSH, generates keys, uploads pubkey to VPS
# ============================================================

param(
    [string]$VPS_IP = "",
    [string]$VPS_USER = "tunnel",
    [string]$VPS_SSH_PORT = "",
    [int]$REMOTE_PORT = 0,
    [int]$LOCAL_PORT = 22
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigFile = Join-Path $ScriptDir "vps-config.json"

if (Test-Path $ConfigFile) {
    $saved = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    if (-not $VPS_IP -and $saved.VPS_IP) { $VPS_IP = $saved.VPS_IP }
    if (-not $VPS_SSH_PORT -and $saved.VPS_SSH_PORT) { $VPS_SSH_PORT = [string]$saved.VPS_SSH_PORT }
    if ($REMOTE_PORT -eq 0 -and $saved.PC_PORTS) {
        $myPort = $saved.PC_PORTS.($env:COMPUTERNAME)
        if ($myPort) { $REMOTE_PORT = [int]$myPort }
    }
}
if ($REMOTE_PORT -eq 0) { $REMOTE_PORT = 2222 }
if (-not $VPS_IP) {
    Write-Host "ERROR: VPS_IP not found. Run sync-to-vps.ps1 first or pass -VPS_IP." -ForegroundColor Red
    exit 1
}
if (-not $VPS_SSH_PORT) { $VPS_SSH_PORT = "22" }
$VPS_SSH_PORT = [int]$VPS_SSH_PORT

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " Reverse SSH Tunnel - Windows 11 Setup" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# Check admin privileges
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: This script requires Administrator privileges." -ForegroundColor Red
    Write-Host "  Right-click PowerShell -> Run as Administrator" -ForegroundColor Yellow
    exit 1
}

# ---------- 1. Install OpenSSH ----------
Write-Host ""
Write-Host "[1/6] Checking and installing OpenSSH..." -ForegroundColor Yellow

$clientCapability = Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Client*'
if ($clientCapability.State -ne 'Installed') {
    Write-Host "  Installing OpenSSH Client..."
    Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
}
else {
    Write-Host "  OpenSSH Client already installed."
}

$serverCapability = Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Server*'
if ($serverCapability.State -ne 'Installed') {
    Write-Host "  Installing OpenSSH Server..."
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
}
else {
    Write-Host "  OpenSSH Server already installed."
}

# ---------- 2. Configure and start SSH service ----------
Write-Host ""
Write-Host "[2/6] Configuring SSH service..." -ForegroundColor Yellow

Start-Service sshd -ErrorAction SilentlyContinue
try {
    Set-Service -Name sshd -StartupType Automatic -ErrorAction Stop
    Write-Host "  SSH service started and set to automatic."
}
catch {
    Write-Host ("  ERROR: " + $_.Exception.Message) -ForegroundColor Red
    Write-Host "  Please run this script as Administrator." -ForegroundColor Red
    exit 1
}

$rule = Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
if (-not $rule) {
    New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH Server (sshd)" -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
    Write-Host "  Firewall rule added."
}
else {
    Write-Host "  Firewall rule already exists."
}

# Set default shell to PowerShell for SSH connections (e.g. iPhone Terminus)
$currentShell = (Get-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -ErrorAction SilentlyContinue).DefaultShell
if ($currentShell -ne "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe") {
    New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -PropertyType String -Force | Out-Null
    Write-Host "  Default SSH shell set to PowerShell." -ForegroundColor Green
}
else {
    Write-Host "  Default SSH shell already set to PowerShell."
}

# Default to key-based login for Windows OpenSSH
$sshdConfigPath = "C:\ProgramData\ssh\sshd_config"
if (Test-Path $sshdConfigPath) {
    $sshdContent = Get-Content $sshdConfigPath -Raw
    if ($sshdContent -match '(?m)^#?\s*PasswordAuthentication\s+(yes|no)') {
        $sshdContent = $sshdContent -replace '(?m)^#?\s*PasswordAuthentication\s+(yes|no)', 'PasswordAuthentication no'
    }
    else {
        $sshdContent += "`r`nPasswordAuthentication no"
    }

    if ($sshdContent -match '(?m)^#?\s*PubkeyAuthentication\s+(yes|no)') {
        $sshdContent = $sshdContent -replace '(?m)^#?\s*PubkeyAuthentication\s+(yes|no)', 'PubkeyAuthentication yes'
    }
    else {
        $sshdContent += "`r`nPubkeyAuthentication yes"
    }

    Set-Content -Path $sshdConfigPath -Value $sshdContent -NoNewline
    Restart-Service sshd -ErrorAction SilentlyContinue
    Write-Host "  OpenSSH auth defaulted to key-based login." -ForegroundColor Green
}
else {
    Write-Host "  WARN: sshd_config not found, skip key-based auth defaults." -ForegroundColor Yellow
}

# ---------- 3. Generate SSH key pair ----------
Write-Host ""
Write-Host "[3/6] Generating SSH key pair..." -ForegroundColor Yellow

$keyPath = Join-Path $env:USERPROFILE ".ssh\id_ed25519_tunnel"

if (-not (Test-Path $keyPath)) {
    $sshDir = Join-Path $env:USERPROFILE ".ssh"
    if (-not (Test-Path $sshDir)) {
        New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    }
    ssh-keygen -t ed25519 -f $keyPath -N '""' -C ("reverse-tunnel-" + $env:COMPUTERNAME)
    Write-Host ("  Key generated: " + $keyPath)
}
else {
    Write-Host ("  Key already exists: " + $keyPath)
}

# ---------- 4. Upload public key to VPS ----------
Write-Host ""
Write-Host "[4/6] Uploading public key to VPS..." -ForegroundColor Yellow
Write-Host "  Enter password for root:" -ForegroundColor White

$pubKeyContent = Get-Content ($keyPath + ".pub")
$uploadTarget = 'root@' + $VPS_IP
$tunnelHome = '/home/' + $VPS_USER
$sshCmd = "mkdir -p " + $tunnelHome + "/.ssh; grep -qF '" + $pubKeyContent + "' " + $tunnelHome + "/.ssh/authorized_keys 2>/dev/null || echo '" + $pubKeyContent + "' >> " + $tunnelHome + "/.ssh/authorized_keys; chmod 600 " + $tunnelHome + "/.ssh/authorized_keys; chown -R " + $VPS_USER + ":" + $VPS_USER + " " + $tunnelHome + "/.ssh"
ssh -p $VPS_SSH_PORT $uploadTarget $sshCmd

if ($LASTEXITCODE -eq 0) {
    Write-Host "  Public key uploaded." -ForegroundColor Green
}
else {
    Write-Host "  Upload failed. Manually copy the key below to VPS:" -ForegroundColor Red
    Write-Host ("  " + $pubKeyContent) -ForegroundColor White
    Write-Host ("  Add to /home/" + $VPS_USER + "/.ssh/authorized_keys (via root)") -ForegroundColor White
}

# ---------- 5. Add iPhone public key to admin authorized_keys ----------
Write-Host ""
Write-Host "[5/6] Configure iPhone SSH public key..." -ForegroundColor Yellow
Write-Host "  Enter 'y' or paste the public key directly (N to skip):" -ForegroundColor White
# Disable bracketed paste mode so pasted text won't show ^[[200~ in terminal
[Console]::Write("$([char]27)[?2004l")
$addIphoneKey = Read-Host "  "
[Console]::Write("$([char]27)[?2004h")
# Strip any remaining escape sequences as fallback
$addIphoneKey = $addIphoneKey -replace '\x1b\[\d*~', '' -replace '\x1b\[[\d;]*[A-Za-z]', ''
$addIphoneKey = $addIphoneKey.Trim()

# If user pasted the key directly, use it; if 'y', ask for it next
$iphonePubKey = $null
if ($addIphoneKey -match '^ssh-(ed25519|rsa|ecdsa)\s+\S+') {
    $iphonePubKey = $addIphoneKey
}
elseif ($addIphoneKey -eq 'y' -or $addIphoneKey -eq 'Y') {
    Write-Host "  Paste the iPhone public key below (one line, e.g. ssh-ed25519 AAAA... or ssh-rsa AAAA...):" -ForegroundColor White
    [Console]::Write("$([char]27)[?2004l")
    $iphonePubKey = Read-Host "  "
    [Console]::Write("$([char]27)[?2004h")
    $iphonePubKey = $iphonePubKey -replace '\x1b\[\d*~', '' -replace '\x1b\[[\d;]*[A-Za-z]', ''
    $iphonePubKey = $iphonePubKey.Trim()
}

if ($iphonePubKey -and $iphonePubKey -match '^ssh-(ed25519|rsa|ecdsa)\s+\S+') {
    $adminAuthKeysFile = "C:\ProgramData\ssh\administrators_authorized_keys"
    $sshProgramData = "C:\ProgramData\ssh"

    # Ensure directory exists
    if (-not (Test-Path $sshProgramData)) {
        New-Item -ItemType Directory -Path $sshProgramData -Force | Out-Null
    }

    # Check if key already exists
    $keyExists = $false
    if (Test-Path $adminAuthKeysFile) {
        $existingKeys = Get-Content $adminAuthKeysFile -ErrorAction SilentlyContinue
        if ($existingKeys -contains $iphonePubKey) {
            $keyExists = $true
        }
    }

    if ($keyExists) {
        Write-Host "  iPhone public key already exists in administrators_authorized_keys." -ForegroundColor Green
    }
    else {
        # Append the key
        Add-Content -Path $adminAuthKeysFile -Value $iphonePubKey -Encoding UTF8
        Write-Host "  iPhone public key added to $adminAuthKeysFile" -ForegroundColor Green
    }

    # Fix ACL: only SYSTEM and Administrators should have access
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)  # Disable inheritance
    $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "BUILTIN\Administrators", "FullControl", "Allow")
    $systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "NT AUTHORITY\SYSTEM", "FullControl", "Allow")
    $acl.AddAccessRule($adminRule)
    $acl.AddAccessRule($systemRule)
    Set-Acl -Path $adminAuthKeysFile -AclObject $acl
    Write-Host "  ACL permissions set (SYSTEM + Administrators only)." -ForegroundColor Green
}
elseif ($addIphoneKey -eq 'y' -or $addIphoneKey -eq 'Y') {
    Write-Host "  Invalid public key format. Skipping." -ForegroundColor Red
    Write-Host "  Expected format: ssh-ed25519 AAAA... or ssh-rsa AAAA..." -ForegroundColor Yellow
}
else {
    Write-Host "  Skipped iPhone public key configuration." -ForegroundColor Gray
}

# ---------- 6. Show test command ----------
Write-Host ""
Write-Host "[6/6] Setup complete." -ForegroundColor Yellow
Write-Host ("  Tunnel: localhost:" + $LOCAL_PORT + " -> VPS:" + $REMOTE_PORT) -ForegroundColor White

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " Windows Setup Complete!" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""
$tunnelTarget = $VPS_USER + '@' + $VPS_IP
$testCmd = "  ssh -i " + $keyPath + " -N -R " + $REMOTE_PORT + ":localhost:" + $LOCAL_PORT + " -p " + $VPS_SSH_PORT + " " + $tunnelTarget
Write-Host "Manual test command:" -ForegroundColor White
Write-Host $testCmd -ForegroundColor White
Write-Host ""
Write-Host "Next: run install-tunnel-service.ps1 to install as a service." -ForegroundColor White
Write-Host ""
