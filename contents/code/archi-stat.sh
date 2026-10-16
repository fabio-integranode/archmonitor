#!/usr/bin/env bash
# archi-stat — one-pass telemetry snapshot for Archmonitor, JSON on stdout.
#
#   archi-stat.sh        fast probe (every 2 s): CPU, mem, thermals, GPU, disk, net, battery
#   archi-stat.sh sec    slow probe (every 30 s): LUKS on /, firewall, USBGuard, reboot pending
#   archi-stat.sh top    on-demand (~1 s): top consumers by CPU and RSS, grouped by command
#   archi-stat.sh kill SIG NAME PID...   SIGTERM/SIGKILL to the listed PIDs, re-validated
#   archi-stat.sh media                  what a browser is playing (MPRIS, via playerctl)
#   archi-stat.sh media-ctl ACTION PLAYER   play-pause | next | previous | raise
#
# Reads /proc and /sys directly. External tools per fast tick: stat(1), iw(8) on Wi-Fi
# when installed, nvidia-smi only while an NVIDIA card is awake. No lm_sensors, no awk,
# no cat. ~10 ms per run.
#
# Test hooks (never set in production): ARCHI_SYS (a fake /sys root for the fast probe),
# ARCHI_SYSBLK, ARCHI_ROOT_DEV, ARCHI_MODDIR, ARCHI_SYSTEMCTL, ARCHI_NVSMI (stand-ins for
# those commands), ARCHI_ROUTE (a /proc/net/route file), ARCHI_IW_FILE (canned
# `iw dev X link` output), ARCHI_WIRELESS (a /proc/net/wireless file),
# ARCHI_MEDIA_FILE (canned `playerctl -a metadata` output).

set -u
shopt -s nullglob

# rd VAR FILE — read an integer from FILE into VAR; leaves VAR untouched on failure.
rd() {
    local __v
    { read -r __v < "$2"; } 2>/dev/null || return 1
    [[ $__v =~ ^-?[0-9]+$ ]] || return 1
    printf -v "$1" '%s' "$__v"
}
# rs VAR FILE — read a raw string.
rs() {
    local __v
    { read -r __v < "$2"; } 2>/dev/null || return 1
    printf -v "$1" '%s' "$__v"
}
# js STRING — JSON string literal. Escapes \ and ", the common control characters by
# name and any other control character as \u00XX, so no system string can break the
# snapshot. The per-character loop only runs when a stray control character is present.
js() {
    local v=${1//\\/\\\\} out="" c i
    v=${v//\"/\\\"}
    v=${v//$'\n'/\\n}; v=${v//$'\r'/\\r}; v=${v//$'\t'/\\t}
    if [[ $v == *[[:cntrl:]]* ]]; then
        for (( i = 0; i < ${#v}; i++ )); do
            c=${v:i:1}
            [[ $c == [[:cntrl:]] ]] && printf -v c '\\u%04x' "'$c"
            out+=$c
        done
        v=$out
    fi
    printf '"%s"' "$v"
}

# ── Slow probe: security posture ─────────────────────────────────────────────
SYSBLK=${ARCHI_SYSBLK:-/sys/class/block}
MODDIR=${ARCHI_MODDIR:-/usr/lib/modules}

# root_dev — kernel name of the block device backing / (e.g. dm-0, nvme0n1p2).
root_dev() {
    if [[ -n ${ARCHI_ROOT_DEV:-} ]]; then printf '%s' "$ARCHI_ROOT_DEV"; return 0; fi
    local src
    src=$(findmnt -rno SOURCE / 2>/dev/null) || return 1
    src=${src%%\[*}                       # btrfs reports /dev/mapper/x[/@]
    src=$(readlink -f -- "$src") || return 1
    printf '%s' "${src##*/}"
}

# luks_backed DEV — true if DEV is a LUKS mapping or sits on top of one (LVM-on-LUKS).
luks_backed() {
    local d=$1 u s
    [[ -n $d && -d $SYSBLK/$d ]] || return 1
    if rs u "$SYSBLK/$d/dm/uuid" && [[ $u == CRYPT-LUKS* ]]; then return 0; fi
    for s in "$SYSBLK/$d"/slaves/*; do
        luks_backed "${s##*/}" && return 0
    done
    return 1
}

# reboot_pending — true when a newer kernel of the same package is installed than the one
# running, or when the running kernel's module tree was removed by an upgrade. Returns
# false (quiet) when it can't tell, e.g. a kernel not installed from an Arch package.
reboot_pending() {
    local run base cand cb newest p
    rs run /proc/sys/kernel/osrelease || return 1
    if [[ ! -d $MODDIR/$run ]]; then
        # Modules gone: an upgrade removed them — but only claim that on a system whose
        # kernels come from Arch packages (a pkgbase file somewhere). Elsewhere the module
        # tree may simply live in another place (NixOS, containers).
        for p in "$MODDIR"/*/pkgbase; do return 0; done
        return 1
    fi
    rs base "$MODDIR/$run/pkgbase" || return 1
    newest=$run
    for cand in "$MODDIR"/*/; do
        cand=${cand%/}; cand=${cand##*/}
        [[ $cand == "$run" ]] && continue
        rs cb "$MODDIR/$cand/pkgbase" && [[ $cb == "$base" ]] || continue
        [[ $(printf '%s\n%s\n' "$newest" "$cand" | sort -V | tail -n1) == "$cand" ]] && newest=$cand
    done
    [[ $newest != "$run" ]]
}

# svc_states UNIT... — one state per unit, in order, on stdout:
#   active   running (a oneshot that stays active after exit, like ufw.service, counts)
#   down     enabled or failed, yet not running: a real fault
#   off      installed but neither enabled nor running: the owner's choice
#   absent   not installed
#   unknown  systemctl could not answer (no bus, timeout)
# `systemctl is-active` cannot tell "not installed" from "stopped" (both print inactive),
# which is why this reads LoadState and UnitFileState too.
SYSTEMCTL=${ARCHI_SYSTEMCTL:-systemctl}
svc_states() {
    local k v load="" act="" ufs="" s
    local -a out=()
    while IFS='=' read -r k v; do
        case $k in
            LoadState) load=$v ;;
            ActiveState) act=$v ;;
            UnitFileState) ufs=$v ;;
            "")
                [[ -n $load ]] || continue
                case $load in
                    not-found) s=absent ;;
                    masked) s=off ;;
                    loaded)
                        case $act in
                            active|reloading|activating|deactivating) s=active ;;
                            failed) s=down ;;
                            *) [[ $ufs == enabled* ]] && s=down || s=off ;;
                        esac ;;
                    *) s=unknown ;;
                esac
                out+=("$s"); load="" act="" ufs="" ;;
        esac
    done < <("$SYSTEMCTL" show -p LoadState -p ActiveState -p UnitFileState -- "$@" 2>/dev/null; echo)
    if (( ${#out[@]} != $# )); then
        out=(); for k; do out+=(unknown); done
    fi
    printf '%s\n' "${out[@]}"
}

if [[ ${1:-} == sec ]]; then
    # luks: true / false, or null when the device behind / cannot be resolved.
    luks=null reboot=false kernel=""
    if rd_=$(root_dev) && [[ -n $rd_ && -d $SYSBLK/$rd_ ]]; then
        luks=false
        luks_backed "$rd_" && luks=true
    fi
    reboot_pending && reboot=true
    rs kernel /proc/sys/kernel/osrelease
    # Firewall: whichever front end is in use. One running wins; else one that should run
    # (enabled or failed) is reported down. Installed-but-unused units say nothing about
    # intent (iptables.service and nftables.service ship with common packages), so they
    # only make the firewall "off", without a name.
    fws=(ufw firewalld nftables iptables)
    mapfile -t st < <(svc_states ufw.service firewalld.service nftables.service iptables.service usbguard.service)
    fw=absent fw_name=""
    for want in active down off unknown; do
        for i in 0 1 2 3; do
            [[ ${st[i]} == "$want" ]] || continue
            fw=$want
            [[ $want == active || $want == down ]] && fw_name=${fws[i]}
            break 2
        done
    done
    printf '{"luks":%s,"fw":%s,"fw_name":%s,"usbguard":%s,"reboot":%s,"kernel":%s}\n' \
        "$luks" "$(js "$fw")" "$(js "$fw_name")" "$(js "${st[4]}")" "$reboot" "$(js "$kernel")"
    exit 0
fi

# ── Process names and protection (shared by `top` and `kill`) ────────────────
# Command names are normalised in the C locale so `top` and `kill` agree byte for byte.
# cname VAR NAME — sets VAR without a subshell (top calls it for every process, twice).
cname() {
    local LC_ALL=C
    local __c=${2//[^A-Za-z0-9._:\/+ -]/_}
    printf -v "$1" '%s' "${__c:-?}"
}

# Processes the widget never offers to stop: killing them takes down the session, the
# desktop (and this widget), audio, keyrings, or a shell. Names are as /proc/PID/comm
# shows them: truncated to 15 characters and normalised by cname().
protected_name() {
    case $1 in
        plasmashell|kwin_wayland|kwin_x11|Xwayland|ksmserver|kded6|kglobalacceld|kactivitymanag|\
        startplasma-way|plasma_session|sddm|sddm-helper|systemd|_sd-pam_|dbus-daemon|\
        dbus-broker|dbus-broker-lau|pipewire|pipewire-pulse|wireplumber|kwalletd6|ksecretd|\
        ssh-agent|gpg-agent|polkit-kde-auth|xdg-desktop-por|xdg-document-po|xdg-permission-|\
        bash|zsh|fish|sh|dash|login|sudo|su) return 0 ;;
    esac
    return 1
}

# ── On-demand: stop a process group ──────────────────────────────────────────
# Every PID is re-checked at send time: still alive, same command name, owned by the
# caller, not PID 1, not this script. A PID reused since the sample fails the name check.
if [[ ${1:-} == kill ]]; then
    sig=${2:-} name=${3:-}
    shift $(( $# < 3 ? $# : 3 ))
    sent=0 skipped=0 refused=false
    if [[ ( $sig == TERM || $sig == KILL ) && -n $name ]] && ! protected_name "$name"; then
        for p in "$@"; do
            if [[ ! $p =~ ^[0-9]+$ ]] || (( p <= 1 || p == $$ || p == PPID )); then
                skipped=$(( skipped + 1 )); continue
            fi
            c=""; { read -r c < "/proc/$p/comm"; } 2>/dev/null
            [[ -n $c ]] && cname c "$c"
            if [[ -n $c && $c == "$name" && -O /proc/$p ]] && kill -s "$sig" "$p" 2>/dev/null; then
                sent=$(( sent + 1 ))
            else
                skipped=$(( skipped + 1 ))
            fi
        done
    else
        refused=true
    fi
    printf '{"sig":%s,"name":%s,"sent":%d,"skipped":%d,"refused":%s}\n' \
        "$(js "$sig")" "$(js "$name")" "$sent" "$skipped" "$refused"
    exit 0
fi

# ── Media: what a browser is playing ─────────────────────────────────────────
# Browsers publish their media sessions over MPRIS (D-Bus); playerctl reads them all in
# one call. Only browser players are considered, a playing one beats a paused one, and
# plasma-browser-integration (KDE's browser extension) is preferred on a tie because it
# supports Raise, which focuses the exact tab.
is_browser_player() {
    case ${1%%.*} in
        firefox|librewolf|zen|chromium|chrome|google-chrome|brave|vivaldi|opera|microsoft-edge|plasma-browser-integration) return 0 ;;
    esac
    return 1
}
valid_player() { [[ $1 =~ ^[A-Za-z0-9._-]{1,128}$ ]] && is_browser_player "$1"; }

if [[ ${1:-} == media ]]; then
    US=$'\x1f'          # unit separator: unlike a tab, `read` keeps empty fields (no artist)
    if [[ -n ${ARCHI_MEDIA_FILE:-} ]]; then
        exec 3< "$ARCHI_MEDIA_FILE"
    elif command -v playerctl >/dev/null; then
        exec 3< <(playerctl -a metadata --format "{{playerInstance}}$US{{status}}$US{{artist}}$US{{title}}$US{{position}}$US{{mpris:length}}$US{{mpris:artUrl}}$US{{xesam:url}}" 2>/dev/null)
    else
        printf '{"available":false}\n'
        exit 0
    fi
    best="" best_rank=0 b_st="" b_artist="" b_title="" b_pos=null b_len=null b_art="" b_url=""
    while IFS=$US read -r inst st artist title pos len art url <&3; do
        is_browser_player "$inst" || continue
        case $st in Playing) rank=4 ;; Paused) rank=2 ;; *) continue ;; esac
        [[ ${inst%%.*} == plasma-browser-integration ]] && rank=$(( rank + 1 ))
        (( rank > best_rank )) || continue
        best=$inst best_rank=$rank b_st=$st b_artist=$artist b_title=$title
        [[ $pos =~ ^[0-9]+$ ]] && b_pos=$pos || b_pos=null
        [[ $len =~ ^[0-9]+$ && $len -gt 0 ]] && b_len=$len || b_len=null
        # Cover art: browsers hand out a local file (Firefox/Chromium write it to /tmp)
        # or an https URL (plasma-browser-integration). Anything else is dropped.
        [[ $art == file:///* || $art == https://* ]] && b_art=$art || b_art=""
        b_url=$url
    done
    exec 3<&-
    # A browser announces the artwork path and writes the file a moment later. Report a
    # local file only once it exists and is non-empty, versioned by size and mtime: a file
    # still being written changes version on the next poll, so the widget re-reads it
    # instead of keeping a failed or half-decoded first load.
    if [[ $b_art == file:///* ]]; then
        af=${b_art#file://}
        if [[ -s $af ]] && ver=$(stat -c '%s-%Y' -- "$af" 2>/dev/null); then
            b_art+="?v=$ver"
        else
            b_art=""
        fi
    fi
    # YouTube and YouTube Music: plasma-browser-integration may not re-publish the artwork
    # after a track change until playback state changes. When no artwork is available and
    # the page URL names a video, use YouTube's own thumbnail for it. hqdefault is 4:3 with
    # the 16:9 frame letterboxed inside, so the card's 16:9 crop removes the bars exactly.
    if [[ -z $b_art && $b_url =~ ^https://(www\.|music\.|m\.)?youtube\.com/watch\?(.*\&)?v=([A-Za-z0-9_-]{11}) ]]; then
        b_art="https://i.ytimg.com/vi/${BASH_REMATCH[3]}/hqdefault.jpg"
    elif [[ -z $b_art && $b_url =~ ^https://youtu\.be/([A-Za-z0-9_-]{11}) ]]; then
        b_art="https://i.ytimg.com/vi/${BASH_REMATCH[1]}/hqdefault.jpg"
    fi
    if [[ -z $best ]]; then
        printf '{"available":true,"player":null}\n'
    else
        printf '{"available":true,"player":%s,"status":%s,"artist":%s,"title":%s,"pos_us":%s,"len_us":%s,"art":%s}\n' \
            "$(js "$best")" "$(js "$b_st")" "$(js "$b_artist")" "$(js "$b_title")" "$b_pos" "$b_len" "$(js "$b_art")"
    fi
    exit 0
fi

if [[ ${1:-} == media-ctl ]]; then
    action=${2:-} player=${3:-} ok=false
    if valid_player "$player"; then
        case $action in
            play-pause|next|previous)
                command -v playerctl >/dev/null && playerctl -p "$player" "$action" 2>/dev/null && ok=true ;;
            raise)
                dbus-send --session --type=method_call --dest="org.mpris.MediaPlayer2.$player" \
                    /org/mpris/MediaPlayer2 org.mpris.MediaPlayer2.Raise 2>/dev/null && ok=true ;;
        esac
    fi
    printf '{"action":%s,"ok":%s}\n' "$(js "$action")" "$ok"
    exit 0
fi

# ── On-demand: top consumers ─────────────────────────────────────────────────
# CPU is measured over a ~1 s window from /proc/PID/stat deltas (ps(1) only offers a
# lifetime average, which misleads). Values are % of ONE core, like top(1) in Irix mode.
# RSS is summed per command, so shared pages are counted once per process: approximate.
# Each entry also carries the caller's own PIDs for that command ("p") and whether the
# widget may offer to stop it ("k": own PIDs present and the name not protected).
if [[ ${1:-} == top ]]; then
    tick=$(getconf CLK_TCK 2>/dev/null) || tick=100
    page=$(getconf PAGESIZE 2>/dev/null) || page=4096
    declare -A ticks0 ticks1 comm_of cpu_by rss_by cnt_by pids_by

    sample() {   # sample ARRAY — fills ARRAY with pid → utime+stime; records each pid's command
        local -n out=$1
        local p line rest c
        local -a f
        for p in /proc/[0-9]*; do
            p=${p##*/}
            { read -r line < "/proc/$p/stat"; } 2>/dev/null || continue
            c=${line#*(}; c=${c%)*}
            cname c "$c"
            rest=${line##*) }
            read -ra f <<< "$rest"
            [[ ${f[11]:-} =~ ^[0-9]+$ && ${f[12]:-} =~ ^[0-9]+$ ]] || continue
            out[$p]=$(( f[11] + f[12] ))
            comm_of[$p]=$c
        done
    }

    t0=${EPOCHREALTIME//[.,]/}
    sample ticks0
    sleep 1
    sample ticks1
    t1=${EPOCHREALTIME//[.,]/}
    dt=$(( t1 - t0 )); (( dt > 0 )) || dt=1000000

    for p in "${!ticks1[@]}"; do
        [[ -n ${ticks0[$p]:-} ]] || continue
        c=${comm_of[$p]}
        cpu_by["$c"]=$(( ${cpu_by["$c"]:-0} + ticks1[$p] - ticks0[$p] ))
        cnt_by["$c"]=$(( ${cnt_by["$c"]:-0} + 1 ))
        [[ -O /proc/$p ]] && pids_by["$c"]+="${pids_by["$c"]:+,}$p"
        { read -r _ r _ < "/proc/$p/statm"; } 2>/dev/null && [[ $r =~ ^[0-9]+$ ]] \
            && rss_by["$c"]=$(( ${rss_by["$c"]:-0} + r * page ))
    done
    # ticks → tenths of a percent of one core
    for c in "${!cpu_by[@]}"; do
        cpu_by["$c"]=$(( cpu_by["$c"] * 1000 * 1000000 / (tick * dt) ))
    done

    pick() {   # pick ARRAY — JSON array of the top 3 entries by value
        local -n arr=$1
        local -A used=()
        local out="" k best bv v i pl kk
        for i in 1 2 3; do
            best="" bv=0
            for k in "${!arr[@]}"; do
                [[ -n ${used["$k"]:-} ]] && continue
                v=${arr["$k"]}
                (( v > bv )) && { best=$k; bv=$v; }
            done
            [[ -n $best ]] || break
            used["$best"]=1
            pl=${pids_by["$best"]:-}
            kk=false; [[ -n $pl ]] && ! protected_name "$best" && kk=true
            out+="${out:+,}{\"n\":$(js "$best"),\"v\":$bv,\"c\":${cnt_by["$best"]:-1},\"p\":[$pl],\"k\":$kk}"
        done
        printf '[%s]' "$out"
    }

    printf '{"cpu":%s,"mem":%s,"win_ms":%s}\n' "$(pick cpu_by)" "$(pick rss_by)" "$(( dt / 1000 ))"
    exit 0
fi

# ── Fast probe ───────────────────────────────────────────────────────────────
# Hardware differs from machine to machine, so every sensor is found by what its driver
# is called, never by index or by this author's laptop. Each figure that has a source
# also reports which one (`src`), so `archi-stat.sh | jq .src` explains a blank row.
ts=${EPOCHREALTIME//[.,]/}          # µs; locale-proof (es_AR uses a comma)
SYS=${ARCHI_SYS:-/sys}

host=""
rs host /proc/sys/kernel/hostname

# Model. Firmware fills DMI fields carelessly, so placeholders are skipped. Lenovo puts
# the marketing name in product_version (product_name is a machine type like 21XX…);
# everyone else uses product_name; self-built desktops only fill the board fields; ARM
# boards have none of it and name themselves in the device tree.
junk_dmi() {
    local LC_ALL=C v=${1,,}
    v=${v#"${v%%[![:space:]]*}"}; v=${v%"${v##*[![:space:]]}"}
    case $v in
        ""|none|n/a|na|"not applicable"|"not specified"|"not available"|"to be filled by o.e.m."|\
        "to be filled by oem"|"system product name"|"system version"|"system manufacturer"|\
        "default string"|invalid|o.e.m.|oem|0|1.0|0.1|x.x|123456789|"type1productconfigid") return 0 ;;
    esac
    return 1
}
dmi=$SYS/class/dmi/id
model="" vendor="" pname="" pver="" bname=""
rs vendor "$dmi/sys_vendor"; rs pname "$dmi/product_name"; rs pver "$dmi/product_version"
if [[ ${vendor^^} == LENOVO* ]] && ! junk_dmi "$pver"; then
    model=$pver
elif ! junk_dmi "$pname"; then
    model=$pname
elif rs bname "$dmi/board_name" && ! junk_dmi "$bname"; then
    model=$bname                    # the board name alone is specific enough ("ROG STRIX B550-F GAMING")
else
    { IFS= read -r -d '' model < "$SYS/firmware/devicetree/base/model"; } 2>/dev/null
    [[ $model =~ ^(.*[^ ])\ Rev\ [0-9.]+$ ]] && model=${BASH_REMATCH[1]}   # "Raspberry Pi 5 Model B Rev 1.0"
fi
model=${model#"${model%%[![:space:]]*}"}; model=${model%"${model##*[![:space:]]}"}

read -r up_ _ < /proc/uptime; uptime=${up_:-0}; uptime=${uptime%%[.,]*}   # field 1; field 2 is idle time summed over all CPUs
read -r _ u n s i w q sq st _ < /proc/stat
cpu_total=$((u + n + s + i + w + q + sq + st))
cpu_idle=$((i + w))

mem_total=0 mem_avail=0
while read -r k v _; do
    case $k in
        MemTotal:) mem_total=$v ;;
        MemAvailable:) mem_avail=$v; break ;;
    esac
done < /proc/meminfo

# temp_by_label DIR VAR LABEL... — VAR from the first tempN of DIR whose label matches,
# trying the labels in the order given.
temp_by_label() {
    local dir=$1 var=$2 want l f
    shift 2
    for want; do
        for f in "$dir"/temp*_label; do
            rs l "$f" && [[ $l == "$want" ]] || continue
            rd "$var" "${f%_label}_input" && return 0
        done
    done
    return 1
}

# hwmon, matched by driver name — hwmonN indices are not stable across boots.
#   CPU   k10temp / zenpower (AMD: Tdie, which excludes the fan-curve offset some parts add
#         to Tctl, else Tctl), coretemp (Intel: the package sensor), the SoC sensor of
#         ARM boards. acpitz is deliberately not used: on many laptops it is a board or EC
#         zone, sometimes a constant, and a wrong CPU temperature is worse than none.
#   GPU   amdgpu (the first one that answers: a sleeping dGPU fails its reads without
#         being woken, so an APU next to it is picked), nouveau.
#   SSD   nvme (Composite), else drivetemp (SATA; needs `modprobe drivetemp`).
#   FAN   the fastest fan any driver reports (thinkpad, dell_smm, asus, nct67xx, it87…).
cpu_t=null cpu_src="" gpu_t=null gpu_busy=null gpu_f=null gpu_fmax=null gpu_src="" gpu_state=""
pwr=null pwr_cap=null pwr_kind="" ssd_t=null ssd_src="" ssd_rank=0 fan=null fan_src=""
nv_t=null
for h in "$SYS"/class/hwmon/hwmon*; do
    rs name "$h/name" || continue
    v=""
    case $name in
        k10temp|zenpower)
            [[ -z $cpu_src ]] && { temp_by_label "$h" v Tdie Tctl || rd v "$h/temp1_input"; } && { cpu_t=$v; cpu_src=$name; } ;;
        coretemp)
            [[ -z $cpu_src ]] && { temp_by_label "$h" v "Package id 0" || rd v "$h/temp1_input"; } && { cpu_t=$v; cpu_src=$name; } ;;
        cpu_thermal|cpu-thermal|cpu0_thermal|soc_thermal|soc-thermal)
            [[ -z $cpu_src ]] && rd v "$h/temp1_input" && { cpu_t=$v; cpu_src=$name; } ;;
        amdgpu)
            if [[ $gpu_src != amdgpu ]]; then
                t_=null b_=null
                rd t_ "$h/temp1_input"                                   # edge
                rd b_ "$h/device/gpu_busy_percent"
                if [[ $t_ != null || $b_ != null ]]; then
                    gpu_t=$t_ gpu_busy=$b_ gpu_src=amdgpu
                    rd v "$h/freq1_input" && gpu_f=$(( v / 1000000 ))   # sclk, Hz → MHz
                    if rd pwr "$h/power1_average" || rd pwr "$h/power1_input"; then
                        rd pwr_cap "$h/power1_cap"
                        # An APU's sensor covers the whole package (PPT); a discrete card's,
                        # its board. sysfs has no APU flag, but only APUs expose vddnb
                        # (in1_input); a cap under 60 W is taken as a second sign.
                        pwr_kind=gpu
                        if [[ -e $h/in1_input ]] || { [[ $pwr_cap != null ]] && (( pwr_cap < 60000000 )); }; then
                            pwr_kind=soc
                        fi
                    fi
                fi
            fi ;;
        nouveau)
            rd nv_t "$h/temp1_input" ;;
        nvme)
            (( ssd_rank < 2 )) && rd v "$h/temp1_input" && { ssd_t=$v; ssd_src=nvme; ssd_rank=2; } ;;   # Composite
        drivetemp)
            (( ssd_rank < 1 )) && rd v "$h/temp1_input" && { ssd_t=$v; ssd_src=drivetemp; ssd_rank=1; } ;;
    esac
    for f in "$h"/fan[0-9]*_input; do
        rd v "$f" || continue
        if [[ $fan == null ]] || (( v > fan )); then fan=$v; fan_src=$name; fi
    done
done

# CPU fallback: the package thermal zone (Intel without coretemp, some ARM SoCs).
if [[ -z $cpu_src ]]; then
    for z in "$SYS"/class/thermal/thermal_zone*; do
        rs ty "$z/type" || continue
        case $ty in
            x86_pkg_temp|cpu-thermal|cpu_thermal|cpu0-thermal|soc_thermal|soc-thermal)
                v=""; rd v "$z/temp" && { cpu_t=$v; cpu_src=$ty; break; } ;;
        esac
    done
fi

# Intel graphics: no busy % in sysfs (that needs perf counters), but the actual GPU clock
# against its maximum is a fair load gauge, and 0 MHz means it is power-gated (RC6).
i_f=null i_max=null i_src=""
for c in "$SYS"/class/drm/card[0-9] "$SYS"/class/drm/card[0-9][0-9]; do
    if rd i_f "$c/gt_act_freq_mhz"; then
        rd i_max "$c/gt_RP0_freq_mhz" || rd i_max "$c/gt_max_freq_mhz"; i_src=i915; break
    elif rd i_f "$c/device/tile0/gt0/freq0/act_freq"; then
        rd i_max "$c/device/tile0/gt0/freq0/rp0_freq" || rd i_max "$c/device/tile0/gt0/freq0/max_freq"; i_src=xe; break
    fi
done

# NVIDIA's proprietary driver has no hwmon, only nvidia-smi — and on hybrid laptops the
# card spends most of its time asleep (runtime D3). Querying it would wake it every 2 s
# and cost real battery, so a sleeping card is reported as asleep and left alone.
nv_dev="" nv_sleep=false
for d in "$SYS"/bus/pci/drivers/nvidia/0000:*; do
    s_=""; rs s_ "$d/power/runtime_status"
    if [[ $s_ == suspended ]]; then nv_sleep=true; else nv_dev=$d; nv_sleep=false; break; fi
done
NVSMI=${ARCHI_NVSMI:-nvidia-smi}
uw() {   # uw VAR WATTS — decimal watts ("18.4") to integer µW, without a subshell
    local i=${2%%.*} f=""
    [[ $2 == *.* ]] && f=${2#*.}
    f=${f}000000
    printf -v "$1" '%s' $(( 10#$i * 1000000 + 10#${f:0:6} ))
}
n_busy=null n_t=null n_w=null n_cap=null a_="" b_="" c_="" d_=""
if [[ -n $nv_dev ]] && command -v "$NVSMI" >/dev/null 2>&1; then
    IFS=', ' read -r a_ b_ c_ d_ < <("$NVSMI" --query-gpu=utilization.gpu,temperature.gpu,power.draw,power.limit \
        --format=csv,noheader,nounits -i 0 2>/dev/null)
    [[ $a_ =~ ^[0-9]+$ ]] && n_busy=$a_
    [[ $b_ =~ ^[0-9]+$ ]] && n_t=$(( b_ * 1000 ))
    [[ $c_ =~ ^[0-9]+(\.[0-9]+)?$ ]] && uw n_w "$c_"
    [[ $d_ =~ ^[0-9]+(\.[0-9]+)?$ ]] && uw n_cap "$d_"
fi

# Which GPU the card shows: an awake NVIDIA card (it is where the work is), else AMD,
# else Intel, else nouveau, else a sleeping NVIDIA card as "sleep".
if [[ $n_busy != null || $n_t != null ]]; then
    gpu_src=nvidia gpu_busy=$n_busy gpu_t=$n_t gpu_f=null gpu_fmax=null
    # Package power from an APU stays: it says more than the dGPU's board power.
    [[ $pwr_kind == soc ]] || { [[ $n_w != null ]] && { pwr=$n_w pwr_cap=$n_cap pwr_kind=gpu; }; }
elif [[ $gpu_src == amdgpu ]]; then
    :
elif [[ -n $i_src ]]; then
    gpu_src=$i_src gpu_f=$i_f gpu_fmax=$i_max
elif [[ $nv_t != null ]]; then
    gpu_src=nouveau gpu_t=$nv_t
elif [[ $nv_sleep == true || -n $nv_dev ]]; then
    gpu_src=nvidia; [[ $nv_sleep == true ]] && gpu_state=sleep
fi

read -r fs_blocks fs_free fs_avail fs_bsize < <(stat -f -c '%b %f %a %S' / 2>/dev/null)

# Network: the physical uplink, i.e. the UP default route with the lowest metric in the
# main table (dock Ethernet at metric 100 beats Wi-Fi at 600). VPN tunnels route through
# other tables via policy rules and are deliberately not picked: SSID and signal belong
# to the physical link.
iface="" rx=null tx=null ssid="" sig=null best=""
while read -r ifc dst _ flags _ _ metric mask _; do
    [[ $dst == 00000000 && $mask == 00000000 && $flags =~ ^[0-9A-Fa-f]+$ && $metric =~ ^[0-9]+$ ]] || continue
    (( 16#$flags & 1 )) || continue                     # RTF_UP
    if [[ -z $best ]] || (( metric < best )); then iface=$ifc; best=$metric; fi
done < "${ARCHI_ROUTE:-/proc/net/route}"
if [[ -n $iface ]]; then
    rd rx "$SYS/class/net/$iface/statistics/rx_bytes"
    rd tx "$SYS/class/net/$iface/statistics/tx_bytes"
    if [[ -n ${ARCHI_IW_FILE:-} ]] || { [[ -e $SYS/class/net/$iface/phy80211 ]] && command -v iw >/dev/null; }; then
        if [[ -n ${ARCHI_IW_FILE:-} ]]; then exec 3< "$ARCHI_IW_FILE"; else exec 3< <(iw dev "$iface" link 2>/dev/null); fi
        while IFS= read -r line <&3; do
            line=${line#"${line%%[![:space:]]*}"}
            case $line in
                SSID:*)   ssid=${line#SSID: } ;;
                signal:*) sig=${line#signal: }; sig=${sig%% *} ;;
            esac
        done
        exec 3<&-
        # iw prints every non-printable SSID byte (all non-ASCII, '\', edge spaces) as \xNN,
        # so "Señal" arrives as "Se\xc3\xb1al". Decode it back to UTF-8.
        [[ $ssid == *'\x'* ]] && printf -v ssid '%b' "$ssid"
        [[ $sig =~ ^-?[0-9]+$ ]] || sig=null
    elif [[ -e $SYS/class/net/$iface/phy80211 || -n ${ARCHI_WIRELESS:-} ]]; then
        # Without iw(8): the signal level from /proc/net/wireless; the SSID stays unknown
        # and the card names the interface instead.
        while read -r ifc _ _ lvl _; do
            [[ ${ifc%:} == "$iface" ]] || continue
            lvl=${lvl%.}; [[ $lvl =~ ^-[0-9]+$ ]] && sig=$lvl
        done < "${ARCHI_WIRELESS:-/proc/net/wireless}"
    fi
fi

# Battery: the first system battery. Peripherals (mice, headsets) are power supplies too
# but carry scope=Device. Drivers report either energy (µWh) or charge (µAh); charge is
# converted with the design voltage, and power is unsigned whatever the driver's sign.
bat_cap=null bat_status="" bat_power=null bat_energy=null bat_full=null bat_limit=null bat_src=""
for b in "$SYS"/class/power_supply/*; do
    ty="" sc=""
    rs ty "$b/type" && [[ $ty == Battery ]] || continue
    rs sc "$b/scope" && [[ $sc == Device ]] && continue
    rd bat_cap "$b/capacity" || continue
    bat_src=${b##*/}
    rs bat_status "$b/status"
    if ! rd bat_power "$b/power_now"; then
        cur=0 vol=0
        rd cur "$b/current_now" && rd vol "$b/voltage_now" && bat_power=$(( cur * vol / 1000000 ))
    fi
    [[ $bat_power != null ]] && bat_power=${bat_power#-}
    if ! { rd bat_energy "$b/energy_now" && rd bat_full "$b/energy_full"; }; then
        bat_energy=null bat_full=null cn=0 cf=0 vd=0
        if rd cn "$b/charge_now" && rd cf "$b/charge_full" && { rd vd "$b/voltage_min_design" || rd vd "$b/voltage_now"; }; then
            bat_energy=$(( cn * vd / 1000000 )) bat_full=$(( cf * vd / 1000000 ))
        fi
    fi
    rd bat_limit "$b/charge_control_end_threshold"
    break
done

printf '{"ts":%s,"host":%s,"model":%s,"uptime":%s,' "$ts" "$(js "$host")" "$(js "$model")" "$uptime"
printf '"cpu_total":%s,"cpu_idle":%s,"cpu_temp":%s,' "$cpu_total" "$cpu_idle" "$cpu_t"
printf '"mem_total":%s,"mem_avail":%s,' "$mem_total" "$mem_avail"
printf '"gpu_busy":%s,"gpu_temp":%s,"gpu_freq":%s,"gpu_freq_max":%s,"gpu_state":%s,' \
    "$gpu_busy" "$gpu_t" "$gpu_f" "$gpu_fmax" "$(js "$gpu_state")"
printf '"soc_power":%s,"soc_cap":%s,"power_kind":%s,' "$pwr" "$pwr_cap" "$(js "$pwr_kind")"
printf '"ssd_temp":%s,"fan":%s,' "$ssd_t" "$fan"
printf '"fs_blocks":%s,"fs_free":%s,"fs_avail":%s,"fs_bsize":%s,' "${fs_blocks:-0}" "${fs_free:-0}" "${fs_avail:-0}" "${fs_bsize:-0}"
printf '"iface":%s,"rx":%s,"tx":%s,"ssid":%s,"signal":%s,' "$(js "$iface")" "$rx" "$tx" "$(js "$ssid")" "$sig"
printf '"bat_cap":%s,"bat_status":%s,"bat_power":%s,"bat_energy":%s,"bat_full":%s,"bat_limit":%s,' \
    "$bat_cap" "$(js "$bat_status")" "$bat_power" "$bat_energy" "$bat_full" "$bat_limit"
printf '"src":{"cpu":%s,"gpu":%s,"ssd":%s,"fan":%s,"bat":%s}}\n' \
    "$(js "$cpu_src")" "$(js "$gpu_src")" "$(js "$ssd_src")" "$(js "$fan_src")" "$(js "$bat_src")"
