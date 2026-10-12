/* Kylord Studios Gold Pass: the connection to the studio's Supabase server.
   - Accounts: a gamertag plus a secret sign-in code kept on the device. The server only
     stores a hash of the code, and every change goes through a server function that checks it.
   - Live play: Supabase Realtime presence channels, shaped like the `room` the game was
     first written against, so the battle code is unchanged. */
(function (G) {
  'use strict';
  const URL = 'https://lfdpbifgtcxszvyjfqty.supabase.co';
  const KEY = 'sb_publishable_BqGPGENDOndnS0sg-QqG6A_E6n-joIf';
  const CREDS = 'kylord_goldpass_v1';
  const MIN_GAP = 100;        // ms between presence updates from this tab (Realtime rate limits)

  const KG = G.KylordGold = { ok: false };
  if (!G.supabase || !G.supabase.createClient) return;
  const sb = G.supabase.createClient(URL, KEY, { auth: { persistSession: false, autoRefreshToken: false }, realtime: { params: { eventsPerSecond: 20 } } });
  KG.ok = true;
  KG.sb = sb;
  const tabId = 't' + Math.random().toString(36).slice(2, 12);

  /* ---------- account ---------- */
  KG.creds = () => { try { return JSON.parse(localStorage.getItem(CREDS) || 'null'); } catch (e) { return null; } };
  KG.saveCreds = c => { try { if (c) localStorage.setItem(CREDS, JSON.stringify(c)); else localStorage.removeItem(CREDS); } catch (e) { /* optional */ } };
  const why = e => (e && (e.message || e.details)) || 'The Gold Pass server could not be reached. Check your connection.';
  async function rpc(fn, args) {
    const { data, error } = await sb.rpc(fn, args);
    if (error) throw new Error(why(error));
    return data;
  }
  const auth = () => { const c = KG.creds(); if (!c) throw new Error('Not signed in'); return { p_pid: c.pid, p_secret: c.secret }; };
  KG.register = async (tag, av) => { const r = await rpc('gp_register', { p_tag: tag, p_av: av }); KG.saveCreds({ pid: r.profile.pid, secret: r.secret }); return r.profile; };
  KG.login = async () => rpc('gp_login', auth());
  KG.update = (tag, av) => rpc('gp_update', Object.assign(auth(), { p_tag: tag, p_av: av }));
  KG.friends = () => rpc('gp_friends', auth());
  KG.addFriend = (pid, tag) => rpc('gp_add_friend', Object.assign(auth(), { p_to: pid || null, p_tag: tag || null }));
  KG.removeFriend = pid => rpc('gp_remove_friend', Object.assign(auth(), { p_other: pid }));
  KG.result = won => rpc('gp_result', Object.assign(auth(), { p_won: !!won }));
  // a sign-in code moves a Gold Pass to another phone or computer
  KG.code = () => { const c = KG.creds(); return c ? 'KG-' + btoa(c.pid + ':' + c.secret).replace(/=+$/, '') : ''; };
  KG.useCode = async code => {
    let pid, secret;
    try { [pid, secret] = atob(String(code).trim().replace(/^KG-/i, '')).split(':'); } catch (e) { /* bad code */ }
    if (!pid || !secret) throw new Error('That sign-in code is not right. Copy it again from your other device.');
    const old = KG.creds(); KG.saveCreds({ pid, secret });
    try { return await KG.login(); } catch (e) { KG.saveCreds(old); throw new Error('That sign-in code is not right. Copy it again from your other device.'); }
  };

  /* ---------- live rooms ---------- */
  function makeRoom(name) {
    const ch = sb.channel(name, { config: { presence: { key: tabId } } });
    const peerFns = [], connFns = [], closeFns = [];
    let state = {}, live = false, want = null, sentJson = '', timer = 0, lastSent = 0, closed = false;
    ch.on('presence', { event: 'sync' }, () => { state = ch.presenceState(); for (const f of peerFns) try { f(); } catch (e) { /* screen closed */ } });
    function flush() {
      timer = 0;
      if (!live || closed || want === null) return;
      const j = JSON.stringify(want);
      if (j === sentJson) return;
      sentJson = j; lastSent = Date.now();
      ch.track(want).catch(() => { sentJson = ''; });
    }
    const ready = new Promise((resolve, reject) => {
      let settled = false;
      ch.subscribe(status => {
        if (status === 'SUBSCRIBED') { live = true; sentJson = ''; flush(); for (const f of connFns) f(true); if (!settled) { settled = true; resolve(); } }
        else if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT' || status === 'CLOSED') {
          live = false; for (const f of connFns) f(false);
          if (!settled) { settled = true; reject(new Error(status)); }
          if (status === 'CLOSED' && closed) for (const f of closeFns) f();
        }
      });
    });
    const room = {
      ready,
      presence(obj) {
        want = obj;
        if (!timer) timer = setTimeout(flush, Math.max(0, lastSent + MIN_GAP - Date.now()));
        return Promise.resolve();
      },
      peers() {
        const list = [];
        for (const k in state) for (const meta of state[k] || []) {
          const pr = Object.assign({}, meta); delete pr.presence_ref;
          list.push({ presence: pr, sameTab: k === tabId, guest: false });
        }
        return list;
      },
      onPeers(fn) { peerFns.push(fn); },
      onConnection(fn, onClose) { connFns.push(fn); if (onClose) closeFns.push(onClose); if (live) fn(true); },
      async join(sub) { const r = makeRoom(name + ':' + sub); await r.ready; return r; },
      async leave() { closed = true; clearTimeout(timer); try { await ch.untrack(); } catch (e) { /* gone */ } try { await sb.removeChannel(ch); } catch (e) { /* gone */ } }
    };
    return room;
  }
  KG.room = async name => { const r = makeRoom(name); try { await r.ready; } catch (e) { /* keeps retrying in the background */ } return r; };
})(window);
