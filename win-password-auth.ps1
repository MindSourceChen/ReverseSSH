# ============================================================
# Toggle Windows OpenSSH Password Authentication
# Run PowerShell as Administrator
# ============================================================

# Check admin privileges
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: Please run this script as Administrator!" -ForegroundColor Red
    exit 1
}

$SshdConfig = "C:\ProgramData\ssh\sshd_config"

if (-not (Test-Path $SshdConfig)) {
    Write-Host "ERROR: sshd_config not found at $SshdConfig" -ForegroundColor Red
    exit 1
}

# Read current status
$content = Get-Content $SshdConfig -Raw
$currentMatch = [regex]::Match($content, '(?m)^#?\s*PasswordAuthentication\s+(yes|no)')
if ($currentMatch.Success) {
    $line = $currentMatch.Value.Trim()
    if ($line.StartsWith("#") -or $line -match "yes") {
        $currentStatus = "enabled"
    } else {
        $currentStatus = "disabled"
    }
} else {
    $currentStatus = "enabled (default)"
}

# Show current status
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " Windows OpenSSH Password Authentication" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""
if ($currentStatus -like "enabled*") {
    Write-Host "  Current Status: ENABLED" -ForegroundColor Green
} else {
    Write-Host "  Current Status: DISABLED" -ForegroundColor Yellow
}
Write-Host ""

# Ask user what to do
if ($currentStatus -like "enabled*") {
    $choice = Read-Host "  Disable password authentication? (y/n)"
    if ($choice -eq "y" -or $choice -eq "Y") {
        $newContent = $content -replace '(?m)^#?\s*PasswordAuthentication\s+(yes|no)', 'PasswordAuthentication no'
        Set-Content -Path $SshdConfig -Value $newContent -NoNewline
        Restart-Service sshd
        Write-Host ""
        Write-Host "  Password authentication DISABLED. Only key-based login allowed." -ForegroundColor Green
    } else {
        Write-Host "  No changes made." -ForegroundColor White
    }
} else {
    $choice = Read-Host "  Enable password authentication? (y/n)"
    if ($choice -eq "y" -or $choice -eq "Y") {
        $newContent = $content -replace '(?m)^#?\s*PasswordAuthentication\s+(yes|no)', 'PasswordAuthentication yes'
        Set-Content -Path $SshdConfig -Value $newContent -NoNewline
        Restart-Service sshd
        Write-Host ""
        Write-Host "  Password authentication ENABLED." -ForegroundColor Green
    } else {
        Write-Host "  No changes made." -ForegroundColor White
    }
}

Write-Host ""
