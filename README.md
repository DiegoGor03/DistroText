# DistroText
A script and TUI to configure distrobox containers from text file

## Quick start
This script let's you manage distrobox containers in a config.txt (in the same directory of ther script) file with the following sintax:
```
home_directory: /home/user/distrobox_homes
-container1: image
program1
program2
-ubuntu: ubuntu:22.04 --flags
nala
librecad
```

When a program is removed and the script is executed the program is uninstalled and the container is recreated.  
This can be avoided by using the --no-recrate flag

## Flags
--nvidia: enables nvidia drivers on the container  
--no-recreate: avoids the container from being recreated when a package is uninstalled  
--no-autoexport: disables the autoexport feature  

## Interactive TUI (pkgtui.py)
`pkgtui.py` wraps the whole workflow - editing config.txt and running
DistroText.sh - into one terminal menu, built on top of repofind.py and
pkgadd.py (it needs both in the same directory to run).
```
./pkgtui.py [--config config.txt] [--script DistroText.sh]
```
From the main menu you can:
- **Search & add a package to a container** - search Repology once, pick a
  result, then pick which configured container(s) to add it to (only
  containers whose distro family matches the result are offered).
- **Create a container** - pick a name, pick an image from a list of
  common distrobox images (or choose "Custom" to type any image
  manually), and pick flags (`--nvidia`, `--no-recreate`,
  `--no-autoexport`). Adds a new block to config.txt.
- **Remove a container** - pick one or more configured containers and
  delete their block from config.txt (with a confirmation prompt).
- **Enter a container (shell)** - runs `distrobox-enter` on a container so
  you can poke around inside it.
- **Run DistroText.sh (apply changes)** - runs the script so any of the
  above edits actually get applied (containers created/destroyed,
  packages installed/removed).

Like `pkgadd.py`, every action above except "Run DistroText.sh" and "Enter
a container" only edits config.txt - it never calls distrobox directly.
Nothing is actually created, removed, or installed until DistroText.sh
runs, either from the menu or by hand as usual.

Controls: Up/Down (or j/k) to move, Enter to confirm/select, Space to
toggle an item in a multi-select list, ESC/q to go back or cancel.

## Installation

1. Make sure `install_launcher.sh`, `pkgtui.py`, and `DistroText_icon.png` are all in the same folder.
2. Open a terminal in that folder and run:

   ```bash
   ./install_launcher.sh
   ```

   If the script isn't executable yet, first run:

   ```bash
   chmod +x install_launcher.sh
   ```

This copies all the application files to `~/.local/share/DistroText` and creates a launcher entry, so **DistroText** will appear in your application menu.

## Updating

To update to a newer version, just copy the new files (including the updated `install_launcher.sh`) into a folder and run the script again:

```bash
./install_launcher.sh
```

The installer detects the existing installation and replaces it cleanly, so no files from the previous version are left behind.

## Uninstalling

To remove DistroText, run:

```bash
./install_launcher.sh --uninstall
```

This deletes the installed files (`~/.local/share/DistroText`) and the application menu entry.

## Help

To see all available options:

```bash
./install_launcher.sh --help
```

## Finding package names (repofind.py, pkgadd.py)
Package names differ across distros, so two standalone helper scripts are
included to look them up via [Repology](https://repology.org). They work
exactly as before and don't require pkgtui.py:

- `repofind.py <term>` searches Repology and prints the matching package
  name for each configured distro family, so you know what to write in
  config.txt.
  ```
  ./repofind.py libreoffice
  ./repofind.py htop --families ubuntu,fedora,arch --exact
  ```
- `pkgadd.py <container> <term>` does the same search, but scoped to one
  container already defined in config.txt (it infers the distro family
  from that container's image), and adds your chosen result straight into
  that container's block in config.txt for you.
  ```
  ./pkgadd.py ubuntu libreoffice
  ./pkgadd.py test htop --config /path/to/config.txt
  ```

Both remain plain command-line tools and can be used on their own, without
the TUI.
