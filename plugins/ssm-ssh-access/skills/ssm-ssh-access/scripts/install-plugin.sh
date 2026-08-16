#!/usr/bin/env bash
# scripts/install-plugin.sh — install the AWS Session Manager plugin (macOS/Linux)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

command -v aws >/dev/null 2>&1 || ssm_die "AWS CLI v2 not found. Install it first: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"

if command -v session-manager-plugin >/dev/null 2>&1; then
  ssm_log "session-manager-plugin already installed: $(session-manager-plugin --version 2>&1 | head -1)"
  exit 0
fi

OS="$(uname -s)"
case "$OS" in
  Darwin)
    if command -v brew >/dev/null 2>&1; then
      ssm_log "Installing session-manager-plugin via Homebrew..."
      brew install --cask session-manager-plugin
    else
      ssm_log "Homebrew not found; downloading the official .pkg..."
      TMP_PKG="$(mktemp -d)/sessionmanager-bundle.zip"
      curl -sSL "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/mac/sessionmanager-bundle.zip" -o "$TMP_PKG"
      UNZIP_DIR="$(dirname "$TMP_PKG")/bundle"
      unzip -q "$TMP_PKG" -d "$UNZIP_DIR"
      sudo "${UNZIP_DIR}/sessionmanager-bundle/install" -i /usr/local/sessionmanagerplugin -b /usr/local/bin/session-manager-plugin
    fi
    ;;
  Linux)
    if command -v apt-get >/dev/null 2>&1; then
      ssm_log "Installing session-manager-plugin via apt..."
      TMP_DEB="$(mktemp -d)/session-manager-plugin.deb"
      curl -sSL "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o "$TMP_DEB"
      sudo dpkg -i "$TMP_DEB"
    elif command -v yum >/dev/null 2>&1; then
      ssm_log "Installing session-manager-plugin via yum..."
      TMP_RPM="$(mktemp -d)/session-manager-plugin.rpm"
      curl -sSL "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/linux_64bit/session-manager-plugin.rpm" -o "$TMP_RPM"
      sudo yum install -y "$TMP_RPM"
    else
      ssm_die "No supported package manager (apt/yum) found. See https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html"
    fi
    ;;
  *)
    ssm_die "Unsupported OS: ${OS}. See https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html"
    ;;
esac

command -v session-manager-plugin >/dev/null 2>&1 || ssm_die "Install finished but session-manager-plugin is still not on PATH. You may need to open a new shell."
ssm_log "Installed: $(session-manager-plugin --version 2>&1 | head -1)"
