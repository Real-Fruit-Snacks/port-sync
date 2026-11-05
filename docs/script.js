// port-sync page: theme switch, copy button, and the panel acting out one reconnect.
// Without JS the panel shows its synced state. With reduced motion the sequence still runs, without
// the ring, pulse and pauses.
(function () {
  var root = document.documentElement;
  var still = matchMedia('(prefers-reduced-motion: reduce)');
  var light = matchMedia('(prefers-color-scheme: light)');
  var $ = function (id) { return document.getElementById(id); };

  // ---- theme ----
  function theme() { return root.dataset.theme || (light.matches ? 'dayshift' : 'nightshift'); }
  function paint() {
    var night = theme() === 'nightshift';
    document.querySelector('meta[name="theme-color"]').content = night ? '#0C0D10' : '#F6F5F2';
    $('theme').setAttribute('aria-label', 'Theme: ' + (night ? 'night' : 'day') + '. Switch to ' + (night ? 'day' : 'night'));
  }
  $('theme').addEventListener('click', function () {
    root.dataset.theme = theme() === 'nightshift' ? 'dayshift' : 'nightshift';
    try { localStorage.setItem('rfs-theme', root.dataset.theme); } catch (e) {}
    paint();
  });
  light.addEventListener('change', paint);
  paint();

  // ---- copy ----
  document.querySelectorAll('[data-copy]').forEach(function (b) {
    var label = b.textContent;
    b.addEventListener('click', function () {
      var done = function (ok) { b.textContent = ok ? 'Copied' : 'Select it'; clearTimeout(b._t); b._t = setTimeout(function () { b.textContent = label; }, 1600); };
      if (navigator.clipboard) navigator.clipboard.writeText(b.dataset.copy).then(function () { done(true); }, function () { done(false); });
      else done(false);
    });
  });

  // ---- the panel ----
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

  // One reconnect: Proton forwards a new port, qBittorrent is out of sync until the next read sets it.
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
