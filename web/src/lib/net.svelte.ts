// Reachability of the server. Offline = a health check timed out/failed or a request couldn't reach the
// server. While offline the app is view-only and retries every 10 s (and when the device comes back online).
import { api, ApiError, onNetworkError, type ServerInfo } from './api';

const RETRY_MS = 10_000;
const TIMEOUT_MS = 2500;

class Net {
	online = $state(true);
	private retry: ReturnType<typeof setInterval> | undefined;
	private reconnect = new Set<() => void>();
	private started = false;

	start() {
		if (this.started || typeof window === 'undefined') return;
		this.started = true;
		onNetworkError(() => this.set(false));
		window.addEventListener('online', () => this.check());
		window.addEventListener('offline', () => this.set(false));
		document.addEventListener('visibilitychange', () => {
			if (document.visibilityState === 'visible' && !this.online) this.check();
		});
	}

	/** Runs `fn` whenever the server becomes reachable again. */
	onReconnect(fn: () => void) {
		this.reconnect.add(fn);
		return () => this.reconnect.delete(fn);
	}

	/** Health check with a short timeout; null when the server can't be reached. */
	async check(): Promise<ServerInfo | null> {
		try {
			const info = await api.health(AbortSignal.timeout(TIMEOUT_MS));
			this.set(true);
			return info;
		} catch (e) {
			if (e instanceof ApiError && e.status < 500) {
				this.set(true);
				throw e;
			}
			this.set(false);
			return null;
		}
	}

	set(online: boolean) {
		if (online === this.online) return;
		this.online = online;
		if (online) {
			clearInterval(this.retry);
			this.retry = undefined;
			for (const fn of this.reconnect) fn();
		} else if (!this.retry) {
			this.retry = setInterval(() => this.check(), RETRY_MS);
		}
	}
}

export const net = new Net();
