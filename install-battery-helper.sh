#!/usr/bin/env bash
# Optional: lets Archmonitor change the battery charge window (sudo ./install-battery-helper.sh).
# Installs a small root helper, its polkit rule and a boot unit that re-applies the saved
# window. Without it the widget shows the window read-only.
#   sudo ./install-battery-helper.sh              install or upgrade
#   sudo ./install-battery-helper.sh --uninstall  remove (thresholds stay as they are)
set -euo pipefail
cd "$(dirname "$0")"
(( EUID == 0 )) || { echo "ejecutalo con sudo: sudo $0 $*"; exit 1; }

HELPER=/usr/local/lib/archmonitor/archmonitor-battery
POLICY=/usr/share/polkit-1/actions/io.arquimedes.archmonitor.battery.policy
UNIT=/etc/systemd/system/archmonitor-battery.service
CONF=/etc/archmonitor/battery.conf

if [[ ${1:-} == --uninstall ]]; then
    systemctl disable archmonitor-battery.service 2>/dev/null || true
    rm -f "$HELPER" "$POLICY" "$UNIT"
    rmdir /usr/local/lib/archmonitor 2>/dev/null || true
    systemctl daemon-reload
    echo "Desinstalado. $CONF se conserva; borralo a mano si no lo querés."
    exit 0
fi

# A battery with thresholds, or there is nothing to control.
bat=""
for b in /sys/class/power_supply/*; do
    [[ $(cat "$b/type" 2>/dev/null) == Battery && $(cat "$b/scope" 2>/dev/null) != Device \
       && -e $b/charge_control_end_threshold ]] && { bat=$b; break; }
done
[[ -n $bat ]] || { echo "Esta máquina no expone umbrales de carga (charge_control_end_threshold). Nada que instalar."; exit 1; }
command -v pkexec >/dev/null || { echo "falta pkexec (sudo pacman -S polkit)"; exit 1; }

install -D -o root -g root -m 0755 extras/battery/archmonitor-battery "$HELPER"
install -D -o root -g root -m 0644 extras/battery/io.arquimedes.archmonitor.battery.policy "$POLICY"
install -D -o root -g root -m 0644 extras/battery/archmonitor-battery.service "$UNIT"

# First install: keep whatever window is in force now, so nothing changes until the
# window is moved in the widget.
if [[ ! -e $CONF ]]; then
    end=$(cat "$bat/charge_control_end_threshold" 2>/dev/null || echo 100)
    start=$(cat "$bat/charge_control_start_threshold" 2>/dev/null || echo 0)
    if [[ $end =~ ^[0-9]+$ && $start =~ ^[0-9]+$ ]] && (( end < 100 && end >= 50 && end - start >= 5 && start <= 95 )); then
        "$HELPER" set "$start" "$end"
        echo "Ventana actual guardada: $start–$end %."
    else
        echo "Sin ventana activa (fin = ${end} %): se elige en el widget."
    fi
fi

systemctl daemon-reload
systemctl enable archmonitor-battery.service >/dev/null
echo "OK. En el widget: clic en BATTERY para ajustar la ventana o cargar al 100 %."

# Another unit that writes thresholds at boot would undo the widget's choice on every boot.
for u in battery-care.service tlp.service; do
    if systemctl is-enabled "$u" >/dev/null 2>&1; then
        echo "aviso: $u también fija umbrales al arrancar y pisaría lo que elijas en el widget."
        [[ $u == battery-care.service ]] && echo "       sudo systemctl disable --now $u && sudo rm /etc/systemd/system/$u"
        [[ $u == tlp.service ]] && echo "       en /etc/tlp.conf comentá START_CHARGE_THRESH_* y STOP_CHARGE_THRESH_*"
    fi
done
