#!/bin/bash

# Config file name
SCRIPT_DIR=$(dirname "$(realpath "$0")")
CONFIG_FILE="$SCRIPT_DIR/config.txt"

# Creation of the config file
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Creating config.txt"
    cat <<EOL > "$CONFIG_FILE"
# Example of configuration
# -programming: ubuntu --nvidia
# htop
# curl
EOL
    echo "config.txt created. Modify it and rerun the script"
    exit 0
fi

# Creation of present.txt
PRESENT_FILE="$SCRIPT_DIR/present.txt"
if [ ! -f "$PRESENT_FILE" ]; then
    touch "$PRESENT_FILE"
    echo "File present.txt' didn't exist. Created."
fi


# Temp variables
container_name=""
distro=""
flags=""
nvidia_flag=""
packages=()
home_directory=""

# package manager detect function
detect_package_manager() {
    local container=$1
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

    # Update every container program list
    awk -v container="$container" -v updated_packages="${updated_packages[*]}" '
        BEGIN {found=0}
        $0 ~ "Container: " container {found=1}
        found && $0 ~ "Installed programs: " {
            print "Installed programs: " updated_packages
            next
        }
        found && $0 ~ "^---------------------------------" {found=0}
        {print}
    ' "$PRESENT_FILE" > "${PRESENT_FILE}.tmp" && mv "${PRESENT_FILE}.tmp" "$PRESENT_FILE"
}

# packages install function
install_packages() {
    local container="$1"
    local distribution="$2"
    local nvidia_fl="$3"
    local flag_str="$4"
    local package_man="$5"
    local packages_list=("${@:6}")  # List of packages to be installed

    echo "Installing packages for '$container'..."

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
            echo "Error: package manager '$package_man' unsupported!"
            return 1
            ;;
    esac

    # Update present.txt with the new packages
    if grep -q "Container: $container" "$PRESENT_FILE"; then
        awk -v container="$container" -v updated_packages="${packages_list[*]}" '
            BEGIN {found=0}
            $0 ~ "Container: " container {found=1}
            found && $0 ~ "Installed programs: " {
                print "Installed programs: " updated_packages
                next
            }
            found && $0 ~ "^---------------------------------" {found=0}
            {print}
        ' "$PRESENT_FILE" > "${PRESENT_FILE}.tmp" && mv "${PRESENT_FILE}.tmp" "$PRESENT_FILE"
    else
        # Add new container
        {
            echo "Container: $container"
            echo "Distro: $distribution"
            echo "Flags: $nvidia_fl $flag_str"
            echo "Installed programs: ${packages_list[*]}"
            echo "---------------------------------"
        } >> "$PRESENT_FILE"
    fi

}

#remove packages function
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

    # Extract from present.txt the current packages
    if grep -q "Container: $container" "$PRESENT_FILE"; then
        present_packages=$(awk -v container="$container" '
            $0 ~ "Container: " container {found=1}
            found && $0 ~ "Installed programs: " {
                sub("Installed programs: ", "")
                print $0
                exit
            }
        ' "$PRESENT_FILE")
        IFS=' ' read -r -a present_packages <<< "$present_packages"
    fi

    # Packages to remove
    for package in "${present_packages[@]}"; do
        if [[ ! " ${current_packages[@]} " =~ " $package " ]]; then
            obsolete_packages+=("$package")
        fi
    done

    # Remove old packages
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
                echo "Error: package manager '$package_manager' unsupported!"
                return 1
                ;;
        esac

        # recreate container unless --no-recreate
        if [[ "$recreate_flag_str" != *"--no-recreate"* ]]; then
            recreate_container=true
        fi
    fi

    # Container recreation
    if $recreate_container; then
        echo "Recreation of '$container' ..."
        distrobox rm "$container" --force
        distrobox create --name "$container" --image "$distro" "$nvidia_flag" --home "$home/$container" --yes
    fi

    # Update present.txt
    update_present_file "$container" "${packages[@]}"
}

# Read config.txt
while IFS= read -r -u3 line || [[ -n "$line" ]]; do
    # Skip comments and empty lines
    if [[ -z "$line" || "$line" == \#* ]]; then
        continue
    fi


    # Search home directory path
    if [[ "$line" == home_directory:* ]]; then
        home_directory=$(echo "$line" | awk -F': ' '{print $2}' | xargs)
        echo "Home directory: $home_directory"
        continue
    fi

    # If a container is defined
    if [[ "$line" == -*:* ]]; then

        # Remove old packages
        if [[ -n "$container_name" ]]; then
            remove_unused_packages "$container_name" "$distro" "$nvidia_flag" "$flags" "$package_manager" "${packages[@]}" "$home_directory"
        fi
        
        # Add new packages
        if [[ -n "$container_name" && ${#packages[@]} -gt 0 ]]; then
            install_packages "$container_name" "$distro" "$nvidia_flag" "$flags" "$package_manager" "${packages[@]}"
            packages=()
        fi


        # Read container name, distro and flag
        container_name=$(echo "$line" | awk -F': ' '{print $1}' | sed 's/-//')
        distro=$(echo "$line" | awk -F': ' '{print $2}' | awk '{print $1}')
        flags=$(echo "$line" | awk -F': ' '{print $2}' | awk '{$1=""; print $0}' | xargs)

        # Extract nvidia flag
        if [[ "$flags" == *"--nvidia"* ]]; then
            nvidia_flag="--nvidia"
            flags=$(echo "$flags" | sed 's/--nvidia//g') # Remove --nvidia from other flags
        fi

        # Create adn start container
        echo "Creation of $container_name' (distro: $distro, flags: $nvidia_flag)..."
        distrobox create --name "$container_name" --image "$distro" "$nvidia_flag" --home "$home_directory/$container_name" --yes

        # Detect package manager
        package_manager=$(detect_package_manager "$container_name" | tail -n 1 | tr -d '\r')

        # If unsupported error
        if [[ "$package_manager" == "unknown" ]]; then
            echo "Error: undefined package manager: '$container_name'."
            exit 1
        else
            echo "Detected package manager: $package_manager"
        fi

        # Clean packages
        packages=()
    else
        # Packages ++
        packages+=("$line")
    fi

done 3< "$CONFIG_FILE"

# Remove old packages from last container
if [[ -n "$container_name" ]]; then
    remove_unused_packages "$container_name" "$distro" "$nvidia_flag" "$flags" "$package_manager" "${packages[@]}" "$home_directory"
fi

# Add new packages to last container
if [[ -n "$container_name" && ${#packages[@]} -gt 0 ]]; then
    install_packages "$container_name" "$distro" "$nvidia_flag" "$flags" "$package_manager" "${packages[@]}"
    packages=()
fi

echo "End withot errors"
