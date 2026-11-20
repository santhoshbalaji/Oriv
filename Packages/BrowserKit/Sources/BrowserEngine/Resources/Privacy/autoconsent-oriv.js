// Oriv host bridge for Autoconsent 18.9.0. SPDX-License-Identifier: MIT
if (!globalThis.orivConsentStarted) {
    globalThis.orivConsentStarted = true;
    const bridge = window.webkit.messageHandlers.orivConsent;
    const post = message => bridge.postMessage(message).catch(() => false);
    const { default: AutoConsent, filterCompactRules } = module.exports;
    const compact = filterCompactRules(indexedRules, {
        url: location.href, mainFrame: window === window.top
    });
    let attemptingOptOut = false;
    let fallbackRequested = false;
    let finished = false;
    const fallback = () => {
        if (!finished && !fallbackRequested) {
            fallbackRequested = true;
            void post({ type: 'hide' });
        }
    };
    class RejectConsent extends AutoConsent {
        start() {
            void this._start();
        }

        async _start() {
            try {
                await super._start();
                if (!attemptingOptOut) fallback();
            } catch { fallback(); }
        }

        async handlePopup(cmp) {
            // Upstream starts the opt-out without awaiting it. Mark it before
            // the native permission round trip so fallback cannot hide controls.
            attemptingOptOut = true;
            try {
                if (!await post({ type: "mayReject" })) return false;
                return await super.handlePopup(cmp);
            } catch {
                fallback();
                return false;
            }
        }
    }
    const consent = new RejectConsent(async message => {
        switch (message.type) {
        case 'eval': {
            // Native code looks up a fixed bundled snippet by name. It never
            // evaluates source supplied by a message or by the page.
            const result = message.snippetId
                ? await post({ type: 'eval', snippet: message.snippetId })
                : false;
            await consent.receiveMessageCallback({ type: 'evalResp', id: message.id, result: !!result });
            break;
        }
        case 'autoconsentDone':
            if (!message.isCosmetic) {
                finished = true;
                void post({ type: 'handled', cmp: message.cmp });
            }
            break;
        case 'optOutResult':
            if (!message.result) fallback();
            break;
        }
    });
    consent.initialize({
        autoAction: 'optOut',
        enableCosmeticRules: false,
        enablePrehide: false,
        enableHeuristicDetection: false,
        enablePopupMutationObserver: false,
        heuristicMode: 'off',
        // Upstream waits for a DOM mutation on further retries, which can
        // postpone the fallback on a static page for a full minute.
        detectRetries: 1,
        // A single, fixed opt-out pass. Only explicit upstream recipes can act.
        logs: { errors: false }
    }, { autoconsent: [], compact });
}
