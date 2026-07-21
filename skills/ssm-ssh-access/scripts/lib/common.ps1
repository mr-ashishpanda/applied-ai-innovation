# scripts/lib/common.ps1 — shared helpers for the ssm-ssh-access skill (Windows)

$Script:SsmSshRoot = Join-Path $env:USERPROFILE ".ssh\ssm-ssh-access"

function Write-SsmLog {
    param([string]$Message)
    Write-Host "[ssm-ssh-access] $Message"
}

function Write-SsmError {
    param([string]$Message)
    Write-Host "[ssm-ssh-access] ERROR: $Message"
    exit 1
}

function Assert-SsmCli {
    $missing = @()
    if (-not (Get-Command aws -ErrorAction SilentlyContinue)) { $missing += "aws (AWS CLI v2)" }
    if (-not (Get-Command session-manager-plugin -ErrorAction SilentlyContinue)) { $missing += "session-manager-plugin" }
    if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) { $missing += "ssh-keygen (OpenSSH Client)" }
    if ($missing.Count -gt 0) {
        Write-SsmLog "Missing required tools:"
        $missing | ForEach-Object { Write-SsmLog "  - $_" }
        Write-SsmError "Run scripts/install-plugin.ps1 first, then retry."
    }
}

function Get-SsmInstanceDir { param([string]$InstanceId) Join-Path $Script:SsmSshRoot $InstanceId }
function Get-SsmStateFile   { param([string]$InstanceId) Join-Path (Get-SsmInstanceDir $InstanceId) "state.env" }
function Get-SsmKeyPath     { param([string]$InstanceId) Join-Path (Get-SsmInstanceDir $InstanceId) "id_ed25519" }

function Get-SsmTimestamp { [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ") }

function Import-SsmState {
    param([string]$InstanceId)
    $f = Get-SsmStateFile $InstanceId
    if (-not (Test-Path $f)) { return $null }
    $state = @{}
    Get-Content $f | ForEach-Object {
        if ($_ -match '^([A-Z_]+)=(.*)$') { $state[$matches[1]] = $matches[2] }
    }
    return $state
}

function Save-SsmState {
    param([string]$InstanceId, [string]$RemoteUser, [string]$Profile, [string]$Region, [string]$Comment)
    $dir = Get-SsmInstanceDir $InstanceId
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $f = Get-SsmStateFile $InstanceId
    @(
        "INSTANCE_ID=$InstanceId"
        "REMOTE_USER=$RemoteUser"
        "PROFILE=$Profile"
        "REGION=$Region"
        "KEY_COMMENT=$Comment"
        "PUSHED_AT=$(Get-SsmTimestamp)"
    ) | Set-Content -Path $f -Encoding UTF8
}

function Invoke-SsmAws {
    param([string]$Profile, [string[]]$Arguments)
    if ($Profile) {
        & aws --profile $Profile @Arguments
    } else {
        & aws @Arguments
    }
}

function Send-SsmShellCommand {
    param([string]$Profile, [string]$InstanceId, [string[]]$Lines)
    # .Replace() (not -replace) is used deliberately: it's a literal string replace,
    # so there's no regex-escaping ambiguity around doubling backslashes.
    $escaped = $Lines | ForEach-Object { '"' + $_.Replace('\', '\\').Replace('"', '\"') + '"' }
    $json = '{"commands":[' + ($escaped -join ',') + ']}'
    $tmp = New-TemporaryFile
    Set-Content -Path $tmp -Value $json -Encoding UTF8 -NoNewline
    $cmdId = Invoke-SsmAws $Profile @("ssm","send-command","--instance-ids",$InstanceId,"--document-name","AWS-RunShellScript","--parameters","file://$tmp","--query","Command.CommandId","--output","text")
    Remove-Item $tmp -Force
    return $cmdId.Trim()
}

function Wait-SsmCommand {
    param([string]$Profile, [string]$InstanceId, [string]$CommandId)
    for ($i = 0; $i -lt 30; $i++) {
        $status = (Invoke-SsmAws $Profile @("ssm","get-command-invocation","--instance-id",$InstanceId,"--command-id",$CommandId,"--query","Status","--output","text") 2>$null)
        if ($status -eq "Success") { return $true }
        if ($status -in @("Failed","Cancelled","TimedOut")) { return $false }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Get-SsmCommandOutput {
    param([string]$Profile, [string]$InstanceId, [string]$CommandId)
    Invoke-SsmAws $Profile @("ssm","get-command-invocation","--instance-id",$InstanceId,"--command-id",$CommandId,"--query","StandardOutputContent","--output","text")
}

function Get-SsmSshConfigPath { Join-Path $env:USERPROFILE ".ssh\config" }

function Remove-SsmSshConfigBlock {
    param([string]$InstanceId)
    $cfg = Get-SsmSshConfigPath
    if (-not (Test-Path $cfg)) { return }
    $lines = Get-Content $cfg
    $out = @()
    $skip = $false
    foreach ($line in $lines) {
        if ($line -eq "# BEGIN ssm-ssh-access $InstanceId") { $skip = $true; continue }
        if ($line -eq "# END ssm-ssh-access $InstanceId") { $skip = $false; continue }
        if (-not $skip) { $out += $line }
    }
    Set-Content -Path $cfg -Value $out -Encoding UTF8
}

function Update-SsmSshConfigBlock {
    param([string]$InstanceId, [string]$RemoteUser, [string]$KeyPath, [string]$Profile, [string]$Region)
    $cfg = Get-SsmSshConfigPath
    New-Item -ItemType Directory -Force -Path (Split-Path $cfg) | Out-Null
    if (-not (Test-Path $cfg)) { New-Item -ItemType File -Path $cfg | Out-Null }
    Remove-SsmSshConfigBlock -InstanceId $InstanceId
    $proxy = "aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p"
    if ($Profile) { $proxy += " --profile $Profile" }
    if ($Region) { $proxy += " --region $Region" }
    @(
        "# BEGIN ssm-ssh-access $InstanceId"
        "Host $InstanceId"
        "  User $RemoteUser"
        "  IdentityFile $KeyPath"
        "  ProxyCommand $proxy"
        "  StrictHostKeyChecking accept-new"
        "# END ssm-ssh-access $InstanceId"
    ) | Add-Content -Path $cfg -Encoding UTF8
}
