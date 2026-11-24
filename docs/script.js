// port-sync page: Cyclorama Dawn v2.1.0 theme switch (Dark LX 263 default), copy toasts,
// and the interactive 7-segment process controller acting out a Proton VPN reconnect.
(function () {
  var root = document.documentElement;
  var still = matchMedia('(prefers-reduced-motion: reduce)');
  var $ = function (id) { return document.getElementById(id); };

  // ---- theme (Dark LX 263 default; Light LX 512 opt-in) ----
  function currentTheme() { return root.dataset.theme === 'light' ? 'light' : 'dark'; }
  function applyTheme(next) {
    if (next === 'light') root.dataset.theme = 'light';
    else delete root.dataset.theme;
    var isDark = currentTheme() === 'dark';
    var cs = document.querySelector('meta[name="color-scheme"]');
    if (cs) cs.content = isDark ? 'dark' : 'light';
    var tc = document.querySelector('meta[name="theme-color"]');
    if (tc) tc.content = isDark ? '#050507' : '#F5F7F9';
    var btn = $('theme');
    if (btn) btn.setAttribute('aria-label', isDark ? 'Switch to Alabaster Day light mode' : 'Switch to Beacon Horizon dark mode');
  }
  $('theme').addEventListener('click', function (e) {
    var next = currentTheme() === 'dark' ? 'light' : 'dark';
    var flip = function () {
      applyTheme(next);
      try { localStorage.setItem('rfs-theme', next); } catch (err) {}
    };
    if (!document.startViewTransition || still.matches) return flip();
    var x = e.clientX || innerWidth - 40, y = e.clientY || 32;
    var r = Math.hypot(Math.max(x, innerWidth - x), Math.max(y, innerHeight - y));
    document.startViewTransition(flip).ready.then(function () {
      root.animate(
        { clipPath: ['circle(0 at ' + x + 'px ' + y + 'px)', 'circle(' + r + 'px at ' + x + 'px ' + y + 'px)'] },
        { duration: 520, easing: 'cubic-bezier(.2,.7,.2,1)', pseudoElement: '::view-transition-new(root)' }
      );
    });
  });
  window.addEventListener('storage', function (e) {
    if (e.key === 'rfs-theme') applyTheme(e.newValue === 'light' || e.newValue === 'dayshift' ? 'light' : 'dark');
  });
  applyTheme(currentTheme());

  // ---- semantic toast notification ----
  var toastRegion = $('toast-region');
  var toastSr = $('toast-sr');
  function showToast(kind, tag, message) {
    if (typeof document.ariaNotify === 'function') {
      try { document.ariaNotify(message); } catch (e) {}
    } else if (toastSr) {
      toastSr.textContent = '';
      toastSr.textContent = message;
    }
    if (!toastRegion) return;
    if (typeof toastRegion.showPopover === 'function') {
      try { if (!toastRegion.matches(':popover-open')) toastRegion.showPopover(); } catch (e) {}
    }
    var item = document.createElement('div');
    item.className = 'rfs-toast is-' + kind;
    var msg = document.createElement('span');
    msg.className = 'rfs-toast-msg';
    var k = document.createElement('span');
    k.className = 'k';
    k.textContent = tag + ' ';
    msg.appendChild(k);
    msg.appendChild(document.createTextNode(message));
    var close = document.createElement('button');
    close.type = 'button';
    close.className = 'rfs-toast-close';
    close.setAttribute('aria-label', 'Dismiss notification');
    close.textContent = '×';
    item.appendChild(msg);
    item.appendChild(close);
    toastRegion.appendChild(item);

    var remove = function () {
      if (item.parentNode) item.parentNode.removeChild(item);
      if (toastRegion.childElementCount === 0 && typeof toastRegion.hidePopover === 'function') {
        try { toastRegion.hidePopover(); } catch (e) {}
      }
    };
    close.addEventListener('click', remove);
    setTimeout(function tick() {
      if (item.contains(document.activeElement)) return setTimeout(tick, 1200);
      remove();
    }, 2600);
  }

  // ---- copy ----
  document.querySelectorAll('[data-copy]').forEach(function (b) {
    var label = b.textContent;
    b.addEventListener('click', function () {
      var done = function (ok) {
        b.textContent = ok ? '[ok] Copied' : 'Select text';
        showToast(ok ? 'ok' : 'warn', ok ? '[ok]' : '[!]', ok ? 'Command copied to clipboard.' : 'Copy manually from the code block.');
        clearTimeout(b._t);
        b._t = setTimeout(function () { b.textContent = label; }, 1800);
      };
      if (navigator.clipboard) navigator.clipboard.writeText(b.dataset.copy).then(function () { done(true); }, function () { done(false); });
      else done(false);
    });
  });

  // ---- the 7-segment process controller ----
  var src = $('d-src'), dst = $('d-dst'), out = $('dst'), ring = $('ring'), pulse = document.querySelector('.pulse');
  var read = $('l-read'), set = $('l-set'), tail = $('tail'), btn = $('replay'), sr = $('sr-ports');
  var port = 48213, busy = false;

  function show(el, n) {
    var s = String(n).padStart(5, ' ');
    el.querySelectorAll('.dg').forEach(function (d, i) { d.dataset.d = s[i].trim(); });
  }
  function stamp() {
    var d = new Date(), p = function (x) { return String(x).padStart(2, '0'); };
    return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) + ' ' + p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds()) + ' [port-sync]';
  }
  function log(text) { tail.innerHTML = '<span class="ts">' + stamp() + '</span> ' + text; }
  function restart(el, cls) { el.classList.remove(cls); void el.offsetWidth; el.classList.add(cls); }
  function later(ms, fn) { return new Promise(function (ok) { setTimeout(function () { fn(); ok(); }, still.matches ? 0 : ms); }); }

  function reconnect(want) {
    if (busy) return; busy = true; btn.disabled = true;
    var old = port, next;
    next = typeof want === 'number' ? want : old;
    while (next === old) next = 10000 + Math.floor(Math.random() * 55536);
    port = next;
    show(src, next); restart(src.parentNode, 'bump');
    out.dataset.state = 'off';
    tail.textContent = 'Proton VPN log: Port pair ' + next + '->' + next;
    restart(ring, 'scan');
    later(1500, function () { read.classList.add('on'); restart(pulse, 'go'); })
      .then(function () { return later(420, function () { read.classList.remove('on'); set.classList.add('on'); }); })
      .then(function () { return later(260, function () {
        show(dst, next); out.dataset.state = 'sync';
        log('listening port updated: ' + old + ' -&gt; ' + next);
        sr.textContent = next;
      }); })
      .then(function () { return later(500, function () { set.classList.remove('on'); busy = false; btn.disabled = false; }); });
  }
  btn.addEventListener('click', function () { reconnect(); });
  if (!still.matches) setTimeout(function () { reconnect(51037); }, 1100);
})();
