#!/usr/bin/env bash
# Hardware portability tests: the probe against fake /sys trees of machines other than
# the author's (Intel, NVIDIA hybrid, self-built desktop, ARM board, VM) and fake
# systemctl answers for security set-ups other than his. No hardware needed.
set -u
here=$(cd "$(dirname "$0")" && pwd)
probe=$here/../contents/code/archi-stat.sh
if [[ -n ${ARCHI_KEEP:-} ]]; then tmp=$ARCHI_KEEP; mkdir -p "$tmp"; else tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT; fi
fail=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fail=1; }

# w FILE VALUE — write a sysfs-style file, creating its directory.
w() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"; }
# get JSON PATH — a jq path from the probe output; "null" for JSON null.
get() { jq -r "$2 | if . == null then \"null\" else tostring end" <<< "$1"; }
# check LABEL JSON PATH=VALUE...
check() {
    local label=$1 json=$2 kv k v g; shift 2
    jq -e . >/dev/null 2>&1 <<< "$json" || { bad "$label (invalid JSON: $json)"; return; }
    for kv; do
        k=${kv%%=*} v=${kv#*=}
        g=$(get "$json" "$k")
        [[ $g == "$v" ]] || { bad "$label: $k = $g, want $v"; return; }
    done
    ok "$label"
}
# A route file so the probe has an uplink and does not reach for the real /sys net tree.
rt=$tmp/route
printf '%s\n' $'Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\tMTU\tWindow\tIRTT' \
    $'wlan0\t00000000\t0101A8C0\t0003\t0\t0\t600\t00000000\t0\t0\t0' > "$rt"
fast() { local sys=$1; shift; env ARCHI_SYS="$sys" ARCHI_ROUTE="$rt" ARCHI_NVSMI="$tmp/no-nvsmi" "$@" bash "$probe"; }

echo "AMD ThinkPad (the author's laptop: nothing may change)"
S=$tmp/amd
w $S/class/hwmon/hwmon0/name k10temp;  w $S/class/hwmon/hwmon0/temp1_label Tctl; w $S/class/hwmon/hwmon0/temp1_input 53000
w $S/class/hwmon/hwmon1/name amdgpu;   w $S/class/hwmon/hwmon1/temp1_input 48000; w $S/class/hwmon/hwmon1/in1_input 750
w $S/class/hwmon/hwmon1/power1_average 14500000; w $S/class/hwmon/hwmon1/freq1_input 600000000
w $S/class/hwmon/hwmon1/device/gpu_busy_percent 9
w $S/class/hwmon/hwmon2/name nvme;     w $S/class/hwmon/hwmon2/temp1_input 41000
w $S/class/hwmon/hwmon3/name thinkpad; w $S/class/hwmon/hwmon3/fan1_input 2400
w $S/class/hwmon/hwmon4/name acpitz;   w $S/class/hwmon/hwmon4/temp1_input 99000
w $S/class/dmi/id/sys_vendor LENOVO;   w $S/class/dmi/id/product_name 21QA0012AR; w $S/class/dmi/id/product_version "ThinkPad T14 Gen 7"
w $S/class/power_supply/AC/type Mains
w $S/class/power_supply/BAT0/type Battery; w $S/class/power_supply/BAT0/capacity 99; w $S/class/power_supply/BAT0/status Charging
w $S/class/power_supply/BAT0/power_now 7300000; w $S/class/power_supply/BAT0/energy_now 50000000
w $S/class/power_supply/BAT0/energy_full 52000000; w $S/class/power_supply/BAT0/charge_control_end_threshold 100
check "k10temp, amdgpu APU (SOC power), nvme, thinkpad fan, BAT0, model from product_version" "$(fast $S)" \
    .cpu_temp=53000 .src.cpu=k10temp .gpu_busy=9 .gpu_temp=48000 .gpu_freq=600 .src.gpu=amdgpu \
    .soc_power=14500000 .power_kind=soc .ssd_temp=41000 .src.ssd=nvme .fan=2400 .src.fan=thinkpad \
    .bat_cap=99 .bat_power=7300000 .bat_energy=50000000 .bat_limit=100 .src.bat=BAT0 '.model=ThinkPad T14 Gen 7'

echo "Intel laptop (Dell)"
S=$tmp/intel
w $S/class/hwmon/hwmon0/name coretemp
w $S/class/hwmon/hwmon0/temp1_label "Core 0";       w $S/class/hwmon/hwmon0/temp1_input 58000
w $S/class/hwmon/hwmon0/temp2_label "Package id 0"; w $S/class/hwmon/hwmon0/temp2_input 61000
w $S/class/hwmon/hwmon1/name dell_smm; w $S/class/hwmon/hwmon1/fan1_input 3100; w $S/class/hwmon/hwmon1/fan2_input 0
w $S/class/hwmon/hwmon2/name nvme;     w $S/class/hwmon/hwmon2/temp1_input 39000
w $S/class/drm/card1/gt_act_freq_mhz 450; w $S/class/drm/card1/gt_RP0_freq_mhz 1300
w $S/class/dmi/id/sys_vendor "Dell Inc."; w $S/class/dmi/id/product_name "XPS 13 9310"; w $S/class/dmi/id/product_version " "
# A wireless mouse is a power supply of type Battery too; it must not be taken for the laptop's.
w $S/class/power_supply/Apple_mouse/type Battery; w $S/class/power_supply/Apple_mouse/scope Device
w $S/class/power_supply/Apple_mouse/capacity 40
w $S/class/power_supply/BAT1/type Battery; w $S/class/power_supply/BAT1/capacity 75; w $S/class/power_supply/BAT1/status Discharging
w $S/class/power_supply/BAT1/current_now -1500000; w $S/class/power_supply/BAT1/voltage_now 12000000
w $S/class/power_supply/BAT1/charge_now 3000000; w $S/class/power_supply/BAT1/charge_full 4000000
w $S/class/power_supply/BAT1/voltage_min_design 11400000
check "coretemp package sensor, i915 clock, dell_smm fan, BAT1 in charge units, mouse ignored" "$(fast $S)" \
    .cpu_temp=61000 .src.cpu=coretemp .src.gpu=i915 .gpu_freq=450 .gpu_freq_max=1300 .gpu_busy=null \
    .soc_power=null .fan=3100 .src.fan=dell_smm .src.bat=BAT1 .bat_cap=75 \
    .bat_power=18000000 .bat_energy=34200000 .bat_full=45600000 '.model=XPS 13 9310'
w $S/class/drm/card1/gt_act_freq_mhz 0; rm $S/class/drm/card1/gt_RP0_freq_mhz; w $S/class/drm/card1/gt_max_freq_mhz 1450
check "i915 power-gated reads 0 MHz; max from gt_max_freq_mhz" "$(fast $S)" .gpu_freq=0 .gpu_freq_max=1450
rm -r $S/class/drm/card1; w $S/class/drm/card0/device/tile0/gt0/freq0/act_freq 800; w $S/class/drm/card0/device/tile0/gt0/freq0/rp0_freq 2050
check "xe driver (Lunar Lake, Battlemage)" "$(fast $S)" .src.gpu=xe .gpu_freq=800 .gpu_freq_max=2050

echo "Intel without coretemp: thermal zones"
S=$tmp/zone
w $S/class/thermal/thermal_zone0/type acpitz;       w $S/class/thermal/thermal_zone0/temp 30000
w $S/class/thermal/thermal_zone1/type x86_pkg_temp; w $S/class/thermal/thermal_zone1/temp 66000
check "x86_pkg_temp zone used" "$(fast $S)" .cpu_temp=66000 .src.cpu=x86_pkg_temp
rm -r $S/class/thermal/thermal_zone1
check "acpitz alone is not taken for the CPU" "$(fast $S)" .cpu_temp=null .src.cpu=""

echo "Self-built desktop (Ryzen + Radeon, no battery)"
S=$tmp/desk
w $S/class/hwmon/hwmon0/name zenpower
w $S/class/hwmon/hwmon0/temp1_label Tdie; w $S/class/hwmon/hwmon0/temp1_input 45000
w $S/class/hwmon/hwmon0/temp2_label Tctl; w $S/class/hwmon/hwmon0/temp2_input 55000
w $S/class/hwmon/hwmon1/name amdgpu; w $S/class/hwmon/hwmon1/temp1_input 40000; w $S/class/hwmon/hwmon1/device/gpu_busy_percent 2
w $S/class/hwmon/hwmon1/power1_average 30000000; w $S/class/hwmon/hwmon1/power1_cap 180000000
w $S/class/hwmon/hwmon2/name nct6798; w $S/class/hwmon/hwmon2/fan1_input 950; w $S/class/hwmon/hwmon2/fan2_input 1400
w $S/class/hwmon/hwmon2/fan3_input 0
w $S/class/hwmon/hwmon3/name drivetemp; w $S/class/hwmon/hwmon3/temp1_input 38000
for f in sys_vendor product_name product_version; do w $S/class/dmi/id/$f "To Be Filled By O.E.M."; done
w $S/class/dmi/id/board_vendor "ASUSTeK COMPUTER INC."; w $S/class/dmi/id/board_name "ROG STRIX B550-F GAMING"
w $S/class/power_supply/ups/type UPS
check "zenpower Tdie, discrete card power is GPU not SOC, fastest fan, SATA drive, board model, no battery" "$(fast $S)" \
    .cpu_temp=45000 .src.cpu=zenpower .power_kind=gpu .soc_power=30000000 .fan=1400 .src.fan=nct6798 \
    .ssd_temp=38000 .src.ssd=drivetemp .bat_cap=null .src.bat="" '.model=ROG STRIX B550-F GAMING'
w $S/class/hwmon/hwmon4/name nvme; w $S/class/hwmon/hwmon4/temp1_input 44000
check "NVMe preferred over SATA" "$(fast $S)" .ssd_temp=44000 .src.ssd=nvme

echo "Two Radeons: sleeping dGPU first, APU second"
S=$tmp/two
w $S/class/hwmon/hwmon0/name amdgpu          # runtime-suspended: its reads fail
w $S/class/hwmon/hwmon1/name amdgpu; w $S/class/hwmon/hwmon1/temp1_input 51000; w $S/class/hwmon/hwmon1/device/gpu_busy_percent 4
check "the APU that answers is shown" "$(fast $S)" .gpu_temp=51000 .gpu_busy=4

echo "NVIDIA hybrid laptop"
S=$tmp/nv
w $S/class/hwmon/hwmon0/name coretemp; w $S/class/hwmon/hwmon0/temp1_label "Package id 0"; w $S/class/hwmon/hwmon0/temp1_input 50000
w $S/class/drm/card1/gt_act_freq_mhz 300; w $S/class/drm/card1/gt_RP0_freq_mhz 1500
w $S/bus/pci/drivers/nvidia/0000:01:00.0/power/runtime_status suspended
nvs=$tmp/nvidia-smi; calls=$tmp/nvsmi.calls; : > "$calls"
printf '#!/bin/sh\necho call >> %s\necho "35, 52, 18.40, 80.00"\n' "$calls" > "$nvs"; chmod +x "$nvs"
check "sleeping dGPU: Intel shown, nvidia-smi never run" "$(fast $S ARCHI_NVSMI=$nvs)" .src.gpu=i915 .gpu_freq=300
[[ ! -s $calls ]] && ok "a sleeping NVIDIA card is not woken" || bad "a sleeping NVIDIA card is not woken (nvidia-smi ran)"
w $S/bus/pci/drivers/nvidia/0000:01:00.0/power/runtime_status active
check "awake dGPU: NVIDIA figures and board power" "$(fast $S ARCHI_NVSMI=$nvs)" \
    .src.gpu=nvidia .gpu_busy=35 .gpu_temp=52000 .soc_power=18400000 .soc_cap=80000000 .power_kind=gpu .gpu_freq=null
printf '#!/bin/sh\necho "0, 41, [N/A], [N/A]"\n' > "$nvs"
check "nvidia-smi without power readings" "$(fast $S ARCHI_NVSMI=$nvs)" .gpu_busy=0 .gpu_temp=41000 .soc_power=null
printf '#!/bin/sh\nexit 9\n' > "$nvs"
check "nvidia-smi failing: falls back to the integrated GPU" "$(fast $S ARCHI_NVSMI=$nvs)" .src.gpu=i915 .gpu_freq=300
S2=$tmp/nvdesk
w $S2/bus/pci/drivers/nvidia/0000:01:00.0/power/runtime_status suspended
check "NVIDIA-only machine, card asleep: shown as sleep" "$(fast $S2 ARCHI_NVSMI=$nvs)" .src.gpu=nvidia .gpu_state=sleep .gpu_busy=null

echo "ARM board (Raspberry Pi)"
S=$tmp/arm
w $S/class/hwmon/hwmon0/name cpu_thermal; w $S/class/hwmon/hwmon0/temp1_input 47000
mkdir -p $S/firmware/devicetree/base; printf 'Raspberry Pi 5 Model B Rev 1.0\0' > $S/firmware/devicetree/base/model
check "SoC sensor and device-tree model" "$(fast $S)" .cpu_temp=47000 .src.cpu=cpu_thermal '.model=Raspberry Pi 5 Model B'

echo "Virtual machine (nothing to read)"
S=$tmp/vm
w $S/class/dmi/id/sys_vendor QEMU; w $S/class/dmi/id/product_name "System Product Name"
check "no sensors, placeholder model dropped" "$(fast $S)" .cpu_temp=null .gpu_busy=null .ssd_temp=null .fan=null \
    .bat_cap=null .model="" .src.gpu=""

echo "Wi-Fi without iw(8)"
S=$tmp/wifi
mkdir -p $S/class/net/wlan0/phy80211; w $S/class/net/wlan0/statistics/rx_bytes 100; w $S/class/net/wlan0/statistics/tx_bytes 50
wl=$tmp/wireless
printf '%s\n' 'Inter-| sta-|   Quality        |   Discarded packets               | Missed | WE' \
    ' face | tus | link level noise |  nwid  crypt   frag  retry   misc | beacon | 22' \
    ' wlan0: 0000   54.  -56.  -256        0      0      0      0     29        0' > "$wl"
check "signal from /proc/net/wireless, SSID unknown" "$(PATH=/usr/bin:/bin fast $S ARCHI_WIRELESS=$wl)" .signal=-56 .ssid="" .rx=100

echo "Security set-ups"
units=$tmp/units sctl=$tmp/systemctl
cat > "$sctl" <<EOF
#!/usr/bin/env bash
# Fake systemctl show: one "unit load active unitfile" line per unit in \$UNITS.
[[ -s "$units" ]] || exit 1
first=1
for u; do
    [[ \$u == *.service ]] || continue
    read -r _ l a f < <(grep "^\$u " "$units" || echo "\$u not-found inactive")
    (( first )) || echo
    first=0
    echo "LoadState=\$l"; echo "ActiveState=\$a"; echo "UnitFileState=\${f:-}"
done
EOF
chmod +x "$sctl"
sec() { printf '%s\n' "$@" > "$units"; ARCHI_SYSTEMCTL=$sctl ARCHI_ROOT_DEV=none bash "$probe" sec; }
check "author's set-up: UFW and USBGuard running" \
    "$(sec 'ufw.service loaded active enabled' 'nftables.service loaded inactive disabled' 'iptables.service loaded inactive disabled' 'usbguard.service loaded active enabled')" \
    .fw=active .fw_name=ufw .usbguard=active
check "no firewall configured: off without a name; USBGuard not installed: absent" \
    "$(sec 'nftables.service loaded inactive disabled' 'iptables.service loaded inactive disabled')" \
    .fw=off .fw_name="" .usbguard=absent
check "nothing installed at all" "$(sec 'dummy.service loaded active enabled')" .fw=absent .usbguard=absent
check "firewalld enabled but stopped: down, named" "$(sec 'firewalld.service loaded inactive enabled')" .fw=down .fw_name=firewalld
check "ufw failed: down" "$(sec 'ufw.service loaded failed enabled')" .fw=down .fw_name=ufw
check "nftables ruleset loaded (oneshot, active)" "$(sec 'nftables.service loaded active enabled')" .fw=active .fw_name=nftables
check "one running beats another stopped" "$(sec 'firewalld.service loaded inactive enabled' 'nftables.service loaded active enabled')" .fw=active .fw_name=nftables
check "USBGuard installed, disabled: off" "$(sec 'usbguard.service loaded inactive disabled')" .usbguard=off
check "masked counts as off" "$(sec 'ufw.service masked inactive masked')" .fw=off
: > "$units"
check "systemctl cannot answer: unknown" "$(ARCHI_SYSTEMCTL=$sctl ARCHI_ROOT_DEV=none bash "$probe" sec)" .fw=unknown .usbguard=unknown

echo "Battery charge window: root helper (test mode, not root)"
helper=$here/../extras/battery/archmonitor-battery
S=$tmp/batw; B=$S/class/power_supply/BAT0; conf=$tmp/batw.conf
w $B/type Battery; w $B/capacity 79; w $B/charge_control_start_threshold 40; w $B/charge_control_end_threshold 80
w $S/class/power_supply/mouse/type Battery; w $S/class/power_supply/mouse/scope Device
w $S/class/power_supply/mouse/charge_control_end_threshold 100
hl() { ARCHI_SYS=$S ARCHI_BATCONF=$conf bash "$helper" "$@" 2>/dev/null; }
thr() { printf '%s-%s' "$(< $B/charge_control_start_threshold)" "$(< $B/charge_control_end_threshold)"; }
hl set 40 80; [[ $? == 0 && $(thr) == 40-80 && $(< $conf) == $'start=40\nend=80' ]] && ok "set saves and applies" || bad "set saves and applies ($(thr))"
hl full; [[ $(thr) == 99-100 && $(< $conf) == $'start=40\nend=80' ]] && ok "full: 99–100 now, saved window untouched" || bad "full ($(thr))"
[[ $(< $S/class/power_supply/mouse/charge_control_end_threshold) == 100 ]] && ok "peripherals untouched" || bad "peripherals untouched"
hl care; [[ $(thr) == 40-80 ]] && ok "care restores the saved window (start written after end when lowering)" || bad "care ($(thr))"
hl set 85 95; [[ $(thr) == 85-95 ]] && ok "raising past the current end: end written first" || bad "raising past current end ($(thr))"
hl set 40 80
for args in "set 40 45" "set 40 42" "set 96 100" "set 40 101" "set 4x 80" "set 40" "full extra" "rm -rf /"; do
    hl $args; rc=$?
    [[ $rc == 2 && $(thr) == 40-80 ]] && ok "refused: $args" || bad "refused: $args (rc $rc, $(thr))"
done
S2=$tmp/batnone; w $S2/class/power_supply/BAT0/type Battery
ARCHI_SYS=$S2 ARCHI_BATCONF=$conf bash "$helper" set 40 80 2>/dev/null; [[ $? == 3 ]] && ok "no thresholds: exit 3" || bad "no thresholds: exit 3"
rm -f $tmp/none.conf; ARCHI_SYS=$S ARCHI_BATCONF=$tmp/none.conf bash "$helper" care; [[ $? == 0 && $(thr) == 40-80 ]] && ok "care without a saved window: no-op" || bad "care without a saved window"

echo "Battery charge window: probe"
fh=$tmp/fakehelper; log=$tmp/pk.log
printf '#!/bin/sh\nexit 0\n' > "$fh"; chmod +x "$fh"
pk=$tmp/pkexec; printf '#!/bin/sh\necho "$@" >> %s\nexit ${PK_RC:-0}\n' "$log" > "$pk"; chmod +x "$pk"
bp() { env ARCHI_BATHELPER=$fh ARCHI_PKEXEC=$pk ARCHI_BATCONF=$conf ARCHI_SYS=$S ARCHI_ROUTE=$rt "$@"; }
check "fast probe: thresholds, helper present, saved window" "$(bp bash "$probe")" .bat_start=40 .bat_limit=80 .bat_ctl=true .care_start=40 .care_end=80
check "fast probe: no helper, read-only" "$(bp ARCHI_BATHELPER=$tmp/nope bash "$probe")" .bat_ctl=false .care_end=null
: > "$log"
check "bat-set goes through pkexec" "$(bp bash "$probe" bat-set 40 80)" .ok=true .code=0
[[ $(< $log) == "$fh set 40 80" ]] && ok "pkexec called with the helper path and validated numbers" || bad "pkexec args: $(< $log)"
check "bat-full" "$(bp bash "$probe" bat-full)" .action=full .ok=true
check "dismissed authorisation: 126" "$(bp PK_RC=126 bash "$probe" bat-care)" .ok=false .code=126
: > "$log"
check "malformed request never reaches pkexec" "$(bp bash "$probe" bat-set 40 '80;id')" .ok=false .code=2
[[ ! -s $log ]] && ok "nothing executed for a malformed request" || bad "pkexec ran for a malformed request"
check "helper missing: 127" "$(bp ARCHI_BATHELPER=$tmp/nope bash "$probe" bat-full)" .ok=false .code=127

(( fail )) || echo "all passed"
exit $fail
