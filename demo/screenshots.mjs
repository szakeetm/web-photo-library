// Takes the README screenshots from a running demo server. Run via take-screenshots.sh.
// usage: node screenshots.mjs <base-url> <out-dir> <upload-dir> [name,name,...]
import { chromium, webkit } from 'playwright';

const [BASE, OUT, UP, ONLY] = process.argv.slice(2);
const only = ONLY?.split(',');
const want = (n) => !only || only.includes(n);
const settle = async (p, ms = 1500) => {
	await p.waitForLoadState('networkidle').catch(() => {});
	await p.waitForTimeout(ms);
};
const shot = (p, n) => p.screenshot({ path: `${OUT}/${n}.png` });
const iPhone = {
	viewport: { width: 390, height: 844 },
	deviceScaleFactor: 2,
	isMobile: true,
	hasTouch: true,
	userAgent:
		'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1'
};
// Album ids follow takeout import order: 1 City Weekend, 2 Coast Trip, 3 Dolomites.

async function openEditor(p, album, index) {
	await p.goto(`${BASE}/albums/${album}`);
	await settle(p);
	await p.locator('.thumb').nth(index).click();
	await settle(p, 2000);
	await p.getByRole('button', { name: 'Edit', exact: true }).click();
	await p.getByRole('dialog', { name: 'Edit photo' }).waitFor();
	await settle(p, 2500);
}

// Desktop: Chromium, headed when an editor shot is wanted (headless Chromium loses the WebGPU device there).
const editorShots = !only || only.some((n) => n.endsWith('-editor'));
const cb = await chromium.launch({ headless: !editorShots, args: ['--enable-unsafe-webgpu'] });
const d = await cb.newPage({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1 });
if (want('desktop-library')) {
	await d.goto(BASE + '/');
	await settle(d, 2500);
	await shot(d, 'desktop-library');
}
if (want('desktop-viewer')) {
	await d.goto(BASE + '/albums/2');
	await settle(d);
	await d.locator('.thumb').nth(9).click();
	await settle(d, 2500);
	await d.getByRole('button', { name: 'Info' }).click();
	await settle(d, 1000);
	await shot(d, 'desktop-viewer');
}
if (want('desktop-editor')) {
	await openEditor(d, 3, 10);
	await d.getByRole('button', { name: 'Auto' }).click();
	await settle(d, 2500);
	await shot(d, 'desktop-editor');
}
if (want('desktop-albums')) {
	await d.goto(BASE + '/albums');
	await settle(d);
	await shot(d, 'desktop-albums');
}
if (want('desktop-search')) {
	await d.goto(BASE + '/search');
	await settle(d);
	await d.locator('input[type=search]').fill('coast');
	await settle(d, 2500);
	await shot(d, 'desktop-search');
}
if (want('desktop-folders')) {
	await d.goto(BASE + '/folders/');
	await settle(d);
	await shot(d, 'desktop-folders');
}
if (want('desktop-settings')) {
	await d.goto(BASE + '/settings');
	await settle(d);
	await shot(d, 'desktop-settings');
}
if (want('desktop-places')) {
	await d.goto(BASE + '/places');
	await settle(d, 4000);
	await shot(d, 'desktop-places');
}
if (want('desktop-people')) {
	await d.goto(BASE + '/people');
	await settle(d, 2500);
	await shot(d, 'desktop-people');
}
if (want('desktop-person')) {
	await d.goto(BASE + '/people');
	await settle(d);
	await d.locator('a.person').first().click();
	await settle(d, 2500);
	await shot(d, 'desktop-person');
}
if (want('desktop-viewer-people')) {
	await d.goto(BASE + '/people');
	await settle(d);
	await d.locator('a.person').first().click();
	await settle(d);
	await d.locator('.thumb').first().click();
	await settle(d, 2000);
	await d.getByRole('button', { name: 'Info' }).click();
	await settle(d, 2000);
	await shot(d, 'desktop-viewer-people');
}
if (want('desktop-objects')) {
	await d.goto(BASE + '/objects');
	await settle(d, 2500);
	await shot(d, 'desktop-objects');
}
if (want('desktop-viewer-objects')) {
	// info open: the recognised objects at the bottom (the zoom slider shows top left)
	await d.goto(BASE + '/albums/2');
	await settle(d);
	await d.locator('.thumb').nth(3).click();
	await settle(d, 2500);
	await d.getByRole('button', { name: 'Info' }).click();
	await settle(d, 1500);
	await d.locator('aside.info').evaluate((el) => el.scrollTo(0, el.scrollHeight));
	await settle(d, 800);
	await shot(d, 'desktop-viewer-objects');
}
if (want('desktop-download')) {
	await d.goto(BASE + '/albums/3');
	await settle(d);
	await d.getByRole('button', { name: 'Select' }).click();
	for (const i of [0, 1, 2, 4]) await d.locator('.thumb').nth(i).click();
	await d.getByRole('button', { name: 'Export', exact: true }).click();
	await settle(d, 800);
	await shot(d, 'desktop-download');
	await d.keyboard.press('Escape');
}
if (want('desktop-filter')) {
	// the title bar's filter and sort menu
	await d.goto(BASE + '/');
	await settle(d, 2000);
	await d.getByRole('button', { name: 'Filter and sort' }).click();
	await settle(d, 600);
	await shot(d, 'desktop-filter');
	await d.keyboard.press('Escape');
}
if (want('desktop-trim')) {
	await d.goto(BASE + '/videos');
	await settle(d);
	await d.locator('.thumb').first().click();
	await settle(d, 2500);
	await d.getByRole('button', { name: 'Trim' }).click();
	await settle(d, 2500);
	await shot(d, 'desktop-trim');
}
if (want('desktop-export')) {
	await d.goto(BASE + '/');
	await settle(d, 2000);
	await d.getByRole('button', { name: 'Export library' }).click();
	await settle(d, 800);
	await d.locator('select').first().selectOption('xmp');
	await d.getByRole('radio', { name: /^Both/ }).check();
	await settle(d, 400);
	await shot(d, 'desktop-export');
	await d.keyboard.press('Escape');
}
if (want('desktop-duplicates')) {
	await d.goto(BASE + '/duplicates');
	await settle(d, 2500);
	await shot(d, 'desktop-duplicates');
}
if (want('desktop-upload')) {
	await d.goto(BASE + '/');
	await settle(d, 2000);
	await d.locator('input[type=file]').first().setInputFiles([`${UP}/IMG_from_phone.jpg`, `${UP}/river-valley.jpg`]);
	await settle(d, 4000);
	await shot(d, 'desktop-upload');
}

// Phone shots are emulated unless PHONE=none (then they're taken in the iOS Simulator instead).
const phone = process.env.PHONE !== 'none';

// Phone editor: Chromium with iPhone emulation (Playwright's WebKit has no WebGPU).
if (phone && want('mobile-editor')) {
	const mctx = await cb.newContext(iPhone);
	await mctx.addInitScript(() => localStorage.setItem('photos.forceRemote', '1'));
	const m = await mctx.newPage();
	await openEditor(m, 2, 12);
	await m.getByRole('button', { name: 'Auto' }).click();
	await settle(m, 2000);
	await m.getByRole('option', { name: 'Vibrance' }).click();
	await settle(m, 1500);
	await shot(m, 'mobile-editor');
}
await cb.close();

// Phone: WebKit (iPhone Safari).
if (!phone) process.exit(0);
const wb = await webkit.launch();
const wctx = await wb.newContext(iPhone);
await wctx.addInitScript(() => localStorage.setItem('photos.forceRemote', '1'));
const m = await wctx.newPage();
if (want('mobile-library')) {
	await m.goto(BASE + '/');
	await settle(m, 2500);
	await shot(m, 'mobile-library');
}
if (want('mobile-viewer')) {
	await m.goto(BASE + '/albums/3');
	await settle(m);
	await m.locator('.thumb').nth(4).click();
	await settle(m, 2500);
	await shot(m, 'mobile-viewer');
}
if (want('mobile-info')) {
	// swipe up on a photo: the info sheet
	await m.goto(BASE + '/albums/3');
	await settle(m);
	await m.locator('.thumb').nth(4).click();
	await settle(m, 2500);
	await m.getByRole('button', { name: 'Info' }).click();
	await settle(m, 1500);
	await shot(m, 'mobile-info');
}
if (want('mobile-albums')) {
	await m.goto(BASE + '/albums');
	await settle(m);
	await shot(m, 'mobile-albums');
}
if (want('mobile-select')) {
	await m.goto(BASE + '/albums/2');
	await settle(m);
	await m.getByRole('button', { name: 'Select' }).click();
	await m.waitForTimeout(400);
	for (const i of [0, 2, 3, 5]) await m.locator('.thumb').nth(i).click();
	await settle(m, 800);
	await shot(m, 'mobile-select');
}
if (want('mobile-places')) {
	await m.goto(BASE + '/places');
	await settle(m, 4000);
	await shot(m, 'mobile-places');
}
if (want('mobile-places-list')) {
	await m.goto(BASE + '/places');
	await settle(m);
	await m.getByRole('tab', { name: 'List' }).click();
	await settle(m, 2000);
	await shot(m, 'mobile-places-list');
	await m.getByRole('tab', { name: 'Map' }).click();
}
if (want('mobile-people')) {
	await m.goto(BASE + '/people');
	await settle(m, 2500);
	await shot(m, 'mobile-people');
}
if (want('mobile-folder')) {
	await m.goto(BASE + '/folders/Dolomites');
	await settle(m, 2500);
	await shot(m, 'mobile-folder');
}
await wb.close();
