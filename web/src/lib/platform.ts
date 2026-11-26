// What the browser and its computer can do, where the app has to say or do something differently.
// The library lives on a Mac, but the browser can be anything: Safari, Chrome, Edge or Firefox, on a
// Mac, a Windows PC, Linux, an iPhone or an Android phone.

const nav = typeof navigator !== 'undefined' ? navigator : undefined;

/** A Mac, iPhone or iPad: shortcuts use ⌘ there, Ctrl everywhere else. */
export const isApple =
	!!nav &&
	/Mac|iPhone|iPad|iPod/.test((nav as Navigator & { userAgentData?: { platform?: string } }).userAgentData?.platform || nav.platform || nav.userAgent);

/** Firefox (it asks the user before granting persistent storage, and can't install web apps on desktop). */
export const isFirefox = !!nav && /Firefox\//.test(nav.userAgent);

/** Chrome or Edge (and other Chromium browsers): Install app, folder export. */
export const isChromium = !!nav && /Chrome\//.test(nav.userAgent) && !isFirefox;

/** The browser's name, for telling the user what it can and can't do. */
export const browserName =
	!nav ? 'this browser'
	: isFirefox ? 'Firefox'
	: /Edg\//.test(nav.userAgent) ? 'Edge'
	: isChromium ? 'Chrome'
	: /Safari\//.test(nav.userAgent) ? 'Safari'
	: 'this browser';

/** A keyboard shortcut as this computer writes it: shortcut('Z') → "⌘Z" on a Mac, "Ctrl+Z" elsewhere;
 *  shortcut('Z', true) → "⇧⌘Z" / "Ctrl+Shift+Z". */
export function shortcut(key: string, shift = false): string {
	return isApple ? `${shift ? '⇧' : ''}⌘${key}` : `Ctrl+${shift ? 'Shift+' : ''}${key}`;
}

/**
 * The browser decodes HEVC (H.265) video, with 10-bit (HDR) too, as iPhones record it. Safari does;
 * Chrome, Edge and Firefox only with the computer's hardware decoder: on Macs and most recent Windows
 * PCs, not on Linux. Without it the server sends H.264 copies instead.
 */
export const playsHevc =
	typeof document !== 'undefined' && document.createElement('video').canPlayType('video/mp4; codecs="hvc1.2.4.L153.B0"') !== '';
