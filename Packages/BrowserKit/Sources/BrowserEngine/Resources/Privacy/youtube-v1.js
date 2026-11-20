// Oriv YouTube v1. SPDX-License-Identifier: MIT
(() => {
    const hosts = ['youtube.com', 'www.youtube.com', 'm.youtube.com', 'music.youtube.com',
        'youtube-nocookie.com', 'www.youtube-nocookie.com'];
    const host = location.hostname.toLowerCase().replace(/\.$/, '');
    if (!/^https?:$/.test(location.protocol) || !hosts.includes(host) ||
        disabledHosts.includes(host) || window.orivYouTubeProtection) return;

    const adFields = ['adPlacements', 'playerAds', 'adSlots', 'adBreakHeartbeatParams',
        'adBreakParams', 'playerAdParams', 'adTrackingParams'];
    const parse = JSON.parse;
    const stringify = JSON.stringify;
    function prune(root) {
        if (!root || typeof root !== 'object') return false;
        const visited = new WeakSet();
        const pending = [root];
        let changed = false;
        while (pending.length) {
            const value = pending.pop();
            if (visited.has(value)) continue;
            visited.add(value);
            for (const key of Object.keys(value)) {
                if (adFields.includes(key)) {
                    changed = Reflect.deleteProperty(value, key) || changed;
                } else {
                    const child = Object.getOwnPropertyDescriptor(value, key)?.value;
                    if (child && typeof child === 'object') pending.push(child);
                }
            }
        }
        return changed;
    }
    function pruneInline(value) {
        // Inline assignments are normally JSON literals. Avoid traversing arbitrary
        // objects supplied by a page, including cyclic objects and live proxies.
        try { prune(value); } catch {}
        return value;
    }
    function installInlineTrap(name) {
        const existing = Object.getOwnPropertyDescriptor(window, name);
        if (existing && (!existing.configurable || !existing.writable)) return false;
        let value = pruneInline(existing?.value);
        Object.defineProperty(window, name, {
            configurable: true,
            enumerable: existing?.enumerable ?? true,
            get: () => value,
            set: next => { value = pruneInline(next); }
        });
        return true;
    }
    function matches(raw) {
        try {
            const url = new URL(raw, location.href);
            return /^https?:$/.test(url.protocol) && hosts.includes(url.hostname) &&
                /^(?:\/youtubei\/v1\/(?:player|next|browse|search|reel(?:\/[a-z_]+)?|get_watch)|\/get_watch)\/?$/.test(url.pathname);
        } catch { return false; }
    }
    function pruneText(text) {
        try {
            const data = parse(text);
            return prune(data) ? stringify(data) : text;
        } catch { return text; }
    }

    const inline = ['ytInitialPlayerResponse', 'ytInitialData'].map(installInlineTrap);
    const marked = new WeakSet();
    const asJSON = Response.prototype.json;
    const asText = Response.prototype.text;
    const clone = Response.prototype.clone;
    const nativeFetch = window.fetch;
    // Mark only successful JSON responses from known endpoints. Preserve the
    // original Response (status, headers, URL and streaming body) and request.
    window.fetch = new Proxy(nativeFetch, {
        apply(target, receiver, args) {
            const result = Reflect.apply(target, receiver, args);
            return result.then(response => {
                if (response.ok && matches(response.url) &&
                    /\b(?:json|\w+\+json)\b/i.test(response.headers.get('content-type') ?? '')) marked.add(response);
                return response;
            });
        }
    });
    Response.prototype.json = new Proxy(asJSON, {
        apply(target, receiver, args) {
            const result = Reflect.apply(target, receiver, args);
            if (!marked.has(receiver)) return result;
            return result.then(data => {
                try { prune(data); } catch {}
                return data;
            });
        }
    });
    Response.prototype.text = new Proxy(asText, {
        apply(target, receiver, args) {
            const result = Reflect.apply(target, receiver, args);
            return marked.has(receiver) ? result.then(pruneText) : result;
        }
    });
    Response.prototype.clone = new Proxy(clone, {
        apply(target, receiver, args) {
            const copy = Reflect.apply(target, receiver, args);
            if (marked.has(receiver)) marked.add(copy);
            return copy;
        }
    });

    const xhr = XMLHttpRequest.prototype;
    const completed = new WeakMap();
    function xhrValue(request, value) {
        if (request.readyState !== 4 || request.status < 200 || request.status >= 300 ||
            !matches(request.responseURL)) return value;
        if (request.responseType === 'json') {
            try { prune(value); } catch {}
        } else if (typeof value === 'string') {
            const cached = completed.get(request);
            if (cached?.original === value) return cached.filtered;
            const filtered = pruneText(value);
            completed.set(request, { original: value, filtered });
            return filtered;
        }
        return value;
    }
    for (const name of ['response', 'responseText']) {
        const descriptor = Object.getOwnPropertyDescriptor(xhr, name);
        Object.defineProperty(xhr, name, {
            ...descriptor,
            get() { return xhrValue(this, Reflect.apply(descriptor.get, this, [])); }
        });
    }

    const addStyle = () => {
        const sheet = new CSSStyleSheet();
        sheet.replaceSync([
            '#masthead-ad', 'ytd-ad-slot-renderer', 'ytm-ad-slot-renderer',
            'ytd-promoted-sparkles-web-renderer', 'ytd-search-pyv-renderer',
            'ytd-display-ad-renderer', 'ytm-promoted-sparkles-web-renderer',
            'ytd-in-feed-ad-layout-renderer', 'ytd-reel-video-renderer[is-ad]',
            'ytm-reel-video-renderer[is-ad]', '#player-ads'
        ].join(',') + '{display:none!important}');
        document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
    };
    if (document.documentElement) addStyle();
    else document.addEventListener('DOMContentLoaded', addStyle, { once: true });

    if (skipAds) {
        // Only click YouTube's explicit skip control while its player says an
        // ad is playing. Never change playback position, rate or audio.
        const skip = () => {
            const button = document.querySelector('.html5-video-player.ad-showing .ytp-skip-ad-button,' +
                '.html5-video-player.ad-showing .ytp-ad-skip-button-modern');
            if (button?.getClientRects().length && !button.disabled && button.getAttribute('aria-disabled') !== 'true') button.click();
        };
        document.addEventListener('timeupdate', skip, true);
    }

    const sample = { adPlacements: [{}], playerResponse: { adSlots: [], streamingData: { marker: true } } };
    const passed = prune(sample) && !('adPlacements' in sample) && !('adSlots' in sample.playerResponse) &&
        sample.playerResponse.streamingData.marker === true;
    Object.defineProperty(window, 'orivYouTubeProtection', {
        value: Object.freeze({ version: 1, selfTest: passed && inline.every(Boolean) })
    });
})();
