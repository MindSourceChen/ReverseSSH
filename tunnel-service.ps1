# ============================================================
# Manage Reverse SSH Tunnel Service
# Usage:
#   .\tunnel-service.ps1                (show status)
#   .\tunnel-service.ps1 -Action start  (start tunnel)
#   .\tunnel-service.ps1 -Action stop   (stop tunnel)
# Run PowerShell as Administrator
# ============================================================

param(
    [ValidateSet("start", "stop", "restart", "status")]
    [string]$Action = "status"
)

$TaskName = "ReverseSSHTunnel"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Show-Status {
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host " Reverse SSH Tunnel Status" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host ""

    # Config info
    $cfgFile = Join-Path $ScriptDir "vps-config.json"
    if (Test-Path $cfgFile) {
        $cfg = Get-Content $cfgFile -Raw | ConvertFrom-Json
        if ($cfg.VPS_IP) {
            Write-Host ("  VPS            : " + $cfg.VPS_IP + ":" + $cfg.VPS_SSH_PORT) -ForegroundColor White
        }
        $myPort = "2222"
        if ($cfg.PC_PORTS) {
            $p = $cfg.PC_PORTS.($env:COMPUTERNAME)
            if ($p) { $myPort = [string]$p }
        }
        Write-Host ("  This PC        : " + $env:COMPUTERNAME + " -> port " + $myPort) -ForegroundColor White
        if ($cfg.PC_PORTS) {
            $otherCount = ($cfg.PC_PORTS.PSObject.Properties | Measure-Object).Count
            if ($otherCount -gt 1) {
                Write-Host ("  Total PCs      : " + $otherCount) -ForegroundColor DarkGray
            }
        }
    }
    Write-Host ""

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
            Write-Host ("  SSH Process    : Running (PID: " + $p.Id + ")") -ForegroundColor Green
        }
    } else {
        Write-Host "  SSH Process    : Not Running" -ForegroundColor Red
    }

    # Keepalive Script (powershell running tunnel-keepalive.ps1)
    $keepaliveProc = Get-WmiObject Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine -like "*tunnel-keepalive*" }
    if ($keepaliveProc) {
        Write-Host ("  Keepalive Script: Running (PID: " + $keepaliveProc.ProcessId + ")") -ForegroundColor Green
    } else {
        Write-Host "  Keepalive Script: Not Running" -ForegroundColor Red
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
        Write-Host "  Last 5 log entries:" -ForegroundColor Cyan
        Get-Content $logFile -Tail 5 | ForEach-Object { Write-Host "    $_" }
    }

    Write-Host ""
}

if ($Action -eq "status") {
    Show-Status

    # Check if tunnel is running to show appropriate options
    $sshProc = Get-Process -Name "ssh" -ErrorAction SilentlyContinue
    $isRunning = $null -ne $sshProc

    if ($isRunning) {
        Write-Host "  [1] Stop tunnel" -ForegroundColor White
        Write-Host "  [2] Restart tunnel" -ForegroundColor White
    } else {
        Write-Host "  [1] Start tunnel" -ForegroundColor White
        Write-Host "  [2] Restart tunnel" -ForegroundColor White
    }
    Write-Host "  [q] Quit" -ForegroundColor White
    Write-Host ""
    $choice = Read-Host "  Select"

    if ($choice -eq "q" -or $choice -eq "") { exit 0 }

    # Check admin for operations
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "ERROR: This operation requires Administrator!" -ForegroundColor Red
        exit 1
    }

    if ($choice -eq "1") {
        if ($isRunning) { $Action = "stop" } else { $Action = "start" }
    } elseif ($choice -eq "2") {
        $Action = "restart"
    } else {
        exit 0
    }
}

if ($Action -eq "start") {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) {
        Write-Host "ERROR: Task not installed. Run install-tunnel-service.ps1 first." -ForegroundColor Red
        exit 1
    }
    # Kill existing ssh to let keepalive script restart cleanly
    Get-Process -Name "ssh" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 2
    Write-Host "Tunnel service started." -ForegroundColor Green
    Show-Status
}

if ($Action -eq "stop") {
    # Stop scheduled task
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task -and $task.State -eq "Running") {
        Stop-ScheduledTask -TaskName $TaskName
    }
    # Kill ssh processes
    Get-Process -Name "ssh" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 1
    Write-Host "Tunnel service stopped." -ForegroundColor Green
    Show-Status
}

if ($Action -eq "restart") {
    # Stop
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task -and $task.State -eq "Running") {
        Stop-ScheduledTask -TaskName $TaskName
    }
    Get-Process -Name "ssh" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 1
    # Start
    if (-not $task) {
        Write-Host "ERROR: Task not installed. Run install-tunnel-service.ps1 first." -ForegroundColor Red
        exit 1
    }
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 2
    Write-Host "Tunnel service restarted." -ForegroundColor Green
    Show-Status
}
