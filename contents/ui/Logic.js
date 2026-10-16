.pragma library

// Thresholds [warn, crit]. For lowIsBad metrics, values at or below trigger.
var TH = {
    cpuT: [80, 90],     // °C Tctl
    gpuT: [80, 90],     // °C edge
    ssdT: [65, 75],     // °C Composite
    mem:  [85, 95],     // %
    disk: [85, 95],     // %
    bat:  [20, 10],     // % while discharging (lowIsBad)
    sig:  [-72, -80]    // dBm (lowIsBad)
};

// Palette shared by Card.qml and Detail.qml.
var C = {
    fg: "#E6E8EB", sub: "#8A939C", faint: "#525B64", bar: "#A9B2BB", accent: "#86B6C6",
    ok: "#7DB597", warn: "#E2B45C", crit: "#E4685F",
    surface: [0.035, 0.043, 0.055]
};

function has(v) { return v !== null && v !== undefined && !isNaN(v); }

function sev(v, t, lowIsBad) {
    if (!has(v)) return 0;
    if (lowIsBad) return v <= t[1] ? 2 : v <= t[0] ? 1 : 0;
    return v >= t[1] ? 2 : v >= t[0] ? 1 : 0;
}

function degC(milli) { return has(milli) ? Math.round(milli / 1000) + "°C" : "—"; }
// For sensors a machine may simply not have: blank instead of a dash.
function degOpt(milli) { return has(milli) ? degC(milli) : ""; }
function celsius(milli) { return has(milli) ? milli / 1000 : NaN; }

function pct(v) { return has(v) && v >= 0 ? Math.round(v) + "%" : "—"; }

function gib(kib) { return (kib / 1048576).toFixed(1); }

function gb(bytes) { return Math.round(bytes / 1073741824); }

// SI rates, fixed significant figures so width stays stable.
function rate(b) {
    if (!has(b) || b < 0) return "—";
    if (b < 1000) return Math.round(b) + " B/s";
    if (b < 1e6)  return (b / 1e3).toFixed(b < 1e4 ? 1 : 0) + " kB/s";
    if (b < 1e9)  return (b / 1e6).toFixed(b < 1e7 ? 1 : 0) + " MB/s";
    return (b / 1e9).toFixed(1) + " GB/s";
}

function dur(sec) {
    if (!has(sec) || sec <= 0) return "—";
    var d = Math.floor(sec / 86400), h = Math.floor(sec % 86400 / 3600), m = Math.floor(sec % 3600 / 60);
    if (d > 0) return d + "d " + h + "h";
    if (h > 0) return h + "h " + (m < 10 ? "0" : "") + m + "m";
    return m + "m";
}

function signalBars(dbm) {
    if (!has(dbm)) return 0;
    return dbm >= -55 ? 4 : dbm >= -65 ? 3 : dbm >= -75 ? 2 : 1;
}

function batteryLine(s) {
    var st = s.bat_status, w = has(s.bat_power) ? s.bat_power / 1e6 : 0, out = [];
    if (st === "Discharging") {
        out.push("On battery");
        if (w > 0.1) {
            out.push(w.toFixed(1) + " W");
            if (has(s.bat_energy)) out.push(dur(s.bat_energy / s.bat_power * 3600) + " left");
        }
    } else if (st === "Charging") {
        out.push("Charging");
        if (w > 0.1) {
            out.push(w.toFixed(1) + " W");
            if (has(s.bat_energy) && has(s.bat_full)) {
                var target = has(s.bat_limit) ? s.bat_full * s.bat_limit / 100 : s.bat_full;
                if (target > s.bat_energy) out.push(dur((target - s.bat_energy) / s.bat_power * 3600) + " to " + (has(s.bat_limit) ? s.bat_limit + "%" : "full"));
            }
        }
    } else if (st === "Not charging") {
        if (has(s.bat_limit) && s.bat_cap >= s.bat_limit - 3) out.push("AC · held at " + s.bat_limit + "%");
        else if (has(s.bat_start) && s.bat_start > 0 && s.bat_cap > s.bat_start) out.push("AC · charges below " + s.bat_start + "%");
        else out.push("AC · idle");
    } else if (st === "Full") {
        out.push("AC · full");
    } else if (st) {
        out.push(st);
    }
    return out.join("  ·  ");
}

// Values the views and the alert engine both need, from one snapshot.
function derive(s) {
    var d = { live: !!s && s.ts !== undefined, memUsed: 0, memPct: -1, diskUsed: 0, diskCap: 0, diskPct: -1 };
    if (!d.live) return d;
    d.memUsed = s.mem_total - s.mem_avail;
    d.memPct = s.mem_total > 0 ? 100 * d.memUsed / s.mem_total : -1;
    d.diskUsed = (s.fs_blocks - s.fs_free) * s.fs_bsize;
    d.diskCap = (s.fs_blocks - s.fs_free + s.fs_avail) * s.fs_bsize;
    d.diskPct = d.diskCap > 0 ? 100 * d.diskUsed / d.diskCap : -1;
    return d;
}

// ── Alert engine ─────────────────────────────────────────────────────────────
// Raw thresholds flap. Every rule therefore has
//   persistence: a worse level must hold for UP consecutive samples before it shows
//                (the fast probe runs every 2 s, so UP = 3 is 6 s);
//   hysteresis:  a shown level is released only once the value is `margin` past its
//                threshold, so a reading sitting on the line cannot toggle it.
// State lives in the caller's object (`st`), keeping this module pure.
var UP = 3;

// Freshness. Fast telemetry arrives every 2 s, so 7 s means three samples missed.
// Security arrives every 30 s, so 90 s means two missed.
var FAST_STALE_MS = 7000;
var SEC_STALE_MS = 90000;

// Every list entry has a kind. Ranking: stale > crit > warn > unknown.
//   crit / warn  a measured value is out of bounds
//   unknown      a value that guards something important could not be measured
//   stale        nothing on the card is current (added by present(), never by evaluate())
var RANK = { stale: 4, crit: 3, warn: 2, unknown: 1 };

var RULES = [
    { key: "cpuT",  th: TH.cpuT, margin: 3, val: function (c) { return celsius(c.s.cpu_temp); }, text: function (c) { return "CPU " + degC(c.s.cpu_temp); } },
    { key: "gpuT",  th: TH.gpuT, margin: 3, val: function (c) { return celsius(c.s.gpu_temp); }, text: function (c) { return "GPU " + degC(c.s.gpu_temp); } },
    { key: "ssdT",  th: TH.ssdT, margin: 3, val: function (c) { return celsius(c.s.ssd_temp); }, text: function (c) { return "SSD " + degC(c.s.ssd_temp); } },
    { key: "mem",   th: TH.mem,  margin: 3, val: function (c) { return c.d.memPct; },            text: function (c) { return "MEM " + pct(c.d.memPct); } },
    { key: "disk",  th: TH.disk, margin: 2, val: function (c) { return c.d.diskPct; },           text: function (c) { return "DISK " + pct(c.d.diskPct); } },
    { key: "bat",   th: TH.bat,  margin: 3, low: true,
      val: function (c) { return c.s.bat_status === "Discharging" ? c.s.bat_cap : NaN; },
      text: function (c) { return "BAT " + c.s.bat_cap + "%"; } },
    { key: "sig",   th: TH.sig,  margin: 3, low: true,
      val: function (c) { return c.s.ssid ? c.s.signal : NaN; },
      text: function () { return "WEAK SIGNAL"; } },
    // Silent rules drive layout (the FAN row) but never appear in the alert list.
    { key: "hotT",  th: [70, 1e9],   margin: 5,   silent: true, val: function (c) { return celsius(c.s.cpu_temp); } },
    { key: "fan",   th: [4000, 1e9], margin: 600, silent: true, val: function (c) { return c.s.fan; } },
    { key: "socHi", th: [15, 1e9],   margin: 3,   silent: true, val: function (c) { return has(c.s.soc_power) ? c.s.soc_power / 1e6 : NaN; } }
];

// Security policy. Services come from the probe as active / down / off / absent / unknown
// ("down" = enabled or failed yet not running, "off" = installed and unused, "absent" =
// not installed). A service that should be running and is not always alerts. What a
// machine is *required* to have is its owner's call (settings → Security): only then do
// "off", "absent", an unencrypted / or an answer nobody could get raise an alert.
//   pol = { luks: bool, fw: bool, usbguard: bool }
function svcFault(st, required) {
    return st === "down" || (!!required && (st === "off" || st === "absent"));
}
function fwText(c) { return c.sec.fw_name ? c.sec.fw_name.toUpperCase() + " DOWN" : "NO FIREWALL"; }

// What blocks NOMINAL besides measured values: no uplink, a CPU temperature sensor that
// was there and stopped answering (a machine that never had one just shows "—"), the
// security probe going quiet, and the security findings above.
var FLAGS = [
    { key: "offline", text: "OFFLINE",        cond: function (c) { return !c.s.iface; } },
    { key: "cpuTunk", text: "CPU TEMP ?",     short: "CPU °C ?", kind: "unknown", cond: function (c) { return c.cpuSeen && !has(c.s.cpu_temp); } },
    { key: "secunk",  text: "SECURITY ?",     kind: "unknown", cond: function (c) { return !c.secFresh; } },
    { key: "luks",    text: "LUKS OFF",       cond: function (c) { return c.secFresh && c.pol.luks && c.sec.luks === false; } },
    { key: "luksunk", text: "LUKS ?",         kind: "unknown", cond: function (c) { return c.secFresh && c.pol.luks && c.sec.luks !== true && c.sec.luks !== false; } },
    { key: "fw",      text: fwText,           short: function (c) { return c.sec.fw_name === "ufw" ? "UFW DOWN" : c.sec.fw_name ? "FW DOWN" : "NO FW"; },
                      cond: function (c) { return c.secFresh && svcFault(c.sec.fw, c.pol.fw); } },
    { key: "fwunk",   text: "FIREWALL ?",     kind: "unknown", cond: function (c) { return c.secFresh && c.pol.fw && c.sec.fw === "unknown"; } },
    { key: "usbg",    text: "USBGUARD DOWN",  short: "USBGUARD", cond: function (c) { return c.secFresh && svcFault(c.sec.usbguard, c.pol.usbguard); } },
    { key: "usbgunk", text: "USBGUARD ?",     kind: "unknown", cond: function (c) { return c.secFresh && c.pol.usbguard && c.sec.usbguard === "unknown"; } },
    { key: "reboot",  text: "REBOOT PENDING", short: "REBOOT", cond: function (c) { return c.secFresh && c.sec.reboot === true; } }
];
function txt(v, c) { return typeof v === "function" ? v(c) : v; }

// Highest level <= cur whose threshold the value is still within `margin` of.
function held(v, th, low, margin, cur) {
    for (var l = cur; l >= 1; l--) {
        var t = th[l - 1];
        if (low ? v <= t + margin : v >= t - margin) return l;
    }
    return 0;
}

function stepRule(st, r, v) {
    var cur = st.lv[r.key] || 0;
    if (!has(v)) { st.pend[r.key] = 0; return (st.lv[r.key] = 0); }
    var raw = sev(v, r.th, r.low);
    if (raw > cur) {
        var n = (st.pend[r.key] || 0) + 1;
        st.pmin[r.key] = n === 1 ? raw : Math.min(st.pmin[r.key], raw);
        st.pend[r.key] = n;
        if (n >= UP) { st.lv[r.key] = st.pmin[r.key]; st.pend[r.key] = 0; }
    } else {
        st.pend[r.key] = 0;
        st.lv[r.key] = held(v, r.th, r.low, r.margin, cur);
    }
    return st.lv[r.key];
}

function stepFlag(st, f, on) {
    if (on) {
        var n = (st.pend[f.key] || 0) + 1;
        st.pend[f.key] = n;
        if (n >= UP) st.lv[f.key] = 1;
    } else {
        st.pend[f.key] = 0;
        st.lv[f.key] = 0;
    }
    return st.lv[f.key] || 0;
}

function freshState() { return { lv: {}, pend: {}, pmin: {}, seen: {} }; }

// One sample in; { levels: {key: 0|1|2}, list: [{key, kind, sev, text, short}] worst first } out.
// secAgeMs: time since the security snapshot arrived; omitted means fresh.
// pol: the security policy (see svcFault); omitted means nothing is required.
function evaluate(st, s, sec, secAgeMs, pol) {
    var d = derive(s);
    if (!d.live) return { levels: {}, list: [] };
    if (!st.seen) st.seen = {};
    if (has(s.cpu_temp)) st.seen.cpu = true;
    var fresh = secValid(sec) && !(secAgeMs > SEC_STALE_MS);
    var c = { s: s, sec: sec || {}, d: d, secFresh: fresh, pol: pol || {}, cpuSeen: !!st.seen.cpu };
    var list = [], i, lvl, t;
    for (i = 0; i < RULES.length; i++) {
        lvl = stepRule(st, RULES[i], RULES[i].val(c));
        if (lvl > 0 && !RULES[i].silent) {
            t = RULES[i].text(c);
            list.push({ key: RULES[i].key, kind: lvl >= 2 ? "crit" : "warn", sev: lvl, text: t, short: t, i: i });
        }
    }
    for (i = 0; i < FLAGS.length; i++) {
        lvl = stepFlag(st, FLAGS[i], FLAGS[i].cond(c));
        if (lvl > 0) {
            var kind = FLAGS[i].kind || "warn";
            var tx = txt(FLAGS[i].text, c);
            list.push({ key: FLAGS[i].key, kind: kind, sev: kind === "warn" ? 1 : 0,
                        text: tx, short: FLAGS[i].short ? txt(FLAGS[i].short, c) : tx, i: RULES.length + i });
        }
    }
    list.sort(function (a, b) { return RANK[b.kind] - RANK[a.kind] || a.i - b.i; });
    var levels = {};
    for (var k in st.lv) levels[k] = st.lv[k];
    return { levels: levels, list: list };
}

// What the card shows: the engine's list, preceded by a STALE entry when the fast
// telemetry is older than FAST_STALE_MS. Stale outranks everything: an alert computed
// from old data is old too.
function present(list, fastAgeMs) {
    if (!(fastAgeMs > FAST_STALE_MS)) return list;
    var sec = Math.round(fastAgeMs / 1000);
    var t = "STALE " + (sec < 120 ? sec + " s" : dur(sec));
    return [{ key: "stale", kind: "stale", sev: 0, text: t, short: t }].concat(list);
}

// A security snapshot in the current format (the probe and the views ship together, but
// an old probe still running after an upgrade must read as unknown, not as all clear).
function secValid(sec) { return !!sec && sec.fw !== undefined; }

// The security row: one dot per check. tone: ok (running / encrypted), bad (a fault, or
// a requirement not met), off (not in use, not required: shown, quiet), unk (cannot
// tell). USBGuard is left out when it is not installed and not required; the firewall
// is always shown, since having none is worth seeing even when nobody requires one.
function secView(sec, pol, fresh, reboot) {
    pol = pol || {};
    var known = !!fresh && secValid(sec), out = [];
    function svc(k, st, req, hideAbsent) {
        if (!known || st === "unknown") return { k: k, tone: "unk" };
        if (st === "active") return { k: k, tone: "ok" };
        if (svcFault(st, req)) return { k: k, tone: "bad" };
        return st === "absent" && hideAbsent ? null : { k: k, tone: "off" };
    }
    var luks = !known || (sec.luks !== true && sec.luks !== false) ? "unk"
             : sec.luks ? "ok" : pol.luks ? "bad" : "off";
    out.push({ k: "LUKS", tone: luks });
    out.push(svc(known && sec.fw_name ? sec.fw_name.toUpperCase() : "FIREWALL", known ? sec.fw : "", pol.fw, false));
    var u = svc("USBGUARD", known ? sec.usbguard : "", pol.usbguard, true);
    if (u) out.push(u);
    if (reboot) out.push({ k: "REBOOT", tone: "bad" });
    return out;
}

// The GPU row. Busy % where the driver reports it (AMD, NVIDIA); otherwise the actual
// clock against its maximum (Intel); "sleep" for a powered-down dGPU. Hidden on a
// machine where no GPU driver was found at all.
function gpuView(s) {
    if (!s || s.ts === undefined) return { show: true, value: "—", frac: 0 };
    if (has(s.gpu_busy)) return { show: true, value: s.gpu_busy + "%", frac: s.gpu_busy / 100 };
    if (has(s.gpu_freq) && s.gpu_freq_max > 0)
        return { show: true, value: Math.round(s.gpu_freq) + " MHz", frac: Math.min(1, s.gpu_freq / s.gpu_freq_max) };
    if (s.gpu_state === "sleep") return { show: true, value: "sleep", frac: 0 };
    var any = has(s.gpu_temp) || (s.src && s.src.gpu);
    return { show: !!any, value: "—", frac: 0 };
}

// The card's single contextual row, fixed in height so the card never changes size:
// FAN when hot, else the APU's package power (quiet unless on battery, charging or above
// 15 W), else empty. A discrete card's board power is not shown: next to the GPU row it
// reads as a second GPU, and it says nothing about the battery. On a machine with neither
// a fan sensor nor package power the row can never show anything, so it is not reserved.
function contextRowUsed(s) {
    return !s || s.ts === undefined || has(s.fan) || socPower(s);
}
function socPower(s) { return has(s.soc_power) && s.power_kind !== "gpu"; }
function contextRow(s, levels) {
    var none = { label: "", value: "", aux: "", tone: "none" };
    if (!s || s.ts === undefined) return none;
    levels = levels || {};
    if (has(s.fan) && ((levels.hotT || 0) > 0 || (levels.fan || 0) > 0))
        return { label: "FAN", value: s.fan + " rpm", aux: "", tone: "warn" };
    if (socPower(s)) {
        var active = (levels.socHi || 0) > 0 || s.bat_status === "Discharging" || s.bat_status === "Charging";
        return { label: "SOC", value: (s.soc_power / 1e6).toFixed(1) + " W",
                 aux: has(s.soc_cap) && s.soc_cap > 0 ? "/" + Math.round(s.soc_cap / 1e6) : "",
                 tone: active ? "normal" : "quiet" };
    }
    return none;
}

function bytes(b) {
    if (!has(b) || b < 0) return "—";
    if (b >= 1073741824) return (b / 1073741824).toFixed(1) + " GiB";
    return Math.round(b / 1048576) + " MiB";
}

// ── Stopping a process group from the drawer ─────────────────────────────────
// First confirmed click sends SIGTERM (lets the program save and exit). If the same
// command is still listed TERM_GRACE_MS later, the next confirmed click sends SIGKILL.
// A SIGTERM older than TERM_WINDOW_MS is forgotten, so a later, unrelated run of the
// same program starts again from SIGTERM.
var TERM_GRACE_MS = 3000;
var TERM_WINDOW_MS = 60000;

function termAge(name, termLog, now) {
    var t = termLog ? termLog[name] : undefined;
    return t === undefined ? Infinity : now - t;
}
function killPending(name, termLog, now) {
    return termAge(name, termLog, now) < TERM_GRACE_MS;
}
function killSignal(name, termLog, now) {
    var a = termAge(name, termLog, now);
    return a >= TERM_GRACE_MS && a < TERM_WINDOW_MS ? "KILL" : "TERM";
}

// Shell command for the probe's kill mode, or "" when anything is off. Names come from
// the probe already normalised to [A-Za-z0-9._:/+ -], so single quotes are safe; this
// re-checks rather than trusts it. The probe re-validates every PID again at send time.
function killCommand(probe, sig, name, pids) {
    if (sig !== "TERM" && sig !== "KILL") return "";
    if (typeof name !== "string" || !/^[A-Za-z0-9._:\/+ -]{1,15}$/.test(name)) return "";
    var ids = [];
    for (var i = 0; pids && i < pids.length; i++)
        if (typeof pids[i] === "number" && pids[i] > 1 && Math.floor(pids[i]) === pids[i]) ids.push(pids[i]);
    if (!ids.length) return "";
    return probe + " kill " + sig + " '" + name + "' " + ids.join(" ");
}

// ── Media bar ────────────────────────────────────────────────────────────────
function clock(us) {
    if (!has(us) || us < 0) return "";
    var s = Math.floor(us / 1e6), h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), r = s % 60;
    return (h ? h + ":" + (m < 10 ? "0" : "") : "") + m + ":" + (r < 10 ? "0" : "") + r;
}

// What the media bar shows, from the probe's `media` snapshot. The position only arrives
// every 2 s, so while playing it is advanced locally with the 1 s clock.
function mediaView(m, now, receivedAt) {
    var hidden = { visible: false, playing: false, player: "", line: "", art: "", frac: -1, time: "" };
    if (!m || !m.available || !m.player) return hidden;
    var playing = m.status === "Playing";
    var pos = has(m.pos_us) ? m.pos_us + (playing && has(receivedAt) ? Math.max(0, now - receivedAt) * 1000 : 0) : NaN;
    var len = has(m.len_us) && m.len_us > 0 ? m.len_us : NaN;
    if (!isNaN(pos) && !isNaN(len)) pos = Math.min(pos, len);
    var title = m.title || (m.artist ? "" : "Unknown");
    return {
        visible: true,
        playing: playing,
        player: m.player,
        line: title + (m.artist ? (title ? "  ·  " : "") + m.artist : ""),
        art: typeof m.art === "string" && /^(file:\/\/\/|https:\/\/)/.test(m.art) ? m.art : "",
        frac: !isNaN(pos) && !isNaN(len) ? pos / len : -1,
        time: !isNaN(len) ? "-" + clock(len - (isNaN(pos) ? 0 : pos)) : ""      // remaining only
    };
}

// Probe command for a media button, or "" when the action or player name is off.
function mediaCommand(probe, action, player) {
    if (["play-pause", "next", "previous", "raise"].indexOf(action) < 0) return "";
    if (typeof player !== "string" || !/^[A-Za-z0-9._-]{1,128}$/.test(player)) return "";
    return probe + " media-ctl " + action + " '" + player + "'";
}

// Keep the artwork across polls while the same track is shown: a player that drops the
// artwork field (it happens on pause/seek) should not blank the cover.
function keepArt(prev, next) {
    if (!next || !next.player || next.art || !prev || !prev.art) return next;
    if (prev.title !== next.title || prev.artist !== next.artist) return next;
    var m = {};
    for (var k in next) m[k] = next[k];
    m.art = prev.art;
    return m;
}

// ── Battery charge window ────────────────────────────────────────────────────
// Charging starts below `start` and stops at `end` (charge_control_*_threshold). The
// widget edits the saved window through a root helper; "full" charges to 100 % until the
// saved window is applied again (button, or next boot). Limits match the helper's.
var WIN = { startMax: 95, endMin: 50, gap: 5, step: 5 };

function batteryView(s) {
    if (!s || s.ts === undefined || !has(s.bat_limit)) return { show: false, ctl: false, hasStart: false, full: false, start: 0, end: 100 };
    var hasStart = has(s.bat_start);
    var careEnd = has(s.care_end) ? s.care_end : s.bat_limit;
    var careStart = has(s.care_start) ? s.care_start : hasStart ? s.bat_start : 0;
    return {
        show: true,
        ctl: s.bat_ctl === true,
        hasStart: hasStart,
        full: s.bat_limit === 100 && has(s.care_end) && s.care_end < 100,
        start: careStart,
        end: careEnd
    };
}

// The window after moving one handle: snapped to 5 %, inside the limits, and never
// narrower than 5 %: the moved handle stops at the other one instead of pushing it.
function clampWindow(start, end, moved) {
    var g = WIN.gap;
    start = Math.round(start / WIN.step) * WIN.step;
    end = Math.round(end / WIN.step) * WIN.step;
    start = Math.max(0, Math.min(WIN.startMax, start));
    end = Math.max(WIN.endMin, Math.min(100, end));
    if (end - start < g) {
        if (moved === "start") start = end - g;
        else end = Math.min(100, start + g);
        if (end - start < g) start = end - g;
    }
    return { start: start, end: end };
}

function isInt(v) { return typeof v === "number" && Math.floor(v) === v; }

// Probe command for a battery action, or "" when anything is off.
function batteryCommand(probe, action, start, end) {
    if (action === "full" || action === "care") return probe + " bat-" + action;
    if (action !== "set" || !isInt(start) || !isInt(end)) return "";
    if (start < 0 || start > WIN.startMax || end < WIN.endMin || end > 100 || end - start < WIN.gap) return "";
    return probe + " bat-set " + start + " " + end;
}

// One line for a failed battery action (exit codes of the probe's bat-* modes).
function batteryError(code) {
    return code === 126 ? "not authorised" : code === 127 ? "helper not installed"
         : code === 3 ? "no thresholds" : code === 4 ? "write failed" : "rejected";
}
