#!/bin/bash
#
# Installer per DistroText
# Copia tutti i file dell'app in una cartella di installazione stabile,
# crea la voce nel menu applicazioni (.desktop), gestisce update e
# disinstallazione.
#
# Uso:
#   ./install_launcher.sh              installa oppure aggiorna
#   ./install_launcher.sh --uninstall  disinstalla
#   ./install_launcher.sh --help       mostra questo aiuto

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

# Cartella in cui si trova questo installer (contiene i file da copiare)
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Cartella di installazione definitiva (per-utente, non serve sudo)
INSTALL_DIR="$HOME/.local/share/$APP_NAME"

DESKTOP_DIR="$HOME/.local/share/applications"
DESKTOP_FILE="$DESKTOP_DIR/$APP_NAME.desktop"

# Nome di questo stesso script, da escludere dalla copia
SELF_NAME="$(basename "${BASH_SOURCE[0]}")"

usage() {
    echo "Uso: $0 [--uninstall|--help]"
    echo
    echo "  (nessuna opzione)   installa $APP_NAME, oppure lo aggiorna se già presente"
    echo "  --uninstall, -u     rimuove $APP_NAME e il launcher dal menu"
    echo "  --help, -h          mostra questo messaggio"
}

do_uninstall() {
    echo "== Disinstallazione di $APP_NAME =="

    if [ ! -d "$INSTALL_DIR" ] && [ ! -f "$DESKTOP_FILE" ]; then
        echo "$APP_NAME non risulta installato. Niente da fare."
        exit 0
    fi

    if [ -d "$INSTALL_DIR" ]; then
        rm -rf "$INSTALL_DIR"
        echo "Rimossa cartella: $INSTALL_DIR"
    fi

    if [ -f "$DESKTOP_FILE" ]; then
        rm -f "$DESKTOP_FILE"
        echo "Rimosso launcher: $DESKTOP_FILE"
    fi

    echo
    echo "Disinstallazione completata."
    exit 0
}

do_install() {
    echo "== Installazione di $APP_NAME =="

    if [ ! -f "$SOURCE_DIR/$MAIN_SCRIPT" ]; then
        echo "Errore: $MAIN_SCRIPT non trovato in $SOURCE_DIR."
        exit 1
    fi

    # Se è già presente una versione precedente, la sostituiamo interamente
    # (cartella pulita) cosi' non restano file obsoleti di versioni vecchie.
    if [ -d "$INSTALL_DIR" ]; then
        echo "Rilevata un'installazione esistente in: $INSTALL_DIR"
        echo "Procedo con l'aggiornamento..."
        rm -rf "$INSTALL_DIR"
    fi

    # 1. Crea la cartella di installazione
    mkdir -p "$INSTALL_DIR"

    # 2. Copia tutti i file della cartella sorgente (script inclusi),
    #    escludendo l'installer stesso
    echo "Copia dei file in: $INSTALL_DIR"
    shopt -s dotglob nullglob
    for f in "$SOURCE_DIR"/*; do
        name="$(basename "$f")"
        [ "$name" = "$SELF_NAME" ] && continue
        cp -rf "$f" "$INSTALL_DIR/"
    done
    shopt -u dotglob nullglob

    # 3. Rende eseguibili gli script copiati
    find "$INSTALL_DIR" -maxdepth 1 -type f \( -name "*.py" -o -name "*.sh" \) -exec chmod +x {} \;

    INSTALLED_SCRIPT="$INSTALL_DIR/$MAIN_SCRIPT"
    INSTALLED_ICON="$INSTALL_DIR/$ICON_NAME"

    if [ ! -f "$INSTALLED_SCRIPT" ]; then
        echo "Errore: copia fallita, $INSTALLED_SCRIPT non trovato."
        exit 1
    fi

    # 4. Crea la cartella per i file .desktop e il file stesso
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
    echo "Installazione completata."
    echo "  File installati in: $INSTALL_DIR"
    echo "  Launcher creato in: $DESKTOP_FILE"
    echo
    echo "Ora dovresti trovare '$APP_NAME' nel menu applicazioni."
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
        echo "Opzione sconosciuta: $1"
        usage
        exit 1
        ;;
esac
