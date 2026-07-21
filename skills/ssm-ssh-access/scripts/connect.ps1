# scripts/connect.ps1 — push an ephemeral SSH key to an EC2 instance over SSM and
# configure the SSH config so `ssh <instance-id>` works directly afterwards.
param(
    [Parameter(Mandatory=$true)][string]$InstanceId,
    [string]$Profile = "",
    [string]$Region = "",
    [string]$User = ""
)
. "$PSScriptRoot\lib\common.ps1"

Assert-SsmCli

Write-SsmLog "Checking AWS auth..."
Invoke-SsmAws $Profile @("sts","get-caller-identity") | Out-Null
if ($LASTEXITCODE -ne 0) { Write-SsmError "AWS auth failed. Check -Profile / AWS_PROFILE / your credential chain." }

Write-SsmLog "Checking instance $InstanceId is SSM-managed..."
$pingStatus = (Invoke-SsmAws $Profile @("ssm","describe-instance-information","--filters","Key=InstanceIds,Values=$InstanceId","--query","InstanceInformationList[0].PingStatus","--output","text") 2>$null)
if ($pingStatus -ne "Online") { Write-SsmError "Instance $InstanceId is not SSM-managed/online (got: $pingStatus). Check the SSM Agent and the instance's IAM role." }

$remoteUser = $User
if (-not $remoteUser) {
    Write-SsmLog "Discovering real login users on the instance via SSM (no guessing)..."
    $cmdId = Send-SsmShellCommand -Profile $Profile -InstanceId $InstanceId -Lines @('{ ls /home 2>/dev/null; echo root; } | sort -u')
    if (-not (Wait-SsmCommand -Profile $Profile -InstanceId $InstanceId -CommandId $cmdId)) { Write-SsmError "Failed to list remote users on $InstanceId." }
    $users = (Get-SsmCommandOutput -Profile $Profile -InstanceId $InstanceId -CommandId $cmdId) -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    if ($users.Count -eq 0) { Write-SsmError "No candidate users discovered on the instance." }
    Write-Host "Discovered users on ${InstanceId}:"
    for ($i = 0; $i -lt $users.Count; $i++) { Write-Host "  [$($i+1)] $($users[$i])" }
    $choice = Read-Host "Select the remote user to use (number)"
    $idx = [int]$choice - 1
    if ($idx -lt 0 -or $idx -ge $users.Count) { Write-SsmError "Invalid selection." }
    $remoteUser = $users[$idx]
}

$keyPath = Get-SsmKeyPath $InstanceId
$state = Import-SsmState $InstanceId
$reuse = $false
if ($state -and (Test-Path $keyPath) -and (Test-Path "$keyPath.pub")) {
    $reuse = $true
    $remoteUser = $state.REMOTE_USER
    Write-SsmLog "Reusing existing key for $InstanceId (previously pushed at $($state.PUSHED_AT) for user $remoteUser)."
} else {
    Write-SsmLog "Generating new ed25519 keypair for $InstanceId..."
    New-Item -ItemType Directory -Force -Path (Split-Path $keyPath) | Out-Null
    Remove-Item -Force -ErrorAction SilentlyContinue $keyPath, "$keyPath.pub"
    & ssh-keygen -t ed25519 -N '""' -f $keyPath -C "ssm-ssh-access-$InstanceId-$(Get-SsmTimestamp)" -q
}

$keyComment = ((Get-Content "$keyPath.pub") -split '\s+')[2]
$pubKeyContent = (Get-Content "$keyPath.pub" -Raw).Trim()

if (-not $reuse) {
    Write-SsmLog "Pushing public key to $InstanceId as $remoteUser..."
    $remoteLines = @(
        "U=`"$remoteUser`"",
        'HOME_DIR=$(getent passwd "$U" | cut -d: -f6)',
        'if [ -z "$HOME_DIR" ]; then HOME_DIR="/home/$U"; fi',
        'mkdir -p "$HOME_DIR/.ssh"',
        'touch "$HOME_DIR/.ssh/authorized_keys"',
        "grep -qF `"$keyComment`" `"`$HOME_DIR/.ssh/authorized_keys`" || echo `"$pubKeyContent`" >> `"`$HOME_DIR/.ssh/authorized_keys`"",
        'chmod 700 "$HOME_DIR/.ssh"',
        'chmod 600 "$HOME_DIR/.ssh/authorized_keys"',
        'chown -R "$U":"$U" "$HOME_DIR/.ssh" || true',
        'echo "PUSH_OK"'
    )
    $cmdId = Send-SsmShellCommand -Profile $Profile -InstanceId $InstanceId -Lines $remoteLines
    if (-not (Wait-SsmCommand -Profile $Profile -InstanceId $InstanceId -CommandId $cmdId)) { Write-SsmError "Failed to push public key to $InstanceId." }
    $out = Get-SsmCommandOutput -Profile $Profile -InstanceId $InstanceId -CommandId $cmdId
    if ($out -notmatch "PUSH_OK") { Write-SsmError "Key push did not confirm success. Output: $out" }
    Save-SsmState -InstanceId $InstanceId -RemoteUser $remoteUser -Profile $Profile -Region $Region -Comment $keyComment
}

Write-SsmLog "Configuring SSH config for $InstanceId..."
Update-SsmSshConfigBlock -InstanceId $InstanceId -RemoteUser $remoteUser -KeyPath $keyPath -Profile $Profile -Region $Region

Write-SsmLog "Ready. You can now run:"
Write-SsmLog "  ssh $InstanceId"
Write-SsmLog "  scp <file> ${InstanceId}:/path"
Write-SsmLog "Remember to run scripts/revoke.ps1 -InstanceId $InstanceId when you're done, if you don't want to reuse this key later."
