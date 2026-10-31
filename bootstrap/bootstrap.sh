#!/usr/bin/env sh
set -eu

VERSION=7.6.9
ARCHIVE="powershell-${VERSION}-linux-x64.tar.gz"
EXPECTED_SHA256=1da6d6d6035d651f20e70ddee7c4c15ac6ab8b9fb40ee92240d91263f28a884b

if [ -d /workspace ] && [ -w /workspace ]; then
    WORKSPACE_ROOT=/workspace
elif [ -n "${CODEX_WORKSPACE:-}" ] && [ -d "$CODEX_WORKSPACE" ] && [ -w "$CODEX_WORKSPACE" ]; then
    WORKSPACE_ROOT=$CODEX_WORKSPACE
else
    echo 'A writable /workspace or CODEX_WORKSPACE directory is required for the PowerShell runtime.' >&2
    exit 1
fi

if [ -n "${POWERSHELL_INSTALL_ROOT:-}" ]; then
    INSTALL_ROOT=$POWERSHELL_INSTALL_ROOT
else
    INSTALL_ROOT="$WORKSPACE_ROOT/.powershell"
fi
INSTALL_DIR="$INSTALL_ROOT/$VERSION"
RUNTIME_HOME="$WORKSPACE_ROOT/.review-tools/cli-home"
XDG_CACHE_HOME="$RUNTIME_HOME/.cache"
XDG_CONFIG_HOME="$RUNTIME_HOME/.config"
XDG_DATA_HOME="$RUNTIME_HOME/.local/share"
TMPDIR="$WORKSPACE_ROOT/.review-tools/tmp"
TEMP=$TMPDIR
TMP=$TMPDIR
DOTNET_ROOT=${DOTNET_ROOT:-"$WORKSPACE_ROOT/.review-tools/dotnet"}

command -v mktemp >/dev/null 2>&1 || { echo 'mktemp is required for writable-directory checks' >&2; exit 1; }
umask 077
ensure_writable_dir() {
    directory=$1
    if ! mkdir -p "$directory"; then
        echo "Could not create required runtime directory: $directory" >&2
        exit 1
    fi
    if ! probe=$(mktemp "$directory/.codex-bootstrap-write-check.XXXXXX"); then
        echo "Required runtime directory is not writable: $directory" >&2
        exit 1
    fi
    if ! rm -f "$probe"; then
        echo "Could not remove runtime write-check file: $probe" >&2
        exit 1
    fi
}

for directory in "$RUNTIME_HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$TMPDIR" "$INSTALL_ROOT"; do
    ensure_writable_dir "$directory"
done

PATH="$INSTALL_DIR:$DOTNET_ROOT:$PATH"
export HOME="$RUNTIME_HOME" XDG_CACHE_HOME XDG_CONFIG_HOME XDG_DATA_HOME TMPDIR TEMP TMP DOTNET_ROOT PATH

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
