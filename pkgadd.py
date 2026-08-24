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
pkgadd.py - Search Repology for a package in the correct distro family and
add it directly to the container block in config.txt (DistroText).

Usage:
    ./pkgadd.py <container> <search term> [--config config.txt] [--family FAMILY]

Example:
    ./pkgadd.py ubuntu libreoffice
    ./pkgadd.py test htop --config /path/to/config.txt

The container name and distro are read from the existing
"-container: image [flag...]" line in config.txt; the Repology family
(ubuntu/fedora/arch/...) is inferred from the image name.
If inference fails (for example, with a custom image), you can force it with --family.
"""

import sys
import os
import argparse

import repofind  # reuses search_projects, filter_families, DEFAULT_FAMILIES

# Heuristic: substring in the image name -> Repology family
IMAGE_FAMILY_HINTS = [
    ("ubuntu", "ubuntu"),
    ("debian", "debian"),
    ("fedora", "fedora"),
    ("arch", "arch"),
    ("alpine", "alpine"),
    ("opensuse", "opensuse"),
    ("suse", "opensuse"),
]

MAX_CANDIDATES_SHOWN = 15


def parse_config(path):
    """Return (lines, blocks). blocks: [{'name','distro','header_line','end'}, ...]
    header_line/end are 0-based indices in the 'lines' list."""
    with open(path, "r") as f:
        lines = f.readlines()

    # If the file doesn't end with a newline, readlines() leaves the last
    # line without one. Inserting a new line right after it would then glue
    # the two together on the same physical line, so normalize it here.
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"

    blocks = []
    current = None
    for i, raw in enumerate(lines):
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith("home_directory:"):
            continue
        if stripped.startswith("-") and ":" in stripped:
            if current:
                current["end"] = i
                blocks.append(current)
            head, rest = stripped.split(":", 1)
            name = head[1:].strip()
            rest = rest.strip()
            distro = rest.split()[0] if rest else ""
            current = {"name": name, "distro": distro, "header_line": i, "end": None}
        # Package lines do not need to be tracked here, only the block range.

    if current:
        current["end"] = len(lines)
        blocks.append(current)

    return lines, blocks


def guess_family(distro_string):
    low = distro_string.lower()
    for hint, family in IMAGE_FAMILY_HINTS:
        if hint in low:
            return family
    return None


def find_insertion_point(lines, block, next_block):
    """Return where to insert the new package: immediately before the next
    block (or the end of the file), skipping any trailing blank lines."""
    end = next_block["header_line"] if next_block else len(lines)
    insert_at = end
    while insert_at > block["header_line"] + 1 and lines[insert_at - 1].strip() == "":
        insert_at -= 1
    return insert_at


def insert_package_line(lines, insert_at, pkg_name):
    """Insert pkg_name as its own line at index insert_at. Guards against the
    classic 'missing trailing newline' bug: if the line right before the
    insertion point doesn't end with '\\n' (typically the last line of a
    file that wasn't newline-terminated), the new package would otherwise
    get glued onto the end of it instead of starting on its own line."""
    if insert_at > 0 and not lines[insert_at - 1].endswith("\n"):
        lines[insert_at - 1] = lines[insert_at - 1] + "\n"
    lines.insert(insert_at, pkg_name + "\n")


def remove_block(lines, block):
    """Return a new list of lines with the given container block (header
    line through its package lines) cut out entirely."""
    return lines[: block["header_line"]] + lines[block["end"]:]


def format_container_header(name, image, flags):
    """Build a '-name: image [flags...]' header line, e.g.
    format_container_header('ubuntu', 'ubuntu:22.04', ['--nvidia'])."""
    flag_str = " ".join(flags)
    line = f"-{name}: {image}"
    if flag_str:
        line += f" {flag_str}"
    return line + "\n"


def append_block(lines, header_line):
    """Append a new container header line at the end of the file, making
    sure it starts on its own line (guards against a missing trailing
    newline the same way insert_package_line does) and is separated from
    any preceding content by a blank line for readability."""
    if lines and not lines[-1].endswith("\n"):
        lines[-1] = lines[-1] + "\n"
    if lines and lines[-1].strip() != "":
        lines.append("\n")
    lines.append(header_line)
    return lines


def package_already_present(lines, block, next_block, pkg_name):
    end = next_block["header_line"] if next_block else len(lines)
    for i in range(block["header_line"] + 1, end):
        if lines[i].strip() == pkg_name:
            return True
    return False


def main():
    parser = argparse.ArgumentParser(
        description="Search Repology for a package and add it to the DistroText config.txt"
    )
    parser.add_argument("container", help="Name of the container defined in config.txt (for example, 'ubuntu')")
    parser.add_argument("term", help="Name or part of the package name to search for")
    parser.add_argument("--config", default="config.txt", help="Path to config.txt (default: ./config.txt)")
    parser.add_argument(
        "--family",
        default=None,
        help="Force the Repology family (ubuntu, fedora, arch, ...) instead of inferring it from the image",
    )
    args = parser.parse_args()

    if not os.path.isfile(args.config):
        print(f"Error: configuration file not found: {args.config}", file=sys.stderr)
        sys.exit(1)

    lines, blocks = parse_config(args.config)

    block = next((b for b in blocks if b["name"] == args.container), None)
    if not block:
        names = ", ".join(b["name"] for b in blocks) or "(none)"
        print(f"Error: container '{args.container}' not found in {args.config}.", file=sys.stderr)
        print(f"Available containers: {names}", file=sys.stderr)
        sys.exit(1)

    family_key = args.family or guess_family(block["distro"])
    if not family_key:
        print(
            f"Unable to infer the distro from '{block['distro']}'. "
            f"Specify --family (for example, --family ubuntu).",
            file=sys.stderr,
        )
        sys.exit(1)
    if family_key not in repofind.DEFAULT_FAMILIES:
        print(
            f"Unknown family '{family_key}'. Known families: "
            f"{', '.join(repofind.DEFAULT_FAMILIES)}",
            file=sys.stderr,
        )
        sys.exit(1)

    label = repofind.DEFAULT_FAMILIES[family_key]
    families = {family_key: label}

    print(f"Searching for '{args.term}' for '{block['name']}' ({block['distro']}, family: {family_key})...")
    projects = repofind.search_projects(args.term)
    if not projects:
        print("No results found on Repology.")
        sys.exit(1)

    ordered_names = sorted(projects.keys(), key=lambda n: (n != args.term, len(n), n))
    candidates = []
    for project_name in ordered_names:
        grouped = repofind.filter_families(projects[project_name], families, show_all=False)
        if label not in grouped:
            continue
        for pkg_name, (version, status) in sorted(grouped[label].items()):
            candidates.append((project_name, pkg_name, version, status))

    if not candidates:
        print(f"No package found for the '{family_key}' family.")
        sys.exit(1)

    print()
    shown = candidates[:MAX_CANDIDATES_SHOWN]
    for idx, (project_name, pkg_name, version, status) in enumerate(shown, start=1):
        marker = "  <- exact match" if project_name == args.term else ""
        print(f"  [{idx}] {pkg_name}  (v{version}, {status}){marker}")
    if len(candidates) > MAX_CANDIDATES_SHOWN:
        print(f"  ... and {len(candidates) - MAX_CANDIDATES_SHOWN} more results not shown")

    print()
    choice = input(
        "Number to add (press Enter to cancel, or type a package name manually): "
    ).strip()

    if not choice:
        print("Cancelled, no changes made.")
        return

    if choice.isdigit() and 1 <= int(choice) <= len(shown):
        pkg_name = shown[int(choice) - 1][1]
    else:
        pkg_name = choice

    idx_block = blocks.index(block)
    next_block = blocks[idx_block + 1] if idx_block + 1 < len(blocks) else None

    if package_already_present(lines, block, next_block, pkg_name):
        print(f"'{pkg_name}' is already present in the '{block['name']}' block. No changes made.")
        return

    insert_at = find_insertion_point(lines, block, next_block)
    insert_package_line(lines, insert_at, pkg_name)

    with open(args.config, "w") as f:
        f.writelines(lines)

    print(f"Added '{pkg_name}' to the '{block['name']}' container in {args.config}.")


if __name__ == "__main__":
    main()
