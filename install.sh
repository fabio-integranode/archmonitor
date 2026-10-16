#!/usr/bin/env bash
# Install or upgrade Archmonitor and retire the old Conky setup.
set -euo pipefail
cd "$(dirname "$0")"
ID=io.arquimedes.archimonitor

for dep in iw stat; do command -v "$dep" >/dev/null || { echo "falta: $dep"; exit 1; }; done
fc-list | grep -i 'Inter' >/dev/null || echo "aviso: instalá inter-font"
fc-list | grep -i 'JetBrains Mono' >/dev/null || echo "aviso: instalá ttf-jetbrains-mono"
command -v playerctl >/dev/null || echo "aviso: instalá playerctl para la barra de música (sudo pacman -S playerctl)"

if kpackagetool6 -t Plasma/Applet -l | grep -qx "$ID"; then
    kpackagetool6 -t Plasma/Applet -u .
else
    kpackagetool6 -t Plasma/Applet -i .
fi

# Plasma keeps compiled QML in a cache; drop it so the new version is what runs.
rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/plasmashell/qmlcache"

# Retire Conky: stop it and disable its autostart, keep the config as backup.
pkill -x conky 2>/dev/null || true
for f in ~/.config/autostart/conky*.desktop; do [[ -e $f ]] && mv "$f" "$f.disabled"; done
systemctl --user disable --now conky.service 2>/dev/null || true

echo "OK. Clic derecho en el escritorio → Añadir elementos gráficos → «Archmonitor»."
echo "Versión instalada: $(grep -o '"Version": *"[^"]*"' metadata.json)"
echo "Tras actualizar: systemctl --user restart plasma-plasmashell"
