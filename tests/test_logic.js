// Alert engine tests. Run: node tests/test_logic.js
const fs = require('fs'), path = require('path'), assert = require('assert');
const src = fs.readFileSync(path.join(__dirname, '../contents/ui/Logic.js'), 'utf8').replace(/^\.pragma library.*$/m, '');
const L = new Function(src + '; return { TH, UP, WIN, batteryView, clampWindow, batteryCommand, batteryError, contextRowUsed, secView, gpuView, degOpt, FAST_STALE_MS, SEC_STALE_MS, TERM_GRACE_MS, TERM_WINDOW_MS, derive, evaluate, present, contextRow, freshState, batteryLine, rate, dur, killSignal, killPending, killCommand, mediaView, mediaCommand, keepArt };')();

const base = () => ({
    ts: 1, host: 'archi', mem_total: 28e6, mem_avail: 15e6, fs_blocks: 100, fs_free: 50, fs_avail: 50, fs_bsize: 4096,
    cpu_temp: 45000, gpu_temp: 40000, ssd_temp: 44000, fan: 2000, iface: 'wlan0', ssid: 'x', signal: -40,
    bat_cap: 80, bat_status: 'Not charging'
});
const secOk = { luks: true, fw: 'active', fw_name: 'ufw', usbguard: 'active', reboot: false };
// The author's settings: everything required. Defaults (nothing required) are tested apart.
const STRICT = { luks: true, fw: true, usbguard: true };

// Feed a series of overrides, one per sample; returns the result of each.
function run(series, sec = secOk, st = L.freshState(), pol = STRICT) {
    return series.map(o => L.evaluate(st, Object.assign(base(), o), sec, undefined, pol));
}
const lvl = (r, k) => r.levels[k] || 0;
const texts = r => r.list.map(a => a.text);
let n = 0; const t = (name, fn) => { fn(); n++; console.log('  ok   ', name); };

t('a single hot sample does not alert', () => {
    const r = run([{ cpu_temp: 85000 }, {}, {}]);
    assert.strictEqual(r.at(-1).list.length, 0);
});
t(`alerts only after ${L.UP} consecutive samples`, () => {
    const r = run(Array(L.UP).fill({ cpu_temp: 85000 }));
    assert.strictEqual(lvl(r[L.UP - 2], 'cpuT'), 0);
    assert.strictEqual(lvl(r[L.UP - 1], 'cpuT'), 1);
    assert.deepStrictEqual(texts(r[L.UP - 1]), ['CPU 85°C']);
});
t('a reading oscillating across the threshold never alerts', () => {
    const r = run(Array.from({ length: 40 }, (_, i) => ({ cpu_temp: i % 2 ? 84000 : 76000 })));
    assert(r.every(x => x.list.length === 0));
});
t('hysteresis: warn holds inside the margin, releases beyond it', () => {
    const r = run([...Array(3).fill({ cpu_temp: 85000 }), { cpu_temp: 78000 }, { cpu_temp: 77000 }, { cpu_temp: 76000 }]);
    assert.strictEqual(lvl(r[3], 'cpuT'), 1);
    assert.strictEqual(lvl(r[4], 'cpuT'), 1);
    assert.strictEqual(lvl(r[5], 'cpuT'), 0);
});
t('critical steps down to warning, then clears', () => {
    const r = run([...Array(3).fill({ cpu_temp: 95000 }), { cpu_temp: 88000 }, { cpu_temp: 86000 }, { cpu_temp: 70000 }]);
    assert.strictEqual(lvl(r[2], 'cpuT'), 2);
    assert.strictEqual(lvl(r[3], 'cpuT'), 2);
    assert.strictEqual(lvl(r[4], 'cpuT'), 1);
    assert.strictEqual(lvl(r[5], 'cpuT'), 0);
});
t('escalation takes the lowest level seen during the streak', () => {
    const r = run([{ cpu_temp: 85000 }, { cpu_temp: 95000 }, { cpu_temp: 95000 }]);
    assert.strictEqual(lvl(r[2], 'cpuT'), 1);
});
t('an interrupted streak restarts the count', () => {
    const r = run([{ cpu_temp: 85000 }, { cpu_temp: 85000 }, { cpu_temp: 60000 }, { cpu_temp: 85000 }, { cpu_temp: 85000 }]);
    assert(r.every(x => lvl(x, 'cpuT') === 0));
});
t('battery alerts only while discharging, clears at once on AC', () => {
    const dis = { bat_cap: 9, bat_status: 'Discharging' };
    const r = run([dis, dis, dis, { bat_cap: 9, bat_status: 'Charging' }]);
    assert.strictEqual(lvl(r[2], 'bat'), 2);
    assert.deepStrictEqual(texts(r[2]), ['BAT 9%']);
    assert.strictEqual(lvl(r[3], 'bat'), 0);
});
t('low-is-bad hysteresis on battery (warn ≤20, releases >23)', () => {
    const d = c => ({ bat_cap: c, bat_status: 'Discharging' });
    const r = run([d(19), d(19), d(19), d(22), d(24)]);
    assert.strictEqual(lvl(r[2], 'bat'), 1);
    assert.strictEqual(lvl(r[3], 'bat'), 1);
    assert.strictEqual(lvl(r[4], 'bat'), 0);
});
t('weak signal: hysteresis in dBm and no alert without an SSID', () => {
    const w = { signal: -75 };
    const r = run([w, w, w, { signal: -70 }, { signal: -66 }]);
    assert.strictEqual(lvl(r[2], 'sig'), 1);
    assert.strictEqual(lvl(r[3], 'sig'), 1);
    assert.strictEqual(lvl(r[4], 'sig'), 0);
    const e = run(Array(4).fill({ ssid: '', signal: -90 }));
    assert.strictEqual(lvl(e[3], 'sig'), 0);
});
t('offline needs persistence, recovers immediately', () => {
    const r = run([{ iface: '' }, { iface: '' }, { iface: '' }, {}]);
    assert.strictEqual(lvl(r[1], 'offline'), 0);
    assert.deepStrictEqual(texts(r[2]), ['OFFLINE']);
    assert.strictEqual(r[3].list.length, 0);
});
t('security flags: LUKS off, UFW down, USBGuard down, reboot pending', () => {
    const bad = { luks: false, fw: 'down', fw_name: 'ufw', usbguard: 'down', reboot: true };
    const r = run(Array(L.UP).fill({}), bad).at(-1);
    assert.deepStrictEqual(texts(r).sort(), ['LUKS OFF', 'REBOOT PENDING', 'UFW DOWN', 'USBGUARD DOWN']);
});
t('pill label is shortened for long flags, full text kept for the panel', () => {
    const r = run(Array(L.UP).fill({}), { ...secOk, reboot: true, usbguard: 'down' }).at(-1);
    const by = Object.fromEntries(r.list.map(a => [a.key, a]));
    assert.strictEqual(by.reboot.short, 'REBOOT');
    assert.strictEqual(by.reboot.text, 'REBOOT PENDING');
    assert.strictEqual(by.usbg.short, 'USBGUARD');
});
t('security probe never reported: SECURITY ? (unknown) after persistence, not before', () => {
    for (const sec of [{}, null]) {   // null, not undefined: undefined would pick run()'s default
        const r = run(Array(L.UP).fill({}), sec);
        assert.strictEqual(r[L.UP - 2].list.length, 0);
        assert.deepStrictEqual(r.at(-1).list.map(a => [a.text, a.kind]), [['SECURITY ?', 'unknown']]);
    }
});
t('security snapshot older than 90 s: SECURITY ?, and its stale findings are not reported', () => {
    const st = L.freshState(), sec = { luks: false, fw: 'down', fw_name: 'ufw', usbguard: 'active', reboot: false };
    let r; for (let i = 0; i < L.UP; i++) r = L.evaluate(st, base(), sec, L.SEC_STALE_MS + 1, STRICT);
    assert.deepStrictEqual(texts(r), ['SECURITY ?']);
    for (let i = 0; i < L.UP; i++) r = L.evaluate(st, base(), sec, 1000, STRICT);
    assert.deepStrictEqual(texts(r).sort(), ['LUKS OFF', 'UFW DOWN']);
});
t('systemctl "unknown" is FIREWALL ?, not a fault', () => {
    const r = run(Array(L.UP).fill({}), { ...secOk, fw: 'unknown', fw_name: '', usbguard: 'unknown' }).at(-1);
    assert.deepStrictEqual(r.list.map(a => [a.text, a.kind]), [['FIREWALL ?', 'unknown'], ['USBGUARD ?', 'unknown']]);
});
t('LUKS undeterminable (null) is LUKS ?, not LUKS OFF', () => {
    const r = run(Array(L.UP).fill({}), { ...secOk, luks: null }).at(-1);
    assert.deepStrictEqual(r.list.map(a => [a.text, a.kind]), [['LUKS ?', 'unknown']]);
});
t('list is ordered critical first, then by rule order', () => {
    const o = { cpu_temp: 85000, ssd_temp: 80000 };
    const r = run(Array(3).fill(o)).at(-1);
    assert.deepStrictEqual(texts(r), ['SSD 80°C', 'CPU 85°C']);
    assert.deepStrictEqual(r.list.map(a => a.sev), [2, 1]);
});
t('FAN row trigger has hysteresis (on ≥70 °C, off <65 °C)', () => {
    const r = run([...Array(3).fill({ cpu_temp: 72000 }), { cpu_temp: 66000 }, { cpu_temp: 64000 }]);
    assert.strictEqual(lvl(r[2], 'hotT'), 1);
    assert.strictEqual(lvl(r[3], 'hotT'), 1);
    assert.strictEqual(lvl(r[4], 'hotT'), 0);
    assert.strictEqual(r[2].list.length, 0, 'silent rules stay out of the alert list');
});
t('missing secondary sensors (GPU/SSD temp, fan, signal) never alert', () => {
    const o = { gpu_temp: null, ssd_temp: null, fan: null, signal: null };
    assert(run(Array(5).fill(o)).every(x => x.list.length === 0));
});
t('a CPU sensor that stops answering blocks NOMINAL as unknown, ranked below warnings', () => {
    const r = run([{}, ...Array(L.UP).fill({ cpu_temp: null, mem_avail: 3e6 })]).at(-1);
    assert.deepStrictEqual(r.list.map(a => [a.text, a.kind]), [['MEM 89%', 'warn'], ['CPU TEMP ?', 'unknown']]);
});
t('a machine that never had a CPU sensor (VM, unknown board) is not flagged', () => {
    const r = run(Array(10).fill({ cpu_temp: null })).at(-1);
    assert.strictEqual(r.list.length, 0);
});
t('entries carry their kind: crit and warn from rules', () => {
    const r = run(Array(L.UP).fill({ cpu_temp: 95000, ssd_temp: 66000 })).at(-1);
    assert.deepStrictEqual(r.list.map(a => a.kind), ['crit', 'warn']);
});
t('present(): nothing added while fresh; STALE first, above critical, once 7 s pass', () => {
    const list = run(Array(L.UP).fill({ cpu_temp: 95000 })).at(-1).list;
    assert.strictEqual(L.present(list, 2000), list);
    assert.strictEqual(L.present(list, L.FAST_STALE_MS), list);
    const p = L.present(list, 12400);
    assert.deepStrictEqual(p.map(a => a.kind), ['stale', 'crit']);
    assert.strictEqual(p[0].text, 'STALE 12 s');
    assert.strictEqual(L.present([], 300000)[0].text, 'STALE 5m');
});
t('contextRow: FAN when hot, quiet SOC at idle, normal SOC on battery or above 15 W', () => {
    const lv = r => r.at(-1).levels;
    let r = run(Array(L.UP).fill({ cpu_temp: 72000, fan: 4100, soc_power: 9e6 }));
    assert.deepStrictEqual(L.contextRow(Object.assign(base(), { fan: 4100 }), lv(r)), { label: 'FAN', value: '4100 rpm', aux: '', tone: 'warn' });
    const idle = Object.assign(base(), { soc_power: 3.5e6, soc_cap: null });
    assert.strictEqual(L.contextRow(idle, {}).tone, 'quiet');
    assert.strictEqual(L.contextRow(Object.assign(idle, { bat_status: 'Discharging' }), {}).tone, 'normal');
    r = run([...Array(3).fill({ soc_power: 18e6 }), { soc_power: 13e6 }, { soc_power: 11e6 }]);
    assert.strictEqual(r[2].levels.socHi, 1);
    assert.strictEqual(r[3].levels.socHi, 1, 'held inside the 3 W margin');
    assert.strictEqual(r[4].levels.socHi, 0);
    assert.strictEqual(L.contextRow(Object.assign(base(), { soc_power: null }), {}).tone, 'none');
    assert.strictEqual(L.contextRow({}, {}).tone, 'none');
});
t('before the first snapshot: empty result', () => {
    assert.deepStrictEqual(L.evaluate(L.freshState(), {}, {}), { levels: {}, list: [] });
});
t('derive: memory and disk figures', () => {
    const d = L.derive(base());
    assert.strictEqual(Math.round(d.diskPct), 50);
    assert.strictEqual(Math.round(d.memPct), 46);
});
t('batteryLine wording', () => {
    assert.strictEqual(L.batteryLine({ bat_status: 'Not charging', bat_cap: 89, bat_limit: 90 }), 'AC · held at 90%');
    assert.strictEqual(L.batteryLine({ bat_status: 'Discharging', bat_power: 6200000, bat_energy: 50000000 }), 'On battery  ·  6.2 W  ·  8h 03m left');
});
t('kill escalation: TERM first, KILL only 3–60 s after a TERM to the same command', () => {
    const now = 1e6, log = { cc1plus: now - 1000, ld: now - 5000, old: now - 120000 };
    assert.strictEqual(L.killSignal('firefox', log, now), 'TERM');
    assert.strictEqual(L.killSignal('cc1plus', log, now), 'TERM');
    assert.strictEqual(L.killPending('cc1plus', log, now), true);
    assert.strictEqual(L.killSignal('ld', log, now), 'KILL');
    assert.strictEqual(L.killPending('ld', log, now), false);
    assert.strictEqual(L.killSignal('old', log, now), 'TERM', 'a stale TERM is forgotten');
    assert.strictEqual(L.killSignal('x', undefined, now), 'TERM');
});
t('killCommand: builds a quoted command and rejects anything unsafe', () => {
    const p = "bash '/p/archi-stat.sh'";
    assert.strictEqual(L.killCommand(p, 'TERM', 'Web Content', [101, 102]), p + " kill TERM 'Web Content' 101 102");
    assert.strictEqual(L.killCommand(p, 'KILL', 'cc1plus', [1, 0, -3, 2.5, '7', 300]), p + " kill KILL 'cc1plus' 300");
    assert.strictEqual(L.killCommand(p, 'HUP', 'cc1plus', [300]), '');
    assert.strictEqual(L.killCommand(p, 'TERM', "x'; rm -rf ~; '", [300]), '');
    assert.strictEqual(L.killCommand(p, 'TERM', 'a$(id)', [300]), '');
    assert.strictEqual(L.killCommand(p, 'TERM', 'cc1plus', []), '');
    assert.strictEqual(L.killCommand(p, 'TERM', 'cc1plus', [1]), '');
});
t('mediaView: hidden without a browser player', () => {
    for (const m of [null, { available: false }, { available: true, player: null }])
        assert.strictEqual(L.mediaView(m, 0, 0).visible, false);
});
t('mediaView: line, art filter, and position advanced locally while playing', () => {
    const m = { available: true, player: 'firefox.i1', status: 'Playing', artist: 'Canal', title: 'Video',
                pos_us: 60e6, len_us: 240e6, art: 'file:///tmp/firefox-mpris/x.png' };
    const v = L.mediaView(m, 10000, 7000);
    assert.strictEqual(v.line, 'Video  ·  Canal');
    assert.strictEqual(v.art, 'file:///tmp/firefox-mpris/x.png');
    assert.strictEqual(v.time, '-2:57');
    assert(Math.abs(v.frac - 63 / 240) < 1e-9);
    const p = L.mediaView(Object.assign({}, m, { status: 'Paused' }), 10000, 7000);
    assert.strictEqual(p.playing, false);
    assert.strictEqual(p.time, '-3:00', 'paused: no local advance');
    assert.strictEqual(L.mediaView(Object.assign({}, m, { art: 'javascript:x' }), 0, 0).art, '');
    assert.strictEqual(L.mediaView(Object.assign({}, m, { len_us: null }), 0, 0).frac, -1);
    assert.strictEqual(L.mediaView(Object.assign({}, m, { artist: '' }), 0, 0).line, 'Video');
    assert.strictEqual(L.mediaView(Object.assign({}, m, { pos_us: 239e6 }), 1e7, 0).frac, 1, 'clamped to the end');
});
t('mediaCommand: whitelisted actions and safe player names only', () => {
    const p = "bash '/p/archi-stat.sh'";
    assert.strictEqual(L.mediaCommand(p, 'play-pause', 'firefox.instance_1_23'), p + " media-ctl play-pause 'firefox.instance_1_23'");
    assert.strictEqual(L.mediaCommand(p, 'stop', 'firefox'), '');
    assert.strictEqual(L.mediaCommand(p, 'next', "firefox'; id; '"), '');
    assert.strictEqual(L.mediaCommand(p, 'raise', ''), '');
});
t('keepArt: same track keeps its cover; a new track or a real cover does not', () => {
    const prev = { player: 'p', title: 'Muerte En Hawaii', artist: 'Residente', art: 'file:///tmp/a.jpg?v=1-2' };
    assert.strictEqual(L.keepArt(prev, { player: 'p', title: 'Muerte En Hawaii', artist: 'Residente', art: '' }).art, prev.art);
    assert.strictEqual(L.keepArt(prev, { player: 'p', title: 'Otra', artist: 'Residente', art: '' }).art, '');
    assert.strictEqual(L.keepArt(prev, { player: 'p', title: 'Muerte En Hawaii', artist: 'Residente', art: 'https://x/y.jpg' }).art, 'https://x/y.jpg');
    assert.strictEqual(L.keepArt(null, { player: 'p', title: 't', art: '' }).art, '');
    assert.deepStrictEqual(L.keepArt(prev, { available: true, player: null }), { available: true, player: null });
});

// ── Portability: other people's machines ─────────────────────────────────────
const DEF = {};   // default policy: nothing required
const runP = (sec, pol) => run(Array(L.UP).fill({}), sec, L.freshState(), pol).at(-1);
t('default policy: no firewall, no USBGuard, no LUKS is still NOMINAL', () => {
    const r = runP({ luks: false, fw: 'off', fw_name: '', usbguard: 'absent', reboot: false }, DEF);
    assert.deepStrictEqual(texts(r), []);
    assert.deepStrictEqual(texts(runP({ luks: null, fw: 'absent', fw_name: '', usbguard: 'absent', reboot: false }, DEF)), []);
    assert.deepStrictEqual(texts(runP({ ...secOk, fw: 'unknown', usbguard: 'unknown' }, DEF)), []);
});
t('default policy: a service that should run and does not still alerts', () => {
    assert.deepStrictEqual(texts(runP({ ...secOk, fw: 'down', fw_name: 'firewalld' }, DEF)), ['FIREWALLD DOWN']);
    const r = runP({ ...secOk, usbguard: 'down' }, DEF);
    assert.deepStrictEqual(r.list.map(a => [a.text, a.short]), [['USBGUARD DOWN', 'USBGUARD']]);
});
t('required: missing firewall / USBGuard / encryption alert, with short pill labels', () => {
    const r = runP({ luks: false, fw: 'absent', fw_name: '', usbguard: 'off', reboot: false }, STRICT);
    assert.deepStrictEqual(r.list.map(a => [a.text, a.short]),
        [['LUKS OFF', 'LUKS OFF'], ['NO FIREWALL', 'NO FW'], ['USBGUARD DOWN', 'USBGUARD']]);
    assert.strictEqual(runP({ ...secOk, fw: 'down', fw_name: 'ufw' }, STRICT).list[0].short, 'UFW DOWN');
    assert.strictEqual(runP({ ...secOk, fw: 'down', fw_name: 'firewalld' }, STRICT).list[0].short, 'FW DOWN');
});
t('an old-format security snapshot reads as SECURITY ?, not as all clear', () => {
    const r = runP({ luks: true, ufw: 'active', usbguard: 'active', reboot: false }, DEF);
    assert.deepStrictEqual(texts(r), ['SECURITY ?']);
});
t('secView: dots per check and policy', () => {
    const v = (sec, pol, fresh = true, rb = false) => L.secView(sec, pol, fresh, rb).map(i => i.k + ':' + i.tone).join(' ');
    assert.strictEqual(v(secOk, STRICT), 'LUKS:ok UFW:ok USBGUARD:ok');
    assert.strictEqual(v({ luks: false, fw: 'off', fw_name: '', usbguard: 'absent' }, DEF), 'LUKS:off FIREWALL:off');
    assert.strictEqual(v({ luks: false, fw: 'off', fw_name: '', usbguard: 'absent' }, STRICT), 'LUKS:bad FIREWALL:bad USBGUARD:bad');
    assert.strictEqual(v({ luks: true, fw: 'down', fw_name: 'firewalld', usbguard: 'off' }, DEF), 'LUKS:ok FIREWALLD:bad USBGUARD:off');
    assert.strictEqual(v({ luks: null, fw: 'unknown', fw_name: '', usbguard: 'unknown' }, DEF), 'LUKS:unk FIREWALL:unk USBGUARD:unk');
    assert.strictEqual(v(secOk, STRICT, false), 'LUKS:unk FIREWALL:unk USBGUARD:unk', 'stale: nothing claimed');
    assert.strictEqual(v(secOk, DEF, true, true), 'LUKS:ok UFW:ok USBGUARD:ok REBOOT:bad');
});
t('gpuView: busy %, Intel clock, sleeping dGPU, no GPU at all', () => {
    const g = o => L.gpuView(Object.assign(base(), o));
    assert.deepStrictEqual(g({ gpu_busy: 9 }), { show: true, value: '9%', frac: 0.09 });
    assert.deepStrictEqual(g({ gpu_busy: null, gpu_freq: 450, gpu_freq_max: 1300 }), { show: true, value: '450 MHz', frac: 450 / 1300 });
    assert.deepStrictEqual(g({ gpu_busy: null, gpu_state: 'sleep', src: { gpu: 'nvidia' } }), { show: true, value: 'sleep', frac: 0 });
    assert.strictEqual(g({ gpu_busy: null, gpu_temp: null, src: { gpu: '' } }).show, false);
    assert.strictEqual(g({ gpu_busy: null, gpu_temp: 40000 }).show, true);
    assert.strictEqual(L.gpuView({}).show, true, 'before the first sample the row is kept');
});
t('contextRow: APU package power shown, a discrete card\'s board power not; no FAN without a fan sensor', () => {
    assert.strictEqual(L.contextRow(Object.assign(base(), { soc_power: 30e6, power_kind: 'gpu' }), {}).tone, 'none');
    assert.strictEqual(L.contextRow(Object.assign(base(), { soc_power: 9e6, power_kind: 'soc' }), {}).label, 'SOC');
    assert.strictEqual(L.contextRow(Object.assign(base(), { fan: null, soc_power: null }), { hotT: 1 }).tone, 'none');
    assert.strictEqual(L.contextRowUsed(Object.assign(base(), { fan: null, soc_power: null })), false);
    assert.strictEqual(L.contextRowUsed(Object.assign(base(), { fan: null, soc_power: 30e6, power_kind: 'gpu' })), false);
    assert.strictEqual(L.contextRowUsed(base()), true);
    assert.strictEqual(L.contextRowUsed({}), true);
});
t('degOpt: blank for a sensor the machine does not have', () => {
    assert.strictEqual(L.degOpt(null), '');
    assert.strictEqual(L.degOpt(41000), '41°C');
});

// ── Battery charge window ────────────────────────────────────────────────────
t('batteryView: window, full-charge detection, read-only', () => {
    const b = o => L.batteryView(Object.assign(base(), o));
    assert.strictEqual(b({ bat_limit: null }).show, false, 'no thresholds: nothing to open');
    const care = b({ bat_limit: 80, bat_start: 40, bat_ctl: true, care_start: 40, care_end: 80 });
    assert.deepStrictEqual([care.show, care.ctl, care.full, care.start, care.end], [true, true, false, 40, 80]);
    const full = b({ bat_limit: 100, bat_start: 99, bat_ctl: true, care_start: 40, care_end: 80 });
    assert.deepStrictEqual([full.full, full.start, full.end], [true, 40, 80], 'full charge shows the saved window');
    assert.strictEqual(b({ bat_limit: 100, bat_start: 0, bat_ctl: true, care_start: 0, care_end: 100 }).full, false, 'a chosen 100 % is not "full charge"');
    const ro = b({ bat_limit: 80, bat_start: 40 });
    assert.deepStrictEqual([ro.ctl, ro.start, ro.end], [false, 40, 80], 'without the helper: current thresholds, read-only');
    assert.deepStrictEqual([b({ bat_limit: 80, bat_start: null }).hasStart, L.batteryView({}).end], [false, 100]);
});
t('clampWindow: 5 % steps, limits, the moved handle stops at the other', () => {
    const c = (s, e, m) => { const w = L.clampWindow(s, e, m); return [w.start, w.end]; };
    assert.deepStrictEqual(c(41.2, 78.9, 'end'), [40, 80]);
    assert.deepStrictEqual(c(40, 30, 'end'), [40, 50], 'end never below 50');
    assert.deepStrictEqual(c(90, 60, 'start'), [55, 60], 'start stops 5 below end');
    assert.deepStrictEqual(c(98, 100, 'start'), [95, 100], 'start at most 95');
    assert.deepStrictEqual(c(70, 72, 'end'), [70, 75], 'end stops 5 above start');
    assert.deepStrictEqual(c(-5, 120, 'end'), [0, 100]);
});
t('batteryCommand: validated commands only', () => {
    const p = "bash '/p/archi-stat.sh'";
    assert.strictEqual(L.batteryCommand(p, 'set', 40, 80), p + ' bat-set 40 80');
    assert.strictEqual(L.batteryCommand(p, 'full'), p + ' bat-full');
    assert.strictEqual(L.batteryCommand(p, 'care'), p + ' bat-care');
    for (const [s, e] of [[40, 45.5], [40, 40], [96, 100], [0, 45], ['40', 80], [-1, 80], [40, 101]])
        assert.strictEqual(L.batteryCommand(p, 'set', s, e), '', `${s}-${e} rejected`);
    assert.strictEqual(L.batteryCommand(p, 'rm -rf', 40, 80), '');
    assert.strictEqual(L.batteryError(126), 'not authorised');
    assert.strictEqual(L.batteryError(127), 'helper not installed');
});
t('batteryLine: on AC above the start threshold, says when it will charge', () => {
    assert.strictEqual(L.batteryLine({ bat_status: 'Not charging', bat_cap: 62, bat_limit: 80, bat_start: 40 }), 'AC · charges below 40%');
    assert.strictEqual(L.batteryLine({ bat_status: 'Not charging', bat_cap: 79, bat_limit: 80, bat_start: 40 }), 'AC · held at 80%');
    assert.strictEqual(L.batteryLine({ bat_status: 'Not charging', bat_cap: 62, bat_limit: 80 }), 'AC · idle');
});

console.log(`${n} passed`);
