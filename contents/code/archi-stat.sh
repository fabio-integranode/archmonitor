#!/usr/bin/env bash
# archi-stat — one-pass telemetry snapshot for Archmonitor, JSON on stdout.
#
#   archi-stat.sh        fast probe (every 2 s): CPU, mem, thermals, GPU, disk, net, battery
#   archi-stat.sh sec    slow probe (every 30 s): LUKS on /, UFW, USBGuard, reboot pending
#   archi-stat.sh top    on-demand (~1 s): top consumers by CPU and RSS, grouped by command
#   archi-stat.sh kill SIG NAME PID...   SIGTERM/SIGKILL to the listed PIDs, re-validated
#   archi-stat.sh media                  what a browser is playing (MPRIS, via playerctl)
#   archi-stat.sh media-ctl ACTION PLAYER   play-pause | next | previous | raise
#
# Reads /proc and /sys directly. External tools per fast tick: stat(1) and,
# on Wi-Fi, iw(8). No lm_sensors, no awk, no cat. ~9 ms per run.
#
# Test hooks (never set in production): ARCHI_SYSBLK, ARCHI_ROOT_DEV, ARCHI_MODDIR,
# ARCHI_ROUTE (a /proc/net/route file), ARCHI_IW_FILE (canned `iw dev X link` output),
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
    local run base cand cb newest
    rs run /proc/sys/kernel/osrelease || return 1
    [[ -d $MODDIR/$run ]] || return 0
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

if [[ ${1:-} == sec ]]; then
    # luks: true / false, or null when the device behind / cannot be resolved.
    luks=null reboot=false kernel=""
    if rd_=$(root_dev) && [[ -n $rd_ && -d $SYSBLK/$rd_ ]]; then
        luks=false
        luks_backed "$rd_" && luks=true
    fi
    reboot_pending && reboot=true
    rs kernel /proc/sys/kernel/osrelease
    mapfile -t st < <(systemctl is-active ufw.service usbguard.service 2>/dev/null)
    printf '{"luks":%s,"ufw":%s,"usbguard":%s,"reboot":%s,"kernel":%s}\n' \
        "$luks" "$(js "${st[0]:-unknown}")" "$(js "${st[1]:-unknown}")" "$reboot" "$(js "$kernel")"
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
ts=${EPOCHREALTIME//[.,]/}          # µs; locale-proof (es_AR uses a comma)

host=archi model=""
rs host /proc/sys/kernel/hostname
rs model /sys/class/dmi/id/product_version

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

# hwmon, matched by driver name — hwmonN indices are not stable across boots.
cpu_t=null gpu_t=null gpu_w=null gpu_cap=null gpu_f=null ssd_t=null fan=null
for h in /sys/class/hwmon/hwmon*; do
    rs name "$h/name" || continue
    case $name in
        k10temp)  rd cpu_t "$h/temp1_input" ;;                       # Tctl
        amdgpu)   rd gpu_t "$h/temp1_input"                           # edge
                  rd gpu_w "$h/power1_average" || rd gpu_w "$h/power1_input"   # PPT (SoC package), µW
                  rd gpu_cap "$h/power1_cap"
                  rd gpu_f "$h/freq1_input" ;;                        # sclk, Hz
        nvme)     [[ $ssd_t == null ]] && rd ssd_t "$h/temp1_input" ;; # Composite
        thinkpad) rd fan "$h/fan1_input" ;;
    esac
done

gpu_busy=null
for f in /sys/class/drm/card[0-9]/device/gpu_busy_percent /sys/class/drm/card[0-9][0-9]/device/gpu_busy_percent; do
    rd gpu_busy "$f" && break
done

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
    rd rx "/sys/class/net/$iface/statistics/rx_bytes"
    rd tx "/sys/class/net/$iface/statistics/tx_bytes"
    if [[ -n ${ARCHI_IW_FILE:-} || -e /sys/class/net/$iface/phy80211 ]]; then
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
    fi
fi

# Battery: first BAT* present.
bat_cap=null bat_status="" bat_power=null bat_energy=null bat_full=null bat_limit=null
for b in /sys/class/power_supply/BAT*; do
    rd bat_cap "$b/capacity"
    rs bat_status "$b/status"
    if ! rd bat_power "$b/power_now"; then
        cur=0 vol=0
        rd cur "$b/current_now" && rd vol "$b/voltage_now" && bat_power=$((cur * vol / 1000000))
    fi
    rd bat_energy "$b/energy_now"
    rd bat_full "$b/energy_full"
    rd bat_limit "$b/charge_control_end_threshold"
    break
done

printf '{"ts":%s,"host":%s,"model":%s,"uptime":%s,' "$ts" "$(js "$host")" "$(js "$model")" "$uptime"
printf '"cpu_total":%s,"cpu_idle":%s,"cpu_temp":%s,' "$cpu_total" "$cpu_idle" "$cpu_t"
printf '"mem_total":%s,"mem_avail":%s,' "$mem_total" "$mem_avail"
printf '"gpu_busy":%s,"gpu_temp":%s,"gpu_freq":%s,"soc_power":%s,"soc_cap":%s,' "$gpu_busy" "$gpu_t" "$gpu_f" "$gpu_w" "$gpu_cap"
printf '"ssd_temp":%s,"fan":%s,' "$ssd_t" "$fan"
printf '"fs_blocks":%s,"fs_free":%s,"fs_avail":%s,"fs_bsize":%s,' "${fs_blocks:-0}" "${fs_free:-0}" "${fs_avail:-0}" "${fs_bsize:-0}"
printf '"iface":%s,"rx":%s,"tx":%s,"ssid":%s,"signal":%s,' "$(js "$iface")" "$rx" "$tx" "$(js "$ssid")" "$sig"
printf '"bat_cap":%s,"bat_status":%s,"bat_power":%s,"bat_energy":%s,"bat_full":%s,"bat_limit":%s}\n' \
    "$bat_cap" "$(js "$bat_status")" "$bat_power" "$bat_energy" "$bat_full" "$bat_limit"
