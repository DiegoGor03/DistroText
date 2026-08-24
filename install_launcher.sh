#!/bin/bash

set -e

APP_NAME="DistroText"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/pkgtui.py"
ICON="$SCRIPT_DIR/DistroText_icon.png"

DESKTOP_DIR="$HOME/.local/share/applications"
DESKTOP_FILE="$DESKTOP_DIR/DistroText.desktop"

if [ ! -f "$SCRIPT" ]; then
    echo "Error: $SCRIPT not found."
    exit 1
fi

mkdir -p "$DESKTOP_DIR"

cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=$APP_NAME
Comment=Launch $APP_NAME
Exec=/usr/bin/python3 "$SCRIPT"
Path=$SCRIPT_DIR
Icon=$ICON
Terminal=true
Categories=System;
EOF

chmod +x "$DESKTOP_FILE"

echo "Launcher installed:"
echo "  $DESKTOP_FILE"
echo
echo "You should now find '$APP_NAME' in your application menu."
