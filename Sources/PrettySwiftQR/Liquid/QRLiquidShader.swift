//
//  QRLiquidShader.swift
//  PrettySwiftQR
//
//  The liquid field as Metal source. It is compiled at runtime (see
//  `QRLiquidGPU`) because Swift packages cannot ship compiled Metal without
//  every consumer installing Xcode's separate Metal toolchain.
//
//  Every pixel evaluates a signed distance field: the modules of drops that have
//  not started yet, each moving drop (its cells contracting into a bead), the
//  threads between drops and, for a morph, the stroke built from landed mass,
//  all joined by a smooth minimum whose reach is the surface tension. Units are
//  modules; the field is antialiased over its screen-space gradient. A port of
//  the fragment shader in Prototypes/LiquidLab/template.html.
//

enum QRLiquidShader {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

constant int PROFILE_N = 512;

struct Uniforms {
    float4 rect;        // x, y (top-left), side in pixels; quiet zone in modules
    float4 radii;       // module, inner, finder outer, finder inner
    float4 foreground;  // premultiplied
    float4 background;  // premultiplied, alpha 0 for none
    float4 params;      // finder centre radius, tension, stroke length
    int4 counts;        // modules per side, mode (0 rest, 3 flow, 4 pull apart), drops, threads
    int4 strokeCount;   // points on the stroke
    float4 stroke[4];   // up to eight points, two per entry
};

struct Env {
    texture2d<uint, access::read> info;     // (n+1)^2: flags, fillets, dark neighbours, drop
    texture2d<float, access::read> state;   // 5 x drops
    texture2d<float, access::read> bonds;   // 4 x threads
    texture2d<float, access::read> profile; // 512 x 1
    texture2d<float, access::read> attach;  // n x n: each cell side's attachment
    constant Uniforms& u;
};

uint cellFlags(thread const Env& e, int2 c) { int n = e.u.counts.x; if (c.x < 0 || c.y < 0 || c.x >= n || c.y >= n) return 0u; return e.info.read(uint2(c)).r; }
uint filletCode(thread const Env& e, int2 c) { int n = e.u.counts.x; if (c.x < 0 || c.y < 0 || c.x > n || c.y > n) return 0u; return e.info.read(uint2(c)).g & 7u; }
int dropletOf(thread const Env& e, int2 c) { int n = e.u.counts.x; if (c.x < 0 || c.y < 0 || c.x >= n || c.y >= n) return -1; return int(e.info.read(uint2(c)).a); }
float2 quadOf(uint code) { return code == 1u ? float2(-1, -1) : code == 2u ? float2(1, -1) : code == 3u ? float2(-1, 1) : float2(1, 1); }
float meltOf(thread const Env& e, int i) { return i < 0 ? 0.0 : e.state.read(uint2(1, i)).w; }

// Rounded box, per-corner radii (tl, tr, br, bl), y down.
float sdRBox(float2 p, float2 b, float4 r) {
    float rr = p.x > 0.0 ? (p.y > 0.0 ? r.z : r.y) : (p.y > 0.0 ? r.w : r.x);
    rr = clamp(rr, 0.0, min(b.x, b.y));
    float2 q = abs(p) - b + rr;
    return min(max(q.x, q.y), 0.0) + length(max(q, float2(0.0))) - rr;
}
float sdBox(float2 p, float2 b) { float2 d = abs(p) - b; return length(max(d, float2(0.0))) + min(max(d.x, d.y), 0.0); }
// A liquid bridge from a to b: radius r at its waist, widening toward its feet (ra at a, rb at b,
// as multiples of r) along concave sides, the way a stretched liquid neck looks, never a bar.
float sdBridge(float2 p, float2 a, float2 b, float r, float ra, float rb, float waist) {
    float2 pa = p - a, ba = b - a; float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
    float side = h < waist ? 1.0 - h / waist : (h - waist) / (1.0 - waist);
    float foot = h < waist ? ra : rb;
    return length(pa - ba * h) - r * (1.0 + (foot - 1.0) * side * side);
}
float smin(float a, float b, float k) {
    if (k < 1e-4) return min(a, b);
    k *= 4.0; float h = max(k - abs(a - b), 0.0) / k; return min(a, b) - h * h * k * 0.25;
}
// The concave fillet: inside the r x r square at the lattice corner, outside the circle of radius r.
// The square reaches 0.3 back over the corner so its union with the cells has no seam.
float sdFillet(float2 p, float2 c, float2 q, float r) {
    return max(sdBox(p - (c + q * (r - 0.3) * 0.5), float2((r + 0.3) * 0.5)), r - length(p - (c + q * r)));
}
// A module at rest. Sides that touch a dark neighbour reach ext into it, but only for the cell
// containing the pixel: a plain min() of abutting boxes is 0 along the shared edge and would
// antialias to a hairline, and extending every cell would poke into diagonal light cells.
float sdCell(thread const Env& e, float2 p, int2 c, float h, float4 r, float ext) {
    uint nb = e.info.read(uint2(c)).b;
    float4 x = float4((nb & 1u) != 0u ? ext : 0.0, (nb & 2u) != 0u ? ext : 0.0, (nb & 4u) != 0u ? ext : 0.0, (nb & 8u) != 0u ? ext : 0.0);
    return sdRBox(p - float2(x.z - x.x, x.w - x.y) * 0.5, float2(h) + float2(x.x + x.z, x.y + x.w) * 0.5, r);
}
float4 cornerRadii(thread const Env& e, uint f) {
    float r = e.u.radii.x;
    return float4((f & 2u) != 0u ? r : 0.0, (f & 4u) != 0u ? r : 0.0, (f & 8u) != 0u ? r : 0.0, (f & 16u) != 0u ? r : 0.0);
}
// A side's state while moving: 0 light, 1 a cell of the same drop, in between a cell of another
// drop, encoded 0.02 + 0.48 x attachment (1 at rest, 0 once the two drops have torn apart).
float sideAttach(float v) { return v > 0.75 ? 1.0 : clamp((v - 0.02) / 0.48, 0.0, 1.0); }
// A box grown by x = (left, up, right, down).
float sdTab(float2 p, float h, float4 x, float4 r) {
    return sdRBox(p - float2(x.z - x.x, x.w - x.y) * 0.5, float2(h) + float2(x.x + x.z, x.y + x.w) * 0.5, r);
}
// A cell is looked up only while it lies in the window around the pixel. Its field is raised
// smoothly as its centre nears the window's edge, so cells leave the lookup without leaving a step.
float windowFade(float2 rel, float a, float b) {
    float t = max(max(abs(rel.x), abs(rel.y)) - a, 0.0) / (b - a);
    return 6.0 * t * t;
}
// A module while the code is moving. Where it touches a cell of another drop that is tearing
// away, the corners on that side round off as the tear opens and the overlap that hides the
// seam (a tab reaching into the neighbour, drawn for every pixel along one axis at a time) shrinks.
// own: the pixel is inside this cell, which may also reach into its own drop's cells (ownExt).
float sdCellLive(thread const Env& e, float2 p, int2 c, float h, float rnd, bool own, float ownExt) {
    float4 v = e.attach.read(uint2(c));
    float4 same = step(float4(0.75), v), light = 1.0 - step(float4(0.01), v);
    float4 a = float4(sideAttach(v.x), sideAttach(v.y), sideAttach(v.z), sideAttach(v.w)) * (1.0 - light);
    float4 torn = (1.0 - same) * a;
    float4 open = 1.0 - max(a, a.yzwx);
    float4 r = mix(0.5 * open, float4(e.u.radii.x), light * light.yzwx);
    // Melting rounds the corners that face out; a corner where the cell still joins another stays
    // square, or the two rounded corners would cut a notch into the edge between them.
    r = mix(r, float4(h), rnd * open);
    if (own) return sdTab(p, h, 0.5 * (same * ownExt + torn), r);
    float d = sdRBox(p, float2(h), r);
    float4 x = 0.5 * torn;
    if (x.x + x.z > 0.0) d = min(d, sdTab(p, h, float4(x.x, 0.0, x.z, 0.0), r));
    if (x.y + x.w > 0.0) d = min(d, sdTab(p, h, float4(0.0, x.y, 0.0, x.w), r));
    return d;
}
// The concave fillets a cell owns (corners where both neighbours are dark and the diagonal cell
// is light), pushed g into the light cell the way the grown cells push the corner, and fading
// with the attachment of the two cells they join.
float ownedFillets(thread const Env& e, float2 p, int2 c, float g, float r) {
    uint bits = (e.info.read(uint2(c)).g >> 3) & 15u;
    if (bits == 0u || r <= 0.0) return 1e3;
    float4 v = e.attach.read(uint2(c));
    float d = 1e3;
    for (int k = 0; k < 4; k++) {
        if ((bits & (1u << uint(k))) == 0u) continue;
        float2 qd = k == 0 ? float2(-1, -1) : k == 1 ? float2(1, -1) : k == 2 ? float2(1, 1) : float2(-1, 1);
        float2 L = float2(c) + max(qd, float2(0.0));
        float rk = r * min(sideAttach(qd.x < 0.0 ? v.x : v.z), sideAttach(qd.y < 0.0 ? v.y : v.w));
        if (rk > 0.0) d = min(d, sdFillet(p, L + qd * g, qd, rk));
    }
    return d;
}
float2 finderCentre(thread const Env& e, int i) { float n = float(e.u.counts.x); return i == 0 ? float2(3.5) : (i == 1 ? float2(n - 3.5, 3.5) : float2(3.5, n - 3.5)); }
// s: scale, form: 0 round blob to 1 final radii, open: 0 eye closed to 1 open.
float sdFinder(thread const Env& e, float2 p, float s, float form, float open) {
    float ho = 3.5 * s, hi = 2.5 * s * open, hc = 1.5 * s;
    float outer = sdRBox(p, float2(ho), float4(mix(ho, e.u.radii.z * s, form)));
    float hole = sdRBox(p, float2(hi), float4(mix(hi, e.u.radii.w * s * open, form)));
    float centre = sdRBox(p, float2(hc), float4(mix(hc, e.u.params.x * s, form)));
    return min(max(outer, -hole), centre);
}

// The code at rest: cells, fillets and finders straight from the grid. When moving, only the
// parts whose drop has not started are drawn here; the rest come from their drops.
float fieldRest(thread const Env& e, float2 q, bool moving) {
    int2 c0 = int2(floor(q));
    float d = 1e3;
    for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
        int2 c = c0 + int2(dx, dy);
        uint f = cellFlags(e, c);
        if ((f & 1u) == 0u) continue;
        if (!moving) { d = min(d, sdCell(e, q - (float2(c) + 0.5), c, 0.5, cornerRadii(e, f), all(c == c0) ? 0.5 : 0.0)); continue; }
        if (meltOf(e, dropletOf(e, c)) > 0.0) continue;
        float2 rel = q - (float2(c) + 0.5);
        d = min(d, sdCellLive(e, rel, c, 0.5, 0.0, all(c == c0), 1.0) + windowFade(rel, 1.0, 1.5));
        d = min(d, ownedFillets(e, q, c, 0.0, e.u.radii.y) + windowFade(rel, 1.1, 1.5));
    }
    if (!moving && e.u.radii.y > 0.0) for (int j = 0; j <= 1; j++) for (int i = 0; i <= 1; i++) {
        int2 L = c0 + int2(i, j);
        uint code = filletCode(e, L);
        if (code == 0u) continue;
        d = min(d, sdFillet(q, float2(L), quadOf(code), e.u.radii.y));
    }
    int drops = e.u.counts.z;
    for (int i = 0; i < 3; i++) {
        if (moving && meltOf(e, drops - 3 + i) > 0.0) continue;
        d = min(d, sdFinder(e, q - finderCentre(e, i), 1.0, 1.0, 1.0));
    }
    return d;
}

struct DS { float2 pos; float Reff; float lam; float2 dir; float st; float m; float wob; float wobAng; float l; float u; float2 cen; float ext; float finder; };
DS fetchState(thread const Env& e, int i) {
    float4 t0 = e.state.read(uint2(0, i)), t1 = e.state.read(uint2(1, i));
    float4 t2 = e.state.read(uint2(2, i)), t3 = e.state.read(uint2(3, i));
    DS s; s.pos = t0.xy; s.Reff = t0.z; s.lam = t0.w; s.dir = t1.xy; s.st = t1.z; s.m = t1.w;
    s.wob = t2.x; s.wobAng = t2.y; s.l = t2.z; s.u = t2.w; s.cen = t3.xy; s.ext = t3.z; s.finder = t3.w;
    return s;
}
// Maps a point relative to the drop's centre into the undeformed drop: a moving drop is
// stretched along its direction and thinned across; a wobbling drop is a slight ellipse.
float2 undeform(float2 lp, DS s) {
    float al = dot(lp, s.dir); float2 pe = lp - s.dir * al;
    float2 p = s.dir * (al / s.st) + pe * sqrt(s.st);
    float2 ax = float2(cos(s.wobAng), sin(s.wobAng));
    float a2 = dot(p, ax); float2 p2 = p - ax * a2;
    return ax * (a2 / (1.0 + s.wob)) + p2 / (1.0 - s.wob);
}
float dropPiece(thread const Env& e, int i, float2 q) {
    DS s = fetchState(e, i);
    float tension = e.u.params.y;
    // Beyond r0 the piece is further than any join can reach, so it fades out over the next 0.6
    // instead of being cut off (a cut shows as a kink wherever a join was still active).
    float stw = s.st * (1.0 + abs(s.wob));
    float r0 = stw * (max((s.ext + 0.7 * s.m + 0.6) * s.lam, s.Reff) + tension * 3.6 * sqrt(s.st)) + 0.05;
    float r = length(q - s.pos);
    if (r > r0 + 0.6) return 1e3;
    float fade = 4.0 * smoothstep(r0, r0 + 0.6, r);
    // A drop that has shrunk to nothing lets go of its neighbours before it vanishes.
    float gone = 1.0 - smoothstep(0.0, 0.06, s.Reff);
    float2 lp = undeform(q - s.pos, s);
    float bead = length(lp) - s.Reff;
    float corr = 1.0 / sqrt(s.st);
    if (s.m >= 0.999) return bead * corr + gone + fade;
    // The patch's own cells, still in their original frame but contracted toward the centre.
    float2 src = s.cen + lp / s.lam;
    float grow = 1.0 + 0.9 * s.m, rnd = smoothstep(0.0, 0.6, s.m);
    float ks = tension * 3.0 * s.m;
    float dc = 1e3;
    if (s.finder > 0.5) {
        dc = sdFinder(e, src - s.cen, 1.0, 1.0 - smoothstep(0.0, 0.7, s.m), 1.0 - smoothstep(0.0, 0.6, s.m));
    } else {
        int2 c0 = int2(floor(src));
        float h = 0.5 * grow, ownExt = 1.0 - smoothstep(0.0, 0.1, s.m);
        // Light cells inside the patch close as round pores.
        float g = 0.45 * s.m, rf = min(mix(e.u.radii.y, 0.5, rnd), 0.5 - g);
        // The lookup window widens from the resting field's 3 x 3 to 5 x 5 as the drop starts, so a
        // drop that has just started is exactly what the resting field drew in its place.
        float wo = smoothstep(0.0, 0.2, s.m), fa = mix(1.0, 1.8, wo), fb = mix(1.5, 2.5, wo), fl = mix(1.1, 1.8, wo);
        for (int dy = -2; dy <= 2; dy++) for (int dx = -2; dx <= 2; dx++) {
            int2 c = c0 + int2(dx, dy);
            uint f = cellFlags(e, c);
            if ((f & 1u) == 0u || dropletOf(e, c) != i) continue;
            float2 rel = src - (float2(c) + 0.5);
            dc = smin(dc, sdCellLive(e, rel, c, h, rnd, all(c == c0), ownExt) + windowFade(rel, fa, fb), ks);
            dc = min(dc, ownedFillets(e, src, c, g, rf) + windowFade(rel, fl, fb));
        }
    }
    float cells = min(dc, 2.5) * s.lam;
    // The cells become the bead only where the bead already is; cells still outside keep their
    // shape and are carried in by the contraction, so nothing fades out before reaching the drop.
    float m4 = s.m * s.m * s.m * s.m;
    float w = smoothstep(0.15, 1.0, s.m) * mix(1.0 - smoothstep(0.4, 1.2, bead), 1.0, m4);
    return mix(cells, bead, w) * corr + gone + fade;
}
float bondPiece(thread const Env& e, int b, float2 q) {
    float4 t0 = e.bonds.read(uint2(0, b)); // thread ends A, B
    float4 t1 = e.bonds.read(uint2(1, b)); // thread, stub, tip and satellite radii
    float4 t2 = e.bonds.read(uint2(2, b)); // stub ends
    float4 t3 = e.bonds.read(uint2(3, b)); // satellite position, join strength
    // The parts flow into each other: a bead on a thread or a blob on a stub has a waist.
    // Each part lets go of the field as it shrinks (raised beyond any join's reach at radius 0)
    // instead of being dropped below some size, which would pop its joins away in one frame.
    float d = 1e3, kb = 0.06;
    if (t1.x > 0.0) d = sdBridge(q, t0.xy, t0.zw, t1.x, 2.2, 2.2, 0.5) + 1.0 - smoothstep(0.0, 0.02, t1.x);
    if (t1.y > 0.0) {
        float lift = 1.0 - smoothstep(0.0, 0.05, t1.y);
        d = smin(d, sdBridge(q, t0.xy, t2.xy, t1.y, 2.0, 1.0, 1.0) + lift, kb);
        d = smin(d, sdBridge(q, t0.zw, t2.zw, t1.y, 2.0, 1.0, 1.0) + lift, kb);
        d = smin(d, length(q - t2.xy) - t1.z + lift, kb);
        d = smin(d, length(q - t2.zw) - t1.z + lift, kb);
    }
    if (t1.w > 0.0) d = smin(d, length(q - t3.xy) - t1.w + 1.0 - smoothstep(0.0, 0.08, t1.w), kb);
    return d;
}
float sampleProfile(thread const Env& e, float x) {
    float fx = x * float(PROFILE_N) - 0.5;
    int i0 = int(floor(fx)); float f = fx - float(i0);
    int i1 = clamp(i0 + 1, 0, PROFILE_N - 1); i0 = clamp(i0, 0, PROFILE_N - 1);
    return mix(e.profile.read(uint2(i0, 0)).r, e.profile.read(uint2(i1, 0)).r, f);
}
float2 strokePoint(thread const Env& e, int i) { float4 v = e.u.stroke[i / 2]; return (i % 2) == 0 ? v.xy : v.zw; }
// Each segment carries its own width, so the field stays continuous across a corner's bisector.
float strokeField(thread const Env& e, float2 q) {
    float d = 1e3, cum = 0.0;
    int count = e.u.strokeCount.x;
    for (int i = 0; i < count - 1; i++) {
        float2 a = strokePoint(e, i), ab = strokePoint(e, i + 1) - a; float L = length(ab);
        float h = clamp(dot(q - a, ab) / max(dot(ab, ab), 1e-6), 0.0, 1.0);
        d = min(d, length(q - a - ab * h) - sampleProfile(e, (cum + h * L) / e.u.params.z));
        cum += L;
    }
    return d;
}
// rest: the resting field on its own (parts whose drop has not started), for antialiasing.
float fieldMercury(thread const Env& e, float2 q, thread float& rest) {
    float d = fieldRest(e, q, true);
    rest = d;
    float kg = e.u.params.y * 0.9;
    int drops = e.u.counts.z, threads = e.u.counts.w;
    // Drops join in order of when they start, latest first: a drop that has just started then
    // takes the place it had in the resting field, which every earlier drop already joined.
    for (int k = 0; k < drops; k++) {
        int i = int(e.state.read(uint2(4, k)).x + 0.5);
        float m = meltOf(e, i);
        if (m <= 0.0) continue;
        // The neck strength grows in with the melt, so a drop that has just started still meets
        // its untouched neighbours with the plain union it had at rest.
        d = smin(d, dropPiece(e, i, q), kg * min(1.0, m * 8.0));
    }
    for (int b = 0; b < threads; b++) d = smin(d, bondPiece(e, b, q), kg * e.bonds.read(uint2(3, b)).z);
    if (e.u.counts.y == 3) d = smin(d, strokeField(e, q), e.u.params.y * 1.5);
    return d;
}

// Coverage of the resting field at a pixel. Distance-based coverage is exact along straight
// edges but overestimates sharp corners, so pixels on an edge are sampled 2 x 2, each sample
// with a quarter pixel's filter: exact for straight edges and close to area coverage at corners,
// which is how the vector outline the transition hands off to is antialiased.
float restCoverage(thread const Env& e, float2 q, float d, float pw, bool moving) {
    if (abs(d) >= pw) return clamp(0.5 - d / pw, 0.0, 1.0);
    float sum = 0.0;
    for (int k = 0; k < 4; k++) {
        float2 o = float2((k & 1) != 0 ? 0.25 : -0.25, (k & 2) != 0 ? 0.25 : -0.25) * pw;
        sum += clamp(0.5 - fieldRest(e, q + o, moving) / (0.5 * pw), 0.0, 1.0);
    }
    return sum * 0.25;
}

struct VertexOut { float4 position [[position]]; };

vertex VertexOut qrLiquidVertex(uint vid [[vertex_id]]) {
    float2 corners[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    VertexOut out;
    out.position = float4(corners[vid], 0, 1);
    return out;
}

fragment float4 qrLiquidFragment(VertexOut in [[stage_in]],
                                 texture2d<uint, access::read> info [[texture(0)]],
                                 texture2d<float, access::read> state [[texture(1)]],
                                 texture2d<float, access::read> bonds [[texture(2)]],
                                 texture2d<float, access::read> profile [[texture(3)]],
                                 texture2d<float, access::read> attach [[texture(4)]],
                                 constant Uniforms& u [[buffer(0)]]) {
    Env e = { info, state, bonds, profile, attach, u };
    float n = float(u.counts.x);
    float scale = u.rect.z / (n + 2.0 * u.rect.w);
    float pw = 1.0 / scale;
    float2 q = (in.position.xy - u.rect.xy) * pw - u.rect.w;
    float cov;
    if (u.counts.y == 0) {
        cov = restCoverage(e, q, fieldRest(e, q, false), pw, false);
    } else {
        // While moving the field is not a true distance (smooth-min, deformation), so antialias
        // over its screen-space gradient rather than assuming one unit per pixel.
        float rest;
        float d = min(fieldMercury(e, q, rest), 1e2);
        float g = clamp(length(float2(dfdx(d), dfdy(d))), pw * 0.1, pw * 3.0);
        // Where nothing has moved yet the field is an exact distance: antialias it exactly as at
        // rest (the estimate is wrong across creases and joins), so the first and last frames of
        // a transition are the resting symbol pixel for pixel.
        cov = d >= rest - 1e-5 ? restCoverage(e, q, d, pw, true) : clamp(0.5 - d / g, 0.0, 1.0);
    }
    return u.foreground * cov + u.background * (1.0 - u.foreground.a * cov);
}
"""#
}
