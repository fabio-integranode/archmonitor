#!/usr/bin/env bash
# Probe tests against synthetic /sys and /usr/lib/modules trees. No hardware needed.
set -u
here=$(cd "$(dirname "$0")" && pwd)
probe=$here/../contents/code/archi-stat.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"; kill $busy 2>/dev/null' EXIT
fail=0; busy=

ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fail=1; }
json_get() { python3 -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$1" "$2"; }
sec() { env "$@" bash "$probe" sec; }
expect() { # expect LABEL JSON KEY VALUE
    local got; got=$(json_get "$2" "$3") || { bad "$1 (invalid JSON: $2)"; return; }
    [[ $got == "$4" ]] && ok "$1" || bad "$1 (got $got, want $4)"
}

echo "LUKS on /"
blk=$tmp/blk
mk_dm() { mkdir -p "$blk/$1/dm" "$blk/$1/slaves"; echo "$2" > "$blk/$1/dm/uuid"; }
mkdir -p "$blk/nvme0n1p2" "$blk/nvme0n1p3"
mk_dm dm-0 CRYPT-LUKS2-abc-cryptroot;  ln -s ../../nvme0n1p2 "$blk/dm-0/slaves/nvme0n1p2"
mk_dm dm-1 CRYPT-LUKS2-def-crypthome;  ln -s ../../nvme0n1p3 "$blk/dm-1/slaves/nvme0n1p3"
mk_dm lvm-root LVM-xyz;                ln -s ../../dm-1 "$blk/lvm-root/slaves/dm-1"
expect "root directly on LUKS"                "$(sec ARCHI_SYSBLK=$blk ARCHI_ROOT_DEV=dm-0)"          luks True
expect "root on LVM on LUKS"                  "$(sec ARCHI_SYSBLK=$blk ARCHI_ROOT_DEV=lvm-root)"      luks True
expect "root unencrypted, LUKS only on /home" "$(sec ARCHI_SYSBLK=$blk ARCHI_ROOT_DEV=nvme0n1p2)"     luks False
expect "root device unresolvable: null, not false" "$(sec ARCHI_SYSBLK=$blk ARCHI_ROOT_DEV=sdz9)"        luks None

echo "Reboot pending"
run=$(< /proc/sys/kernel/osrelease)
mods=$tmp/mods
mk_mod() { mkdir -p "$mods/$1"; [[ -n ${2:-} ]] && echo "$2" > "$mods/$1/pkgbase"; }
reboot() { json_get "$(sec ARCHI_SYSBLK=$blk ARCHI_ROOT_DEV=dm-0 ARCHI_MODDIR=$mods)" reboot; }
rm -rf "$mods"; mk_mod "$run" linux
[[ $(reboot) == False ]] && ok "only the running kernel installed" || bad "only the running kernel installed"
mk_mod "99.0.0-arch1-1" linux
[[ $(reboot) == True ]]  && ok "newer kernel of same package installed" || bad "newer kernel of same package installed"
rm -rf "$mods"; mk_mod "$run" linux; mk_mod "99.0.0-lts1-1-lts" linux-lts
[[ $(reboot) == False ]] && ok "newer kernel of a different package is ignored" || bad "newer kernel of a different package is ignored"
rm -rf "$mods"; mk_mod "99.0.0-arch1-1" linux
[[ $(reboot) == True ]]  && ok "running kernel's modules removed by upgrade" || bad "running kernel's modules removed by upgrade"
rm -rf "$mods"; mk_mod "$run"
[[ $(reboot) == False ]] && ok "no pkgbase: cannot tell, stays quiet" || bad "no pkgbase: cannot tell, stays quiet"
rm -rf "$mods"; mk_mod "$run" linux; mk_mod "1.0.0-arch1-1" linux
[[ $(reboot) == False ]] && ok "older kernel left behind is ignored" || bad "older kernel left behind is ignored"

echo "Default route"
rt=$tmp/route
fast() { env "$@" bash "$probe"; }
hdr=$'Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\tMTU\tWindow\tIRTT'
printf '%s\n' "$hdr" $'wlan0\t00000000\t0101A8C0\t0003\t0\t0\t600\t00000000\t0\t0\t0' \
    $'enp0\t00000000\t0102A8C0\t0003\t0\t0\t100\t00000000\t0\t0\t0' \
    $'wlan0\t0001A8C0\t00000000\t0001\t0\t0\t600\t00FFFFFF\t0\t0\t0' > "$rt"
expect "lowest metric wins over first listed"   "$(fast ARCHI_ROUTE=$rt)" iface enp0
printf '%s\n' "$hdr" $'enp0\t00000000\t0102A8C0\t0002\t0\t0\t100\t00000000\t0\t0\t0' \
    $'wlan0\t00000000\t0101A8C0\t0003\t0\t0\t600\t00000000\t0\t0\t0' > "$rt"
expect "route without RTF_UP is ignored"        "$(fast ARCHI_ROUTE=$rt)" iface wlan0
printf '%s\n' "$hdr" $'wlan0\t0001A8C0\t00000000\t0001\t0\t0\t600\t00FFFFFF\t0\t0\t0' > "$rt"
expect "no default route: offline"              "$(fast ARCHI_ROUTE=$rt)" iface ""

echo "SSID decoding and JSON escaping"
printf '%s\n' "$hdr" $'wlan0\t00000000\t0101A8C0\t0003\t0\t0\t600\t00000000\t0\t0\t0' > "$rt"
iwf=$tmp/iw
printf '%s\n' 'Connected to aa:bb:cc:dd:ee:ff (on wlan0)' \
    $'\tSSID: Se\\xc3\\xb1al \\x22Q\\x22\\x5c\\x0aok\\x01' $'\tfreq: 5180' $'\tsignal: -42 dBm' > "$iwf"
out=$(fast ARCHI_ROUTE=$rt ARCHI_IW_FILE=$iwf)
python3 - "$out" <<'PY' && ok "UTF-8, quote, backslash, newline and \\x01 survive as valid JSON" || bad "SSID decoding/escaping ($out)"
import json, sys
d = json.loads(sys.argv[1])
assert d["ssid"] == 'Señal "Q"\\\nok\x01', repr(d["ssid"])
assert d["signal"] == -42, d["signal"]
PY
printf '%s\n' 'Connected to aa:bb:cc:dd:ee:ff (on wlan0)' $'\tSSID: TECNOVEX STARLINK' $'\tsignal: -35 dBm' > "$iwf"
expect "plain ASCII SSID untouched"             "$(fast ARCHI_ROUTE=$rt ARCHI_IW_FILE=$iwf)" ssid "TECNOVEX STARLINK"

echo "Top consumers"
python3 -c 'while True: pass' & busy=$!
sleep 0.3
out=$(bash "$probe" top)
python3 - "$out" "$busy" <<'PY' && ok "busy loop ranks first at ~100% of one core, with its PID and killable" || bad "busy loop ranking"
import json, sys
d = json.loads(sys.argv[1])
top = d["cpu"][0]
assert int(sys.argv[2]) in top["p"] and top["k"] is True, top
assert all(e["k"] is False for e in d["cpu"] + d["mem"] if e["n"] == "bash"), "bash must never be offered"
assert top["n"].startswith("python"), top
assert 70 <= top["v"] / 10 <= 130, top
assert len(d["mem"]) == 3 and all(m["v"] > 0 for m in d["mem"]), d["mem"]
assert 900 <= d["win_ms"] <= 1500, d["win_ms"]
PY

echo "Stopping processes"
gone() { local st; [[ ! -e /proc/$1 ]] && return 0; read -r _ _ st _ < "/proc/$1/stat"; [[ $st == Z ]]; }
hog=$tmp/archihog; cp "$(command -v sleep)" "$hog"
# Started detached (via $(...)) so init reaps them and bash prints no job notices.
spawn() { "$@" >/dev/null 2>&1 & echo $!; }
h1=$(spawn "$hog" 300); h2=$(spawn "$hog" 300); other=$(spawn sleep 300)
sleep 0.2
out=$(bash "$probe" kill TERM archihog "$h1" "$h2" "$other" 1 abc)
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert (d["sent"],d["skipped"],d["refused"])==(2,3,False), d' "$out" \
    && ok "TERM: both archihog PIDs; skips a different name, PID 1 and junk" || bad "TERM accounting ($out)"
sleep 0.3
gone "$h1" && gone "$h2" && ok "archihog processes ended" || bad "archihog processes ended"
gone "$other" && bad "unrelated sleep survived" || ok "unrelated sleep survived"
out=$(bash "$probe" kill KILL sleep "$other"); sleep 0.2
[[ $(json_get "$out" sent) == 1 ]] && gone "$other" && ok "KILL escalation works" || bad "KILL escalation ($out)"
expect "protected name (bash) is refused"       "$(bash "$probe" kill TERM bash $$)" refused True
expect "only TERM and KILL are accepted"        "$(bash "$probe" kill HUP archihog 12345)" refused True
kill -0 $$ && ok "test shell still alive" || bad "test shell still alive"

echo "Media (MPRIS)"
mf=$tmp/media
U=$'\x1f'
media() { ARCHI_MEDIA_FILE=$mf bash "$probe" media; }
artf=$tmp/cover.jpg; printf 'JPEGDATA' > "$artf"; touch -d @1700000000 "$artf"
printf '%s\n' "spotify${U}Playing${U}Band${U}Song${U}1000${U}2000" \
    "firefox.instance_1_23${U}Paused${U}Canal${U}Video${U}5000000${U}200000000" \
    "chromium.instance42${U}Playing${U}Artista${U}Tema \"uno\"${U}61000000${U}215000000${U}file://$artf" > "$mf"
out=$(media)
python3 - "$out" "$artf" <<'PY' && ok "playing browser wins over paused one; art versioned by size+mtime" || bad "media selection ($out)"
import json, sys
d = json.loads(sys.argv[1])
assert d["player"] == "chromium.instance42" and d["status"] == "Playing", d
assert d["title"] == 'Tema "uno"' and d["pos_us"] == 61000000 and d["len_us"] == 215000000, d
assert d["art"] == "file://" + sys.argv[2] + "?v=8-1700000000", d
PY
printf '%s\n' "firefox.instance_1_23${U}Playing${U}A${U}B${U}${U}" \
    "plasma-browser-integration${U}Playing${U}A${U}B${U}${U}" > "$mf"
expect "plasma-browser-integration preferred on a tie (it can focus the tab)" "$(media)" player plasma-browser-integration
printf '%s\n' "firefox.instance_1_23${U}Playing${U}${U}Lo-fi beats${U}${U}" > "$mf"
out=$(media)
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert (d["artist"],d["title"],d["pos_us"],d["len_us"])==("","Lo-fi beats",None,None), d' "$out" \
    && ok "empty artist and unknown length keep the fields aligned" || bad "empty fields ($out)"
printf '%s\n' "spotify${U}Playing${U}Band${U}Song${U}1${U}2" "firefox.x${U}Stopped${U}${U}${U}${U}" > "$mf"
expect "no playing/paused browser: player null" "$(media)" player None
printf '%s\n' "firefox.instance_1_23${U}Playing${U}A${U}B${U}1${U}2${U}javascript:alert(1)" > "$mf"
expect "cover art other than file:// or https:// is dropped" "$(media)" art ""
printf '%s\n' "firefox.i${U}Playing${U}A${U}B${U}1${U}2${U}file://$tmp/not-yet.jpg" > "$mf"
expect "artwork file not written yet: no art (yet)"   "$(media)" art ""
: > "$tmp/empty.jpg"; printf '%s\n' "firefox.i${U}Playing${U}A${U}B${U}1${U}2${U}file://$tmp/empty.jpg" > "$mf"
expect "artwork file still empty: no art (yet)"       "$(media)" art ""
printf '%s\n' "firefox.i${U}Playing${U}A${U}B${U}1${U}2${U}https://i.ytimg.com/vi/x/hq.jpg" > "$mf"
expect "https artwork passes through unversioned"     "$(media)" art "https://i.ytimg.com/vi/x/hq.jpg"
printf '%s\n' "plasma-browser-integration${U}Playing${U}Residente${U}Muerte En Hawaii${U}1${U}2${U}${U}https://music.youtube.com/watch?v=AbCdEfGhIj0&list=RDAMVM" > "$mf"
expect "YouTube Music page without artwork: video thumbnail" "$(media)" art "https://i.ytimg.com/vi/AbCdEfGhIj0/hqdefault.jpg"
printf '%s\n' "chromium.i1${U}Playing${U}A${U}B${U}1${U}2${U}${U}https://www.youtube.com/watch?t=10&v=Zz_-123abcd" > "$mf"
expect "YouTube watch URL with v= after other params"   "$(media)" art "https://i.ytimg.com/vi/Zz_-123abcd/hqdefault.jpg"
printf '%s\n' "firefox.i${U}Playing${U}A${U}B${U}1${U}2${U}file://$artf${U}https://music.youtube.com/watch?v=AbCdEfGhIj0" > "$mf"
expect "published artwork wins over the YouTube thumbnail" "$(media)" art "file://$artf?v=8-1700000000"
printf '%s\n' "firefox.i${U}Playing${U}A${U}B${U}1${U}2${U}${U}https://evil.example/watch?v=AbCdEfGhIj0" > "$mf"
expect "non-YouTube URL: no derived thumbnail"          "$(media)" art ""
if ! command -v playerctl >/dev/null; then
    expect "playerctl missing: available false" "$(bash "$probe" media)" available False
fi
expect "media-ctl rejects a non-browser player"   "$(bash "$probe" media-ctl play-pause spotify)" ok False
expect "media-ctl rejects an unsafe player name"  "$(bash "$probe" media-ctl next 'firefox;id')" ok False
expect "media-ctl rejects unknown actions"        "$(bash "$probe" media-ctl stop firefox.instance_1)" ok False

echo "Fast probe"
out=$(bash "$probe"); python3 -c 'import json,sys; json.loads(sys.argv[1])' "$out" && ok "valid JSON" || bad "valid JSON"
[[ -z $(bash "$probe" 2>&1 >/dev/null) ]] && ok "silent stderr" || bad "silent stderr"
# Regression: field 2 of /proc/uptime is idle time summed over every CPU, not uptime.
read -r real _ < /proc/uptime
got=$(json_get "$out" uptime)
python3 -c 'import sys; sys.exit(abs(float(sys.argv[1]) - float(sys.argv[2])) > 2)' "$real" "$got" \
    && ok "uptime matches wall-clock uptime (probe $got s, /proc/uptime $real s)" \
    || bad "uptime matches wall-clock uptime (probe $got s, /proc/uptime $real s)"

(( fail )) && { echo "FAILED"; exit 1; }; echo "all passed"
