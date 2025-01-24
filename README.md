# DistroBash
A script to configure DistroBox containers from text file

## Quick start
This script let's you manage distrobox containers in a config.txt (in the same directory of ther script) file with the following sintax:
'''
home_directory: /home/user/distrobox_homes
-container1: image
program1
program2
-ubuntu: ubuntu:22.04 --flags
nala
librecad
'''

When a program is removed and the script is executed the program is uninstalled and the container is recreated.
This can be avoided by using the --no-recrate flag

## Flags
--nvidia: enables nvidia drivers on the container
--no-recreate: avoids the container from being recreated when a package is uninstalled
--no-autoexport: disables the autoexport feature
