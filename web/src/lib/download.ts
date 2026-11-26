// Saving files from the app. In an iPhone/iPad Home Screen app a download (an <a download> link or
// a blob URL) replaces the whole app with iOS's file preview, which has no way back: the app has to
// be force-quit. Opening the URL in a new window doesn't help either (same-origin pages open inside
// the app). There, files go through the share sheet instead (Save Image/Video, Save to Files).

/** An iPhone or iPad. iPadOS reports itself as a Mac, and a touch screen doesn't tell them apart
 * (touchscreen Macs exist), but -webkit-touch-callout is only in iOS's WebKit. */
export const isIOS =
	typeof navigator !== 'undefined' &&
	(/iP(hone|ad|od)/.test(navigator.userAgent) ||
		(/Macintosh/.test(navigator.userAgent) && navigator.maxTouchPoints > 1 && CSS.supports('-webkit-touch-callout', 'none')));

/** Running as an iOS Home Screen app. Not a Mac "Add to Dock" web app: those set navigator.standalone
 * too, but download files normally. */
export const iosStandalone = isIOS && (navigator as Navigator & { standalone?: boolean }).standalone === true;

/** Downloads a file held in memory. Never call it in an iOS Home Screen app (see above). */
export function saveBlob(f: File) {
	const a = document.createElement('a');
	a.href = URL.createObjectURL(f);
	a.download = f.name;
	document.body.appendChild(a);
	a.click();
	a.remove();
	setTimeout(() => URL.revokeObjectURL(a.href), 10_000);
}

/** Downloads a URL (the server sends it as an attachment). Never in an iOS Home Screen app. */
export function downloadUrl(url: string, name = '') {
	const a = document.createElement('a');
	a.href = url;
	a.download = name;
	document.body.appendChild(a);
	a.click();
	a.remove();
}
