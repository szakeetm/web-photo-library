// Opt-in on-screen log of touch, pointer and gesture events in the photo viewer, for diagnosing
// pinch/swipe problems on a phone without a cable. Turn on with ?debug=gestures (or Settings → About),
// off with ?debug=off. Stored per device.
const KEY = 'debug-gestures';

function initial(): boolean {
	try {
		const q = new URLSearchParams(location.search).get('debug');
		if (q === 'gestures') localStorage.setItem(KEY, '1');
		else if (q === 'off') localStorage.removeItem(KEY);
		return localStorage.getItem(KEY) === '1';
	} catch {
		return false;
	}
}

class GestureDebug {
	enabled = $state(typeof location !== 'undefined' ? initial() : false);

	set(on: boolean) {
		this.enabled = on;
		try {
			if (on) localStorage.setItem(KEY, '1');
			else localStorage.removeItem(KEY);
		} catch {
			/* private mode: for this session only */
		}
	}
}

export const gestureDebug = new GestureDebug();
