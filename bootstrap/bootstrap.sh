#!/usr/bin/env sh
set -eu

VERSION=7.6.9
ARCHIVE="powershell-${VERSION}-linux-x64.tar.gz"
EXPECTED_SHA256=1da6d6d6035d651f20e70ddee7c4c15ac6ab8b9fb40ee92240d91263f28a884b
if [ -n "${POWERSHELL_INSTALL_ROOT:-}" ]; then
    INSTALL_ROOT=$POWERSHELL_INSTALL_ROOT
elif [ -d /workspace ] && [ -w /workspace ]; then
    INSTALL_ROOT=/workspace/.powershell
else
    INSTALL_ROOT="${HOME:?}/.local/share/powershell"
fi
INSTALL_DIR="$INSTALL_ROOT/$VERSION"

if [ "$(uname -s)" != Linux ] || [ "$(uname -m)" != x86_64 ]; then
    echo 'This minimal bootstrap currently supports Linux x86_64; install the pinned PowerShell release for this platform separately.' >&2
    exit 1
fi

if command -v pwsh >/dev/null 2>&1; then
    SYSTEM_VERSION=$(pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null || true)
    if [ "$SYSTEM_VERSION" = "$VERSION" ]; then exec pwsh "$@"; fi
fi

if [ -x "$INSTALL_DIR/pwsh" ]; then
    INSTALLED_VERSION=$("$INSTALL_DIR/pwsh" -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')
    if [ "$INSTALLED_VERSION" != "$VERSION" ]; then
        echo "PowerShell version mismatch in $INSTALL_DIR: $INSTALLED_VERSION" >&2
        exit 1
    fi
elif [ -e "$INSTALL_DIR" ]; then
    echo "PowerShell install path exists but is incomplete: $INSTALL_DIR" >&2
    exit 1
else
    command -v curl >/dev/null 2>&1 || { echo 'curl is required for PowerShell bootstrap' >&2; exit 1; }
    command -v tar >/dev/null 2>&1 || { echo 'tar is required for PowerShell bootstrap' >&2; exit 1; }
    command -v sha256sum >/dev/null 2>&1 || { echo 'sha256sum is required for PowerShell bootstrap' >&2; exit 1; }
    mkdir -p "$INSTALL_ROOT"
    TMP_DIR=$(mktemp -d)
    STAGE_DIR="$INSTALL_ROOT/.stage-$VERSION-$$"
    trap 'rm -rf "$TMP_DIR" "$STAGE_DIR"' EXIT HUP INT TERM
    curl --fail --location --silent --show-error "https://github.com/PowerShell/PowerShell/releases/download/v$VERSION/$ARCHIVE" -o "$TMP_DIR/$ARCHIVE"
    printf '%s  %s\n' "$EXPECTED_SHA256" "$TMP_DIR/$ARCHIVE" | sha256sum --check --status || {
        echo 'PowerShell archive SHA-256 mismatch' >&2
        exit 1
    }
    mkdir "$STAGE_DIR"
    tar -xzf "$TMP_DIR/$ARCHIVE" -C "$STAGE_DIR"
    chmod +x "$STAGE_DIR/pwsh"
    STAGED_VERSION=$("$STAGE_DIR/pwsh" -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')
    if [ "$STAGED_VERSION" != "$VERSION" ]; then
        echo "Extracted PowerShell version mismatch: $STAGED_VERSION" >&2
        exit 1
    fi
    mv "$STAGE_DIR" "$INSTALL_DIR"
    rm -rf "$TMP_DIR"
    trap - EXIT HUP INT TERM
fi

INSTALLED_VERSION=$("$INSTALL_DIR/pwsh" -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')
if [ "$INSTALLED_VERSION" != "$VERSION" ]; then
    echo "PowerShell version mismatch in $INSTALL_DIR: $INSTALLED_VERSION" >&2
    exit 1
fi

exec "$INSTALL_DIR/pwsh" "$@"
