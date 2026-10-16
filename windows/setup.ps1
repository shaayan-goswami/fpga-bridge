<#
.SYNOPSIS
    One-time setup for the Windows machine that runs Vivado for fpga-bridge.

.DESCRIPTION
    1. Enables the OpenSSH server (installs it if needed, starts it, opens the firewall).
    2. Optionally authorizes your Mac's public key.
    3. Checks that Tailscale is connected.
    4. Finds the newest Vivado install.
    Then prints the `fpga-bridge init` command to run on your Mac.

    Run from an elevated (Administrator) PowerShell.

.PARAMETER PublicKey
    Contents of your Mac's public key, e.g. the output of `cat ~/.ssh/id_ed25519.pub`.
#>
[CmdletBinding()]
param(
    [string]$PublicKey
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "  [ok]   $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "  [warn] $msg" -ForegroundColor Yellow }

$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated PowerShell (Right-click > Run as administrator).'
}

# --- 1. OpenSSH server -------------------------------------------------------
Write-Step 'OpenSSH server'

# An sshd installed another way (winget, the Win32-OpenSSH installer) is just as good as the Windows feature.
if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
    $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
    if ($cap.State -ne 'Installed') {
        Write-Host '  Installing OpenSSH.Server (this can take a minute)...'
        try {
            Add-WindowsCapability -Online -Name $cap.Name | Out-Null
        } catch {
            Write-Warn2 "Windows could not install OpenSSH: $($_.Exception.Message)"
            Write-Host '  If it says the component store is corrupted, repair Windows and re-run:'
            Write-Host '    DISM /Online /Cleanup-Image /RestoreHealth'
            Write-Host '    sfc /scannow'
            Write-Host '  Or install OpenSSH another way and re-run: winget install Microsoft.OpenSSH.Beta'
            throw
        }
    }
}
Write-Ok 'OpenSSH server installed'

Set-Service -Name sshd -StartupType Automatic
if ((Get-Service sshd).Status -ne 'Running') { Start-Service sshd }
Write-Ok 'sshd is running and starts at boot'

if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
}
Write-Ok 'Firewall allows inbound SSH (port 22)'

# --- 2. Authorize the Mac's key ----------------------------------------------
if ($PublicKey) {
    Write-Step 'Authorizing your Mac'
    $PublicKey = $PublicKey.Trim()

    # Windows OpenSSH reads a different file for members of the Administrators group.
    $admins = @(Get-LocalGroupMember -SID 'S-1-5-32-544' | ForEach-Object { $_.Name.Split('\')[-1] })
    $isAdminUser = $admins -contains $env:USERNAME

    if ($isAdminUser) {
        $keyFile = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
    } else {
        $sshDir = Join-Path $env:USERPROFILE '.ssh'
        New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
        $keyFile = Join-Path $sshDir 'authorized_keys'
    }

    $existing = if (Test-Path $keyFile) { Get-Content $keyFile } else { @() }
    if ($existing -contains $PublicKey) {
        Write-Ok "Key already present in $keyFile"
    } else {
        Add-Content -Path $keyFile -Value $PublicKey -Encoding ascii
        Write-Ok "Key added to $keyFile"
    }

    if ($isAdminUser) {
        # sshd ignores this file unless only Administrators and SYSTEM can touch it.
        & icacls.exe $keyFile /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
    }
} else {
    Write-Step 'Authorizing your Mac'
    Write-Warn2 'No -PublicKey given. Re-run with -PublicKey "<contents of ~/.ssh/id_ed25519.pub>" (or add the key yourself).'
}

# --- 3. Tailscale -------------------------------------------------------------
Write-Step 'Tailscale'

$tsCmd = Get-Command tailscale.exe -ErrorAction SilentlyContinue
$tsPath = if ($tsCmd) { $tsCmd.Source } else { Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe' }
$tsHost = $null

if (-not (Test-Path $tsPath)) {
    Write-Warn2 'Tailscale not found. Install it from https://tailscale.com/download and sign in, then re-run.'
} else {
    try {
        $ts = & $tsPath status --json | ConvertFrom-Json
        if ($ts.BackendState -eq 'Running') {
            $tsHost = $ts.Self.DNSName.TrimEnd('.')
            if (-not $tsHost) { $tsHost = $ts.Self.TailscaleIPs[0] }
            Write-Ok "Connected as $tsHost ($($ts.Self.TailscaleIPs -join ', '))"
        } else {
            Write-Warn2 "Tailscale is installed but its state is '$($ts.BackendState)'. Open Tailscale and sign in."
        }
    } catch {
        Write-Warn2 "Could not read Tailscale status: $($_.Exception.Message)"
    }
}

# --- 4. Vivado ----------------------------------------------------------------
Write-Step 'Vivado'

$found = @()
if ($env:XILINX_VIVADO) {
    $candidate = Join-Path $env:XILINX_VIVADO 'bin\vivado.bat'
    if (Test-Path $candidate) { $found += $candidate }
}
$onPath = Get-Command vivado.bat -ErrorAction SilentlyContinue
if ($onPath) { $found += $onPath.Source }

$roots = Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Root }
foreach ($root in $roots) {
    # AMD renamed the install root over the years; check the known layouts.
    foreach ($base in 'Xilinx\Vivado', 'AMD\Vivado', 'Program Files\Xilinx\Vivado', 'Program Files\AMD\Vivado') {
        $dir = Join-Path $root $base
        if (Test-Path $dir) {
            $found += Get-ChildItem $dir -Directory -ErrorAction SilentlyContinue |
                ForEach-Object { Join-Path $_.FullName 'bin\vivado.bat' } |
                Where-Object { Test-Path $_ }
        }
    }
}

function Get-VivadoVersion($path) {
    # ...\Vivado\2023.2\bin\vivado.bat -> [version]'2023.2'
    $name = Split-Path (Split-Path (Split-Path $path -Parent) -Parent) -Leaf
    $v = $null
    if ([version]::TryParse($name, [ref]$v)) { return $v } else { return [version]'0.0' }
}

$found = @($found | Select-Object -Unique | Sort-Object { Get-VivadoVersion $_ } -Descending)
$vivado = $null
if ($found.Count -eq 0) {
    Write-Warn2 'No Vivado install found. Install Vivado, or pass its path to `fpga-bridge init --vivado` yourself.'
} else {
    $vivado = $found[0]
    Write-Ok "Using $vivado"
    if ($found.Count -gt 1) {
        Write-Host '  Other installs found:'
        $found | Select-Object -Skip 1 | ForEach-Object { Write-Host "    $_" }
    }
}

# --- Summary ------------------------------------------------------------------
Write-Step 'Next: run this on your Mac'

if ($tsHost -and $vivado) {
    Write-Host ''
    Write-Host "  fpga-bridge init --host $tsHost --user $env:USERNAME --vivado `"$vivado`"" -ForegroundColor White
    Write-Host '  fpga-bridge doctor'
    Write-Host ''
} else {
    Write-Warn2 'Fix the warnings above and re-run this script to get the init command.'
}
