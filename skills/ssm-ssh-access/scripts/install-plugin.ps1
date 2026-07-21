# scripts/install-plugin.ps1 — install the AWS Session Manager plugin (Windows)
. "$PSScriptRoot\lib\common.ps1"

if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    Write-SsmError "AWS CLI v2 not found. Install it first: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
}

if (Get-Command session-manager-plugin -ErrorAction SilentlyContinue) {
    Write-SsmLog "session-manager-plugin already installed."
    exit 0
}

Write-SsmLog "Downloading the official Session Manager plugin installer..."
$installer = Join-Path $env:TEMP "SessionManagerPluginSetup.exe"
Invoke-WebRequest -Uri "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/windows/SessionManagerPluginSetup.exe" -OutFile $installer
Start-Process -FilePath $installer -ArgumentList "/quiet" -Wait
Remove-Item $installer -Force

if (-not (Get-Command session-manager-plugin -ErrorAction SilentlyContinue)) {
    Write-SsmError "Install finished but session-manager-plugin is still not on PATH. Open a new PowerShell window and retry."
}
Write-SsmLog "Installed session-manager-plugin."
