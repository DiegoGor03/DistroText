#!/bin/bash

# DistroText - manage distrobox containers from a text config file
# Copyright (C) 2026 Diego G. (DiegoGor03 on GitHub)
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 3 as published by
# the Free Software Foundation
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.

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
    echo "File 'present.txt' didn't exist. Created."
fi

# Temp variables
container_name=""
distro=""
flags=""
packages=()
home_directory="$HOME"

# -----------------------------------------------------------------------
# FIX: exact (non-regex) array membership test.
# The original code used `[[ " ${arr[@]} " =~ " $x " ]]`, which treats
# $x as a *regex*. Package/container names with regex metacharacters
# (e.g. "g++", "python3.11", "libssl1.1-dev") could produce false
# matches or false misses, causing packages/containers to be wrongly
# kept or removed.
# -----------------------------------------------------------------------
array_contains() {
    local needle="$1"
    shift
    local item
    for item in "$@"; do
        if [[ "$item" == "$needle" ]]; then
            return 0
        fi
    done
    return 1
}

# -----------------------------------------------------------------------
# FIX: package manager detection.
# The very first `distrobox-enter` into a freshly created container
# triggers distrobox's first-run initialization, which can print extra
# output. If that output lands on the same "line" as our echo (no clean
# trailing newline yet), `tail -n1` used to grab a corrupted string that
# didn't match "apt"/"dnf"/"pacman" *or* "unknown", so the script kept
# going with a garbage value and later silently failed to install
# anything (the `case` statement fell through to the unsupported branch
# and just returned 1).
#
# Fix: (1) do a throwaway `distrobox-enter ... -- true` first, so the
# first-run setup happens and completes before we try to read output;
# (2) tag the real output with a unique marker and extract it with
# `grep -o`, so stray init text on the same line can no longer corrupt
# the result.
# -----------------------------------------------------------------------
detect_package_manager() {
    local container=$1

    # Warm up: force first-run container initialization to finish
    # before we rely on its output for anything.
    distrobox-enter "$container" -- true >/dev/null 2>&1

    distrobox-enter "$container" -- bash -c "
        if command -v apt >/dev/null 2>&1; then
            echo 'PKGMGR:apt'
        elif command -v dnf >/dev/null 2>&1; then
            echo 'PKGMGR:dnf'
        elif command -v pacman >/dev/null 2>&1; then
            echo 'PKGMGR:pacman'
        else
            echo 'PKGMGR:unknown'
        fi
    " 2>/dev/null | grep -o 'PKGMGR:[a-z]*' | tail -n 1 | sed 's/^PKGMGR://'
}

update_present_file() {
    local container="$1"
    local updated_packages=("${@:2}")

    # Update every container program list
    awk -v container="$container" -v updated_packages="${updated_packages[*]}" '
        BEGIN {found=0}
        $0 ~ "Container: " container {found=1}
        found && $0 ~ "Installed programs:" {
            print "Installed programs: " updated_packages
            next
        }
        found && $0 ~ "^---------------------------------" {found=0}
        {print}
    ' "$PRESENT_FILE" > "${PRESENT_FILE}.tmp" && mv "${PRESENT_FILE}.tmp" "$PRESENT_FILE"
}

remove_old_containers() {
    # read all containers in present
    containers_in_present=($(awk '/^Container: / {print $2}' "$PRESENT_FILE"))
    # read all containers in config
    containers_in_config=($(awk '/^-/ {print substr($1, 2)}' "$CONFIG_FILE" | sed 's/:$//'))

    # Containers to remove
    for name in "${containers_in_present[@]}"; do
        local remove=true
        if array_contains "$name" "${containers_in_config[@]}"; then
            remove=false
        fi

        if $remove; then
            echo "Removing container '$name' (no longer in config.txt)..."
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

# -----------------------------------------------------------------------
# FIX: helper to build the `distrobox create` argument list without
# passing an empty string as a literal positional argument when
# $nvidia_flag is unset. The original code always did:
#   distrobox create ... "$nvidia_flag" --yes
# which, when $nvidia_flag="", passes an empty argument to distrobox
# create every single time --nvidia isn't used.
# -----------------------------------------------------------------------
build_create_args() {
    local name="$1"
    local home="$2"
    local image="$3"
    local nvidia="$4"

    local args=(--name "$name" --home "$home" --image "$image")
    if [[ -n "$nvidia" ]]; then
        args+=("$nvidia")
    fi
    args+=(--yes)
    printf '%s\n' "${args[@]}"
}

# packages install function
install_packages() {
    local container="$1"
    local distribution="$2"
    local nvidia_fl="$3"
    local flag_str="$4"
    local package_man="$5"
    local packages_list=("${@:6}") # List of packages to be installed

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
        if ! array_contains "$pkg" "${installed_packages[@]}"; then
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
        for pkg in "${all_packages[@]}"; do
            if ! array_contains "$pkg" "${unique_packages[@]}"; then
                unique_packages+=("$pkg")
            fi
        done

        update_present_file "$container" "${unique_packages[@]}"
    fi
}

# remove packages function
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
        if ! array_contains "$package" "${current_packages[@]}"; then
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

        mapfile -t create_args < <(build_create_args "$container" "$home/$container" "$distro" "$nvidia_flag")
        distrobox create "${create_args[@]}"

        # The container is now empty: everything that should remain
        # (i.e. every package still in current_packages) must be
        # reinstalled from scratch, not just the newly added ones.
        if [[ ${#current_packages[@]} -gt 0 ]]; then
            echo "Reinstalling remaining packages for '$container' after recreation: ${current_packages[*]}"

            # The freshly recreated container needs its first-run setup
            # to complete (and its package manager re-confirmed) before
            # we try to install into it.
            distrobox-enter "$container" -- true >/dev/null 2>&1
            local fresh_package_manager
            fresh_package_manager=$(detect_package_manager "$container")
            if [[ -n "$fresh_package_manager" && "$fresh_package_manager" != "unknown" ]]; then
                package_manager="$fresh_package_manager"
            fi

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
            echo "Creation of '$container_name' (distro: $distro, flags: $nvidia_flag)..."
            mapfile -t create_args < <(build_create_args "$container_name" "$home_directory/$container_name" "$distro" "$nvidia_flag")
            distrobox create "${create_args[@]}"
        fi

        # Add new container
        if ! grep -q "Container: $container_name" "$PRESENT_FILE"; then
            {
                echo "Container: $container_name"
                echo "Distro: $distro"
                echo "Flags: $nvidia_flag $flags"
                echo "Installed programs: "
                echo "---------------------------------"
            } >> "$PRESENT_FILE"
        fi

        # Detect package manager (also warms up the container so any
        # first-run distrobox init output doesn't corrupt later reads)
        package_manager=$(detect_package_manager "$container_name")

        # If unsupported error
        if [[ -z "$package_manager" || "$package_manager" == "unknown" ]]; then
            echo "Error: undefined package manager for '$container_name'."
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
fi

echo "End without errors"
