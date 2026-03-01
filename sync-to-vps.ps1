# ============================================================
# Sync VPS scripts from PC to VPS
# Usage: .\sync-to-vps.ps1 -VPS_IP "YOUR_VPS_IP"
# ============================================================

param(
    [string]$VPS_IP = "",
    [string]$VPS_USER = "root",
    [string]$VPS_SSH_PORT = "",
    [string]$REMOTE_DIR = "/root/reverse-ssh"
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigFile = Join-Path $ScriptDir "vps-config.json"
$MyPC = $env:COMPUTERNAME

# Load local config for VPS connection info
$saved = $null
if (Test-Path $ConfigFile) {
    $saved = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    if (-not $VPS_IP -and $saved.VPS_IP) { $VPS_IP = $saved.VPS_IP }
    if (-not $VPS_SSH_PORT -and $saved.VPS_SSH_PORT) { $VPS_SSH_PORT = [string]$saved.VPS_SSH_PORT }
}

# Prompt for missing values
if (-not $VPS_IP) {
    $VPS_IP = Read-Host "Please enter VPS IP address"
}
if (-not $VPS_SSH_PORT) {
    $VPS_SSH_PORT = Read-Host "Please enter VPS SSH port (default 22)"
    if (-not $VPS_SSH_PORT) { $VPS_SSH_PORT = "22" }
}
$VPS_SSH_PORT = [int]$VPS_SSH_PORT
$sshTarget = $VPS_USER + '@' + $VPS_IP

# ---- Step 0: Pull config from VPS (single source of truth) ----
Write-Host ""
Write-Host "[0] Pulling config from VPS..." -ForegroundColor Yellow
$remoteConfig = $REMOTE_DIR + '/vps-config.json'
$scpSrc = $VPS_USER + '@' + $VPS_IP + ':' + $remoteConfig
scp -P $VPS_SSH_PORT $scpSrc $ConfigFile 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "  Config pulled from VPS." -ForegroundColor Green
    $saved = Get-Content $ConfigFile -Raw | ConvertFrom-Json
} else {
    Write-Host "  No config on VPS yet (first sync)." -ForegroundColor DarkGray
}

# ---- PC-Port Mapping ----
$pcPorts = @{}
if ($saved -and $saved.PC_PORTS) {
    $saved.PC_PORTS.PSObject.Properties | ForEach-Object { $pcPorts[$_.Name] = [string]$_.Value }
}

# Show current mapping
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " PC-Port Mapping" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
if ($pcPorts.Count -eq 0) {
    Write-Host "  (empty - no PCs registered yet)" -ForegroundColor DarkGray
} else {
    foreach ($key in ($pcPorts.Keys | Sort-Object)) {
        $marker = ""
        if ($key -eq $MyPC) { $marker = " <-- this PC" }
        Write-Host ("  " + $key + " : " + $pcPorts[$key] + $marker) -ForegroundColor White
    }
}
Write-Host ""

# Register this PC if not in the mapping
if (-not $pcPorts.ContainsKey($MyPC)) {
    # Find next available port starting from 2222
    $usedPorts = @()
    if ($pcPorts.Count -gt 0) { $usedPorts = $pcPorts.Values | ForEach-Object { [int]$_ } }
    $newPort = 2222
    while ($usedPorts -contains $newPort) { $newPort++ }
    $pcPorts[$MyPC] = [string]$newPort
    Write-Host ("  New PC registered: " + $MyPC + " -> port " + $newPort) -ForegroundColor Green
} else {
    Write-Host ("  This PC [$MyPC] already registered -> port " + $pcPorts[$MyPC]) -ForegroundColor Green
}

# Build PC_PORTS object for JSON
$pcPortsObj = New-Object PSObject
foreach ($key in ($pcPorts.Keys | Sort-Object)) {
    $pcPortsObj | Add-Member -NotePropertyName $key -NotePropertyValue $pcPorts[$key]
}

# Save config
$config = @{ VPS_IP = $VPS_IP; VPS_SSH_PORT = $VPS_SSH_PORT; PC_PORTS = $pcPortsObj }
$config | ConvertTo-Json | Out-File -FilePath $ConfigFile -Encoding utf8
Write-Host ("  Config saved to " + $ConfigFile) -ForegroundColor DarkGray

$files = @(
    "vps-setup.sh",
    "vps-security.sh",
    "vps-config.json"
)

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " Sync VPS Scripts to Remote Server" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ("  Target: " + $sshTarget + ":" + $REMOTE_DIR) -ForegroundColor White
Write-Host ("  Port: " + $VPS_SSH_PORT) -ForegroundColor White
Write-Host ""

# ---------- 1. Upload files ----------
Write-Host "[1/2] Uploading files (enter password)..." -ForegroundColor Yellow

$localPaths = @()
foreach ($file in $files) {
    $localPath = Join-Path $ScriptDir $file
    if (Test-Path $localPath) {
        $localPaths += $localPath
    }
    else {
        Write-Host ("  Skip " + $file + " (not found locally)") -ForegroundColor DarkYellow
    }
}

# scp all files in one command: scp -P port file1 file2 file3 user@host:dir/
$scpDest = $VPS_USER + '@' + $VPS_IP + ':' + $REMOTE_DIR + '/'
$scpArgs = @("-P", $VPS_SSH_PORT) + $localPaths + @($scpDest)
scp @scpArgs

if ($LASTEXITCODE -ne 0) {
    Write-Host "  Upload failed. Check IP, port, and password." -ForegroundColor Red
    exit 1
}
$successCount = $localPaths.Count
Write-Host ("  Uploaded " + $successCount + " files.") -ForegroundColor Green

# ---------- 2. Set permissions and fix line endings (single ssh call, one password prompt) ----------
Write-Host ""
Write-Host "[2/2] Setting permissions and fixing line endings (enter password)..." -ForegroundColor Yellow

$remoteCmd = "mkdir -p " + $REMOTE_DIR + "; apt-get install -y dos2unix"
foreach ($file in $files) {
    $remotePath = $REMOTE_DIR + '/' + $file
    $remoteCmd += "; dos2unix " + $remotePath + "; chmod +x " + $remotePath
}
ssh -p $VPS_SSH_PORT $sshTarget $remoteCmd

if ($LASTEXITCODE -eq 0) {
    Write-Host "  Permissions set." -ForegroundColor Green
}
else {
    Write-Host "  Failed. Run chmod +x and dos2unix manually on VPS." -ForegroundColor Red
}

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
$doneMsg = " Done! (" + $successCount + "/" + $files.Count + " files)"
Write-Host $doneMsg -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host ("Files on VPS: " + $REMOTE_DIR + "/") -ForegroundColor White
Write-Host "  - vps-setup.sh       (base setup)" -ForegroundColor White
Write-Host "  - vps-security.sh    (security hardening)" -ForegroundColor White
Write-Host ""
Write-Host "  PC-Port mapping:" -ForegroundColor Yellow
foreach ($key in ($pcPorts.Keys | Sort-Object)) {
    $marker = ""
    if ($key -eq $MyPC) { $marker = " <-- this PC" }
    Write-Host ("    " + $key + " -> port " + $pcPorts[$key] + $marker) -ForegroundColor White
}
Write-Host ""
Write-Host "Run on VPS:" -ForegroundColor Yellow
Write-Host ("  cd " + $REMOTE_DIR) -ForegroundColor White
Write-Host "  sudo ./vps-setup.sh" -ForegroundColor White
Write-Host "  sudo ./vps-security.sh    # optional" -ForegroundColor White
Write-Host ""
