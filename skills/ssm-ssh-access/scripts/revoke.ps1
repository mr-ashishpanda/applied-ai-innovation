# scripts/revoke.ps1 — remove a previously-pushed key from the instance and clean up locally.
param(
    [Parameter(Mandatory=$true)][string]$InstanceId,
    [string]$Profile = ""
)
. "$PSScriptRoot\lib\common.ps1"

Assert-SsmCli

$state = Import-SsmState $InstanceId
if (-not $state) {
    Write-SsmLog "No local state for $InstanceId; nothing to revoke remotely. Cleaning up any leftover local files/config anyway."
} else {
    $effectiveProfile = if ($Profile) { $Profile } else { $state.PROFILE }
    Write-SsmLog "Removing pushed key ($($state.KEY_COMMENT)) from $InstanceId as $($state.REMOTE_USER)..."
    $remoteLines = @(
        "U=`"$($state.REMOTE_USER)`"",
        'HOME_DIR=$(getent passwd "$U" | cut -d: -f6)',
        'if [ -z "$HOME_DIR" ]; then HOME_DIR="/home/$U"; fi',
        'if [ -f "$HOME_DIR/.ssh/authorized_keys" ]; then',
        "  grep -vF `"$($state.KEY_COMMENT)`" `"`$HOME_DIR/.ssh/authorized_keys`" > `"`$HOME_DIR/.ssh/authorized_keys.tmp`" || true",
        '  mv "$HOME_DIR/.ssh/authorized_keys.tmp" "$HOME_DIR/.ssh/authorized_keys"',
        'fi',
        'echo "REVOKE_OK"'
    )
    $cmdId = Send-SsmShellCommand -Profile $effectiveProfile -InstanceId $InstanceId -Lines $remoteLines
    if (Wait-SsmCommand -Profile $effectiveProfile -InstanceId $InstanceId -CommandId $cmdId) {
        $out = Get-SsmCommandOutput -Profile $effectiveProfile -InstanceId $InstanceId -CommandId $cmdId
        if ($out -match "REVOKE_OK") { Write-SsmLog "Remote key removed." } else { Write-SsmLog "WARNING: remote cleanup output unexpected: $out" }
    } else {
        Write-SsmLog "WARNING: could not confirm remote key removal (instance may be unreachable). Local cleanup will continue."
    }
}

Write-SsmLog "Removing local key material and state for $InstanceId..."
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue (Get-SsmInstanceDir $InstanceId)

Write-SsmLog "Removing SSH config block for $InstanceId..."
Remove-SsmSshConfigBlock -InstanceId $InstanceId

Write-SsmLog "Done. $InstanceId has been fully revoked."
