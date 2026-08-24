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
repofind.py - Find the correct package name across different distributions
using Repology's public API (https://repology.org/api/v1).

Usage:
    ./repofind.py <search term> [--families ubuntu,fedora,arch] [--exact]

Examples:
    ./repofind.py libreoffice
    ./repofind.py build-essential --families ubuntu,fedora,arch
    ./repofind.py htop --exact
"""

import sys
import time
import json
import argparse
import urllib.request
import urllib.error
import urllib.parse

API_BASE = "https://repology.org/api/v1"
USER_AGENT = "repofind.py/1.0 (github.com/DiegoGor03/DistroText)"

# Distribution families usually relevant to DistroText (distrobox).
# The key is the filter applied to the "repo" field returned by Repology;
# the value is simply a more readable label to print.
DEFAULT_FAMILIES = {
    "ubuntu": "Ubuntu",
    "debian": "Debian",
    "fedora": "Fedora",
    "arch": "Arch Linux",
    "alpine": "Alpine",
    "opensuse": "openSUSE",
}


def api_get(url):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        print(f"HTTP error {e.code} while calling {url}", file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as e:
        print(f"Network error: {e.reason}", file=sys.stderr)
        sys.exit(1)


def search_projects(term):
    """Search for projects whose name contains 'term' (case-insensitive substring)."""
    url = f"{API_BASE}/projects/?search={urllib.parse.quote(term)}"
    return api_get(url)


def get_exact_project(term):
    """Retrieve a project by exact name (Repology's internal name)."""
    url = f"{API_BASE}/project/{urllib.parse.quote(term)}"
    data = api_get(url)
    return {term: data} if data else {}


import re

RELEVANT_STATUSES = {"newest", "devel", "unique"}
MAX_LINES_PER_FAMILY = 3
MAX_PROJECTS_SHOWN = 6


def _version_key(version):
    """Approximate comparison key for versions such as '26.2.5.2' and '0.52.6~rc1'."""
    parts = re.split(r"[.~+_-]", version or "")
    key = []
    for p in parts:
        key.append((0, int(p)) if p.isdigit() else (1, p))
    return key


def filter_families(entries, families, show_all):
    """Group entries by distribution family, keeping only the requested ones.

    NOTE: Repology's 'newest' status is calculated by comparing the version
    across ALL tracked distributions, not just the ones you care about: if
    another distribution has a newer version, even the most up-to-date package
    in Ubuntu/Fedora/Arch may be marked 'outdated'. Therefore, by default we
    do NOT filter by status: for each package (binname) within a family, we
    keep only the highest version found in that family.
    With --all, all historical versions are shown without deduplication.
    """
    grouped = {}
    for entry in entries:
        repo = entry.get("repo", "")
        status = entry.get("status", "")
        for fam_key, fam_label in families.items():
            if fam_key not in repo:
                continue
            pkg_name = entry.get("visiblename") or entry.get("srcname") or entry.get("binname")
            if not pkg_name:
                continue
            version = entry.get("version", "")
            grouped.setdefault(fam_label, {})

            if show_all:
                # No deduplication: keep all versions, using (pkg_name, version) as the key
                grouped[fam_label][(pkg_name, version)] = (version, status)
            else:
                existing = grouped[fam_label].get(pkg_name)
                if existing is None or _version_key(version) > _version_key(existing[0]):
                    grouped[fam_label][pkg_name] = (version, status)
    return grouped


def print_results(projects, families, show_all, term):
    if not projects:
        print("No projects found. Try --exact if you already know the exact name,")
        print("or try a different search term.")
        return

    # Prioritize the exact name, then the shortest names (more likely direct matches)
    ordered_names = sorted(
        projects.keys(),
        key=lambda n: (n != term, len(n), n),
    )

    shown = 0
    hidden = 0
    for project_name in ordered_names:
        entries = projects[project_name]
        grouped = filter_families(entries, families, show_all)
        if not grouped:
            continue
        if shown >= MAX_PROJECTS_SHOWN:
            hidden += 1
            continue
        shown += 1
        print(f"\n=== {project_name} ===")
        for fam_label in families.values():
            if fam_label not in grouped:
                continue
            items = sorted(grouped[fam_label].items(), key=lambda kv: kv[0])
            line_limit = len(items) if show_all else MAX_LINES_PER_FAMILY
            for key, (version, status) in items[:line_limit]:
                pkg_name = key[0] if isinstance(key, tuple) else key
                print(f"  {fam_label:12s} -> {pkg_name} ({version}, {status})")
            extra = len(items) - line_limit
            if extra > 0:
                print(f"  {'':12s}    ... and {extra} more variants (use --all to see them)")

    if hidden > 0:
        print(f"\n({hidden} other matching projects hidden, use --limit to see more)")


def main():
    global MAX_PROJECTS_SHOWN
    parser = argparse.ArgumentParser(description="Find a package name across distributions via Repology")
    parser.add_argument("term", help="Package name (or part of the name) to search for")
    parser.add_argument(
        "--families",
        default="ubuntu,debian,fedora,arch,alpine,opensuse",
        help="Comma-separated list of distribution families to show (default: all)",
    )
    parser.add_argument(
        "--exact",
        action="store_true",
        help="Search by exact project name instead of a substring",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="Also show outdated/legacy versions and all variants (no filtering/limit)",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=MAX_PROJECTS_SHOWN,
        help=f"Maximum number of projects to show (default: {MAX_PROJECTS_SHOWN})",
    )
    args = parser.parse_args()
    MAX_PROJECTS_SHOWN = args.limit

    families = {k: v for k, v in DEFAULT_FAMILIES.items() if k in args.families.split(",")}
    if not families:
        print("No valid distribution family specified.", file=sys.stderr)
        sys.exit(1)

    if args.exact:
        projects = get_exact_project(args.term)
    else:
        projects = search_projects(args.term)
        # Be gentle with the public API rate limit
        time.sleep(0.2)

    print_results(projects, families, args.all, args.term)


if __name__ == "__main__":
    main()
