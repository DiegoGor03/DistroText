#!/bin/bash

# Nome del file di configurazione
SCRIPT_DIR=$(dirname "$(realpath "$0")")
CONFIG_FILE="$SCRIPT_DIR/config.txt"

# Controlla se il file di configurazione esiste, altrimenti lo crea
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Il file di configurazione 'config.txt' non esiste. Creazione in corso..."
    cat <<EOL > "$CONFIG_FILE"
# Esempio di configurazione:
-programmazione: ubuntu --nvidia
htop
curl
-sviluppo: fedora
vim
git
-arch-prova: archlinux
neovim
wget
EOL
    echo "File di configurazione 'config.txt' creato con un esempio di configurazione."
    echo "Modifica il file e ri-esegui lo script."
    exit 0
fi

# Inizializza il file 'present.txt'
PRESENT_FILE="$SCRIPT_DIR/present.txt"
# Crea il file 'present.txt' solo se non esiste
if [ ! -f "$PRESENT_FILE" ]; then
    touch "$PRESENT_FILE"
    echo "Il file 'present.txt' non esisteva. È stato creato."
fi


# Variabili temporanee
container_name=""
distro=""
flags=""
packages=()
home_directory=""

# Funzione per rilevare il package manager
detect_package_manager() {
    local container=$1
    # Usa distrobox per identificare il package manager
    distrobox-enter "$container" -- bash -c "
        if command -v apt >/dev/null; then
            echo 'apt'
        elif command -v dnf >/dev/null; then
            echo 'dnf'
        elif command -v pacman >/dev/null; then
            echo 'pacman'
        else
            echo 'unknown'
        fi
    "
}

update_present_file() {
    local container="$1"
    local updated_packages=("${@:2}")

    # Modifica solo la sezione relativa al container specifico
    awk -v container="$container" -v updated_packages="${updated_packages[*]}" '
        BEGIN {found=0}
        $0 ~ "Container: " container {found=1}
        found && $0 ~ "Programmi installati: " {
            print "Programmi installati: " updated_packages
            next
        }
        found && $0 ~ "^---------------------------------" {found=0}
        {print}
    ' "$PRESENT_FILE" > "${PRESENT_FILE}.tmp" && mv "${PRESENT_FILE}.tmp" "$PRESENT_FILE"
}

#funzione installazione pacchetti
install_packages() {
    local container="$1"
    local distribution="$2"
    local nvidia_fl="$3"
    local flag_str="$4"
    local package_man="$5"
    local packages_list=("${@:6}")  #Prende tutti i pacchetti come array

    echo "Installazione pacchetti per '$container'..."

    case "$package_man" in
        apt)
            distrobox-enter "$container" -- sudo apt update -y
            distrobox-enter "$container" -- sudo apt install -y "${packages_list[@]}"
            ;;
        dnf)
            distrobox-enter "$container" -- sudo dnf install -y "${packages_list[@]}"
            ;;
        pacman)
            distrobox-enter "$container" -- sudo pacman -Syu --noconfirm
            distrobox-enter "$container" -- sudo pacman -S --noconfirm "${packages_list[@]}"
            ;;
        *)
            echo "Errore: package manager '$package_man' non supportato!"
            return 1
            ;;
    esac

    # Aggiorna il file 'present.txt' con i nuovi pacchetti (o aggiungi una nuova sezione se non esiste)
    if grep -q "Container: $container" "$PRESENT_FILE"; then
        # Modifica la sezione esistente
        awk -v container="$container" -v updated_packages="${packages_list[*]}" '
            BEGIN {found=0}
            $0 ~ "Container: " container {found=1}
            found && $0 ~ "Programmi installati: " {
                print "Programmi installati: " updated_packages
                next
            }
            found && $0 ~ "^---------------------------------" {found=0}
            {print}
        ' "$PRESENT_FILE" > "${PRESENT_FILE}.tmp" && mv "${PRESENT_FILE}.tmp" "$PRESENT_FILE"
    else
        # Aggiungi una nuova sezione
        {
            echo "Container: $container"
            echo "Distro: $distribution"
            echo "Flags: $nvidia_fl $flag_str"
            echo "Programmi installati: ${packages_list[*]}"
            echo "---------------------------------"
        } >> "$PRESENT_FILE"
    fi

}

#funzione rimozione pacchetti
remove_unused_packages() {
    local container="$1"
    local distro="$2"
    local nvidia_flag="$3"
    local recreate_flag_str="$4"
    local package_manager="$5"
    local current_packages=("${@:6}")
    local home="$7"
    local present_packages=()
    local obsolete_packages=()
    local recreate_container=false

    # Estrai i pacchetti installati dal file 'present.txt' per il container corrente
    if grep -q "Container: $container" "$PRESENT_FILE"; then
        present_packages=$(awk -v container="$container" '
            $0 ~ "Container: " container {found=1}
            found && $0 ~ "Programmi installati: " {
                sub("Programmi installati: ", "")
                print $0
                exit
            }
        ' "$PRESENT_FILE")
        IFS=' ' read -r -a present_packages <<< "$present_packages"
    fi

    # Determina i pacchetti obsoleti
    for package in "${present_packages[@]}"; do
        if [[ ! " ${current_packages[@]} " =~ " $package " ]]; then
            obsolete_packages+=("$package")
        fi
    done

    # Se ci sono pacchetti obsoleti, rimuovili
    if [[ ${#obsolete_packages[@]} -gt 0 ]]; then
        echo "Rimuovendo pacchetti obsoleti da '$container': ${obsolete_packages[*]}"

        case "$package_manager" in
            apt)
                distrobox-enter "$container" -- sudo apt autoremove -y "${obsolete_packages[@]}"
                ;;
            dnf)
                distrobox-enter "$container" -- sudo dnf remove -y "${obsolete_packages[@]}"
                ;;
            pacman)
                distrobox-enter "$container" -- sudo pacman -Rsnu --noconfirm "${obsolete_packages[@]}"
                ;;
            *)
                echo "Errore: package manager '$package_manager' non supportato per la rimozione!"
                return 1
                ;;
        esac

        # Imposta il flag per ricreare il container
        if [[ "$recreate_flag_str" != *"--no-recreate"* ]]; then
            recreate_container=true
        fi
    fi

    # Ricrea il container se necessario
    if $recreate_container; then
        echo "Ricreazione del container '$container' poiché il flag --no-recreate non è stato trovato..."
        distrobox rm "$container" --force
        distrobox create --name "$container" --image "$distro" "$nvidia_flag" --home "$home/$container" --yes
    fi

    # Aggiorna il file 'present.txt'
    update_present_file "$container" "${packages[@]}"
}

# Legge il file di configurazione
while IFS= read -r -u3 line || [[ -n "$line" ]]; do
    # Ignora righe vuote o commenti
    if [[ -z "$line" || "$line" == \#* ]]; then
        continue
    fi


    # Leggi la home_directory all'inizio
    if [[ "$line" == home_directory:* ]]; then
        home_directory=$(echo "$line" | awk -F': ' '{print $2}' | xargs)
        echo "Home directory definita come: $home_directory"
        continue  # Passa alla prossima riga
    fi

    # Gestisce la definizione del container
    if [[ "$line" == -*:* ]]; then

        # Rimuove i pacchetti obsoleti
        if [[ -n "$container_name" ]]; then
            remove_unused_packages "$container_name" "$distro" "$nvidia_flag" "$flags" "$package_manager" "${packages[@]}" "$home_directory"
        fi
        
        # Dopo l'installazione dei pacchetti, aggiungi i dettagli al file
        if [[ -n "$container_name" && ${#packages[@]} -gt 0 ]]; then
            install_packages "$container_name" "$distro" "$nvidia_flag" "$flags" "$package_manager" "${packages[@]}"
            packages=()
        fi


        # Legge il nome del container, la distro e i flag
        container_name=$(echo "$line" | awk -F': ' '{print $1}' | sed 's/-//')
        distro=$(echo "$line" | awk -F': ' '{print $2}' | awk '{print $1}')
        flags=$(echo "$line" | awk -F': ' '{print $2}' | awk '{$1=""; print $0}' | xargs)

        # Estrae il flag --nvidia (se presente)
        nvidia_flag=""
        if [[ "$flags" == *"--nvidia"* ]]; then
            nvidia_flag="--nvidia"
            flags=$(echo "$flags" | sed 's/--nvidia//g') # Rimuove --nvidia dagli altri flag
        fi

        # Crea e avvia il container
        echo "Creazione del container '$container_name' (distro: $distro, flags: $nvidia_flag)..."
        distrobox create --name "$container_name" --image "$distro" "$nvidia_flag" --home "$home_directory/$container_name" --yes

        # Rileva il package manager
        echo "Rilevamento del package manager per '$container_name'..."
        package_manager=$(detect_package_manager "$container_name" | tail -n 1 | tr -d '\r')

        # Controlla se il package manager è supportato
        if [[ "$package_manager" == "unknown" ]]; then
            echo "Errore: impossibile determinare il package manager per il container '$container_name'."
            exit 1
        else
            echo "Package manager rilevato: $package_manager"
        fi

        # Inizializza la lista dei pacchetti
        packages=()
    else
        # Accumula i pacchetti da installare
        packages+=("$line")
    fi

done 3< "$CONFIG_FILE"

# Rimuove i pacchetti obsoleti
if [[ -n "$container_name" ]]; then
    remove_unused_packages "$container_name" "$distro" "$nvidia_flag" "$flags" "$package_manager" "${packages[@]}" "$home_directory"
fi

# Dopo l'installazione dei pacchetti, aggiungi i dettagli al file
if [[ -n "$container_name" && ${#packages[@]} -gt 0 ]]; then
    install_packages "$container_name" "$distro" "$nvidia_flag" "$flags" "$package_manager" "${packages[@]}"
    packages=()
fi

echo "Tutti i container sono stati configurati e i pacchetti installati."
