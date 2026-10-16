#!/usr/bin/env bash
# Build dist/archmonitor-<version>.plasmoid: the installable widget package (a zip with
# metadata.json at its root). Only what Plasma loads goes in: no tests, docs or video.
set -euo pipefail
cd "$(dirname "$0")"
command -v zip >/dev/null || { echo "falta: zip (sudo pacman -S zip)"; exit 1; }

ver=$(sed -n 's/.*"Version": *"\([^"]*\)".*/\1/p' metadata.json)
[[ -n $ver ]] || { echo "no encuentro la versión en metadata.json"; exit 1; }
out=dist/archmonitor-$ver.plasmoid

mkdir -p dist
rm -f "$out"
# -X: no extra file attributes, so two builds of the same tree are byte-identical
# except for timestamps.
zip -qrX "$out" metadata.json contents LICENSE -x '*/__pycache__/*' '*.qmlc' '*.jsc' '*~'
echo "$out ($(du -h "$out" | cut -f1))"
echo "Instalar:   kpackagetool6 -t Plasma/Applet -i $out"
echo "Actualizar: kpackagetool6 -t Plasma/Applet -u $out && systemctl --user restart plasma-plasmashell"
