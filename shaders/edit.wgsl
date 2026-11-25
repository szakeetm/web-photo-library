// Photo edit pipeline — the single source of truth for how an edit looks.
// The browser runs this file with WebGPU; the server runs the same code translated to Metal by naga
// (scripts/gen-shaders.sh). Hosts only copy recipe numbers into `P`; all edit math lives here.
//
// Passes (fullscreen triangle each):
//   fs_luma     source → small luminance image (fixed 256 px long edge, resolution independent)
//   fs_blur ×2  separable Gaussian on the luminance image (direction in P.v[7].xy)
//   fs_develop  geometry + tone + colour, writes the output image
//
// Colour: the source texture holds Display-P3-encoded values (sRGB transfer curve); the output is
// Display-P3-encoded too. Light maths happens in linear P3.

struct Params {
    // v[0]  outW, outH, srcW, srcH          (pixels)
    // v[1]  crop x, y, w, h                 (normalised to the rotated/flipped frame)
    // v[2]  straighten (degrees), quarter turns clockwise (0..3), flipH (0/1), flipV (0/1)
    // v[3]  exposure (EV, -3..3), brilliance, highlights, shadows   (-1..1)
    // v[4]  brightness, contrast, black point, saturation           (-1..1)
    // v[5]  vibrance, warmth, tint, vignette                        (-1..1)
    // v[6]  sharpen (0..1), curve point count (0 or 2..16), -, -
    // v[7]  blur direction x, y (luma texels), lumaW, lumaH
    // v[8..15] tone curve points: (x0, y0, x1, y1) per vec4, x ascending, 0..1
    v: array<vec4<f32>, 16>,
}

@group(0) @binding(0) var<uniform> P: Params;
@group(0) @binding(1) var src: texture_2d<f32>;
@group(0) @binding(2) var samp: sampler;
@group(0) @binding(3) var luma: texture_2d<f32>;

struct VOut {
    @builtin(position) pos: vec4<f32>,
}

@vertex
fn vs_main(@builtin(vertex_index) i: u32) -> VOut {
    // One triangle covering the viewport.
    let x = f32((i << 1u) & 2u);
    let y = f32(i & 2u);
    var o: VOut;
    o.pos = vec4<f32>(x * 2.0 - 1.0, 1.0 - y * 2.0, 0.0, 1.0);
    return o;
}

const LUMA_W = vec3<f32>(0.2289746, 0.6917385, 0.0792869); // Display P3 luminance

fn to_linear(c: vec3<f32>) -> vec3<f32> {
    let lo = c / 12.92;
    let hi = pow((c + 0.055) / 1.055, vec3<f32>(2.4));
    return select(hi, lo, c <= vec3<f32>(0.04045));
}

fn to_encoded(c: vec3<f32>) -> vec3<f32> {
    let x = max(c, vec3<f32>(0.0));
    let lo = x * 12.92;
    let hi = 1.055 * pow(x, vec3<f32>(1.0 / 2.4)) - 0.055;
    return select(hi, lo, x <= vec3<f32>(0.0031308));
}

// ---------------------------------------------------------------------------------------------
// Pass 1: luminance image

@fragment
fn fs_luma(in: VOut) -> @location(0) vec4<f32> {
    let lumaSize = P.v[7].zw;
    let uv0 = (in.pos.xy - 0.5) / lumaSize;      // top-left of this texel's footprint
    let step = 1.0 / (lumaSize * 4.0);
    var sum = 0.0;
    for (var j = 0; j < 4; j++) {
        for (var i = 0; i < 4; i++) {
            let uv = uv0 + (vec2<f32>(f32(i), f32(j)) + 0.5) * step;
            let c = textureSampleLevel(src, samp, uv, 0.0).rgb;
            sum += dot(to_linear(c), LUMA_W);
        }
    }
    let y = sum / 16.0;
    return vec4<f32>(y, y, y, 1.0);
}

// ---------------------------------------------------------------------------------------------
// Pass 2: separable Gaussian (sigma 6 luma texels, ±18 taps), exact texel loads

@fragment
fn fs_blur(in: VOut) -> @location(0) vec4<f32> {
    let dir = vec2<i32>(P.v[7].xy);
    let size = vec2<i32>(P.v[7].zw);
    let p = vec2<i32>(in.pos.xy);
    var sum = 0.0;
    var wsum = 0.0;
    for (var k = -18; k <= 18; k++) {
        let q = clamp(p + dir * k, vec2<i32>(0), size - 1);
        let w = exp(-f32(k * k) / 72.0);
        sum += textureLoad(luma, q, 0).r * w;
        wsum += w;
    }
    let y = sum / wsum;
    return vec4<f32>(y, y, y, 1.0);
}

// ---------------------------------------------------------------------------------------------
// Pass 3: develop

/// Output pixel (normalised) → source texture coordinate. Outside 0..1 means "no image here".
fn source_uv(uv: vec2<f32>) -> vec2<f32> {
    let srcSize = P.v[0].zw;
    let turns = i32(P.v[2].y + 0.5);
    let odd = (turns & 1) == 1;
    let frame = select(srcSize, srcSize.yx, odd);
    // crop → frame (pixels, centred)
    let crop = P.v[1];
    let f = (crop.xy + uv * crop.zw) * frame - frame * 0.5;
    // undo straighten (the image was turned by +angle, clockwise on screen)
    let a = radians(P.v[2].x);
    let c = cos(a);
    let s = sin(a);
    var q = vec2<f32>(c * f.x + s * f.y, -s * f.x + c * f.y) / frame + 0.5;
    // undo flips
    if (P.v[2].z > 0.5) { q.x = 1.0 - q.x; }
    if (P.v[2].w > 0.5) { q.y = 1.0 - q.y; }
    // undo clockwise quarter turns: rotated (x, y) came from source (y, 1 - x)
    for (var k = 0; k < turns; k++) {
        q = vec2<f32>(q.y, 1.0 - q.x);
    }
    return q;
}

fn curve_point(i: i32) -> vec2<f32> {
    let v = P.v[8 + i / 2];
    return select(v.xy, v.zw, (i & 1) == 1);
}

/// Slope at point i of the monotone cubic (Fritsch–Butland harmonic mean; one-sided at the ends).
fn curve_slope(i: i32, n: i32) -> f32 {
    if (i == 0) {
        let a = curve_point(0);
        let b = curve_point(1);
        return (b.y - a.y) / max(b.x - a.x, 1e-6);
    }
    if (i == n - 1) {
        let a = curve_point(n - 2);
        let b = curve_point(n - 1);
        return (b.y - a.y) / max(b.x - a.x, 1e-6);
    }
    let p0 = curve_point(i - 1);
    let p1 = curve_point(i);
    let p2 = curve_point(i + 1);
    let h0 = max(p1.x - p0.x, 1e-6);
    let h1 = max(p2.x - p1.x, 1e-6);
    let d0 = (p1.y - p0.y) / h0;
    let d1 = (p2.y - p1.y) / h1;
    if (d0 * d1 <= 0.0) { return 0.0; }
    return 3.0 * (h0 + h1) / ((2.0 * h1 + h0) / d0 + (h1 + 2.0 * h0) / d1);
}

fn tone_curve(x: f32, n: i32) -> f32 {
    let first = curve_point(0);
    let last = curve_point(n - 1);
    if (x <= first.x) { return first.y; }
    if (x >= last.x) { return last.y; }
    var i = 0;
    for (var k = 0; k < n - 1; k++) {
        if (x >= curve_point(k).x) { i = k; }
    }
    let a = curve_point(i);
    let b = curve_point(i + 1);
    let h = max(b.x - a.x, 1e-6);
    let t = (x - a.x) / h;
    let m0 = curve_slope(i, n) * h;
    let m1 = curve_slope(i + 1, n) * h;
    let t2 = t * t;
    let t3 = t2 * t;
    let y = (2.0 * t3 - 3.0 * t2 + 1.0) * a.y + (t3 - 2.0 * t2 + t) * m0 + (-2.0 * t3 + 3.0 * t2) * b.y + (t3 - t2) * m1;
    return clamp(y, 0.0, 1.0);
}

/// Symmetric S-curve around 0.5 that keeps 0 and 1 fixed (k > 1 adds contrast).
fn contrast_curve(p: f32, k: f32) -> f32 {
    let x = clamp(p, 0.0, 1.0);
    if (x < 0.5) { return 0.5 * pow(2.0 * x, k); }
    return 1.0 - 0.5 * pow(2.0 * (1.0 - x), k);
}

@fragment
fn fs_develop(in: VOut) -> @location(0) vec4<f32> {
    let outSize = P.v[0].xy;
    let srcSize = P.v[0].zw;
    let uv = in.pos.xy / outSize;
    let s = source_uv(uv);
    if (any(s < vec2<f32>(0.0)) || any(s > vec2<f32>(1.0))) {
        return vec4<f32>(0.0, 0.0, 0.0, 1.0);
    }
    let raw = textureSampleLevel(src, samp, s, 0.0).rgb;

    let exposure = P.v[3].x;
    let brilliance = P.v[3].y;
    let highlights = P.v[3].z;
    let shadows = P.v[3].w;
    let brightness = P.v[4].x;
    let contrast = P.v[4].y;
    let blackPoint = P.v[4].z;
    let saturation = P.v[4].w;
    let vibrance = P.v[5].x;
    let warmth = P.v[5].y;
    let tint = P.v[5].z;
    let vignette = P.v[5].w;
    let sharpen = P.v[6].x;
    let curveN = i32(P.v[6].y + 0.5);

    // Sharpen (unsharp mask on the encoded source; radius ≈ 1 px at 2048 px, scaled with size)
    var enc = raw;
    if (sharpen > 0.0) {
        let r = max(1.0, max(srcSize.x, srcSize.y) / 2048.0) / srcSize;
        let n = textureSampleLevel(src, samp, s + vec2<f32>(r.x, 0.0), 0.0).rgb
              + textureSampleLevel(src, samp, s - vec2<f32>(r.x, 0.0), 0.0).rgb
              + textureSampleLevel(src, samp, s + vec2<f32>(0.0, r.y), 0.0).rgb
              + textureSampleLevel(src, samp, s - vec2<f32>(0.0, r.y), 0.0).rgb;
        let detail = dot(raw - n * 0.25, LUMA_W);
        enc = raw + vec3<f32>(detail * sharpen * 1.5);
    }

    var c = to_linear(clamp(enc, vec3<f32>(0.0), vec3<f32>(1.0)));

    // Exposure
    let gain = exp2(exposure);
    c *= gain;

    // White balance: warm = more red, less blue; tint + = magenta. Luminance preserved.
    let wb = vec3<f32>(1.0 + 0.25 * warmth, 1.0 - 0.18 * tint, 1.0 - 0.25 * warmth);
    c *= wb / dot(wb, LUMA_W);

    // Local tone (shadows / highlights / brilliance) from the blurred luminance around this pixel
    let local = max(textureSampleLevel(luma, samp, s, 0.0).r * gain, 0.0);
    let y = dot(c, LUMA_W);
    // Mostly the neighbourhood's level, partly the pixel's own: softens halos at hard edges.
    let lp = sqrt(mix(local, max(y, 0.0), 0.35));
    let shadowW = 1.0 - smoothstep(0.0, 0.55, lp);
    let highW = smoothstep(0.35, 1.0, lp);
    let stops = shadows * 1.6 * shadowW + highlights * 1.4 * highW + brilliance * (0.9 * shadowW - 0.7 * highW);
    c *= exp2(stops);
    if (brilliance != 0.0) {
        let ratio = (y + 0.01) / (local + 0.01);
        c *= pow(ratio, 0.22 * brilliance);
    }

    // Display-referred adjustments in encoded space
    var p = to_encoded(c);
    p = clamp(p, vec3<f32>(0.0), vec3<f32>(1.0));
    // brightness: midtone gamma
    p = pow(p, vec3<f32>(exp2(-0.75 * brightness)));
    // contrast: S-curve
    let k = exp2(1.1 * contrast);
    p = vec3<f32>(contrast_curve(p.r, k), contrast_curve(p.g, k), contrast_curve(p.b, k));
    // black point
    let bp = 0.12 * blackPoint;
    p = clamp((p - bp) / (1.0 - bp), vec3<f32>(0.0), vec3<f32>(1.0));
    // tone curve
    if (curveN >= 2) {
        p = vec3<f32>(tone_curve(p.r, curveN), tone_curve(p.g, curveN), tone_curve(p.b, curveN));
    }

    // Saturation and vibrance
    let yp = dot(p, LUMA_W);
    let chroma = max(max(p.r, p.g), p.b) - min(min(p.r, p.g), p.b);
    let satGain = (1.0 + saturation) * (1.0 + vibrance * (1.0 - clamp(chroma * 1.5, 0.0, 1.0)));
    p = vec3<f32>(yp) + (p - vec3<f32>(yp)) * satGain;

    // Vignette (on the output frame)
    if (vignette != 0.0) {
        let aspect = outSize.x / outSize.y;
        let d = length((uv - 0.5) * vec2<f32>(aspect, 1.0)) / length(vec2<f32>(aspect, 1.0) * 0.5);
        let v = smoothstep(0.35, 1.05, d);
        // positive darkens the edges, negative lightens them
        p = select(mix(p, vec3<f32>(1.0), -vignette * 0.8 * v), p * (1.0 - vignette * 0.9 * v), vignette > 0.0);
    }

    return vec4<f32>(clamp(p, vec3<f32>(0.0), vec3<f32>(1.0)), 1.0);
}
