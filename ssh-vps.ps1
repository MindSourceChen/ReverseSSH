# ============================================================
# Quick SSH to VPS
# Usage: .\ssh-vps.ps1
# ============================================================

param(
    [string]$VPS_IP = "",
    [string]$VPS_USER = "root",
    [string]$VPS_SSH_PORT = ""
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigFile = Join-Path $ScriptDir "vps-config.json"

if (Test-Path $ConfigFile) {
    $saved = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    if (-not $VPS_IP -and $saved.VPS_IP) { $VPS_IP = $saved.VPS_IP }
    if (-not $VPS_SSH_PORT -and $saved.VPS_SSH_PORT) { $VPS_SSH_PORT = [string]$saved.VPS_SSH_PORT }
}
if (-not $VPS_IP) {
    Write-Host "ERROR: VPS_IP not found. Run sync-to-vps.ps1 first." -ForegroundColor Red
    exit 1
}
if (-not $VPS_SSH_PORT) { $VPS_SSH_PORT = "22" }

$sshTarget = $VPS_USER + '@' + $VPS_IP
Write-Host ("Connecting to " + $sshTarget + " port " + $VPS_SSH_PORT + " ...") -ForegroundColor Cyan
ssh -p $VPS_SSH_PORT $sshTarget
