#!/bin/bash

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

# Config file name
SCRIPT_DIR=$(dirname "$(realpath "$0")")
CONFIG_FILE="$SCRIPT_DIR/config.txt"

# Creation of the config file
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Creating config.txt"
    cat <<EOL > "$CONFIG_FILE"
# Example of configuration
# home_directory: /home/user
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
packages=()
home_directory="$HOME"

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

remove_old_containers() {

    #read all containers in present
    containers_in_present=($(awk '/^Container: / {print $2}' "$PRESENT_FILE"))
    #read all containers in config
    containers_in_config=($(awk '/^-/ {print substr($1, 2)}' "$CONFIG_FILE" | sed 's/:$//'))
    # Packages to remove
    for name in "${containers_in_present[@]}"; do
        local remove=true
        if [[ " ${containers_in_config[@]} " =~ " $name " ]]; then
            remove=false
        fi

        if $remove; then
            distrobox rm "$name" --force

            # Remove container entry from present.txt
            awk -v container="$name" '
                BEGIN {found=0}
                $0 ~ "^Container: " container {found=1}
                found && $0 ~ "^---------------------------------" {found=0; next}
                !found {print}
            ' "$PRESENT_FILE" > "${PRESENT_FILE}.tmp" && mv "${PRESENT_FILE}.tmp" "$PRESENT_FILE"
        fi
    done
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

    # Check which packages are already installed by reading present.txt
    local to_install=()
    local installed_packages=()
    
    # Extract currently installed packages from present.txt
    if grep -q "Container: $container" "$PRESENT_FILE"; then
        local present_packages=$(awk -v container="$container" '
            $0 ~ "Container: " container {found=1}
            found && $0 ~ "Installed programs: " {
                sub("Installed programs: ", "")
                print $0
                exit
            }
        ' "$PRESENT_FILE")
        IFS=' ' read -r -a installed_packages <<< "$present_packages"
    fi

    # Determine which packages need to be installed
    for pkg in "${packages_list[@]}"; do
        local found=false
        for installed_pkg in "${installed_packages[@]}"; do
            if [[ "$pkg" == "$installed_pkg" ]]; then
                found=true
                break
            fi
        done
        if [[ "$found" == false ]]; then
            to_install+=("$pkg")
        fi
    done

    # Only install packages that aren't already installed
    if [ ${#to_install[@]} -gt 0 ]; then
        case "$package_man" in
            apt)
                distrobox-enter "$container" -- sudo apt update -y
                distrobox-enter "$container" -- sudo apt install -y "${to_install[@]}"
                ;;
            dnf)
                distrobox-enter "$container" -- sudo dnf install -y "${to_install[@]}"
                ;;
            pacman)
                distrobox-enter "$container" -- sudo pacman -Syu --noconfirm
                distrobox-enter "$container" -- sudo pacman -S --noconfirm "${to_install[@]}"
                ;;
            *)
                echo "Error: package manager '$package_man' unsupported!"
                return 1
                ;;
        esac
        
        if [[ "$flag_str" != *"--no-autoexport"* ]]; then
            for pack in "${to_install[@]}"; do
                distrobox-enter "$container" -- distrobox-export -a "$pack"
            done
        fi
    else
        echo "All packages already installed for '$container'"
    fi

    # Update present.txt with the new packages
    if grep -q "Container: $container" "$PRESENT_FILE"; then
        # Combine existing and new packages
        local all_packages=("${installed_packages[@]}" "${packages_list[@]}")
        # Remove duplicates while preserving order
        local unique_packages=()
        local seen=()
        for pkg in "${all_packages[@]}"; do
            local found=false
            for seen_pkg in "${seen[@]}"; do
                if [[ "$pkg" == "$seen_pkg" ]]; then
                    found=true
                    break
                fi
            done
            if [[ "$found" == false ]]; then
                seen+=("$pkg")
                unique_packages+=("$pkg")
            fi
        done
        
        awk -v container="$container" -v updated_packages="${unique_packages[*]}" '
            BEGIN {found=0}
            $0 ~ "Container: " container {found=1}
            found && $0 ~ "Installed programs: " {
                print "Installed programs: " updated_packages
                next
            }
            found && $0 ~ "^---------------------------------" {found=0}
            {print}
        ' "$PRESENT_FILE" > "${PRESENT_FILE}.tmp" && mv "${PRESENT_FILE}.tmp" "$PRESENT_FILE"
    fi

}

#remove packages function
remove_unused_packages() {
    local container="$1"
    local distro="$2"
    local nvidia_flag="$3"
    local recreate_flag_str="$4"
    local package_manager="$5"
    local home="$6"
    local current_packages=("${@:7}")
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
        echo "Removing obsolete packages from '$container': ${obsolete_packages[*]}"

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

        if [[ "$recreate_flag_str" != *"--no-autoexport"* ]]; then
            for pack in "${obsolete_packages[@]}"; do
                distrobox-enter "$container" -- distrobox-export -a "$pack" --delete
            done
        fi

        # recreate container unless --no-recreate
        if [[ "$recreate_flag_str" != *"--no-recreate"* ]]; then
            recreate_container=true
        fi
    fi

    # Container recreation
    if $recreate_container; then
        echo "Recreation of '$container' ..."
        distrobox rm "$container" --force
        distrobox create --name "$container" --image "$distro" --home "$home/$container" "$nvidia_flag"  --yes

        # The container is now empty: everything that should remain
        # (i.e. every package still in current_packages) must be
        # reinstalled from scratch, not just the newly added ones.
        if [[ ${#current_packages[@]} -gt 0 ]]; then
            echo "Reinstalling remaining packages for '$container' after recreation: ${current_packages[*]}"

            case "$package_manager" in
                apt)
                    distrobox-enter "$container" -- sudo apt update -y
                    distrobox-enter "$container" -- sudo apt install -y "${current_packages[@]}"
                    ;;
                dnf)
                    distrobox-enter "$container" -- sudo dnf install -y "${current_packages[@]}"
                    ;;
                pacman)
                    distrobox-enter "$container" -- sudo pacman -Syu --noconfirm
                    distrobox-enter "$container" -- sudo pacman -S --noconfirm "${current_packages[@]}"
                    ;;
                *)
                    echo "Error: package manager '$package_manager' unsupported!"
                    return 1
                    ;;
            esac

            if [[ "$recreate_flag_str" != *"--no-autoexport"* ]]; then
                for pack in "${current_packages[@]}"; do
                    distrobox-enter "$container" -- distrobox-export -a "$pack"
                done
            fi
        fi
    fi

    # Update present.txt
    # If the container was recreated, current_packages now accurately
    # reflects what's installed (we just reinstalled all of it above).
    # If it wasn't recreated, current_packages is still correct since
    # the obsolete ones were removed and nothing else changed.
    update_present_file "$container" "${current_packages[@]}"
}

remove_old_containers

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
            remove_unused_packages "$container_name" "$distro" "$nvidia_flag" "$flags" "$package_manager" "$home_directory" "${packages[@]}"
        fi
        
        # Add new packages
        if [[ -n "$container_name" && ${#packages[@]} -gt 0 ]]; then
            install_packages "$container_name" "$distro" "$nvidia_flag" "$flags" "$package_manager" "${packages[@]}"
            packages=()
        fi

        # Clean packages
        packages=()

        # Read container name, distro and flag
        container_name=$(echo "$line" | awk -F': ' '{print $1}' | sed 's/-//')
        distro=$(echo "$line" | awk -F': ' '{print $2}' | awk '{print $1}')
        flags=$(echo "$line" | awk -F': ' '{print $2}' | awk '{$1=""; print $0}' | xargs)

        # Extract nvidia flag
        nvidia_flag=""
        if [[ "$flags" == *"--nvidia"* ]]; then
            nvidia_flag="--nvidia"
            flags=$(echo "$flags" | sed 's/--nvidia//g') # Remove --nvidia from other flags
        fi

        # Check if container already exists
        if distrobox list | grep -q "^$container_name "; then
            echo "Container '$container_name' already exists, skipping creation..."
        else
            # Create and start container
            echo "Creation of $container_name' (distro: $distro, flags: $nvidia_flag)..."
            distrobox create --name "$container_name" --home "$home_directory/$container_name" --image "$distro" "$nvidia_flag" --yes
        fi

        # Add new container
        if ! grep -q "Container: $container_name" "$PRESENT_FILE"; then
        {
            echo "Container: $container_name"
            echo "Distro: $distro"
            echo "Flags: $nvidia_flag $flags"
            echo "Installed programs: ${packages[*]}"
            echo "---------------------------------"
        } >> "$PRESENT_FILE"
        fi
        
        # Detect package manager
        package_manager=$(detect_package_manager "$container_name" | tail -n 1 | tr -d '\r')

        # If unsupported error
        if [[ "$package_manager" == "unknown" ]]; then
            echo "Error: undefined package manager: '$container_name'."
            exit 1
        else
            echo "Detected package manager: $package_manager"
        fi

    else
        # Packages ++
        packages+=("$line")
    fi

done 3< "$CONFIG_FILE"

# Remove old packages from last container
if [[ -n "$container_name" ]]; then
    remove_unused_packages "$container_name" "$distro" "$nvidia_flag" "$flags" "$package_manager" "$home_directory" "${packages[@]}"
fi

# Add new packages to last container
if [[ -n "$container_name" && ${#packages[@]} -gt 0 ]]; then
    install_packages "$container_name" "$distro" "$nvidia_flag" "$flags" "$package_manager" "${packages[@]}"
    packages=()
fi

echo "End without errors"
