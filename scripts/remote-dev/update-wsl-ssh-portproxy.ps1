[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Distro,
    [int] $ListenPort = 2222,
    [int] $ConnectPort = 22,
    [string] $RuleName = "WSL SSH via Tailscale"
)

$ErrorActionPreference = "Stop"

function Test-Administrator {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = [Security.Principal.WindowsPrincipal] $Identity
    return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-ProcessArgument {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Value
    )

    $Text = [string] $Value
    if ($Text -notmatch '[\s"]') {
        return $Text
    }

    return '"' + ($Text -replace '"', '\"') + '"'
}

function Start-ElevatedSelf {
    $ScriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
    $Arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", (ConvertTo-ProcessArgument $ScriptPath),
        "-Distro", (ConvertTo-ProcessArgument $Distro),
        "-ListenPort", $ListenPort,
        "-ConnectPort", $ConnectPort,
        "-RuleName", (ConvertTo-ProcessArgument $RuleName)
    )

    Write-Host "Requesting Administrator permission to update netsh portproxy and Windows Firewall rules..."
    $Process = Start-Process -FilePath "powershell.exe" -ArgumentList ($Arguments -join " ") -Verb RunAs -Wait -PassThru

    if ($Process.ExitCode -ne 0) {
        throw "Elevated PowerShell exited with code $($Process.ExitCode)."
    }
}

if (-not (Test-Administrator)) {
    Start-ElevatedSelf
    return
}

function Invoke-WslQuiet {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )

    # Windows PowerShell treats native stderr as an error when ErrorActionPreference is Stop.
    # WSL can print non-fatal localhost/NAT warnings to stderr, so suppress stderr only here
    # and use the native exit code to detect real failures.
    $PreviousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $Output = & wsl.exe @Arguments 2>$null
        $ExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $PreviousErrorActionPreference
    }

    if ($ExitCode -ne 0) {
        throw ("wsl.exe failed with exit code {0}: wsl.exe {1}" -f $ExitCode, ($Arguments -join " "))
    }

    return $Output
}

$WslDistros = @(
    Invoke-WslQuiet -Arguments @("-l", "-q") |
        ForEach-Object { ($_ -replace "`0", "").Trim() } |
        Where-Object { $_ }
)

if ($WslDistros -notcontains $Distro) {
    throw "Cannot find WSL distro '$Distro'. Run 'wsl -l -v' and pass the exact name with -Distro. Found: $($WslDistros -join ', ')"
}

$TailscaleExe = @(
    "$env:ProgramFiles\Tailscale\tailscale.exe",
    "${env:ProgramFiles(x86)}\Tailscale\tailscale.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $TailscaleExe) {
    throw "Cannot find tailscale.exe. Install Tailscale from https://tailscale.com/download/windows first."
}

$WslIpOutput = Invoke-WslQuiet -Arguments @("-d", $Distro, "--", "hostname", "-I")
$WslIp = ($WslIpOutput -split "\s+" |
    Where-Object { $_ -match "^\d{1,3}(\.\d{1,3}){3}$" } |
    Select-Object -First 1)

if (-not $WslIp) {
    $WslIpOutput = Invoke-WslQuiet -Arguments @("-d", $Distro, "--", "sh", "-lc", "ip -4 -o addr show eth0 scope global | awk '{print `$4}' | cut -d/ -f1")
    $WslIp = ($WslIpOutput -split "\s+" |
        Where-Object { $_ -match "^\d{1,3}(\.\d{1,3}){3}$" } |
        Select-Object -First 1)
}

$TailscaleIp = (& $TailscaleExe ip -4).Trim()

if (-not $WslIp) {
    throw "Cannot detect WSL IP. Try: wsl -d $Distro -- hostname -I"
}

if (-not $TailscaleIp) {
    throw "Cannot detect Tailscale IPv4"
}

netsh interface portproxy delete v4tov4 listenaddress=$TailscaleIp listenport=$ListenPort *> $null
netsh interface portproxy add v4tov4 listenaddress=$TailscaleIp listenport=$ListenPort connectaddress=$WslIp connectport=$ConnectPort

$ExistingRule = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue

if ($ExistingRule) {
    $ExistingRule | Remove-NetFirewallRule
}

New-NetFirewallRule `
    -DisplayName $RuleName `
    -Direction Inbound `
    -Action Allow `
    -Protocol TCP `
    -LocalAddress $TailscaleIp `
    -LocalPort $ListenPort

Write-Host "Forwarding $TailscaleIp`:$ListenPort -> $WslIp`:$ConnectPort"
