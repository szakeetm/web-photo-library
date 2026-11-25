// Tone curve evaluation for drawing the curve editor — the same monotone cubic as tone_curve() in
// shaders/edit.wgsl (the shader is what renders; this only draws the line).
export type Point = [number, number];

function slope(p: Point[], i: number): number {
	const n = p.length;
	if (i === 0) return (p[1][1] - p[0][1]) / Math.max(p[1][0] - p[0][0], 1e-6);
	if (i === n - 1) return (p[n - 1][1] - p[n - 2][1]) / Math.max(p[n - 1][0] - p[n - 2][0], 1e-6);
	const h0 = Math.max(p[i][0] - p[i - 1][0], 1e-6);
	const h1 = Math.max(p[i + 1][0] - p[i][0], 1e-6);
	const d0 = (p[i][1] - p[i - 1][1]) / h0;
	const d1 = (p[i + 1][1] - p[i][1]) / h1;
	if (d0 * d1 <= 0) return 0;
	return (3 * (h0 + h1)) / ((2 * h1 + h0) / d0 + (h1 + 2 * h0) / d1);
}

export function evalCurve(p: Point[], x: number): number {
	const n = p.length;
	if (n < 2) return x;
	if (x <= p[0][0]) return p[0][1];
	if (x >= p[n - 1][0]) return p[n - 1][1];
	let i = 0;
	for (let k = 0; k < n - 1; k++) if (x >= p[k][0]) i = k;
	const [ax, ay] = p[i];
	const [bx, by] = p[i + 1];
	const h = Math.max(bx - ax, 1e-6);
	const t = (x - ax) / h;
	const m0 = slope(p, i) * h;
	const m1 = slope(p, i + 1) * h;
	const t2 = t * t;
	const t3 = t2 * t;
	const y = (2 * t3 - 3 * t2 + 1) * ay + (t3 - 2 * t2 + t) * m0 + (-2 * t3 + 3 * t2) * by + (t3 - t2) * m1;
	return Math.min(1, Math.max(0, y));
}

export const IDENTITY_CURVE: Point[] = [
	[0, 0],
	[1, 1]
];
