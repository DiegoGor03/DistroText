#!/bin/bash
#
# DistroText installer
# Copies all app files to a stable installation folder,
# creates an entry in the applications menu (.desktop), manages updates and
# uninstallation.
#
# Usage:
#   ./install_launcher.sh              installs or updates
#   ./install_launcher.sh --uninstall  uninstalls
#   ./install_launcher.sh --help       shows this help

# DistroText - manage distrobox containers from a text config file
# Copyright (C) 2026  Diego G. (DiegoGor03 on GitHub)
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 3 as published by
# the Free Software Foundation
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

set -e

APP_NAME="DistroText"
MAIN_SCRIPT="pkgtui.py"
ICON_NAME="DistroText_icon.png"

# Files that hold user data and must NOT be overwritten by an update
PRESERVE_FILES=("config.txt" "present.txt")

# Folder where this installer is located (contains files to copy)
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Final installation folder (per-user, no sudo needed)
INSTALL_DIR="$HOME/.local/share/$APP_NAME"

DESKTOP_DIR="$HOME/.local/share/applications"
DESKTOP_FILE="$DESKTOP_DIR/$APP_NAME.desktop"

# Name of this script itself, to exclude from copying
SELF_NAME="$(basename "${BASH_SOURCE[0]}")"

usage() {
    echo "Usage: $0 [--uninstall|--help]"
    echo
    echo "  (no option)         installs $APP_NAME, or updates it if already installed"
    echo "  --uninstall, -u     removes $APP_NAME and its launcher from the menu"
    echo "  --help, -h          shows this message"
}

do_uninstall() {
    echo "== Uninstalling $APP_NAME =="

    if [ ! -d "$INSTALL_DIR" ] && [ ! -f "$DESKTOP_FILE" ]; then
        echo "$APP_NAME does not appear to be installed. Nothing to do."
        exit 0
    fi

    if [ -d "$INSTALL_DIR" ]; then
        rm -rf "$INSTALL_DIR"
        echo "Removed folder: $INSTALL_DIR"
    fi

    if [ -f "$DESKTOP_FILE" ]; then
        rm -f "$DESKTOP_FILE"
        echo "Removed launcher: $DESKTOP_FILE"
    fi

    echo
    echo "Uninstallation complete."
    exit 0
}

do_install() {
    echo "== Installing $APP_NAME =="

    if [ ! -f "$SOURCE_DIR/$MAIN_SCRIPT" ]; then
        echo "Error: $MAIN_SCRIPT not found in $SOURCE_DIR."
        exit 1
    fi

    # If a previous version is already present, back up the user-data
    # files (so an update doesn't wipe them), then replace the rest of
    # the folder entirely (clean folder) so no outdated files remain.
    BACKUP_DIR=""
    if [ -d "$INSTALL_DIR" ]; then
        echo "Existing installation detected in: $INSTALL_DIR"
        echo "Proceeding with update..."
        BACKUP_DIR="$(mktemp -d)"
        for pf in "${PRESERVE_FILES[@]}"; do
            if [ -f "$INSTALL_DIR/$pf" ]; then
                cp -f "$INSTALL_DIR/$pf" "$BACKUP_DIR/$pf"
            fi
        done
        rm -rf "$INSTALL_DIR"
    fi

    # 1. Create the installation folder
    mkdir -p "$INSTALL_DIR"

    # 2. Copy all files from the source folder (including scripts),
    #    excluding the installer itself and the preserved user-data files
    echo "Copying files to: $INSTALL_DIR"
    shopt -s dotglob nullglob
    for f in "$SOURCE_DIR"/*; do
        name="$(basename "$f")"
        [ "$name" = "$SELF_NAME" ] && continue

        skip=false
        for pf in "${PRESERVE_FILES[@]}"; do
            [ "$name" = "$pf" ] && skip=true && break
        done
        [ "$skip" = true ] && continue

        cp -rf "$f" "$INSTALL_DIR/"
    done
    shopt -u dotglob nullglob

    # 3. Restore preserved user-data files: bring back the previous
    #    installation's copy if it existed, otherwise fall back to the
    #    version shipped in the source folder (first install).
    for pf in "${PRESERVE_FILES[@]}"; do
        if [ -n "$BACKUP_DIR" ] && [ -f "$BACKUP_DIR/$pf" ]; then
            cp -f "$BACKUP_DIR/$pf" "$INSTALL_DIR/$pf"
        elif [ -f "$SOURCE_DIR/$pf" ]; then
            cp -f "$SOURCE_DIR/$pf" "$INSTALL_DIR/$pf"
        fi
    done
    [ -n "$BACKUP_DIR" ] && rm -rf "$BACKUP_DIR"

    # 4. Make copied scripts executable
    find "$INSTALL_DIR" -maxdepth 1 -type f \( -name "*.py" -o -name "*.sh" \) -exec chmod +x {} \;

    INSTALLED_SCRIPT="$INSTALL_DIR/$MAIN_SCRIPT"
    INSTALLED_ICON="$INSTALL_DIR/$ICON_NAME"

    if [ ! -f "$INSTALLED_SCRIPT" ]; then
        echo "Error: copy failed, $INSTALLED_SCRIPT not found."
        exit 1
    fi

    # 5. Create folder for .desktop files and create the file itself
    mkdir -p "$DESKTOP_DIR"

    cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=$APP_NAME
Comment=Launch $APP_NAME
Exec=/usr/bin/python3 "$INSTALLED_SCRIPT"
Path=$INSTALL_DIR
Icon=$INSTALLED_ICON
Terminal=true
Categories=System;
EOF

    chmod +x "$DESKTOP_FILE"

    echo
    echo "Installation complete."
    echo "  Files installed in: $INSTALL_DIR"
    echo "  Launcher created in: $DESKTOP_FILE"
    echo
    echo "You should now find '$APP_NAME' in the applications menu."
}

case "${1:-}" in
    --uninstall|-u)
        do_uninstall
        ;;
    --help|-h)
        usage
        ;;
    "")
        do_install
        ;;
    *)
        echo "Unknown option: $1"
        usage
        exit 1
        ;;
esac
