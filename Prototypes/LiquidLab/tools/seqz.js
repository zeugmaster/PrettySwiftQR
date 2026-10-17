<script>
(function () {
  // Zoomed strip: #rest~mode,payload,rm,ri,render,cx,cy,cw,cell,p1,p2,...
  // Renders each frame at `render` px, crops the square at (cx,cy) of side cw (fractions of the canvas), draws it at `cell` px.
  const spec = (location.hash.split('~')[1] || '').split(',');
  const mode = +spec[0], payload = spec[1], rm = +spec[2], ri = +spec[3], size = +spec[4], cx = +spec[5], cy = +spec[6], cw = +spec[7], cell = +spec[8], ps = spec.slice(9).map(Number);
  S.payload = payload; S.frame = 0;
  thumb.resize(size); thumb.setModel(modelFor(currentMatrix(), S.grid));
  const c = document.createElement('canvas'); c.width = ps.length * (cell + 6); c.height = cell; c.id = 'strip';
  const x = c.getContext('2d'); x.fillStyle = '#333'; x.fillRect(0, 0, c.width, c.height); x.imageSmoothingEnabled = false;
  ps.forEach((p, i) => {
    thumb.render(params({ mode: p < 0 ? 0 : mode, p: Math.max(p, 0), radii: derivedRadii(rm, ri) }));
    x.drawImage(thumb.canvas, cx * size, cy * size, cw * size, cw * size, i * (cell + 6), 0, cell, cell);
  });
  c.style.cssText = 'position:fixed;left:0;top:0;z-index:99'; document.body.appendChild(c);
})();
</script>
