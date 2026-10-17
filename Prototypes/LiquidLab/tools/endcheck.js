<script>
(function () {
  // Compare the animated field at P=0 (mode 4 and mode 3) with the resting symbol, pixel by pixel,
  // and sample the last 10% of appear finely to catch any jump.
  const res = {};
  for (const payload of ['static', 'medium', 'animated']) {
    S.payload = payload; S.frame = 0;
    thumb.resize(600); thumb.setModel(modelFor(currentMatrix(), S.grid));
    const gl = thumb.gl, grab = () => { const px = new Uint8Array(600 * 600 * 4); gl.readPixels(0, 0, 600, 600, gl.RGBA, gl.UNSIGNED_BYTE, px); return px; };
    thumb.render(params({ mode: 0, p: 1 })); const rest = grab();
    const diffs = {};
    for (const [name, mode, p] of [['pull@0', 4, 0], ['flow@0', 3, 0], ['pull@0.01', 4, 0.01], ['pull@0.03', 4, 0.03]]) {
      thumb.render(params({ mode, p })); const px = grab();
      let n = 0, mx = 0; for (let k = 0; k < px.length; k += 4) { const v = Math.abs(px[k] - rest[k]); if (v > 24) n++; mx = Math.max(mx, v); }
      diffs[name] = { pixelsOver24: n, max: mx };
    }
    const act = []; let prev = null;
    for (let i = 0; i <= 40; i++) { thumb.render(params({ mode: 4, p: 0.1 * (1 - i / 40) })); const px = grab(); if (prev) { let s = 0; for (let k = 0; k < px.length; k += 4) s += Math.abs(px[k] - prev[k]); act.push(+(s / 360000).toFixed(3)); } prev = px; }
    thumb.render(params({ mode: 0, p: 1 })); const px = grab(); let s = 0; for (let k = 0; k < px.length; k += 4) s += Math.abs(px[k] - prev[k]); act.push(+(s / 360000).toFixed(3));
    res[payload] = { diffs, tail: act };
  }
  const pre = document.createElement('pre'); pre.id = 'act'; pre.textContent = JSON.stringify(res); document.body.appendChild(pre);
})();
</script>
