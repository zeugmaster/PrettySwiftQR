<script>
(function () {
  // #rest~mode,payload,size,p0,p1,step,dp : for each P, find (a) blur: grey pixels in thick grey clusters,
  // (b) pops: pixels that flip by > 50% between P and P + dp. Reports 24px-tile hotspots.
  const spec = (location.hash.split('~')[1] || '').split(',');
  const mode = +spec[0], payload = spec[1], size = +spec[2], p0 = +spec[3], p1 = +spec[4], step = +spec[5], dp = +spec[6];
  S.payload = payload; S.frame = 0;
  thumb.resize(size); thumb.setModel(modelFor(currentMatrix(), S.grid));
  const gl = thumb.gl;
  const grab = (p) => { thumb.render(params({ mode, p })); const px = new Uint8Array(size * size * 4); gl.readPixels(0, 0, size, size, gl.RGBA, gl.UNSIGNED_BYTE, px); const g = new Uint8Array(size * size); for (let i = 0; i < size * size; i++) g[i] = px[i * 4]; return g; };
  const T = 24, out = [];
  for (let p = p0; p <= p1 + 1e-9; p += step) {
    const a = grab(p), b = grab(p + dp);
    const blur = new Map(), pop = new Map();
    for (let y = 1; y < size - 1; y++) for (let x = 1; x < size - 1; x++) {
      const i = y * size + x, v = a[i];
      if (v > 40 && v < 215) {
        let k = 0; for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) { const w = a[i + dy * size + dx]; if (w > 40 && w < 215) k++; }
        if (k >= 7) { const key = ((size - 1 - y) / T | 0) * 1000 + (x / T | 0); blur.set(key, (blur.get(key) || 0) + 1); }
      }
      if (Math.abs(a[i] - b[i]) > 128) { const key = ((size - 1 - y) / T | 0) * 1000 + (x / T | 0); pop.set(key, (pop.get(key) || 0) + 1); }
    }
    const fmt = (m, min) => [...m.entries()].filter(([, c]) => c >= min).sort((u, v) => v[1] - u[1]).slice(0, 6).map(([k, c]) => `${((k % 1000) * T + T / 2) / size}`.slice(0, 5) + ',' + `${((k / 1000 | 0) * T + T / 2) / size}`.slice(0, 5) + ':' + c);
    out.push(`${p.toFixed(3)} blur[${fmt(blur, 4).join(' ')}] pop[${fmt(pop, 6).join(' ')}]`);
  }
  const pre = document.createElement('pre'); pre.id = 'out'; pre.textContent = out.join('\n'); document.body.appendChild(pre);
})();
</script>
