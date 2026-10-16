// Alert engine tests. Run: node tests/test_logic.js
const fs = require('fs'), path = require('path'), assert = require('assert');
const src = fs.readFileSync(path.join(__dirname, '../contents/ui/Logic.js'), 'utf8').replace(/^\.pragma library.*$/m, '');
const L = new Function(src + '; return { TH, UP, FAST_STALE_MS, SEC_STALE_MS, TERM_GRACE_MS, TERM_WINDOW_MS, derive, evaluate, present, contextRow, freshState, batteryLine, rate, dur, killSignal, killPending, killCommand, mediaView, mediaCommand, keepArt };')();

const base = () => ({
    ts: 1, host: 'archi', mem_total: 28e6, mem_avail: 15e6, fs_blocks: 100, fs_free: 50, fs_avail: 50, fs_bsize: 4096,
    cpu_temp: 45000, gpu_temp: 40000, ssd_temp: 44000, fan: 2000, iface: 'wlan0', ssid: 'x', signal: -40,
    bat_cap: 80, bat_status: 'Not charging'
});
const secOk = { luks: true, ufw: 'active', usbguard: 'active', reboot: false };

// Feed a series of overrides, one per sample; returns the result of each.
function run(series, sec = secOk, st = L.freshState()) {
    return series.map(o => L.evaluate(st, Object.assign(base(), o), sec));
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
    const bad = { luks: false, ufw: 'inactive', usbguard: 'failed', reboot: true };
    const r = run(Array(L.UP).fill({}), bad).at(-1);
    assert.deepStrictEqual(texts(r).sort(), ['LUKS OFF', 'REBOOT PENDING', 'UFW DOWN', 'USBGUARD DOWN']);
});
t('pill label is shortened for long flags, full text kept for the panel', () => {
    const r = run(Array(L.UP).fill({}), { ...secOk, reboot: true, usbguard: 'failed' }).at(-1);
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
    const st = L.freshState(), sec = { luks: false, ufw: 'inactive', usbguard: 'active', reboot: false };
    let r; for (let i = 0; i < L.UP; i++) r = L.evaluate(st, base(), sec, L.SEC_STALE_MS + 1);
    assert.deepStrictEqual(texts(r), ['SECURITY ?']);
    for (let i = 0; i < L.UP; i++) r = L.evaluate(st, base(), sec, 1000);
    assert.deepStrictEqual(texts(r).sort(), ['LUKS OFF', 'UFW DOWN']);
});
t('systemctl "unknown" is UFW ?, not UFW DOWN', () => {
    const r = run(Array(L.UP).fill({}), { ...secOk, ufw: 'unknown', usbguard: 'unknown' }).at(-1);
    assert.deepStrictEqual(r.list.map(a => [a.text, a.kind]), [['UFW ?', 'unknown'], ['USBGUARD ?', 'unknown']]);
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
t('missing CPU temperature blocks NOMINAL as unknown, ranked below warnings', () => {
    const r = run(Array(L.UP).fill({ cpu_temp: null, mem_avail: 3e6 })).at(-1);
    assert.deepStrictEqual(r.list.map(a => [a.text, a.kind]), [['MEM 89%', 'warn'], ['CPU TEMP ?', 'unknown']]);
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
console.log(`${n} passed`);
