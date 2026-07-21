# scripts/status.ps1 — list instance-ids that currently have a live pushed key.
. "$PSScriptRoot\lib\common.ps1"

if (-not (Test-Path $Script:SsmSshRoot) -or -not (Get-ChildItem $Script:SsmSshRoot -ErrorAction SilentlyContinue)) {
    Write-Host "No ssm-ssh-access keys currently deployed."
    exit 0
}

"{0,-20} {1,-15} {2,-25}" -f "INSTANCE_ID", "REMOTE_USER", "PUSHED_AT" | Write-Host
Get-ChildItem $Script:SsmSshRoot -Directory | ForEach-Object {
    $state = Import-SsmState $_.Name
    if ($state) {
        "{0,-20} {1,-15} {2,-25}" -f $state.INSTANCE_ID, $state.REMOTE_USER, $state.PUSHED_AT | Write-Host
    }
}
