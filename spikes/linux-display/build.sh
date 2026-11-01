#!/bin/sh
# Builds pwprobe into $1 (default: ./build, which is not committed). Needs libpipewire-0.3-dev.
set -eu
here=$(dirname "$0")
out=${1:-"$here/build"}
mkdir -p "$out"
cc -O2 -Wall -o "$out/pwprobe" "$here/pwprobe.c" $(pkg-config --cflags --libs libpipewire-0.3)
echo "$out/pwprobe"
