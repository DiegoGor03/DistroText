#!/usr/bin/env python3

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

"""
pkgtui.py - Interactive TUI for DistroText.

From a single menu you can:
  - Search Repology for a package and add it to one or more configured
    containers (only containers whose distro family matches the picked
    result are offered, since a package name that is correct for Ubuntu
    is not necessarily correct for Fedora).
  - Create a new container block in config.txt (name, image, flags).
  - Remove one or more container blocks from config.txt.
  - Enter a container's shell (distrobox-enter).
  - Run DistroText.sh to apply everything above.

pkgtui.py mostly only edits config.txt, exactly like pkgadd.py does - it never
calls distrobox directly. Use the "Run DistroText.sh" menu option (or run it
yourself afterwards) to actually create, install into, or destroy containers
based on the updated config.txt.

Usage:
    ./pkgtui.py [--config config.txt] [--script DistroText.sh]

Controls:
    Up/Down (or j/k) to move, Enter to confirm/select, Space to toggle a
    multi-select item, ESC/q to go back/cancel.
"""

import sys
import os
import curses
import argparse
import re
import subprocess

import repofind
import pkgadd


# ---------------------------------------------------------------------------
# Config / container helpers
# ---------------------------------------------------------------------------

def load_containers(config_path):
    """Return a list of {name, distro, family_key, family_label} for every
    container block found in config.txt."""
    _, blocks = pkgadd.parse_config(config_path)
    containers = []
    for b in blocks:
        family_key = pkgadd.guess_family(b["distro"])
        family_label = repofind.DEFAULT_FAMILIES.get(family_key) if family_key else None
        containers.append({
            "name": b["name"],
            "distro": b["distro"],
            "family_key": family_key,
            "family_label": family_label,
        })
    return containers


def build_candidates(term, families):
    """families: dict family_key -> family_label to restrict the search to.
    Returns a list of dicts: project, family_key, family_label, pkg_name,
    version, status - ordered like pkgadd.py (exact name match first)."""
    projects = repofind.search_projects(term)
    if not projects:
        return []

    ordered_names = sorted(projects.keys(), key=lambda n: (n != term, len(n), n))
    candidates = []
    for project_name in ordered_names:
        grouped = repofind.filter_families(projects[project_name], families, show_all=False)
        for family_label, pkgs in grouped.items():
            family_key = next(k for k, v in families.items() if v == family_label)
            for pkg_name, (version, status) in sorted(pkgs.items()):
                candidates.append({
                    "project": project_name,
                    "family_key": family_key,
                    "family_label": family_label,
                    "pkg_name": pkg_name,
                    "version": version,
                    "status": status,
                })
    return candidates


KNOWN_FLAGS = ["--nvidia", "--no-recreate", "--no-autoexport"]

# These are the package-manager families supported by DistroText's package
# lookup flow. The compatibility output contains image names, so use distro
# names rather than registry-specific paths to classify them.
APT_IMAGE_HINTS = (
    "debian", "ubuntu", "kali", "deepin", "linuxmint", "neon",
)
DNF_IMAGE_HINTS = (
    "oraclelinux", "fedora", "centos", "rocky", "almalinux",
    "amazonlinux", "ubi", "bazzite",
)
PACMAN_IMAGE_HINTS = (
    "archlinux", "blackarch", "steamos", "crystal-linux", "arch-toolbox",
)
IMAGE_REFERENCE_RE = re.compile(
    r"^[a-z0-9][a-z0-9./_-]*(?::[a-zA-Z0-9][a-zA-Z0-9._-]*)?"
    r"(?:@[a-zA-Z0-9:._-]+)?$"
)
CUSTOM_IMAGE_LABEL = "Custom / type manually..."


def image_uses_supported_package_manager(image):
    """Return whether an image is expected to use apt, dnf, or pacman."""
    image_name = image.lower()
    return (
        any(hint in image_name for hint in APT_IMAGE_HINTS)
        or any(hint in image_name for hint in DNF_IMAGE_HINTS)
        or any(hint in image_name for hint in PACMAN_IMAGE_HINTS)
    )


def compatible_images():
    """Read supported images from distrobox and keep package-compatible ones."""
    try:
        result = subprocess.run(
            ["distrobox", "create", "--compatibility"],
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        return []

    images = []
    for line in result.stdout.splitlines():
        image = line.strip()
        if (
            image
            and IMAGE_REFERENCE_RE.fullmatch(image)
            and image_uses_supported_package_manager(image)
            and image not in images
        ):
            images.append(image)
    return images


def container_exists(config_path, name):
    _, blocks = pkgadd.parse_config(config_path)
    return any(b["name"] == name for b in blocks)


def load_present_containers(present_path):
    """Return the set of container names that DistroText.sh has actually
    created, as recorded in present.txt. A container listed in config.txt
    but missing here has not been applied yet - distrobox-enter would not
    find it and would offer to create it with a default image instead,
    which is not what we want."""
    names = set()
    if not os.path.isfile(present_path):
        return names
    with open(present_path) as f:
        for line in f:
            line = line.strip()
            if line.startswith("Container:"):
                name = line.split(":", 1)[1].strip()
                if name:
                    names.add(name)
    return names


def valid_container_name(name):
    if not name:
        return "Name cannot be empty."
    if any(c.isspace() for c in name):
        return "Name cannot contain spaces."
    if ":" in name:
        return "Name cannot contain ':'."
    return None


def create_container(config_path, name, image, flags):
    lines, blocks = pkgadd.parse_config(config_path)
    if any(b["name"] == name for b in blocks):
        return f"'{name}': a container with this name already exists, nothing done."

    header = pkgadd.format_container_header(name, image, flags)
    lines = pkgadd.append_block(lines, header)
    with open(config_path, "w") as f:
        f.writelines(lines)
    return f"Added '{name}' ({image}) to config.txt."


def remove_container(config_path, name):
    lines, blocks = pkgadd.parse_config(config_path)
    block = next((b for b in blocks if b["name"] == name), None)
    if not block:
        return f"'{name}': not found in config.txt."

    lines = pkgadd.remove_block(lines, block)
    with open(config_path, "w") as f:
        f.writelines(lines)
    return f"Removed '{name}' from config.txt."


def add_package_to_container(config_path, container_name, pkg_name):
    """Re-reads config.txt, inserts pkg_name into container_name's block if
    it is not already present, writes the file back. Returns a status
    string describing what happened."""
    lines, blocks = pkgadd.parse_config(config_path)
    block = next((b for b in blocks if b["name"] == container_name), None)
    if not block:
        return f"'{container_name}': container not found (was it removed?)"

    idx = blocks.index(block)
    next_block = blocks[idx + 1] if idx + 1 < len(blocks) else None

    if pkgadd.package_already_present(lines, block, next_block, pkg_name):
        return f"'{container_name}': '{pkg_name}' already present, skipped"

    insert_at = pkgadd.find_insertion_point(lines, block, next_block)
    pkgadd.insert_package_line(lines, insert_at, pkg_name)
    with open(config_path, "w") as f:
        f.writelines(lines)
    return f"'{container_name}': added '{pkg_name}'"


def get_container_packages(config_path, container_name):
    """Return a list of package names for a given container."""
    lines, blocks = pkgadd.parse_config(config_path)
    block = next((b for b in blocks if b["name"] == container_name), None)
    if not block:
        return []
    
    # Find the packages in this container block using pkgadd's logic
    idx_block = blocks.index(block)
    next_block = blocks[idx_block + 1] if idx_block + 1 < len(blocks) else None
    
    return pkgadd.list_packages(lines, block, next_block)


def remove_package_from_container(config_path, container_name, pkg_name):
    """Remove a package from a container's block in config.txt.
    Returns a status string describing what happened."""
    lines, blocks = pkgadd.parse_config(config_path)
    block = next((b for b in blocks if b["name"] == container_name), None)
    if not block:
        return f"'{container_name}': container not found (was it removed?)"
    
    idx_block = blocks.index(block)
    next_block = blocks[idx_block + 1] if idx_block + 1 < len(blocks) else None
    
    # Check if package exists before attempting removal
    packages = pkgadd.list_packages(lines, block, next_block)
    if pkg_name not in packages:
        return f"'{container_name}': '{pkg_name}' not found in container"
    
    # Remove the package line
    pkgadd.remove_package_line(lines, block, next_block, pkg_name)
    
    with open(config_path, "w") as f:
        f.writelines(lines)
    
    return f"'{container_name}': removed '{pkg_name}'"


# ---------------------------------------------------------------------------
# Curses UI primitives
# ---------------------------------------------------------------------------

def text_input(stdscr, prompt, footer="[Enter] confirm   [ESC] cancel"):
    """Simple single-line text input. Returns the string, or None if the
    user pressed ESC."""
    curses.curs_set(1)
    buf = ""
    while True:
        stdscr.erase()
        h, w = stdscr.getmaxyx()
        stdscr.addstr(0, 0, prompt[: w - 1])
        stdscr.addstr(2, 0, ("> " + buf)[: w - 1])
        stdscr.addstr(h - 1, 0, footer[: w - 1])
        stdscr.move(2, min(2 + len(buf), w - 1))
        stdscr.refresh()

        ch = stdscr.get_wch()
        if ch == "\x1b":  # ESC
            curses.curs_set(0)
            return None
        if ch in ("\n", "\r"):
            curses.curs_set(0)
            return buf.strip()
        if ch in ("\b", "\x7f", curses.KEY_BACKSPACE):
            buf = buf[:-1]
        elif isinstance(ch, str) and ch.isprintable():
            buf += ch


def select_menu(stdscr, title, items, multi=False, footer=None):
    """items: list of strings. Returns:
       - single mode: selected index, or None if cancelled
       - multi mode: list of selected indices (possibly empty), or None if
         cancelled with no selection made
    """
    if not items:
        return None

    curses.curs_set(0)
    cur = 0
    top = 0
    checked = set()

    while True:
        stdscr.erase()
        h, w = stdscr.getmaxyx()
        stdscr.addstr(0, 0, title[: w - 1], curses.A_BOLD)
        visible_rows = h - 4

        if cur < top:
            top = cur
        if cur >= top + visible_rows:
            top = cur - visible_rows + 1

        for row, i in enumerate(range(top, min(top + visible_rows, len(items)))):
            line = items[i]
            prefix = ""
            if multi:
                prefix = "[x] " if i in checked else "[ ] "
            text = (prefix + line)[: w - 1]
            attr = curses.A_REVERSE if i == cur else curses.A_NORMAL
            stdscr.addstr(2 + row, 0, text, attr)

        default_footer = (
            "[Space] toggle  [Enter] confirm  [q/ESC] cancel"
            if multi else
            "[Enter] select  [q/ESC] cancel"
        )
        stdscr.addstr(h - 1, 0, (footer or default_footer)[: w - 1])
        stdscr.refresh()

        ch = stdscr.getch()
        if ch in (curses.KEY_UP, ord("k")):
            cur = (cur - 1) % len(items)
        elif ch in (curses.KEY_DOWN, ord("j")):
            cur = (cur + 1) % len(items)
        elif ch == ord(" ") and multi:
            if cur in checked:
                checked.discard(cur)
            else:
                checked.add(cur)
        elif ch in (curses.KEY_ENTER, ord("\n"), ord("\r")):
            if multi:
                return sorted(checked)
            return cur
        elif ch in (27, ord("q")):
            return None if not multi else None


def message_screen(stdscr, lines):
    curses.curs_set(0)
    stdscr.erase()
    h, w = stdscr.getmaxyx()
    for i, line in enumerate(lines[: h - 2]):
        stdscr.addstr(i, 0, line[: w - 1])
    stdscr.addstr(h - 1, 0, "[press any key to continue]"[: w - 1])
    stdscr.refresh()
    stdscr.getch()


# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------

def candidate_label(c):
    exact = ""
    return f"{c['pkg_name']:30s} {c['family_label']:10s} v{c['version']:<15s} {c['status']:10s} ({c['project']})"


def search_and_add_flow(stdscr, config_path):
    containers = load_containers(config_path)
    if not containers:
        message_screen(stdscr, [
            "No containers found in config.txt.",
            "Create one first (main menu -> Create a container).",
        ])
        return

    families = {}
    for c in containers:
        if c["family_key"]:
            families[c["family_key"]] = c["family_label"]

    term = text_input(stdscr, "Package search - type a package name (ESC to go back)")
    if not term:
        return

    stdscr.erase()
    stdscr.addstr(0, 0, f"Searching Repology for '{term}'...")
    stdscr.refresh()

    try:
        candidates = build_candidates(term, families or repofind.DEFAULT_FAMILIES)
    except SystemExit:
        message_screen(stdscr, ["Network or API error while contacting Repology."])
        return

    if not candidates:
        message_screen(stdscr, [f"No matching packages found for '{term}'."])
        return

    labels = [candidate_label(c) for c in candidates]
    idx = select_menu(stdscr, f"Results for '{term}' - pick a package:", labels)
    if idx is None:
        return
    chosen = candidates[idx]

    matching_containers = [c for c in containers if c["family_key"] == chosen["family_key"]]
    if not matching_containers:
        message_screen(stdscr, [
            f"No configured container uses the '{chosen['family_label']}' family.",
            "Nothing to do.",
        ])
        return

    container_labels = [f"{c['name']:20s} ({c['distro']})" for c in matching_containers]
    sel = select_menu(
        stdscr,
        f"Install '{chosen['pkg_name']}' into which container(s)?",
        container_labels,
        multi=True,
    )
    if not sel:
        return

    results = [
        add_package_to_container(config_path, matching_containers[i]["name"], chosen["pkg_name"])
        for i in sel
    ]
    message_screen(stdscr, ["Done:"] + results + ["", "Run DistroText.sh to apply the changes."])


def pick_image(stdscr):
    """Let the user pick a common image, or fall back to typing one in."""
    items = compatible_images() + [CUSTOM_IMAGE_LABEL]
    idx = select_menu(stdscr, "Pick an image (ESC to cancel):", items)
    if idx is None:
        return None
    if items[idx] == CUSTOM_IMAGE_LABEL:
        image = text_input(stdscr, "Image (e.g. 'ubuntu:22.04', 'fedora:39') - ESC to cancel")
        return image.strip() if image else None
    return items[idx]


def create_container_flow(stdscr, config_path):
    while True:
        name = text_input(stdscr, "New container name (e.g. 'ubuntu') - ESC to cancel")
        if name is None:
            return
        name = name.strip()
        err = valid_container_name(name)
        if err:
            message_screen(stdscr, [err])
            continue
        if container_exists(config_path, name):
            message_screen(stdscr, [f"A container named '{name}' already exists."])
            continue
        break

    image = pick_image(stdscr)
    if not image:
        return

    flag_idxs = select_menu(stdscr, "Flags (optional) for the new container:", KNOWN_FLAGS, multi=True)
    if flag_idxs is None:
        return
    flags = [KNOWN_FLAGS[i] for i in flag_idxs]

    result = create_container(config_path, name, image.strip(), flags)
    message_screen(stdscr, [result, "", "Run DistroText.sh to actually create the container."])


def remove_container_flow(stdscr, config_path):
    containers = load_containers(config_path)
    if not containers:
        message_screen(stdscr, ["No containers found in config.txt."])
        return

    labels = [f"{c['name']:20s} ({c['distro']})" for c in containers]
    sel = select_menu(stdscr, "Remove which container(s) from config.txt?", labels, multi=True)
    if not sel:
        return

    names = [containers[i]["name"] for i in sel]
    confirm = select_menu(
        stdscr,
        "Confirm removal of: " + ", ".join(names),
        ["Yes, remove", "No, cancel"],
    )
    if confirm != 0:
        return

    results = [remove_container(config_path, name) for name in names]
    message_screen(stdscr, ["Done:"] + results + [
        "",
        "Run DistroText.sh to actually destroy the container(s).",
    ])


def remove_package_flow(stdscr, config_path):
    """Allow user to remove packages from containers."""
    containers = load_containers(config_path)
    if not containers:
        message_screen(stdscr, [
            "No containers found in config.txt.",
            "Create one first (main menu -> Create a container).",
        ])
        return

    # Get packages for each container
    container_packages = []
    for c in containers:
        packages = get_container_packages(config_path, c["name"])
        container_packages.append((c, packages))
    
    # Show containers with their packages
    labels = []
    for container, packages in container_packages:
        if packages:
            package_list = ", ".join(packages[:3])  # Show first 3 packages
            if len(packages) > 3:
                package_list += f" (+{len(packages) - 3} more)"
            labels.append(f"{container['name']:20s} ({container['distro']}) - {package_list}")
        else:
            labels.append(f"{container['name']:20s} ({container['distro']}) - No packages")

    sel = select_menu(
        stdscr,
        "Remove packages from which container(s)?",
        labels,
        multi=True,
    )
    if not sel:
        return

    # Get selected containers
    selected_containers = [container_packages[i][0] for i in sel]
    
    # For each selected container, show its packages and allow removal
    results = []
    for container in selected_containers:
        packages = get_container_packages(config_path, container["name"])
        if not packages:
            results.append(f"'{container['name']}': No packages to remove")
            continue
            
        package_labels = [f"{pkg}" for pkg in packages]
        package_sel = select_menu(
            stdscr,
            f"Remove which packages from '{container['name']}'?",
            package_labels,
            multi=True,
        )
        if not package_sel:
            continue
            
        # Remove selected packages
        for i in package_sel:
            # Add confirmation step
            confirm_msg = [
                f"Are you sure you want to remove '{packages[i]}' from '{container['name']}'?",
                "",
                "This action cannot be undone.",
            ]
            if not confirm_screen(stdscr, confirm_msg):
                results.append(f"'{container['name']}': removal of '{packages[i]}' cancelled")
                continue
                
            result = remove_package_from_container(config_path, container["name"], packages[i])
            results.append(result)
    
    message_screen(stdscr, ["Done:"] + results + ["", "Run DistroText.sh to apply the changes."])


def enter_container_flow(stdscr, config_path, present_path):
    containers = load_containers(config_path)
    if not containers:
        message_screen(stdscr, ["No containers found in config.txt."])
        return

    present_names = load_present_containers(present_path)

    labels = []
    for c in containers:
        created = c["name"] in present_names
        suffix = "" if created else "  [not created yet - run DistroText.sh]"
        labels.append(f"{c['name']:20s} ({c['distro']}){suffix}")

    idx = select_menu(stdscr, "Enter which container?", labels)
    if idx is None:
        return
    name = containers[idx]["name"]

    if name not in present_names:
        message_screen(stdscr, [
            f"'{name}' has not been created yet.",
            "It is only defined in config.txt so far.",
            "",
            "Run DistroText.sh first (main menu -> Run DistroText.sh),",
            "otherwise distrobox would report it as missing and offer",
            "to create it with a default image, which breaks the setup.",
        ])
        return

    # Drop out of curses mode so distrobox-enter gets a real interactive
    # shell attached to the terminal.
    curses.def_prog_mode()
    curses.endwin()
    try:
        print(f"\n--- Entering '{name}' (type 'exit' to return) ---\n")
        try:
            result = subprocess.run(["distrobox-enter", name])
            rc = result.returncode
        except FileNotFoundError:
            print("'distrobox-enter' not found in PATH.")
            rc = None
        print()
        if rc == 0:
            print(f"--- Left '{name}' ---")
        elif rc is not None:
            print(f"--- 'distrobox-enter {name}' exited with code {rc} "
                  f"(container may not exist yet - run DistroText.sh first) ---")
        input("Press Enter to return to the menu...")
    finally:
        curses.reset_prog_mode()
        stdscr.clear()
        stdscr.refresh()


def upgrade_all_containers_flow(stdscr):
    """Run 'distrobox-upgrade --all' to upgrade every existing container."""
    # Drop out of curses mode so distrobox-upgrade's own output (and any
    # sudo password prompt it triggers) shows up normally in the terminal.
    curses.def_prog_mode()
    curses.endwin()
    try:
        print("\n--- Upgrading all containers (distrobox-upgrade --all) ---\n")
        try:
            result = subprocess.run(["distrobox-upgrade", "--all"])
            rc = result.returncode
        except FileNotFoundError:
            print("'distrobox-upgrade' not found in PATH.")
            rc = None
        print()
        if rc == 0:
            print("--- All containers upgraded successfully ---")
        elif rc is not None:
            print(f"--- distrobox-upgrade exited with code {rc} ---")
        input("Press Enter to return to the menu...")
    finally:
        curses.reset_prog_mode()
        stdscr.clear()
        stdscr.refresh()


def run_distrotext_sh(stdscr, script_path):
    if not os.path.isfile(script_path):
        message_screen(stdscr, [
            f"'{script_path}' not found.",
            "Use --script to point pkgtui.py at your DistroText.sh.",
        ])
        return

    # Drop out of curses mode so the script's own output (and any sudo
    # password prompt it triggers) shows up normally in the real terminal.
    curses.def_prog_mode()
    curses.endwin()
    try:
        print(f"\n--- Running {script_path} ---\n")
        result = subprocess.run(["bash", script_path], cwd=os.path.dirname(script_path) or ".")
        print()
        if result.returncode == 0:
            print("--- DistroText.sh finished successfully ---")
        else:
            print(f"--- DistroText.sh exited with code {result.returncode} ---")
        input("Press Enter to return to the menu...")
    finally:
        curses.reset_prog_mode()
        stdscr.clear()
        stdscr.refresh()


def run(stdscr, config_path, script_path, present_path):
    curses.use_default_colors()

    main_menu_items = [
        "Search & add a package to a container",
        "Remove packages from container",
        "Create a container",
        "Remove a container",
        "Enter a container (shell)",
        "Upgrade all containers",
        "Run DistroText.sh (apply changes)",
        "Quit",
    ]

    while True:
        choice = select_menu(stdscr, "DistroText - main menu", main_menu_items, footer="[Enter] select  [q/ESC] quit")
        if choice is None or choice == 7:
            return
        if choice == 0:
            search_and_add_flow(stdscr, config_path)
        elif choice == 1:
            remove_package_flow(stdscr, config_path)
        elif choice == 2:
            create_container_flow(stdscr, config_path)
        elif choice == 3:
            remove_container_flow(stdscr, config_path)
        elif choice == 4:
            enter_container_flow(stdscr, config_path, present_path)
        elif choice == 5:
            upgrade_all_containers_flow(stdscr)
        elif choice == 6:
            run_distrotext_sh(stdscr, script_path)


def main():
    parser = argparse.ArgumentParser(description="Interactive TUI to search Repology and add a package to a DistroText container")
    parser.add_argument("--config", default="config.txt", help="Path to config.txt (default: ./config.txt)")
    parser.add_argument(
        "--script",
        default=None,
        help="Path to DistroText.sh (default: DistroText.sh next to --config)",
    )
    parser.add_argument(
        "--present",
        default=None,
        help="Path to present.txt (default: present.txt next to --config)",
    )
    args = parser.parse_args()

    if not os.path.isfile(args.config):
        print(f"Error: configuration file not found: {args.config}", file=sys.stderr)
        sys.exit(1)

    config_path = os.path.abspath(args.config)
    script_path = os.path.abspath(args.script) if args.script else os.path.join(
        os.path.dirname(config_path), "DistroText.sh"
    )
    present_path = os.path.abspath(args.present) if args.present else os.path.join(
        os.path.dirname(config_path), "present.txt"
    )
    curses.wrapper(run, config_path, script_path, present_path)


def confirm_screen(stdscr, lines):
    """Display a confirmation message and wait for Y/N response."""
    curses.curs_set(0)
    stdscr.erase()
    h, w = stdscr.getmaxyx()
    for i, line in enumerate(lines[: h - 3]):
        stdscr.addstr(i, 0, line[: w - 1])
    stdscr.addstr(h - 3, 0, "Confirm? (y/N): "[: w - 1])
    stdscr.refresh()
    
    while True:
        key = stdscr.getch()
        if key in (ord('y'), ord('Y')):
            return True
        elif key in (ord('n'), ord('N'), curses.KEY_EXIT, 27):  # ESC
            return False
        elif key in (ord('\n'), ord('\r')):
            return False


if __name__ == "__main__":
    main()
