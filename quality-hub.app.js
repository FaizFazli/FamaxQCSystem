/* Famax Quality Hub — Refined MES (Vue 3 port of the Claude Design prototype)
 * No-login workspace; restricted modules behind Admin Login.
 * Reads live data from the factory Supabase (read-only) when reachable; otherwise
 * renders realistic demo data. It never writes/uploads. */
(function () {
  'use strict';

  /* ---------- seed data (module scope so data() can call them) ---------- */
  function blankRm() {
    return { search: '', area: '', category: '', material: '', grade: '', size: '', uom: '', unitW: '', sysBal: '', movePcs: '', ref: '', lot: '', cert: '' };
  }
  function seedReadings() {
    return {
      0: ['85.02', '84.98', '85.05', '85.01', '84.96'],
      1: ['25.008', '25.012', '25.006', '25.014', '25.009'],
      2: ['42.51', '42.49', '42.53', '42.50', '42.48'],
      3: ['0.03', '0.04', '0.071', '0.03', '0.04'],
      4: ['1.2', '1.4', '1.3', '1.5', '1.3'],
    };
  }
  function seedMovements() {
    return [
      { time: '11:20', dir: 'OUT', part: 'FX-1180 Cover Plate', qty: '600 pcs', brk: '—', ref: 'DO-25-0881', by: 'Store A' },
      { time: '10:55', dir: 'IN', part: 'FX-2031 Hub Bracket', qty: '842 pcs', brk: '—', ref: 'JO-25-0412', by: 'CNC-01' },
      { time: '10:10', dir: 'IN', part: 'FX-4501 Locating Pin', qty: '5,124 pcs', brk: '—', ref: 'JO-25-0430', by: 'TURN-01' },
      { time: '09:30', dir: 'OUT', part: 'FX-7701 Housing', qty: '1,200 pcs', brk: '—', ref: 'DO-25-0879', by: 'Store B' },
    ];
  }
  function seedSchedule() {
    return [
      { id: 1, time: '08:00', part: 'FX-2031 Hub Bracket', process: 'CNC Milling', parameter: 'Bore Ø25.000 +0.021', cycle: '38s', machine: 'CNC-01', checker: 'Aiman', reassignedTo: '', target: 50, checked: 50, status: 'Done', inspectionType: 'Initial', parentId: null },
      { id: 2, time: '09:30', part: 'FX-4501 Locating Pin', process: 'Turning', parameter: 'OD Ø6.000 ±0.010', cycle: '9s', machine: 'TURN-01', checker: 'Siti', reassignedTo: '', target: 60, checked: 32, status: 'In Progress', inspectionType: 'Initial', parentId: null },
      { id: 3, time: '10:30', part: 'FX-7701 Housing', process: 'Injection', parameter: 'Flatness 0.05 max', cycle: '22s', machine: 'INJ-01', checker: 'Ravi', reassignedTo: '', target: 40, checked: 0, status: 'Pending', inspectionType: 'Initial', parentId: null },
      { id: 4, time: '11:30', part: 'FX-1180 Cover Plate', process: 'Deburr', parameter: 'Edge break 0.2–0.4', cycle: '27s', machine: 'MILL-02', checker: 'Aiman', reassignedTo: 'Nurul', target: 50, checked: 0, status: 'Overdue', inspectionType: 'Initial', parentId: null },
      { id: 5, time: '13:00', part: 'FX-3310 Shaft Collar', process: 'CNC Milling', parameter: 'Length 85.00 ±0.10', cycle: '18s', machine: 'CNC-04', checker: 'Mei Ling', reassignedTo: '', target: 30, checked: 0, status: 'Pending', inspectionType: 'Initial', parentId: null },
      { id: 6, time: '07:30', part: 'FX-2099 Flange', process: 'Grinding', parameter: 'Surface Ra 1.6 max', cycle: '52s', machine: 'GRIND-01', checker: 'Siti', reassignedTo: '', target: 40, checked: 40, status: 'Waiting Rework', inspectionType: 'Initial', parentId: null },
      { id: 7, time: '12:15', part: 'FX-2099 Flange', process: 'Grinding', parameter: 'Surface Ra 1.6 max', cycle: '52s', machine: 'GRIND-01', checker: 'Siti', reassignedTo: '', target: 6, checked: 0, status: 'Pending', inspectionType: 'Reinspection', parentId: 6 },
    ];
  }
  function seedQueue() {
    return [
      { id: 'WI-0231', parts: 'FX-2031 Hub Bracket · Rev C', issuedBy: 'Eng. Tan', date: '16 Jun · 09:12', status: 'Pending QA', qaBy: '', mgmtBy: '' },
      { id: 'WI-0230', parts: 'FX-7701 Housing · Rev A', issuedBy: 'Eng. Lim', date: '16 Jun · 08:40', status: 'Pending MGMT', qaBy: 'Ayyub', mgmtBy: '' },
      { id: 'WI-0228', parts: 'FX-1180 Cover Plate · Rev B', issuedBy: 'Eng. Tan', date: '15 Jun · 16:20', status: 'Approved', qaBy: 'Ayyub', mgmtBy: 'Mgr. Wong' },
      { id: 'WI-0227', parts: 'FX-4501 Locating Pin · Rev D', issuedBy: 'Eng. Raj', date: '15 Jun · 14:05', status: 'Pending QA', qaBy: '', mgmtBy: '' },
    ];
  }
  function seedMachines() {
    return [
      { id: 'CNC-01', name: 'CNC-01', brand: 'Mori Seiki NLX', status: 'run', part: 'FX-2031 Hub Bracket', jo: 'JO-25-0412', count: 842, target: 1200, cycle: 38, util: 92, note: 'On track' },
      { id: 'CNC-02', name: 'CNC-02', brand: 'Mazak Integrex', status: 'run', part: 'FX-1180 Cover Plate', jo: 'JO-25-0418', count: 1192, target: 1500, cycle: 27, util: 88, note: 'On track' },
      { id: 'CNC-03', name: 'CNC-03', brand: 'Okuma Genos', status: 'idle', part: 'FX-2099 Flange', jo: 'JO-25-0405', count: 430, target: 800, cycle: 45, util: 0, note: 'Setup' },
      { id: 'CNC-04', name: 'CNC-04', brand: 'Brother Speedio', status: 'run', part: 'FX-3310 Shaft Collar', jo: 'JO-25-0421', count: 2308, target: 3000, cycle: 18, util: 95, note: 'Ahead' },
      { id: 'MILL-01', name: 'MILL-01', brand: 'DMG Mori', status: 'run', part: 'FX-2031 Hub Bracket', jo: 'JO-25-0413', count: 671, target: 1200, cycle: 41, util: 80, note: 'On track' },
      { id: 'MILL-02', name: 'MILL-02', brand: 'Haas VF-2', status: 'down', part: 'FX-1180 Cover Plate', jo: 'JO-25-0419', count: 120, target: 1000, cycle: 0, util: 0, note: 'Tool break' },
      { id: 'TURN-01', name: 'TURN-01', brand: 'Doosan Lynx', status: 'run', part: 'FX-4501 Locating Pin', jo: 'JO-25-0430', count: 5124, target: 6000, cycle: 9, util: 97, note: 'Ahead' },
      { id: 'TURN-02', name: 'TURN-02', brand: 'Hwacheon', status: 'run', part: 'FX-4502 Bushing', jo: 'JO-25-0431', count: 3340, target: 4000, cycle: 12, util: 91, note: 'On track' },
      { id: 'INJ-01', name: 'INJ-01', brand: 'Fanuc Roboshot', status: 'run', part: 'FX-7701 Housing', jo: 'JO-25-0440', count: 8810, target: 10000, cycle: 22, util: 85, note: 'On track' },
      { id: 'INJ-02', name: 'INJ-02', brand: 'Nissei', status: 'idle', part: 'FX-7702 End Cap', jo: 'JO-25-0441', count: 2100, target: 5000, cycle: 0, util: 0, note: 'Mat. wait' },
      { id: 'GRIND-01', name: 'GRIND-01', brand: 'Studer S33', status: 'run', part: 'FX-2099 Flange', jo: 'JO-25-0406', count: 540, target: 900, cycle: 52, util: 78, note: 'On track' },
      { id: 'EDM-01', name: 'EDM-01', brand: 'Sodick AG', status: 'down', part: 'FX-9001 Mold Insert', jo: 'JO-25-0450', count: 14, target: 50, cycle: 0, util: 0, note: 'Door open' },
    ];
  }

  const GATED = ['gauge', 'cycle', 'maint', 'bd', 'docctrl', 'users', 'admin'];

  /* factory Supabase (read-only) */
  const SB_URL = `${window.APP_CONFIG.url}/rest/v1`;
  const SB_KEY = window.APP_CONFIG.key;
  const SB_HEADERS = { apikey: SB_KEY, Authorization: 'Bearer ' + SB_KEY };

  function statusColor(raw) {
    const s = String(raw || '').toLowerCase();
    if (/overdue|out of tol|fail|reject|critical|down/.test(s)) return { c: '#DC2626', b: '#FCE8E8' };
    if (/due|pending|draft|monitor|low|wait|rework|idle/.test(s)) return { c: '#D97706', b: '#FCF1DE' };
    if (/active|ok|pass|done|complete|finish|approved|run|open/.test(s)) return { c: '#16A34A', b: '#E7F6EC' };
    return { c: '#64748B', b: '#EEF0F4' };
  }

  const ICONS = {
    quality: '<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3l7 3v5c0 4.5-3 8-7 10-4-2-7-5.5-7-10V6l7-3z"/><path d="M9 12l2 2 4-4"/></svg>',
    output: '<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="14" rx="2"/><path d="M7 21h10M8 14l3-3 2 2 3-4"/></svg>',
    inspect: '<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="11" cy="11" r="7"/><path d="M21 21l-4.3-4.3"/></svg>',
    reports: '<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M5 21V8M12 21V3M19 21v-6"/></svg>',
    store: '<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 8l9-5 9 5v8l-9 5-9-5V8z"/><path d="M3 8l9 5 9-5M12 13v8"/></svg>',
    cycle: '<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></svg>',
    maint: '<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14 7l3-3 3 3-3 3M14 7l-9 9v3h3l9-9M14 7l-3 3"/></svg>',
    pack: '<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 7l9-4 9 4v10l-9 4-9-4V7z"/><path d="M3 7l9 4 9-4M12 11v10"/></svg>',
    admin: '<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19 12a7 7 0 00-.1-1.2l2-1.5-2-3.4-2.3.9a7 7 0 00-2-1.2L14.2 2H9.8l-.4 2.4a7 7 0 00-2 1.2l-2.3-.9-2 3.4 2 1.5A7 7 0 005 12"/></svg>',
    dms: '<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 7a2 2 0 012-2h4l2 2h8a2 2 0 012 2v8a2 2 0 01-2 2H5a2 2 0 01-2-2V7z"/><path d="M8 13h8M8 16h5" opacity=".6"/></svg>',
    notify: '<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M18 8a6 6 0 10-12 0c0 7-3 9-3 9h18s-3-2-3-9"/><path d="M13.7 21a2 2 0 01-3.4 0"/></svg>',
    gauge: '<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 14a8 8 0 018-8M12 14L8 6"/><path d="M3.5 18a10 10 0 0117 0"/><circle cx="12" cy="14" r="1.6" fill="currentColor"/></svg>',
    users: '<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="9" cy="8" r="3.2"/><path d="M3 20a6 6 0 0112 0"/><path d="M16 5.2a3.2 3.2 0 010 5.6M21 20a6 6 0 00-5-5.9"/></svg>',
  };

  const { createApp } = Vue;

  createApp({
    data() {
      return {
        view: 'hub', collapsed: false, shift: 'A',
        reportTab: 'qc', adminTab: 'filegen', storeTab: 'material',
        time: new Date(), source: 'demo',
        machines: seedMachines(),
        dmsPart: 0, wiQueue: seedQueue(), toast: '',
        qSchedule: seedSchedule(), modal: null, modalId: null,
        form: { part: '', jo: '', process: '', parameter: '', cycle: '', machine: '', checker: '', target: '', time: '' },
        keyin: { accept: '', rework: '', scrap: '' },
        auth: false, loginCreds: { id: '', pw: '' }, loginErr: '',
        bdTab: 'packing', docTab: 'revision',
        storeMovements: seedMovements(), txn: { dir: 'IN', item: '', carton: '', perCarton: '25', loose: '', ref: '' },
        inspType: 'ipqc', drawZoom: 1, readings: seedReadings(),
        rmMove: blankRm(),
        live: {},
        _tt: null, _clk: null, _pulse: null,
      };
    },

    mounted() {
      this._clk = setInterval(() => { this.time = new Date(); }, 1000);
      this._pulse = setInterval(() => this.tick(), 2500);
      this.tryLive();
      this.loadLive();
      // Re-pull real data every 30s so on-screen numbers track the database.
      // Skipped while a modal is open so it never clobbers an in-progress dialog.
      this._refresh = setInterval(() => { if (!this.modal) { this.tryLive(); this.loadLive(); } }, 30000);
    },
    beforeUnmount() { clearInterval(this._clk); clearInterval(this._pulse); clearInterval(this._refresh); clearTimeout(this._tt); },

    computed: {
      navBase() {
        return 'display:flex;align-items:center;gap:13px;padding:11px 13px;border-radius:11px;font-size:14px;font-weight:600;color:#C5C2E8;cursor:pointer;text-decoration:none;transition:background .15s;';
      },
      v() { return this.renderVals(); },
    },

    methods: {
      /* ----- raw material movement form ----- */
      setRm(key) { return (e) => { this.rmMove = { ...this.rmMove, [key]: e.target.value }; }; },
      attachCert() {
        this.rmMove = { ...this.rmMove, cert: 'MillCert_' + ((this.rmMove.lot || 'LOT').replace(/\s+/g, '') || 'LOT') + '.pdf' };
        this.flash('Mill cert attached');
      },
      clearRmForm() { this.rmMove = blankRm(); this.flash('Form cleared'); },
      saveRmTxn() {
        const rm = this.rmMove, m = +rm.movePcs || 0;
        if (!m) { this.flash('Enter a stock movement (pcs)'); return; }
        if (!rm.cert) { this.flash('Mill cert attachment is required for raw material'); return; }
        const dir = m >= 0 ? 'IN' : 'OUT';
        const n = new Date(); const p = (x) => String(x).padStart(2, '0');
        const label = (rm.material || rm.search || 'Raw material').slice(0, 42);
        const entry = { time: p(n.getHours()) + ':' + p(n.getMinutes()), dir, part: label, qty: Math.abs(m) + ' pcs', brk: 'Lot ' + (rm.lot || '—') + ' · ' + rm.cert, ref: rm.ref.trim() || '—', by: 'RM store' };
        this.storeMovements = [entry, ...this.storeMovements];
        this.rmMove = blankRm();
        this.flash('Raw material ' + dir + ' saved & form cleared');
      },
      rawStockData() {
        const rm = this.rmMove;
        const unitW = parseFloat(rm.unitW) || 0, sysBal = parseFloat(rm.sysBal) || 0, mp = parseFloat(rm.movePcs) || 0;
        const hasW = rm.unitW !== '' && (rm.sysBal !== '' || rm.movePcs !== '');
        return {
          rmSearch: rm.search, rmArea: rm.area, rmCategory: rm.category, rmMaterial: rm.material,
          rmGrade: rm.grade, rmSize: rm.size, rmUom: rm.uom, rmUnitW: rm.unitW, rmSysBal: rm.sysBal,
          rmFinalW: hasW ? ((sysBal + mp) * unitW).toFixed(3) + ' KG' : '—',
          rmMoveKg: (rm.movePcs !== '' && rm.unitW !== '') ? ((mp >= 0 ? '+' : '') + (mp * unitW).toFixed(3)) : '',
          rmMovePcs: rm.movePcs, rmRef: rm.ref, rmLot: rm.lot, rmCert: rm.cert, rmHasCert: !!rm.cert, rmNoCert: !rm.cert,
          fRmSearch: this.setRm('search'), fRmArea: this.setRm('area'), fRmCategory: this.setRm('category'),
          fRmMaterial: this.setRm('material'), fRmGrade: this.setRm('grade'), fRmSize: this.setRm('size'),
          fRmUom: this.setRm('uom'), fRmUnitW: this.setRm('unitW'), fRmSysBal: this.setRm('sysBal'),
          fRmPcs: this.setRm('movePcs'), fRmRef: this.setRm('ref'), fRmLot: this.setRm('lot'),
          attachCert: () => this.attachCert(), clearRmForm: () => this.clearRmForm(), saveRmTxn: () => this.saveRmTxn(),
        };
      },

      /* ----- measurement readings ----- */
      setReading(ci, si, val) {
        const r = { ...this.readings }; const arr = (r[ci] || []).slice(); arr[si] = val; r[ci] = arr; this.readings = r;
      },
      clearReadings() { this.readings = {}; this.flash('All point readings cleared'); },
      calcResult(vals, lsl, usl) {
        const nums = vals.map((x) => parseFloat(x)).filter((n) => !isNaN(n));
        if (!nums.length) return 'Pending';
        const u = parseFloat(usl), l = parseFloat(lsl);
        let ng = false;
        nums.forEach((n) => { if (!isNaN(u) && n > u) ng = true; if (!isNaN(l) && n < l) ng = true; });
        return ng ? 'NG' : 'OK';
      },

      /* ----- store FG movement ----- */
      setTxnDir(d) { this.txn = { ...this.txn, dir: d }; },
      setTxn(key) { return (e) => { this.txn = { ...this.txn, [key]: e.target.value }; }; },
      submitTxn() {
        const t = this.txn;
        const c = +t.carton || 0, pc = +((this.live.perCarton && this.live.perCarton[t.item]) || t.perCarton) || 0, l = +t.loose || 0;
        const overall = c * pc + l;
        if (!t.item.trim() || !overall) { this.flash('Enter item and a quantity'); return; }
        const n = new Date(); const p = (x) => String(x).padStart(2, '0');
        const brk = (c ? c + (pc ? ' ctn × ' + pc : ' ctn') : '') + (c && l ? ' + ' : '') + (l ? l + ' loose' : '');
        const entry = { time: p(n.getHours()) + ':' + p(n.getMinutes()), dir: t.dir, part: t.item.trim(), qty: overall.toLocaleString('en-US') + ' pcs', brk: brk || '—', ref: t.ref.trim() || '—', by: 'Manual entry' };
        this.storeMovements = [entry, ...this.storeMovements];
        this.txn = { dir: 'IN', item: '', carton: '', perCarton: '25', loose: '', ref: '' };
        this.flash('Stock ' + t.dir + ' recorded — ' + overall.toLocaleString('en-US') + ' pcs ' + t.item.trim());
      },

      /* ----- auth ----- */
      openLogin() { this.modal = 'login'; this.loginErr = ''; this.loginCreds = { id: '', pw: '' }; },
      doLogin() {
        const c = this.loginCreds;
        if (!c.id.trim() || !c.pw.trim()) { this.loginErr = 'Enter both User ID and password.'; return; }
        this.auth = true; this.modal = null; this.loginErr = '';
        this.flash('Signed in as ' + c.id.trim() + ' — restricted modules unlocked');
      },
      logout() {
        const view = this.view;
        this.auth = false; this.view = GATED.includes(view) ? 'hub' : view;
        this.flash('Signed out — restricted modules hidden');
      },
      setLoginId(e) { this.loginCreds = { ...this.loginCreds, id: e.target.value }; },
      setLoginPw(e) { this.loginCreds = { ...this.loginCreds, pw: e.target.value }; },
      goAuth(view) { if (this.auth) this.go(view); else this.openLogin(); },

      /* ----- schedule modals ----- */
      openCreate() {
        const d = new Date(); const p = (x) => String(x).padStart(2, '0');
        const dt = d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) + 'T15:00';
        this.form = { part: 'FX-2031 Hub Bracket', jo: 'JO-25-0412', process: 'CNC Milling', parameter: 'Bore Ø25.000 +0.021', cycle: '38s', machine: '', checker: 'Aiman', target: '50', time: dt };
        this.modal = 'create';
      },
      fmtDT(val) {
        if (!val) return '—';
        const d = new Date(val); if (isNaN(d.getTime())) return val;
        const mo = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
        const p = (x) => String(x).padStart(2, '0');
        return d.getDate() + ' ' + mo[d.getMonth()] + ' · ' + p(d.getHours()) + ':' + p(d.getMinutes());
      },
      openReassign(id) { this.modal = 'reassign'; this.modalId = id; },
      openKeyin(id) { this.modal = 'keyin'; this.modalId = id; this.keyin = { accept: '', rework: '', scrap: '' }; },
      closeModal() { this.modal = null; this.modalId = null; },
      doReassign(name) {
        const id = this.modalId;
        this.qSchedule = this.qSchedule.map((t) => (t.id === id ? { ...t, reassignedTo: name } : t));
        this.modal = null; this.modalId = null;
        this.flash('Task reassigned to ' + name + ' — original checker retained');
      },
      submitKeyin() {
        const id = this.modalId, k = this.keyin;
        const acc = +k.accept || 0, rw = +k.rework || 0, scr = +k.scrap || 0;
        const add = acc + rw + scr;
        if (!add) { this.flash('Enter at least one part count'); return; }
        const row = this.qSchedule.find((t) => t.id === id) || {};
        const isReins = row.inspectionType === 'Reinspection';
        const extra = [];
        let list = this.qSchedule.map((t) => {
          if (t.id !== id) return t;
          const checked = Math.min(t.target, t.checked + add);
          if (t.inspectionType === 'Reinspection') return { ...t, checked, status: 'Done' };
          if (rw > 0) {
            extra.push({ id: Date.now(), time: t.time, part: t.part, process: t.process, parameter: t.parameter, cycle: t.cycle, machine: t.machine, checker: t.reassignedTo || t.checker, reassignedTo: '', target: rw, checked: 0, status: 'Pending', inspectionType: 'Reinspection', parentId: t.id });
            return { ...t, checked, status: 'Waiting Rework' };
          }
          return { ...t, checked, status: checked >= t.target ? 'Done' : 'In Progress' };
        });
        if (isReins && row.parentId) list = list.map((t) => (t.id === row.parentId ? { ...t, status: 'Done' } : t));
        this.qSchedule = [...list, ...extra];
        this.modal = null; this.modalId = null;
        if (isReins) this.flash('Reinspection complete — rework cleared & task marked Done');
        else if (rw > 0) this.flash(add + ' inspected · ' + rw + ' to rework — reinspection task created');
        else this.flash(add + ' parts keyed in to inspection record');
      },
      addTask() {
        const f = this.form;
        if (!f.part || !f.jo || !f.checker) { this.flash('Part, JO and checker are required'); return; }
        this.qSchedule = [{ id: Date.now(), time: this.fmtDT(f.time), part: f.part, process: f.process || '—', parameter: f.parameter || '—', cycle: f.cycle || '—', machine: f.machine || '—', checker: f.checker, reassignedTo: '', target: +f.target || 0, checked: 0, status: 'Pending', inspectionType: 'Initial', parentId: null }, ...this.qSchedule];
        this.modal = null;
        this.flash('Inspection task created & scheduled');
      },
      setForm(key) { return (e) => { this.form = { ...this.form, [key]: e.target.value }; }; },
      setKeyin(key) { return (e) => { this.keyin = { ...this.keyin, [key]: e.target.value }; }; },

      /* ----- WI signature ----- */
      qaSign(id) { this.flash('QA signed ' + id + ' — Management notified via Teams'); this.wiQueue = this.wiQueue.map((w) => (w.id === id ? { ...w, status: 'Pending MGMT', qaBy: 'Ayyub' } : w)); },
      mgmtSign(id) { this.flash(id + ' fully approved — Teams channel notified'); this.wiQueue = this.wiQueue.map((w) => (w.id === id ? { ...w, status: 'Approved', mgmtBy: 'Mgr. Wong' } : w)); },
      flash(msg) { this.toast = msg; clearTimeout(this._tt); this._tt = setTimeout(() => { this.toast = ''; }, 3200); },

      /* ----- live machine tick + Supabase probe ----- */
      tick() {
        this.machines = this.machines.map((m) => {
          if (m.status !== 'run' || m.count >= m.target) return m;
          const rate = m.cycle ? (2500 / 1000) / m.cycle : 0;
          const inc = Math.max(1, Math.round(rate * (0.6 + Math.random() * 0.9)));
          return { ...m, count: Math.min(m.target, m.count + inc) };
        });
      },
      async tryLive() {
        try {
          const ctrl = new AbortController();
          const t = setTimeout(() => ctrl.abort(), 3500);
          const res = await fetch(SB_URL + '/Machine?select=Machinery_No&limit=1', { headers: SB_HEADERS, signal: ctrl.signal });
          clearTimeout(t);
          if (res.ok) { await res.json(); this.source = 'live'; }
        } catch (e) { /* keep demo data */ }
      },
      sbGet(path) {
        const ctrl = new AbortController();
        const t = setTimeout(() => ctrl.abort(), 6000);
        return fetch(SB_URL + '/' + path, { headers: SB_HEADERS, signal: ctrl.signal })
          .then((r) => { clearTimeout(t); return r.ok ? r.json() : Promise.reject(r.status); });
      },
      sbCount(table) {
        const ctrl = new AbortController();
        const t = setTimeout(() => ctrl.abort(), 6000);
        return fetch(SB_URL + '/' + table + '?select=id', { headers: { ...SB_HEADERS, Prefer: 'count=exact', Range: '0-0', 'Range-Unit': 'items' }, signal: ctrl.signal })
          .then((r) => { clearTimeout(t); const cr = r.headers.get('content-range'); return cr ? +cr.split('/')[1] : null; }).catch(() => null);
      },
      mapSchedStatus(raw, rem, qty) {
        const s = String(raw || '').toLowerCase();
        if (/rework|reinspect/.test(s)) return 'Waiting Rework';
        if (/progress|ongoing/.test(s)) return 'In Progress';
        if (/overdue/.test(s)) return 'Overdue';
        if (/done|complete|finish/.test(s)) return 'Done';
        if ((+rem || 0) <= 0 && (+qty || 0) > 0) return 'Done';
        return 'Pending';
      },
      /* Pull real rows from the factory Supabase and bind them into the views.
       * Each table is independent: any failure (offline / empty) silently keeps the
       * demo fallback for that screen so the design always renders. Read-only. */
      async loadLive() {
        const live = {};
        const tasks = [];

        // Inspection task scheduler  <-  InspectionSchedule
        tasks.push(this.sbGet('InspectionSchedule?order=created_at.desc&limit=40').then((rows) => {
          live.sched = rows.map((r) => {
            const repl = String(r.Replacement == null ? '' : r.Replacement).trim();
            const reassignedTo = (repl === '' || repl === '-' || repl === '—') ? '' : repl;
            return {
              id: r.id, time: this.fmtDT(r.StartDate), part: r.Part_Name || r.part_no || '—', process: '—',
              parameter: r.Parameter || r.param_details || '—', cycle: '—', machine: '—',
              checker: r.AssignTo || '—', reassignedTo,
              target: +r.quantity || 0, checked: Math.max(0, (+r.quantity || 0) - (+r.remaining_qty || 0)),
              status: this.mapSchedStatus(r.Status, r.remaining_qty, r.quantity), inspectionType: 'Initial', parentId: null,
            };
          });
        }).catch(() => {}));

        // Recent inspection records  <-  InspectionRecord
        tasks.push(this.sbGet('InspectionRecord?order=created_at.desc&limit=8').then((rows) => {
          live.records = rows.map((r) => {
            const ng = (+r.RejectQty || 0) + (+r.ScrapQty || 0) > 0;
            return { time: this.fmtTime(r.created_at), jo: r.JO_Number || '—', part: r.Part_Name || '—', process: r.process || '—', type: r.Inspection_Type || 'IPQC', result: ng ? 'NG' : 'OK', qty: (+r.AcceptQty || 0) + ' / ' + (+r.TotalCheck || 0) };
          });
        }).catch(() => {}));

        // Job orders  <-  JobOrder
        tasks.push(this.sbGet('JobOrder?order=created_at.desc&limit=20').then((rows) => {
          live.jos = rows.map((r) => { const m = statusColor(r.Status); return { jo: r.JO_Number, part: r.Part_Name, process: r.Process || '—', machine: '—', qty: r.Quantity, status: r.Status || 'Active', sc: m.c, sb: m.b }; });
        }).catch(() => {}));

        // Cycle time study  <-  cycle_time
        tasks.push(this.sbGet('cycle_time?order=created_at.desc&limit=12').then((rows) => {
          live.cycle = rows.map((r) => ({ part: r.part_name || r.part_no || '—', process: r.process || '—', machine: r.machine || '—', ct: r.cycle_time || (r.cycle_time_sec != null ? r.cycle_time_sec + 's' : '—'), std: '—' }));
        }).catch(() => {}));

        // Gauge register  <-  gauges
        tasks.push(this.sbGet('gauges?order=id.asc&limit=12').then((rows) => {
          live.gauges = rows.map((r) => { const m = statusColor(r.status); return { _gid: r.id, id: r.gauge_no || ('G-' + r.id), type: r.gauge_name || '—', range: r.for_process || '—', due: '—', status: r.status || 'OK', sc: m.c, sb: m.b }; });
        }).catch(() => {}));

        // FG store  <-  inventory  (also gives Qty/Ctn per item)
        const cleanLoc = (x) => {
          if (x == null || x === '') return '—';
          if (Array.isArray(x)) return x.join(', ') || '—';
          try { const a = JSON.parse(x); if (Array.isArray(a)) return a.join(', ') || '—'; } catch (e) { /* plain string */ }
          return String(x);
        };
        tasks.push(this.sbGet('inventory?order=updated_at.desc&limit=200').then((rows) => {
          const per = {};
          live.fg = rows.slice(0, 8).map((r) => { const m = statusColor(r.available_pcs > 0 ? 'OK' : 'low'); return { part: r.product_name || '—', loc: cleanLoc(r.item_location), qty: (+r.available_pcs || 0).toLocaleString('en-US'), status: r.available_pcs > 0 ? 'OK' : 'Low', sc: m.c, sb: m.b }; });
          rows.forEach((r) => { if (r.product_name && r.units_per_carton != null) per[r.product_name] = String(r.units_per_carton); });
          live.perCarton = per;
        }).catch(() => {}));

        // Inspection measurement master  <-  IPQC
        tasks.push(this.sbGet('IPQC?order=id.asc&limit=6').then((rows) => {
          live.insBase = rows.map((r, i) => ({ point: r.Point_DWG_Zone || ('P' + (i + 1)), zone: '', char: r.SC || r.Process || '—', spec: '—', tol: '—', usl: r.USL_NG != null ? String(r.USL_NG) : '—', lsl: r.LSL_OK != null ? String(r.LSL_OK) : '—', instr: r.Measuring_Instrument || '—' }));
        }).catch(() => {}));

        // Pass-rate KPI/donut for Quality Hub  <-  recent InspectionRecord sample
        tasks.push(this.sbGet('InspectionRecord?select=AcceptQty,RejectQty,ScrapQty,TotalCheck&order=created_at.desc&limit=300').then((rows) => {
          let tot = 0, ok = 0;
          rows.forEach((r) => { const total = +r.TotalCheck || ((+r.AcceptQty || 0) + (+r.RejectQty || 0) + (+r.ScrapQty || 0)); tot += total; ok += (+r.AcceptQty || 0); });
          if (tot > 0) live.passRate = +(ok / tot * 100).toFixed(1);
        }).catch(() => {}));

        // Raw material inventory  <-  RawMaterialStock
        tasks.push(this.sbGet('RawMaterialStock?order=created_at.desc&limit=12').then((rows) => {
          live.rawStock = rows.map((r) => ({
            _id: r.id,
            name: (String(r.material_type || '').trim()) || r.product_category || 'Material',
            grade: r.grade || '', size: r.size_dimensions || '',
            stock: (+r.qty_pcs || 0), unit: r.uom || 'pcs', reorder: '—', inn: 0, out: 0,
            status: 'OK', sc: '#16A34A', sb: '#E7F6EC', pct: '100%',
          }));
        }).catch(() => {}));

        // FG store movements log  <-  storeRecords
        tasks.push(this.sbGet('storeRecords?order=created_at.desc&limit=10').then((rows) => {
          live.storeMoves = rows.map((r) => {
            const out = /out/i.test(String(r.entry_type || r.remark_in_out || ''));
            return { time: this.fmtTime(r.out_date || r.created_at), dir: out ? 'OUT' : 'IN', part: r.part_name || '—', qty: (+r.quantity || 0).toLocaleString('en-US') + ' pcs', brk: r.carton_info || '—', ref: r.jo_number || '—', by: r.pic_name || r.customer_name || 'Store' };
          });
        }).catch(() => {}));

        // Preventive maintenance  <-  MachinesM + MachineCategoriesM + ChecklistItems + MaintenanceLogs
        tasks.push(Promise.all([
          this.sbGet('MachineCategoriesM?select=code,name&limit=50').catch(() => []),
          this.sbGet('MachinesM?select=machine_id,category_code,is_active&limit=200').catch(() => []),
          this.sbGet('ChecklistItems?select=category_code,task_description,priority_order&order=priority_order.asc&limit=600').catch(() => []),
          this.sbGet('MaintenanceLogs?select=machine_id,created_at&order=created_at.desc&limit=200').catch(() => []),
        ]).then(([cats, machines, checks, logs]) => {
          const catName = {}; (cats || []).forEach((c) => { catName[c.code] = c.name; });
          const lastLog = {}; (logs || []).forEach((l) => { if (!lastLog[l.machine_id]) lastLog[l.machine_id] = l; });
          const active = (machines || []).filter((m) => m.is_active !== false);
          live.maintRows = active.slice(0, 12).map((m) => {
            const lg = lastLog[m.machine_id]; const status = lg ? 'Done' : 'Due'; const sm = statusColor(status);
            return { machine: m.machine_id, cat: catName[m.category_code] || m.category_code || '—', next: lg ? this.fmtDate(lg.created_at) : '—', status, sc: sm.c, sb: sm.b };
          });
          const cat0 = active[0] && active[0].category_code;
          let cl = (checks || []).filter((c) => !cat0 || c.category_code === cat0).map((c) => c.task_description).filter(Boolean);
          if (!cl.length) cl = (checks || []).map((c) => c.task_description).filter(Boolean);
          live.maintChecklist = cl.slice(0, 8);
          live.maintActive = active.length; live.maintDone = (logs || []).length;
        }).catch(() => {}));

        // Gauge verification dates/status  <-  verification_records
        tasks.push(this.sbGet('verification_records?select=gauge_id,due_date,approval_status,verify_date&order=verify_date.desc&limit=400').then((rows) => {
          const byG = {}; rows.forEach((r) => { if (!byG[r.gauge_id]) byG[r.gauge_id] = r; });
          live.verByGauge = byG;
        }).catch(() => {}));

        // Raw material movements (In/Out today)  <-  RawMaterialMovement
        tasks.push(this.sbGet('RawMaterialMovement?select=material_id,move_type,qty_change,created_at&order=created_at.desc&limit=400').then((rows) => { live.rmMoves = rows; }).catch(() => {}));

        // BD Sales Order line items  <-  SalesOrder_Items
        tasks.push(this.sbGet('SalesOrder_Items?select=part_number,order_qty,stock_available,unit_price&order=id.desc&limit=10').then((rows) => {
          live.soItems = rows.map((r) => { const amt = (+r.order_qty || 0) * (+r.unit_price || 0); return { part: r.part_number || '—', qty: +r.order_qty || 0, stock: +r.stock_available || 0, price: (+r.unit_price || 0).toFixed(2), amt: amt.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 }) }; });
        }).catch(() => {}));

        // BD Packing List items (items is jsonb)  <-  packing_list_records
        tasks.push(this.sbGet('packing_list_records?select=items&order=created_at.desc&limit=1').then((rows) => {
          let items = rows && rows[0] && rows[0].items;
          if (typeof items === 'string') { try { items = JSON.parse(items); } catch (e) { items = null; } }
          if (Array.isArray(items) && items.length) {
            live.packItems = items.slice(0, 6).map((it) => ({ part: it.part || it.part_name || it.description || it.partNo || '—', qty: it.qty || it.quantity || '—', ctn: it.cartons || it.ctn || it.carton || '—', net: String(it.net || it.net_weight || it.nw || '—'), gross: String(it.gross || it.gross_weight || it.gw || '—') }));
          }
        }).catch(() => {}));

        // Report — QC by part  <-  aggregate recent InspectionRecord
        tasks.push(this.sbGet('InspectionRecord?select=Part_Name,TotalCheck,AcceptQty,RejectQty,ScrapQty&order=created_at.desc&limit=800').then((rows) => {
          const agg = {};
          rows.forEach((r) => { const p = r.Part_Name || '—'; const a = agg[p] || (agg[p] = { insp: 0, ok: 0, ng: 0 }); const total = +r.TotalCheck || ((+r.AcceptQty || 0) + (+r.RejectQty || 0) + (+r.ScrapQty || 0)); a.insp += total; a.ok += (+r.AcceptQty || 0); a.ng += (+r.RejectQty || 0) + (+r.ScrapQty || 0); });
          live.qcByPart = Object.keys(agg).map((p) => { const a = agg[p]; return { part: p, insp: a.insp, ok: a.ok, ng: a.ng, rate: a.insp ? (a.ok / a.insp * 100).toFixed(1) + '%' : '—' }; }).sort((x, y) => y.insp - x.insp).slice(0, 8);
        }).catch(() => {}));

        // Users  <-  EmployeeTable
        tasks.push(this.sbGet('EmployeeTable?order=id.asc&limit=60').then((rows) => {
          const roleC = (p) => { const s = String(p || '').toLowerCase(); if (/admin|manager|head|exec/.test(s)) return { c: '#3730A3', b: '#EEF0FF' }; if (/qa|quality|inspect/.test(s)) return { c: '#0369A1', b: '#EAF6FF' }; if (/eng/.test(s)) return { c: '#B45309', b: '#FCF1DE' }; if (/oper|tech|production/.test(s)) return { c: '#16A34A', b: '#E7F6EC' }; return { c: '#64748B', b: '#EEF0F4' }; };
          live.users = rows.map((r) => { const m = roleC(r.position); return { name: r.name || '—', emp: r.empID || '—', role: r.position || '—', status: 'Active', last: '—', rc: m.c, rb: m.b, stc: '#16A34A', stb: '#E7F6EC' }; });
        }).catch(() => {}));

        // Data-editor real row counts
        tasks.push(Promise.all(['Parts', 'JobOrder', 'Data_IPQC', 'Machine', 'InspectionRecord', 'gauges'].map((t) => this.sbCount(t))).then((cs) => { live.counts = cs; }).catch(() => {}));

        await Promise.allSettled(tasks);
        // enrich gauge register with latest verification due-date / status
        if (live.gauges && live.verByGauge) {
          live.gauges = live.gauges.map((g) => { const v = live.verByGauge[g._gid]; if (!v) return g; const sm = statusColor(v.approval_status); return { ...g, due: v.due_date ? this.fmtDate(v.due_date) : g.due, status: v.approval_status || g.status, sc: sm.c, sb: sm.b }; });
        }
        // enrich raw-material rows with today's In/Out from movements
        if (live.rawStock && live.rmMoves) {
          const today = new Date().toISOString().slice(0, 10);
          const agg = {};
          live.rmMoves.forEach((m) => { if (String(m.created_at || '').slice(0, 10) !== today) return; const a = agg[m.material_id] || (agg[m.material_id] = { in: 0, out: 0 }); const q = Math.abs(+m.qty_change || 0); if (/out|issue|consume/i.test(m.move_type) || (+m.qty_change < 0)) a.out += q; else a.in += q; });
          live.rawStock = live.rawStock.map((r) => { const a = agg[r._id]; return a ? { ...r, inn: a.in, out: a.out } : r; });
        }
        if (live.sched && live.sched.length) this.qSchedule = live.sched;
        if (live.storeMoves && live.storeMoves.length) this.storeMovements = live.storeMoves;
        if (live.insBase && live.insBase.length) this.readings = {};
        this.live = live;
      },
      fmtTime(ts) {
        if (!ts) return '—';
        const d = new Date(ts); if (isNaN(d.getTime())) return '—';
        const p = (x) => String(x).padStart(2, '0');
        return p(d.getHours()) + ':' + p(d.getMinutes());
      },
      fmtDate(ts) {
        if (!ts) return '—';
        const d = new Date(ts); if (isNaN(d.getTime())) return String(ts).slice(0, 10);
        const mo = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
        return d.getDate() + ' ' + mo[d.getMonth()] + ' ' + d.getFullYear();
      },

      /* ----- helpers ----- */
      go(view) { this.view = view; },
      nf(n) { return Number(n).toLocaleString('en-US'); },
      statusMeta(s) {
        if (s === 'run') return { label: 'RUNNING', color: '#16A34A', bg: '#E7F6EC', accent: '#16A34A', anim: 'livePulse 1.4s infinite', noteColor: '#16A34A' };
        if (s === 'idle') return { label: 'IDLE', color: '#D97706', bg: '#FCF1DE', accent: '#D97706', anim: 'none', noteColor: '#D97706' };
        return { label: 'DOWN', color: '#DC2626', bg: '#FCE8E8', accent: '#DC2626', anim: 'livePulse 1s infinite', noteColor: '#DC2626' };
      },
      bar(val, max) { return Math.round(val / max * 100) + '%'; },

      /* ----- view data producers ----- */
      qualityData() {
        const rmeta = { OK: { c: '#16A34A', b: '#E7F6EC' }, NG: { c: '#DC2626', b: '#FCE8E8' } };
        const demoRecent = [
          { time: '11:12', jo: 'JO-25-0418', part: 'FX-1180 Cover Plate', process: 'Deburr', type: 'IPQC', result: 'NG', qty: '2 / 50' },
          { time: '10:48', jo: 'JO-25-0412', part: 'FX-2031 Hub Bracket', process: 'CNC Milling', type: 'IPQC', result: 'OK', qty: '50 / 50' },
          { time: '10:20', jo: 'JO-25-0440', part: 'FX-7701 Housing', process: 'Injection', type: 'Buy-off', result: 'OK', qty: '8 / 8' },
          { time: '09:35', jo: 'JO-25-0430', part: 'FX-4501 Locating Pin', process: 'Turning', type: 'IPQC', result: 'OK', qty: '32 / 32' },
          { time: '09:02', jo: 'JO-25-0419', part: 'FX-1180 Cover Plate', process: 'Deburr', type: 'Buy-off', result: 'NG', qty: '1 / 12' },
          { time: '08:30', jo: 'JO-25-0405', part: 'FX-2099 Flange', process: 'Grinding', type: 'IPQC', result: 'OK', qty: '24 / 24' },
        ];
        const recentSrc = (this.live.records && this.live.records.length) ? this.live.records : demoRecent;
        const recent = recentSrc.map((r) => ({ ...r, rc: (rmeta[r.result] || rmeta.OK).c, rb: (rmeta[r.result] || rmeta.OK).b }));
        const ngRaw = [['Deburr', 8], ['Injection', 6], ['CNC Milling', 5], ['Turning', 3], ['Assembly', 2], ['Grinding', 1]];
        const ngByProcess = ngRaw.map(([name, c]) => ({ name, count: c, h: this.bar(c, 8) }));
        const trendRaw = [96.4, 97.1, 95.8, 98.2, 97.6, 98.4, 97.5];
        const days = ['Wed', 'Thu', 'Fri', 'Sat', 'Sun', 'Mon', 'Tue'];
        const passTrend = trendRaw.map((vv, i) => ({ day: days[i], val: vv.toFixed(1), h: Math.round((vv - 94) / 6 * 100) + '%' }));
        const qualityKpis = [
          { label: 'Inspections Today', value: '48', sub: '6 scheduled remaining', color: '#16161D', dot: '#4F46E5' },
          { label: 'Pass Rate', value: '97.5%', sub: '▲ 0.6% vs yesterday', color: '#16A34A', dot: '#16A34A' },
          { label: 'Open NG', value: '3', sub: '2 awaiting disposition', color: '#DC2626', dot: '#DC2626' },
          { label: 'Schedule Adherence', value: '83%', sub: '1 inspection overdue', color: '#D97706', dot: '#D97706' },
        ];
        const pr = (this.live.passRate != null) ? this.live.passRate : 97.5;
        if (this.live.passRate != null) { qualityKpis[1].value = pr + '%'; }
        return { qRecent: recent, qNg: ngByProcess, qTrend: passTrend, qualityKpis, qPassDeg: (pr * 3.6) + 'deg', qPassRate: String(pr) };
      },
      reportData(tab) {
        const tb = (id) => (tab === id ? 'background:#fff;color:#3730A3;box-shadow:0 1px 4px rgba(20,18,58,.12)' : 'background:transparent;color:#6B7280');
        const set = (id) => () => { this.reportTab = id; };
        const qcByPart = [
          { part: 'FX-2031 Hub Bracket', insp: 128, ok: 124, ng: 4, rate: '96.9%' },
          { part: 'FX-1180 Cover Plate', insp: 96, ok: 88, ng: 8, rate: '91.7%' },
          { part: 'FX-4501 Locating Pin', insp: 212, ok: 210, ng: 2, rate: '99.1%' },
          { part: 'FX-7701 Housing', insp: 74, ok: 73, ng: 1, rate: '98.6%' },
          { part: 'FX-3310 Shaft Collar', insp: 58, ok: 57, ng: 1, rate: '98.3%' },
        ];
        const stopsRaw = [['MILL-02', 142, 3, 'Tool break'], ['EDM-01', 96, 2, 'Door interlock'], ['INJ-02', 64, 4, 'Material wait'], ['CNC-03', 38, 1, 'Setup overrun'], ['GRIND-01', 22, 1, 'Wheel dress']];
        const stops = stopsRaw.map(([m, mins, c, r]) => ({ machine: m, mins, count: c, reason: r, h: this.bar(mins, 142) }));
        const jos = [
          { jo: 'JO-25-0412', part: 'FX-2031 Hub Bracket', qty: 1200, done: 842, pct: '70%', status: 'Active', sc: '#16A34A', sb: '#E7F6EC' },
          { jo: 'JO-25-0418', part: 'FX-1180 Cover Plate', qty: 1500, done: 1192, pct: '79%', status: 'Active', sc: '#16A34A', sb: '#E7F6EC' },
          { jo: 'JO-25-0421', part: 'FX-3310 Shaft Collar', qty: 3000, done: 2308, pct: '77%', status: 'Active', sc: '#16A34A', sb: '#E7F6EC' },
          { jo: 'JO-25-0440', part: 'FX-7701 Housing', qty: 10000, done: 8810, pct: '88%', status: 'Active', sc: '#16A34A', sb: '#E7F6EC' },
          { jo: 'JO-25-0405', part: 'FX-2099 Flange', qty: 800, done: 800, pct: '100%', status: 'Closed', sc: '#64748B', sb: '#EEF0F4' },
        ];
        const oos = [
          { char: 'Bore Ø25.000 +0.021', part: 'FX-2031 Hub Bracket', count: 4, dev: '+0.024', sev: 'Major' },
          { char: 'Flatness 0.05 max', part: 'FX-1180 Cover Plate', count: 6, dev: '0.071', sev: 'Major' },
          { char: 'Length 85.00 ±0.10', part: 'FX-2031 Hub Bracket', count: 2, dev: '-0.118', sev: 'Minor' },
          { char: 'Surface Ra 1.6 max', part: 'FX-2099 Flange', count: 1, dev: '1.82', sev: 'Minor' },
        ].map((r) => ({ ...r, sevC: r.sev === 'Major' ? '#DC2626' : '#D97706', sevB: r.sev === 'Major' ? '#FCE8E8' : '#FCF1DE' }));
        return { rtQc: tb('qc'), rtStop: tb('stop'), rtJo: tb('jo'), rtOos: tb('oos'),
          setRtQc: set('qc'), setRtStop: set('stop'), setRtJo: set('jo'), setRtOos: set('oos'),
          qcByPart: (this.live.qcByPart && this.live.qcByPart.length) ? this.live.qcByPart : qcByPart, stops, jos, oos,
          isRtQc: tab === 'qc', isRtStop: tab === 'stop', isRtJo: tab === 'jo', isRtOos: tab === 'oos' };
      },
      inspectData() {
        const sizes = { ipqc: 3, buyoff: 5, iqc: 5, oqc: 5 };
        const labels = { ipqc: 'IPQC', buyoff: 'Buy-off', iqc: 'IQC', oqc: 'OQC' };
        const type = this.inspType || 'ipqc';
        const N = sizes[type];
        let base = [
          { point: 'P1', zone: 'A2', char: 'Overall Length', spec: '85.00', tol: '±0.10', usl: '85.10', lsl: '84.90', instr: 'Caliper · VC-014' },
          { point: 'P2', zone: 'B3', char: 'Bore Diameter', spec: '25.000', tol: '+0.021/0', usl: '25.021', lsl: '25.000', instr: 'Bore Gauge · BG-003' },
          { point: 'P3', zone: 'C1', char: 'Hole Pitch', spec: '42.50', tol: '±0.05', usl: '42.55', lsl: '42.45', instr: 'Height Gauge · HG-011' },
          { point: 'P4', zone: 'B2', char: 'Flatness', spec: '0.05', tol: 'max', usl: '0.05', lsl: '—', instr: 'Dial Gauge · DG-005' },
          { point: 'P5', zone: 'D4', char: 'Surface Ra', spec: '1.6', tol: 'max', usl: '1.6', lsl: '—', instr: 'Ra Tester · SR-02' },
        ];
        if (this.live.insBase && this.live.insBase.length) base = this.live.insBase;
        const readings = this.readings || {};
        const rcol = (res) => (res === 'OK' ? { c: '#16A34A', b: '#E7F6EC' } : res === 'NG' ? { c: '#DC2626', b: '#FCE8E8' } : { c: '#64748B', b: '#EEF0F4' });
        const chars = base.map((r, idx) => {
          const arr = readings[idx] || [];
          const cells = Array.from({ length: N }, (_, si) => ({ v: arr[si] || '', on: (e) => this.setReading(idx, si, e.target.value) }));
          const result = this.calcResult(cells.map((c) => c.v), r.lsl, r.usl);
          const m = rcol(result);
          return { ...r, cells, result, rc: m.c, rb: m.b };
        });
        const ngCount = chars.filter((c) => c.result === 'NG').length;
        const pending = chars.some((c) => c.result === 'Pending');
        const overallResult = ngCount > 0 ? 'NG · ' + ngCount + ' point(s) out of spec' : pending ? 'In progress — key in readings' : 'OK · all points within spec';
        const oc = ngCount > 0 ? { c: '#DC2626', b: '#FCE8E8' } : pending ? { c: '#6B7280', b: '#F4F5F8' } : { c: '#16A34A', b: '#E7F6EC' };
        const sampleCols = Array.from({ length: N }, (_, i) => ({ name: 'S' + (i + 1) }));
        const tb = (id) => (type === id ? 'background:linear-gradient(135deg,#4F46E5,#3730A3);color:#fff' : 'background:transparent;color:#6B7280');
        const z = this.drawZoom || 1;
        return {
          insChars: chars, sampleCols, sampleSize: N, inspTypeLabel: labels[type],
          overallResult, overallColor: oc.c, overallBg: oc.b, clearReadings: () => this.clearReadings(),
          tabIpqc: tb('ipqc'), tabBuyoff: tb('buyoff'), tabIqc: tb('iqc'), tabOqc: tb('oqc'),
          setIpqc: () => { this.inspType = 'ipqc'; }, setBuyoff: () => { this.inspType = 'buyoff'; },
          setIqc: () => { this.inspType = 'iqc'; }, setOqc: () => { this.inspType = 'oqc'; },
          drawZoomStyle: 'transform:scale(' + z + ');transform-origin:top left', drawZoomPct: Math.round(z * 100) + '%',
          zoomIn: () => { this.drawZoom = Math.min(3, (this.drawZoom || 1) + 0.25); },
          zoomOut: () => { this.drawZoom = Math.max(1, (this.drawZoom || 1) - 0.25); },
          zoomReset: () => { this.drawZoom = 1; },
        };
      },
      storeData(tab) {
        const tb = (id) => (tab === id ? 'background:#fff;color:#3730A3;box-shadow:0 1px 4px rgba(20,18,58,.12)' : 'background:transparent;color:#6B7280');
        const mt = (s) => (s === 'OK' ? { c: '#16A34A', b: '#E7F6EC' } : s === 'Low' ? { c: '#D97706', b: '#FCF1DE' } : { c: '#DC2626', b: '#FCE8E8' });
        const raw = [
          { name: 'SUS304 Bar Ø25', stock: 1240, unit: 'kg', reorder: 500, inn: 200, out: 340, status: 'OK' },
          { name: 'AL6061 Plate 10mm', stock: 86, unit: 'sheets', reorder: 40, inn: 0, out: 14, status: 'OK' },
          { name: 'Brass C3604 Ø12', stock: 410, unit: 'kg', reorder: 300, inn: 0, out: 120, status: 'Low' },
          { name: 'POM Resin Black', stock: 120, unit: 'kg', reorder: 200, inn: 0, out: 80, status: 'Critical' },
          { name: 'SKD11 Block', stock: 14, unit: 'pcs', reorder: 6, inn: 4, out: 2, status: 'OK' },
          { name: 'Mild Steel Round Ø30', stock: 680, unit: 'kg', reorder: 400, inn: 300, out: 90, status: 'OK' },
        ].map((r) => ({ ...r, sc: mt(r.status).c, sb: mt(r.status).b, pct: this.bar(Math.min(r.stock, r.reorder * 2), r.reorder * 2) }));
        const fg = [
          { part: 'FX-2031 Hub Bracket', qty: 3420, loc: 'A-12', inn: 842, out: 600, status: 'OK' },
          { part: 'FX-4501 Locating Pin', qty: 18200, loc: 'B-04', inn: 5124, out: 4800, status: 'OK' },
          { part: 'FX-7701 Housing', qty: 9650, loc: 'C-21', inn: 880, out: 1200, status: 'OK' },
          { part: 'FX-1180 Cover Plate', qty: 240, loc: 'A-08', inn: 0, out: 1200, status: 'Low' },
          { part: 'FX-2099 Flange', qty: 1540, loc: 'B-15', inn: 540, out: 300, status: 'OK' },
        ].map((r) => ({ ...r, sc: mt(r.status).c, sb: mt(r.status).b }));
        const moves = this.storeMovements.map((r) => ({ ...r, dc: r.dir === 'IN' ? '#16A34A' : '#DC2626', db: r.dir === 'IN' ? '#E7F6EC' : '#FCE8E8', qtyLine: r.brk && r.brk !== '—' ? r.qty + ' · ' + r.brk : r.qty }));
        const txn = this.txn;
        const resolvedPer = (this.live.perCarton && this.live.perCarton[txn.item]) || txn.perCarton;
        const storeKpis = [
          { label: 'Raw Material SKUs', value: '42', sub: '2 below reorder', color: '#D97706' },
          { label: 'FG in Store', value: '33.0k', sub: 'pcs across 5 parts', color: '#16161D' },
          { label: 'Received Today', value: '7,332', sub: 'pcs · 4 movements', color: '#16A34A' },
          { label: 'Delivered Today', value: '3,300', sub: 'pcs · 2 DO', color: '#4F46E5' },
        ];
        return { stMat: tb('material'), stFg: tb('fg'), setStMat: () => { this.storeTab = 'material'; }, setStFg: () => { this.storeTab = 'fg'; },
          isStMat: tab === 'material', isStFg: tab === 'fg', rawMaterials: (this.live.rawStock && this.live.rawStock.length) ? this.live.rawStock : raw, fgItems: (this.live.fg && this.live.fg.length) ? this.live.fg : fg, storeMoves: moves, storeKpis,
          txnDir: txn.dir, txnItem: txn.item, txnCarton: txn.carton, txnPerCarton: resolvedPer, txnLoose: txn.loose, txnRef: txn.ref,
          txnOverall: (((+txn.carton || 0) * (+resolvedPer || 0)) + (+txn.loose || 0)).toLocaleString('en-US'),
          txnInStyle: txn.dir === 'IN' ? 'background:#16A34A;color:#fff' : 'background:transparent;color:#6B7280',
          txnOutStyle: txn.dir === 'OUT' ? 'background:#DC2626;color:#fff' : 'background:transparent;color:#6B7280',
          setTxnIn: () => this.setTxnDir('IN'), setTxnOut: () => this.setTxnDir('OUT'),
          fTxnItem: this.setTxn('item'), fCarton: this.setTxn('carton'), fLoose: this.setTxn('loose'), fTxnRef: this.setTxn('ref'),
          submitTxn: () => this.submitTxn() };
      },
      adminData(tab) {
        const tb = (id) => (tab === id ? 'background:linear-gradient(135deg,#4F46E5,#3730A3);color:#fff' : 'background:#fff;color:#475569;border:1px solid #E8E9EF');
        const set = (id) => () => { this.adminTab = id; };
        const wi = [
          { name: 'FX-2031 Hub Bracket', rev: 'Rev C', date: '2025-06-10', status: 'Active', sc: '#16A34A', sb: '#E7F6EC' },
          { name: 'FX-1180 Cover Plate', rev: 'Rev B', date: '2025-05-28', status: 'Active', sc: '#16A34A', sb: '#E7F6EC' },
          { name: 'FX-7701 Housing', rev: 'Rev A', date: '2025-06-14', status: 'Draft', sc: '#D97706', sb: '#FCF1DE' },
          { name: 'FX-4501 Locating Pin', rev: 'Rev D', date: '2025-04-02', status: 'Active', sc: '#16A34A', sb: '#E7F6EC' },
          { name: 'FX-2099 Flange', rev: 'Rev B', date: '2025-03-19', status: 'Obsolete', sc: '#64748B', sb: '#EEF0F4' },
        ];
        const jos = [
          { jo: 'JO-25-0412', part: 'FX-2031 Hub Bracket', process: 'CNC Milling', machine: 'CNC-01', qty: 1200, status: 'Active', sc: '#16A34A', sb: '#E7F6EC' },
          { jo: 'JO-25-0418', part: 'FX-1180 Cover Plate', process: 'Deburr', machine: 'MILL-02', qty: 1500, status: 'Active', sc: '#16A34A', sb: '#E7F6EC' },
          { jo: 'JO-25-0451', part: 'FX-7701 Housing', process: 'Injection', machine: 'INJ-01', qty: 5000, status: 'Pending', sc: '#D97706', sb: '#FCF1DE' },
        ];
        const tables = [
          { name: 'Parts', rows: '128 rows', icon: 'P' }, { name: 'JobOrder', rows: '342 rows', icon: 'J' },
          { name: 'Data_IPQC', rows: '12,840 rows', icon: 'D' }, { name: 'Machine', rows: '12 rows', icon: 'M' },
          { name: 'InspectionRecord', rows: '4,210 rows', icon: 'I' }, { name: 'gauges', rows: '56 rows', icon: 'G' },
        ];
        const counts = this.live.counts;
        const tablesOut = counts ? tables.map((t, i) => ({ ...t, rows: counts[i] != null ? counts[i].toLocaleString('en-US') + ' rows' : t.rows })) : tables;
        const josOut = (this.live.jos && this.live.jos.length) ? this.live.jos : jos;
        return { atFg: tb('filegen'), atAp: tb('addpart'), atJo: tb('updatejo'), atDe: tb('dataeditor'),
          setAtFg: set('filegen'), setAtAp: set('addpart'), setAtJo: set('updatejo'), setAtDe: set('dataeditor'),
          isAtFg: tab === 'filegen', isAtAp: tab === 'addpart', isAtJo: tab === 'updatejo', isAtDe: tab === 'dataeditor',
          wiFiles: wi, adminJos: josOut, dataTables: tablesOut };
      },
      dmsData(sel) {
        const tmeta = { ok: { l: 'OK', c: '#16A34A', b: '#E7F6EC' }, warning: { l: 'Monitor', c: '#D97706', b: '#FCF1DE' }, critical: { l: 'Critical', c: '#DC2626', b: '#FCE8E8' } };
        const parts = [
          { name: 'FX-2031 Hub Bracket', rev: 'Rev C', docs: 14, tool: 'critical' },
          { name: 'FX-1180 Cover Plate', rev: 'Rev B', docs: 11, tool: 'ok' },
          { name: 'FX-7701 Housing', rev: 'Rev A', docs: 9, tool: 'warning' },
          { name: 'FX-4501 Locating Pin', rev: 'Rev D', docs: 12, tool: 'ok' },
          { name: 'FX-2099 Flange', rev: 'Rev B', docs: 8, tool: 'ok' },
          { name: 'FX-3310 Shaft Collar', rev: 'Rev A', docs: 7, tool: 'ok' },
        ].map((p, i) => ({ ...p, tl: tmeta[p.tool].l, tc: tmeta[p.tool].c, tb: tmeta[p.tool].b,
          selStyle: i === sel ? 'background:#EEF0FF;border-color:#C7CBF5' : 'background:#fff;border-color:#EEF0F4',
          onSel: () => { this.dmsPart = i; } }));
        const active = parts[sel] || parts[0];
        const fmeta = { pdf: { c: '#DC2626', b: '#FCE8E8' }, xlsx: { c: '#16A34A', b: '#E7F6EC' }, nc: { c: '#3730A3', b: '#EEF0FF' }, doc: { c: '#0369A1', b: '#EAF6FF' } };
        const docFile = (name, type, size, group) => ({ name, ext: type.toUpperCase(), size, group, fc: fmeta[type].c, fb: fmeta[type].b });
        const docs = [
          docFile(active.name + '_WI_master.pdf', 'pdf', '2.4 MB', 'Primary Document'),
          docFile(active.name + '_inspection.xlsx', 'xlsx', '318 KB', 'Primary Document'),
          docFile(active.name + '_drawing_' + active.rev + '.pdf', 'pdf', '1.1 MB', 'Primary Document'),
          docFile('OP10 / CNC-01 / op10_rough.nc', 'nc', '64 KB', 'Program Files'),
          docFile('OP20 / MILL-01 / op20_finish.nc', 'nc', '58 KB', 'Program Files'),
          docFile('Control_Plan.docx', 'doc', '142 KB', 'Other Documents'),
          docFile('FMEA.xlsx', 'xlsx', '96 KB', 'Other Documents'),
          docFile('Setup_Sheet.pdf', 'pdf', '220 KB', 'Other Documents'),
        ];
        const groups = ['Primary Document', 'Program Files', 'Other Documents'].map((g) => ({ name: g, files: docs.filter((d) => d.group === g) }));
        const tooling = [
          { name: 'Carbide End Mill Ø10', life: '18%', status: 'critical' },
          { name: 'Boring Bar 25mm', life: '62%', status: 'ok' },
          { name: 'Face Mill 63mm', life: '41%', status: 'warning' },
          { name: 'Drill HSS Ø8.5', life: '88%', status: 'ok' },
        ].map((t) => ({ ...t, tc: tmeta[t.status].c, tb: tmeta[t.status].b, tl: tmeta[t.status].l }));
        const dmsKpis = [
          { label: 'Total Documents', value: '1,284', sub: 'across 128 parts' },
          { label: 'Active Revisions', value: '128', sub: '14 obsolete archived' },
          { label: 'Tooling Alerts', value: '3', sub: '1 critical · 2 monitor' },
          { label: 'CNC Programs', value: '642', sub: 'linked to job orders' },
        ];
        return { dmsParts: parts, dmsActive: active, dmsGroups: groups, dmsTooling: tooling, dmsKpis };
      },
      notifyData() {
        const smeta = { 'Pending QA': { c: '#D97706', b: '#FCF1DE' }, 'Pending MGMT': { c: '#3730A3', b: '#EEF0FF' }, Approved: { c: '#16A34A', b: '#E7F6EC' } };
        const q = this.wiQueue.map((w) => ({
          ...w, sc: smeta[w.status].c, sb: smeta[w.status].b,
          isPendingQa: w.status === 'Pending QA', isPendingMgmt: w.status === 'Pending MGMT', isApproved: w.status === 'Approved',
          step1Style: w.status !== 'Pending QA' ? 'background:#16A34A;color:#fff' : 'background:#EEF0F4;color:#9CA0AD',
          step2Style: w.status === 'Approved' ? 'background:#16A34A;color:#fff' : 'background:#EEF0F4;color:#9CA0AD',
          onQa: () => this.qaSign(w.id), onMgmt: () => this.mgmtSign(w.id),
          qaLabel: w.qaBy ? 'QA: ' + w.qaBy : 'QA: awaiting', mgmtLabel: w.mgmtBy ? 'MGMT: ' + w.mgmtBy : 'MGMT: awaiting',
        }));
        const counts = {
          qa: this.wiQueue.filter((w) => w.status === 'Pending QA').length,
          mgmt: this.wiQueue.filter((w) => w.status === 'Pending MGMT').length,
          done: this.wiQueue.filter((w) => w.status === 'Approved').length,
        };
        const composeParts = [
          { name: 'FX-2031 Hub Bracket · Rev C', on: true },
          { name: 'FX-7701 Housing · Rev A', on: true },
          { name: 'FX-3310 Shaft Collar · Rev A', on: false },
        ];
        const msg = 'Please approve the following WI(s) immediately.\n\nParts: FX-2031 Hub Bracket (Rev C), FX-7701 Housing (Rev A)\n\nAttention Required From: QA Team @Ayyub\n\nIssued by: Eng. Tan';
        return { wiQ: q, wiCounts: counts, composeParts, wiMsg: msg };
      },
      gaugeData() {
        const gm = { OK: { c: '#16A34A', b: '#E7F6EC' }, 'Due Soon': { c: '#D97706', b: '#FCF1DE' }, 'Out of Tol': { c: '#DC2626', b: '#FCE8E8' } };
        const gauges = [
          { id: 'VC-014', type: 'Vernier Caliper', range: '0–150 mm', due: '2025-08-12', status: 'OK' },
          { id: 'MM-007', type: 'Micrometer', range: '0–25 mm', due: '2025-06-30', status: 'Due Soon' },
          { id: 'BG-003', type: 'Bore Gauge', range: '18–35 mm', due: '2025-07-20', status: 'OK' },
          { id: 'HG-011', type: 'Height Gauge', range: '0–300 mm', due: '2025-06-18', status: 'Out of Tol' },
          { id: 'PG-022', type: 'Pin Gauge Set', range: '1–10 mm', due: '2025-11-28', status: 'OK' },
          { id: 'DG-005', type: 'Dial Gauge', range: '0–10 mm', due: '2025-06-25', status: 'Due Soon' },
        ].map((g) => ({ ...g, sc: gm[g.status].c, sb: gm[g.status].b }));
        const kpis = [
          { label: 'Registered Gauges', value: '56', sub: 'across 4 categories', color: '#16161D' },
          { label: 'Calibration Due ≤30d', value: '2', sub: 'schedule recall', color: '#D97706' },
          { label: 'Out of Tolerance', value: '1', sub: 'quarantine HG-011', color: '#DC2626' },
          { label: 'Verified Today', value: '4', sub: 'by QA · Ayyub', color: '#16A34A' },
        ];
        return { gaugeRows: (this.live.gauges && this.live.gauges.length) ? this.live.gauges : gauges, gaugeKpis: kpis };
      },
      cycleData() {
        const rows = [
          { part: 'FX-2031 Hub Bracket', process: 'CNC Milling', machine: 'CNC-01', ct: '00:38', std: '±2.1s' },
          { part: 'FX-1180 Cover Plate', process: 'Deburr', machine: 'MILL-02', ct: '00:27', std: '±1.4s' },
          { part: 'FX-4501 Locating Pin', process: 'Turning', machine: 'TURN-01', ct: '00:09', std: '±0.6s' },
          { part: 'FX-7701 Housing', process: 'Injection', machine: 'INJ-01', ct: '00:22', std: '±1.0s' },
          { part: 'FX-2099 Flange', process: 'Grinding', machine: 'GRIND-01', ct: '00:52', std: '±3.2s' },
        ];
        return { cycleRows: (this.live.cycle && this.live.cycle.length) ? this.live.cycle : rows };
      },
      maintData() {
        const sm = { Done: { c: '#16A34A', b: '#E7F6EC' }, Due: { c: '#D97706', b: '#FCF1DE' }, Overdue: { c: '#DC2626', b: '#FCE8E8' } };
        const rows = [
          { machine: 'CNC-01', cat: 'CNC Machining', next: '2025-06-30', status: 'Due' },
          { machine: 'INJ-01', cat: 'Injection', next: '2025-07-02', status: 'Done' },
          { machine: 'MILL-02', cat: 'CNC Machining', next: '2025-05-28', status: 'Overdue' },
          { machine: 'TURN-01', cat: 'Turning', next: '2025-07-10', status: 'Done' },
          { machine: 'EDM-01', cat: 'EDM', next: '2025-06-15', status: 'Overdue' },
        ].map((r) => ({ ...r, sc: sm[r.status].c, sb: sm[r.status].b }));
        const checklist = ['Lubrication system check', 'Coolant level & concentration', 'Way cover & guard inspection', 'Spindle run-out test', 'Backlash compensation check', 'Air pressure & filter'];
        const kpis = [
          { label: 'Machines Tracked', value: '12', color: '#16161D' },
          { label: 'PM Due This Week', value: '1', color: '#D97706' },
          { label: 'Overdue', value: '2', color: '#DC2626' },
          { label: 'Completed (MTD)', value: '18', color: '#16A34A' },
        ];
        const L = this.live;
        if (L.maintActive != null) { kpis[0].value = String(L.maintActive); kpis[3].value = String(L.maintDone || 0); }
        return {
          maintRows: (L.maintRows && L.maintRows.length) ? L.maintRows : rows,
          maintChecklist: (L.maintChecklist && L.maintChecklist.length) ? L.maintChecklist : checklist,
          maintKpis: kpis,
        };
      },
      bdData(tab) {
        const tb = (id) => (tab === id ? 'background:#fff;color:#3730A3;box-shadow:0 1px 4px rgba(20,18,58,.12)' : 'background:transparent;color:#6B7280');
        const packItems = [
          { part: 'FX-2031 Hub Bracket', qty: 1200, ctn: 24, net: '480 kg', gross: '504 kg' },
          { part: 'FX-7701 Housing', qty: 800, ctn: 16, net: '320 kg', gross: '338 kg' },
        ];
        const shipChecks = [
          { item: 'Commercial invoice attached', on: true },
          { item: 'Packing list verified vs PO', on: true },
          { item: 'Carton labels & shipping marks', on: true },
          { item: 'Pallet wrapped & strapped', on: false },
          { item: 'Container seal number recorded', on: false },
          { item: 'COA / inspection report enclosed', on: true },
        ];
        const soItems = [
          { part: 'FX-2031 Hub Bracket', qty: 1200, stock: 3420, price: '2.85', amt: '3,420.00' },
          { part: 'FX-7701 Housing', qty: 800, stock: 9650, price: '4.10', amt: '3,280.00' },
        ];
        return { bdPacking: tb('packing'), bdShip: tb('shipment'), bdSo: tb('so'),
          setBdPacking: () => { this.bdTab = 'packing'; }, setBdShip: () => { this.bdTab = 'shipment'; }, setBdSo: () => { this.bdTab = 'so'; },
          isBdPacking: tab === 'packing', isBdShip: tab === 'shipment', isBdSo: tab === 'so',
          packItems: (this.live.packItems && this.live.packItems.length) ? this.live.packItems : packItems,
          shipChecks,
          soItems: (this.live.soItems && this.live.soItems.length) ? this.live.soItems : soItems };
      },
      docCtrlData(tab) {
        const tb = (id) => (tab === id ? 'background:#fff;color:#3730A3;box-shadow:0 1px 4px rgba(20,18,58,.12)' : 'background:transparent;color:#6B7280');
        const revHistory = [
          { part: 'FX-2031 Hub Bracket', from: 'Rev B', to: 'Rev C', date: '2025-06-10', by: 'Eng. Tan', status: 'Active' },
          { part: 'FX-1180 Cover Plate', from: 'Rev A', to: 'Rev B', date: '2025-05-28', by: 'Eng. Lim', status: 'Active' },
          { part: 'FX-4501 Locating Pin', from: 'Rev C', to: 'Rev D', date: '2025-04-02', by: 'Eng. Raj', status: 'Active' },
        ];
        const obsoleteParts = [
          { part: 'FX-2099 Flange', rev: 'Rev B', files: 8, jo: 'No active JO' },
          { part: 'FX-9001 Mold Insert', rev: 'Rev A', files: 5, jo: 'No active JO' },
        ];
        return { dcRev: tb('revision'), dcRem: tb('remove'),
          setDcRev: () => { this.docTab = 'revision'; }, setDcRem: () => { this.docTab = 'remove'; },
          isDcRev: tab === 'revision', isDcRem: tab === 'remove', revHistory, obsoleteParts };
      },
      usersData() {
        const rm = { ADMIN: { c: '#3730A3', b: '#EEF0FF' }, QA: { c: '#0369A1', b: '#EAF6FF' }, ENGINEER: { c: '#B45309', b: '#FCF1DE' }, OPERATOR: { c: '#16A34A', b: '#E7F6EC' } };
        const users = [
          { name: 'Ayyub Rahman', emp: 'EMP-1021', role: 'QA', status: 'Active', last: 'Today 11:02' },
          { name: 'Tan Wei Ming', emp: 'EMP-0884', role: 'ENGINEER', status: 'Active', last: 'Today 09:40' },
          { name: 'Mgr. Wong', emp: 'EMP-0501', role: 'ADMIN', status: 'Active', last: 'Today 08:15' },
          { name: 'Aiman Hakim', emp: 'EMP-1133', role: 'OPERATOR', status: 'Active', last: 'Today 10:55' },
          { name: 'Siti Nurhaliza', emp: 'EMP-1140', role: 'OPERATOR', status: 'Active', last: 'Yesterday' },
          { name: 'Raj Kumar', emp: 'EMP-0902', role: 'ENGINEER', status: 'Inactive', last: '12 Jun' },
        ].map((u) => ({ ...u, rc: rm[u.role].c, rb: rm[u.role].b, stc: u.status === 'Active' ? '#16A34A' : '#9A9AAB', stb: u.status === 'Active' ? '#E7F6EC' : '#EEF0F4' }));
        const kpis = [
          { label: 'Total Users', value: '24', color: '#16161D' },
          { label: 'Admins', value: '3', color: '#3730A3' },
          { label: 'QA / Engineers', value: '9', color: '#0369A1' },
          { label: 'Operators', value: '12', color: '#16A34A' },
        ];
        const usersOut = (this.live.users && this.live.users.length) ? this.live.users : users;
        if (this.live.users && this.live.users.length) { kpis[0].value = String(this.live.users.length); }
        return { userRows: usersOut, userKpis: kpis };
      },
      scheduleVals() {
        const smeta = {
          Done: { c: '#16A34A', b: '#E7F6EC' }, 'In Progress': { c: '#3730A3', b: '#EEF0FF' },
          Pending: { c: '#64748B', b: '#EEF0F4' }, Overdue: { c: '#DC2626', b: '#FCE8E8' },
          'Waiting Rework': { c: '#D97706', b: '#FCF1DE' },
        };
        const rows = this.qSchedule.filter((t) => t.status !== 'Done').map((t) => {
          const sm = smeta[t.status] || smeta.Pending;
          const reins = t.inspectionType === 'Reinspection';
          return {
            id: t.id, time: t.time, part: t.part, process: t.process, machine: t.machine,
            parameter: t.parameter || '—', cycle: t.cycle || '—',
            inspectionType: t.inspectionType || 'Initial', isReinspection: reins,
            typeColor: reins ? '#3730A3' : '#64748B', typeBg: reins ? '#EEF0FF' : '#EEF0F4',
            checker: t.checker, hasReassign: !!t.reassignedTo, noReassign: !t.reassignedTo, reassignedTo: t.reassignedTo,
            countStr: t.checked + ' / ' + t.target, pct: Math.min(100, Math.round(t.checked / (t.target || 1) * 100)) + '%',
            statusLabel: t.status, sc: sm.c, sb: sm.b,
            onReassign: () => this.openReassign(t.id), onKeyin: () => this.openKeyin(t.id),
          };
        });
        const checkers = ['Aiman', 'Siti', 'Ravi', 'Mei Ling', 'Ahmad', 'Nurul', 'Hafiz'];
        const item = this.qSchedule.find((t) => t.id === this.modalId) || {};
        const chips = checkers.map((n) => {
          const cur = n === (item.reassignedTo || item.checker);
          return { name: n, isCurrent: cur, chipStyle: cur ? 'background:linear-gradient(135deg,#4F46E5,#3730A3);color:#fff;border-color:transparent' : 'background:#fff;color:#475569;border-color:#E2E4EC', on: () => this.doReassign(n) };
        });
        const k = this.keyin;
        const keyinTotal = (+k.accept || 0) + (+k.rework || 0) + (+k.scrap || 0);
        return {
          schedRows: rows, checkerOptions: checkers,
          openCreate: () => this.openCreate(), closeModal: () => this.closeModal(),
          addTask: () => this.addTask(), submitKeyin: () => this.submitKeyin(),
          modalCreate: this.modal === 'create', modalReassign: this.modal === 'reassign', modalKeyin: this.modal === 'keyin',
          modalOpen: !!this.modal, modalItem: item, reassignChips: chips,
          fPart: this.setForm('part'), fJo: this.setForm('jo'), fProcess: this.setForm('process'), fParameter: this.setForm('parameter'), fCycle: this.setForm('cycle'), fMachine: this.setForm('machine'), fChecker: this.setForm('checker'), fTarget: this.setForm('target'), fTime: this.setForm('time'),
          formPart: this.form.part, formJo: this.form.jo, formProcess: this.form.process, formParameter: this.form.parameter, formCycle: this.form.cycle, formMachine: this.form.machine, formChecker: this.form.checker, formTarget: this.form.target, formTime: this.form.time,
          kAccept: this.setKeyin('accept'), kRework: this.setKeyin('rework'), kScrap: this.setKeyin('scrap'),
          keyAccept: k.accept, keyRework: k.rework, keyScrap: k.scrap, keyinTotal,
        };
      },

      renderVals() {
        const view = this.view;
        const t = this.time;
        const pad = (n) => String(n).padStart(2, '0');
        const clock = pad(t.getHours()) + ':' + pad(t.getMinutes()) + ':' + pad(t.getSeconds());
        const dateStr = t.toLocaleDateString('en-GB', { weekday: 'short', day: '2-digit', month: 'short' });
        const hr = t.getHours();
        const partOfDay = hr < 12 ? 'morning' : hr < 18 ? 'afternoon' : 'evening';

        const ms = this.machines;
        const running = ms.filter((m) => m.status === 'run').length;
        const idle = ms.filter((m) => m.status === 'idle').length;
        const down = ms.filter((m) => m.status === 'down').length;
        const totalOut = ms.reduce((a, m) => a + m.count, 0);
        const totalTarget = ms.reduce((a, m) => a + m.target, 0);
        const pctToTarget = Math.round(totalOut / totalTarget * 100);
        const passRate = (this.live.passRate != null) ? this.live.passRate : 97.5;

        const ACTIVE = 'background:rgba(255,255,255,.13);color:#fff;box-shadow:inset 3px 0 0 #818CF8';
        const navS = (id) => (view === id ? ACTIVE : '');

        const titles = {
          hub: ['Famax MES', 'Workspace Launcher'], quality: ['Quality', 'Quality Hub — Inspection Overview'],
          inspect: ['Quality · Inspection', 'IPQC / Buy-off Key-in'], reports: ['Quality', 'Report Summary'],
          output: ['Production · Live', 'Daily Output — Machine Floor'], store: ['Inventory', 'Store & Inventory'],
          admin: ['System', 'Admin Console'], dms: ['Documents', 'DMS — Document Management'], notify: ['Documents · Approvals', 'WI Signatures & Teams Notify'],
          gauge: ['Restricted · Quality', 'Gauge Verification'], cycle: ['Restricted · Production', 'Cycle Time Study'],
          maint: ['Restricted · Maintenance', 'Preventive Maintenance'], bd: ['Restricted · Business Dev', 'BD Forms'],
          docctrl: ['Restricted · Engineering', 'Document Control'], users: ['Restricted · System', 'User Management'],
        };
        const live = this.source === 'live';

        const hubStats = [
          { label: 'Machines Running', value: running + ' / ' + ms.length, dot: '#16A34A', trend: '▲ ' + running + ' active now', trendColor: '#16A34A' },
          { label: 'Output Today', value: this.nf(totalOut), dot: '#4F46E5', trend: pctToTarget + '% of plan', trendColor: '#6B7280' },
          { label: 'Quality Pass Rate', value: passRate + '%', dot: '#16A34A', trend: '▲ 0.6% vs yesterday', trendColor: '#16A34A' },
          { label: 'Open NG / Alarms', value: (down + 3) + '', dot: '#DC2626', trend: down + ' machines down', trendColor: '#DC2626' },
        ];
        const mod = (title, desc, icon, iconBg, iconColor, tag, tagColor, tagBg, go, active) => ({ title, desc, icon, iconBg, iconColor, tag, tagColor, tagBg, go: active ? go : (() => {}), cursor: active ? 'pointer' : 'default', opacity: active ? '1' : '.58' });
        const modules = [
          mod('Trace by JO', 'ISO soft-key packet: IPQC, Buy-off, logs, lot, store for one JO.', ICONS.reports, '#EEF0FF', '#4338CA', 'Read-only', '#16A34A', '#E7F6EC', () => { window.open('screen_page/inspection/inspectionTraceJO.html', '_blank'); }, true),
          mod('Quality Hub', 'Live inspection overview, schedule adherence & NG tracking.', ICONS.quality, '#EEF0FF', '#4338CA', 'Active', '#16A34A', '#E7F6EC', () => this.go('quality'), true),
          mod('Daily Output', 'Real-time machine part-counts from the MTLinki feed.', ICONS.output, '#E7F6EC', '#16A34A', 'Live', '#16A34A', '#E7F6EC', () => this.go('output'), true),
          mod('Inspection Key-in', 'IPQC, Buy-off, IQC & OQC measurement entry by JO.', ICONS.inspect, '#FCF1DE', '#B45309', 'Form', '#4338CA', '#EEF0FF', () => this.go('inspect'), true),
          mod('Report Summary', 'QC, machine-stop, job-order & out-of-spec analytics.', ICONS.reports, '#EAF6FF', '#0369A1', 'Active', '#16A34A', '#E7F6EC', () => this.go('reports'), true),
          mod('Store & Inventory', 'Raw material levels, FG store records & movements.', ICONS.store, '#F1F0FA', '#6D28D9', 'Active', '#16A34A', '#E7F6EC', () => this.go('store'), true),
          mod('Document (DMS)', 'Browse part docs, revisions, CNC programs & tooling.', ICONS.dms, '#EAF6FF', '#0369A1', 'Active', '#16A34A', '#E7F6EC', () => this.go('dms'), true),
          mod('WI Signatures', 'QA → Management sign-off workflow + Teams notify.', ICONS.notify, '#FCF1DE', '#B45309', 'Workflow', '#3730A3', '#EEF0FF', () => this.go('notify'), true),
        ];
        const auth = this.auth;
        const lockMod = (title, desc, icon, view2) => ({ title, desc, icon, iconBg: auth ? '#EEF0FF' : '#F1F2F6', iconColor: auth ? '#3730A3' : '#9AA1B2', tag: auth ? 'Open' : 'Login', tagColor: auth ? '#16A34A' : '#B45309', tagBg: auth ? '#E7F6EC' : '#FCF1DE', go: auth ? () => this.go(view2) : () => this.openLogin(), cursor: 'pointer', opacity: '1', locked: !auth });
        const modulesLocked = [
          lockMod('Gauge Verification', 'Gauge register, calibration due & verification readings.', ICONS.gauge, 'gauge'),
          lockMod('Cycle Time Study', 'Standard cycle-time per part, process & machine.', ICONS.cycle, 'cycle'),
          lockMod('Preventive Maintenance', 'PM schedule, checklists & maintenance logs.', ICONS.maint, 'maint'),
          lockMod('BD Forms', 'Packing list, shipment checklist & sales order.', ICONS.pack, 'bd'),
          lockMod('Document Control', 'Revision upload & obsolete folder removal.', ICONS.dms, 'docctrl'),
          lockMod('User Management', 'Manage users, roles & access credentials.', ICONS.users, 'users'),
          lockMod('Admin Console', 'File generator, add part, update JO & data editor.', ICONS.admin, 'admin'),
        ];

        const outputKpis = [
          { label: 'Total Output', value: this.nf(totalOut), sub: 'parts · shift ' + this.shift, bg: 'linear-gradient(135deg,#2A2470,#4338CA)', border: 'transparent', labelColor: '#C7C3FF', valColor: '#fff', subColor: '#C7C3FF' },
          { label: 'vs Plan', value: pctToTarget + '%', sub: this.nf(totalTarget) + ' target', bg: '#fff', border: '#E8E9EF', labelColor: '#8A8A9A', valColor: '#16161D', subColor: '#9A9AAB' },
          { label: 'Running', value: running + '', sub: 'of ' + ms.length + ' machines', bg: '#fff', border: '#E8E9EF', labelColor: '#8A8A9A', valColor: '#16A34A', subColor: '#9A9AAB' },
          { label: 'Idle', value: idle + '', sub: 'setup / waiting', bg: '#fff', border: '#E8E9EF', labelColor: '#8A8A9A', valColor: '#D97706', subColor: '#9A9AAB' },
          { label: 'Down', value: down + '', sub: 'needs attention', bg: '#fff', border: '#E8E9EF', labelColor: '#8A8A9A', valColor: '#DC2626', subColor: '#9A9AAB' },
        ];
        const machineCards = ms.map((m) => {
          const sm = this.statusMeta(m.status);
          const pct = Math.min(100, Math.round(m.count / m.target * 100));
          return {
            name: m.name, brand: m.brand, part: m.part, jo: m.jo,
            countFmt: this.nf(m.count), targetFmt: this.nf(m.target), pctStr: pct + '%',
            cycleStr: m.cycle ? m.cycle + 's' : '—',
            utilStr: m.util ? m.util + '%' : '—', utilColor: m.util >= 85 ? '#16A34A' : m.util > 0 ? '#D97706' : '#9A9AAB',
            statusLabel: sm.label, statusColor: sm.color, statusBg: sm.bg, accent: sm.accent, dotAnim: sm.anim,
            note: m.note, noteColor: sm.noteColor,
          };
        });

        return {
          sidebarW: this.collapsed ? '74px' : '252px',
          labelDisp: this.collapsed ? 'none' : 'block',
          liveTagDisp: this.collapsed ? 'none' : 'inline-block',
          toggleCollapse: () => { this.collapsed = !this.collapsed; },
          goHome: () => this.go('hub'), goQuality: () => this.go('quality'), goInspect: () => this.go('inspect'),
          goReports: () => this.go('reports'), goOutput: () => this.go('output'), goStore: () => this.go('store'), goAdmin: () => this.goAuth('admin'),
          goDms: () => this.go('dms'), goNotify: () => this.go('notify'),
          goGauge: () => this.goAuth('gauge'), goCycle: () => this.goAuth('cycle'), goMaint: () => this.goAuth('maint'), goBd: () => this.goAuth('bd'), goDocctrl: () => this.goAuth('docctrl'), goUsers: () => this.goAuth('users'),
          navHome: navS('hub'), navQuality: navS('quality'), navInspect: navS('inspect'),
          navReports: navS('reports'), navOutput: navS('output'), navStore: navS('store'), navAdmin: navS('admin'),
          navDms: navS('dms'), navNotify: navS('notify'),
          navGauge: navS('gauge'), navCycle: navS('cycle'), navMaint: navS('maint'), navBd: navS('bd'), navDocctrl: navS('docctrl'), navUsers: navS('users'),
          isHub: view === 'hub', isQuality: view === 'quality', isInspect: view === 'inspect', isReports: view === 'reports', isOutput: view === 'output', isStore: view === 'store', isAdmin: view === 'admin', isDms: view === 'dms', isNotify: view === 'notify',
          isGauge: view === 'gauge', isCycle: view === 'cycle', isMaint: view === 'maint', isBd: view === 'bd', isDocctrl: view === 'docctrl', isUsers: view === 'users',
          auth: this.auth, guest: !this.auth,
          openLogin: () => this.openLogin(), doLogin: () => this.doLogin(), logout: () => this.logout(),
          setLoginId: (e) => this.setLoginId(e), setLoginPw: (e) => this.setLoginPw(e),
          loginId: this.loginCreds.id, loginPw: this.loginCreds.pw, loginErr: this.loginErr, hasLoginErr: !!this.loginErr,
          modalLogin: this.modal === 'login',
          crumb: titles[view][0], pageTitle: titles[view][1],
          clock, dateStr, partOfDay,
          plantState: down > 0 ? 'running with attention needed' : 'running smoothly',
          srcLabel: live ? 'Live data' : 'Demo data', srcColor: live ? '#16A34A' : '#D97706',
          srcBg: live ? '#E7F6EC' : '#FCF1DE', srcBorder: live ? '#B8E6C6' : '#F0D9A8',
          shift: this.shift,
          shiftA: () => { this.shift = 'A'; }, shiftB: () => { this.shift = 'B'; },
          shiftABtn: this.shift === 'A' ? 'background:#4F46E5;color:#fff' : 'background:transparent;color:#6B7280',
          shiftBBtn: this.shift === 'B' ? 'background:#4F46E5;color:#fff' : 'background:transparent;color:#6B7280',
          runningCount: running, machineTotal: ms.length, totalOutFmt: this.nf(totalOut), passRate,
          hubStats, modules, modulesLocked,
          outputKpis, machineCards,
          ...this.gaugeData(), ...this.cycleData(), ...this.maintData(),
          ...this.bdData(this.bdTab), ...this.docCtrlData(this.docTab), ...this.usersData(),
          ...this.qualityData(),
          ...this.reportData(this.reportTab),
          ...this.inspectData(),
          ...this.storeData(this.storeTab),
          ...this.rawStockData(),
          ...this.adminData(this.adminTab),
          ...this.dmsData(this.dmsPart),
          ...this.notifyData(),
          ...this.scheduleVals(),
          toast: this.toast,
        };
      },
    },
  }).mount('#app');
})();
