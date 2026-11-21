#!/usr/bin/env python3
"""Synthetic native-test fixtures, bound to loopback by default. No credentials."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, urlsplit
from pathlib import Path
import re
import argparse
import html
import json
import time

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / 'scripts' / 'fixtures'
MEDIA = ROOT / 'build' / 'media-fixtures'

PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>{title}</title>
<style>body{{font:18px -apple-system,sans-serif;max-width:800px;margin:70px auto;padding:24px;color:#172536;background:#f7f9fc}}h1{{font-size:44px}}a{{color:#246bce}}input,button{{font:inherit;padding:10px}}section{{margin:28px 0;padding:24px;background:white;border-radius:12px}}nav{{display:flex;gap:24px}}</style></head>
<body><p>Personal Browser · Local test page</p><h1>{title}</h1>{body}</body></html>"""

class Handler(BaseHTTPRequestHandler):
    privacy_destination_requests = 0
    privacy_destination_runs = {}
    favicon_requests = {}

    def do_CONNECT(self):
        # A synthetic origin for the CNAME integration test. Never open an
        # upstream connection. Only these fixture hosts may enter the tunnel.
        if self.path not in ('analytics.airtm.com:80', 'analytics.sixt.com:80', 'analytics.seagate.com:80'):
            self.send_error(403)
            return
        self.send_response_only(200, 'Connection Established')
        self.end_headers()
        self.handle_one_request()

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == '/cname-page':
            self.send_bytes(b"""
                <title>CNAME fixture</title>
                <script src="/cname-probe.js" onload="window.probe = 'loaded'"
                        onerror="window.probe = 'blocked'"></script>
            """, 'text/html; charset=utf-8', no_store=True)
            return
        if path == '/cname-probe.js':
            self.send_bytes(b'window.cnameProbeRan = true;', 'text/javascript; charset=utf-8', no_store=True)
            return
        if path == '/github-favicon':
            self.send_bytes((FIXTURES / 'github-favicon.html').read_bytes(), 'text/html; charset=utf-8', no_store=True)
            return
        if path == '/github-favicon.png':
            artwork = ROOT / 'Apps/Shared/Resources/Assets.xcassets/OrivMark.imageset/OrivMark.png'
            self.send_bytes(artwork.read_bytes(), 'image/png')
            return
        if path in ('/github-favicon.svg', '/github-favicon-dark.svg', '/github-mask.svg'):
            # The preferred SVG contains no paint. The other candidates have
            # visible black artwork, distinguishable from the PNG fallback.
            paint = b'' if path == '/github-favicon.svg' else b'<rect width="32" height="32" fill="black"/>'
            svg = b'<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32">' + paint + b'</svg>'
            self.send_bytes(svg, 'image/svg+xml')
            return
        if path == '/favicon-page':
            run = parse_qs(urlsplit(self.path).query).get('run', [''])[0]
            icon = '/favicon-redirect?run=' + quote(run, safe='')
            body = f'<html><head><title>Favicon fixture</title><link rel="icon" href="{icon}"></head><body><h1>Site icon</h1><input value="Keyboard fixture"></body></html>'.encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Set-Cookie', 'oriv-icon=allowed; Path=/; SameSite=Lax')
            self.end_headers(); self.wfile.write(body)
            return
        if path in ('/favicon-redirect', '/favicon-image.svg', '/favicon-requests'):
            run = parse_qs(urlsplit(self.path).query).get('run', [''])[0]
            if path == '/favicon-requests':
                self.send_bytes(json.dumps(Handler.favicon_requests.pop(run, [])).encode(), 'application/json', no_store=True)
                return
            headers = {name: self.headers.get(name) for name in ('User-Agent', 'Cookie', 'Authorization', 'Referer')}
            if run:
                Handler.favicon_requests.setdefault(run, []).append({'path': path, **headers})
            if any(headers[name] is not None for name in ('Cookie', 'Authorization', 'Referer')):
                self.send_error(403); return
            if path == '/favicon-redirect':
                self.send_response(302)
                self.send_header('Location', '/favicon-image.svg?run=' + quote(run, safe=''))
                self.send_header('Set-Cookie', 'oriv-icon-redirect=blocked; Path=/')
                self.send_header('Content-Length', '0')
                self.end_headers()
                return
            self.send_bytes(b'<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128"><rect width="128" height="128" rx="24" fill="#217f67"/><path d="M28 64L54 90L102 38" stroke="white" stroke-width="13" fill="none"/></svg>', 'image/svg+xml')
            return
        if path == '/ads-front.min.js':
            self.send_bytes(b'window.shippingTrackerLoaded=true;', 'text/javascript', no_store=True)
            return
        if path == '/privacy-stats':
            run = parse_qs(urlsplit(self.path).query).get('run', [None])[0]
            count = Handler.privacy_destination_requests if run is None else Handler.privacy_destination_runs.get(run, 0)
            self.send_bytes(json.dumps({'destinationRequests': count}).encode(), 'application/json', no_store=True)
            return
        if path == '/private-cookie-fixture':
            self.page('Private cookie fixture', '<main><h1>Private cookie fixture</h1></main>')
            return
        if path in {'/consent', '/youtube-protection'}:
            self.send_bytes((FIXTURES / (path[1:] + '.html')).read_bytes(), 'text/html; charset=utf-8')
            return
        if path.startswith('/youtubei/v1/') or path in {'/get_watch', '/youtube-fixture-unmatched'}:
            query = parse_qs(urlsplit(self.path).query)
            if 'malformed' in query:
                payload = b'{invalid'
            elif 'unmodified' in query:
                payload = b' { "keep": 42 } '
            else:
                payload = b'{"adSlots":[],"keep":42,"playerResponse":{"adPlacements":[{}],"streamingData":{"itag":18}}}'
            self.send_bytes(payload, 'application/json')
            return
        if path == '/privacy':
            self.send_bytes((FIXTURES / 'privacy.html').read_text().replace(':8768', ':' + str(self.server.server_port)).replace('__GPC__', json.dumps(self.headers.get('Sec-GPC'))).encode(), 'text/html; charset=utf-8')
            return
        if path == '/privacy-script.js':
            self.send_bytes(('window.privacyScriptHeader=' + json.dumps(self.headers.get('Sec-GPC'))).encode(), 'text/javascript')
            return
        if path == '/privacy-frame':
            self.send_bytes(('<html><script>window.frameHeader=' + json.dumps(self.headers.get('Sec-GPC')) + '</script></html>').encode(), 'text/html; charset=utf-8')
            return
        if path == '/privacy-checkout':
            self.page('Checkout fixture', '<form><label>Order<input name="order" value="synthetic"></label><button type="button">Review order</button></form>')
            return
        if path == '/privacy-headers':
            self.send_bytes(json.dumps({'gpc': self.headers.get('Sec-GPC'), 'path': self.path}).encode(), 'application/json')
            return
        if path == '/privacy-destination':
            Handler.privacy_destination_requests += 1
            run = parse_qs(urlsplit(self.path).query).get('run', [''])[0][:64]
            Handler.privacy_destination_runs[run] = Handler.privacy_destination_runs.get(run, 0) + 1
            self.send_bytes(PAGE.format(title='Privacy destination', body='<h2 id="destination">Explicit destination load</h2>').encode(), 'text/html; charset=utf-8', no_store=True)
            return
        if path == '/tab-switch':
            query = parse_qs(urlsplit(self.path).query)
            try: delay = min(2, max(0, float(query.get('delay', ['0'])[0])))
            except ValueError: delay = 0
            time.sleep(delay)
            tiles = ''.join(f'<section>Fixture tile {i}</section>' for i in range(4000 if query.get('heavy') == ['1'] else 12))
            self.send_bytes(('<!doctype html><meta name="viewport" content="width=device-width"><title>Tab switch fixture</title>'
                '<style>body{margin:0;background:#d4e8c8;color:#172d22;font:24px system-ui}main{padding:40px}section{padding:16px;margin:10px;border:2px solid #246b50}</style>'
                '<main><h1>Tab switch fixture</h1>' + tiles + '</main>').encode(), 'text/html; charset=utf-8', no_store=True)
            return
        if path == '/chrome-revisit':
            placeholder = parse_qs(urlsplit(self.path).query).get('stage') == ['placeholder']
            color = '#1d1d1f' if placeholder else '#161617'
            first = ('<html><head><meta name="viewport" content="width=device-width"><title>Revisit paint</title><style>body{margin:0;background:'+color+';color:white}header{position:fixed;top:0;width:100%;height:64px;background:'+color+'}main{padding:90px 20px;min-height:2000px}</style></head><body><header>Revisit header</header><main>Streaming paint fixture</main>').encode()
            last = b"<script>document.body.style.background='#161617';document.querySelector('header').style.background='#161617';document.title='Revisit ready'</script></body></html>"
            self.send_response(200); self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(first)+len(last))); self.end_headers()
            self.wfile.write(first); self.wfile.flush()
            if placeholder: time.sleep(0.4)
            self.wfile.write(last)
            return
        if path == '/chrome-paint':
            try: first_byte_delay = min(2, max(0, float(parse_qs(urlsplit(self.path).query).get('firstByteDelay', ['0'])[0])))
            except ValueError: first_byte_delay = 0
            if first_byte_delay: time.sleep(first_byte_delay)
            delay = parse_qs(urlsplit(self.path).query).get('delay', ['1.5'])[0]
            body = '<html><head><meta name="viewport" content="width=device-width"><style>body{margin:0;background:#6300dd;color:white}header{position:fixed;top:0;width:100%;height:64px;background:#6300dd}main{padding:90px 20px;height:3000px}</style></head><body><header>Paint timing fixture</header><main>Visible before the delayed image<img src="/chrome-slow-image?delay=' + quote(delay, safe='') + '"></main></body></html>'
            self.send_bytes(body.encode(), 'text/html; charset=utf-8')
            return
        if path in ('/swipe-dark', '/swipe-light'):
            dark = path == '/swipe-dark'
            title = 'Dark swipe page' if dark else 'Light swipe page'
            background, foreground = ('#10151b', '#f7f6f2') if dark else ('#f7f6f2', '#10151b')
            body = f'''<!doctype html><html><head><meta name="viewport" content="width=device-width">
            <title>{title}</title><style>body{{margin:0;background:{background};color:{foreground};font:20px system-ui}}
            header{{position:fixed;top:0;width:100%;height:64px;background:{background}}}
            main{{padding:90px 24px;min-height:1600px}}section{{height:120px;border:4px solid currentColor;margin:30px 0}}
            </style></head><body><header>Stable viewport fixture</header><main><h1>{title}</h1>
            <section>ONE</section><section>TWO</section><section>THREE</section></main></body></html>'''
            self.send_bytes(body.encode(), 'text/html; charset=utf-8')
            return
        if path == '/chrome-slow-image':
            try: delay = min(30, max(0, float(parse_qs(urlsplit(self.path).query).get('delay', ['1.5'])[0])))
            except ValueError: delay = 1.5
            time.sleep(delay)
            self.send_bytes((ROOT / 'Apps/Shared/Resources/Assets.xcassets/OrivMark.imageset/OrivMark.png').read_bytes(), 'image/png')
            return
        if path == '/standards-worker.js':
            body = b'''self.addEventListener('install', event => event.waitUntil(self.skipWaiting()));
            self.addEventListener('activate', event => event.waitUntil(self.clients.claim()));
            self.addEventListener('message', event => event.waitUntil((async () => {
              const cache = await caches.open('oriv-worker-regression');
              await cache.put('/worker-result', new Response('worker-cache-ok'));
              event.ports[0].postMessage(await (await cache.match('/worker-result')).text());
            })()));'''
            self.send_bytes(body, 'text/javascript')
            return
        if path == '/data-navigation':
            self.send_bytes((FIXTURES / 'data-navigation.html').read_bytes(), 'text/html; charset=utf-8')
            return
        if path == '/standards':
            self.send_bytes((FIXTURES / 'standards.html').read_bytes(), 'text/html; charset=utf-8')
            return
        if path == '/standards-data':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            if parse_qs(urlsplit(self.path).query).get('cors') == ['1']:
                self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(b'{"ok":true}')
            return
        if path == '/standards-csp':
            body = b'<html><title>CSP fixture</title><script>window.blockedScriptExecuted=true</script><h1>Content policy</h1></html>'
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.send_header('Content-Security-Policy', "default-src 'none'; script-src 'none'")
            self.send_header('Content-Length', str(len(body)))
            self.end_headers(); self.wfile.write(body)
            return
        if path == '/gestures':
            self.send_bytes((FIXTURES / 'gestures.html').read_bytes(), 'text/html; charset=utf-8')
            return
        if path == '/short-gestures':
            self.send_bytes(b'<html><meta name="viewport" content="width=device-width"><title>Short Gesture Page</title><body><h1>Short page</h1><a href="/gestures">Gesture Lab</a><p>Pull to refresh this short page.</p><p id="loaded"></p><script>document.getElementById("loaded").textContent="Loaded "+new Date().toLocaleTimeString()</script></body></html>', 'text/html; charset=utf-8')
            return
        if path == '/gesture-image.png':
            self.send_bytes((ROOT / 'Apps/Shared/Resources/Assets.xcassets/OrivMark.imageset/OrivMark.png').read_bytes(), 'image/png')
            return
        if path == '/history-redirect':
            self.send_response(302)
            self.send_header('Location', '/quality')
            self.end_headers()
            return
        if path == '/history-error':
            body = b'<!doctype html><title>Missing history fixture</title>'
            self.send_response(404)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if path == '/quality':
            self.page('Browser quality fixture', '<article><h2>Quiet browser testing</h2><p>Alpha beta Alpha. Search, read and save this synthetic page.</p><p>No personal information is used.</p><input id="draft" aria-label="Test draft"><a href="/two" target="_blank" id="new-tab">Open second tab</a><a href="/large-download">Download test data</a></article>')
            return
        if path == '/tab-memory-history':
            self.page('Tab history fixture', '<article style="min-height:6000px"><h2>History and scroll restoration</h2><p>Local synthetic page</p><input id="draft"></article>')
            return
        if path == '/basic-auth':
            if self.headers.get('Authorization') != 'Basic dGVzdDpwYXNz':
                self.send_response(401)
                self.send_header('WWW-Authenticate', 'Basic realm="Oriv local fixture"')
                self.send_header('Content-Length', '0')
                self.end_headers()
                return
            self.page('Authenticated fixture', '<p id="authenticated">Synthetic test credentials accepted.</p>')
            return
        if path == '/large-download':
            length = 8 * 1024 * 1024
            match = re.fullmatch(r'bytes=(\d+)-', self.headers.get('Range', ''))
            start = int(match.group(1)) if match else 0
            if start >= length:
                self.send_error(416); return
            self.send_response(206 if match else 200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Disposition', 'attachment; filename="quality-download.bin"')
            self.send_header('Content-Length', str(length - start))
            self.send_header('Accept-Ranges', 'bytes')
            self.send_header('ETag', '"oriv-quality-v1"')
            self.send_header('Last-Modified', 'Mon, 26 Oct 2026 00:00:00 GMT')
            if match: self.send_header('Content-Range', f'bytes {start}-{length - 1}/{length}')
            self.end_headers()
            try:
                for position in range(start, length, 65536):
                    self.wfile.write(b'Q' * min(65536, length - position))
                    self.wfile.flush()
                    time.sleep(0.03)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        if path == '/login':
            self.page('AutoFill check', '''<p>Local form. Nothing is submitted or saved.</p>
            <form onsubmit="return false"><section>
            <p><label>Username <input name="username" autocomplete="username"></label></p>
            <p><label>Password <input type="password" name="password" autocomplete="current-password"></label></p>
            </section></form>''')
            return
        if path == '/context':
            self.send_bytes((FIXTURES / 'context.html').read_bytes(), 'text/html; charset=utf-8')
            return
        if path == '/adblock':
            self.send_bytes((FIXTURES / 'adblock.html').read_bytes(), 'text/html; charset=utf-8')
            return
        if path in {'/adblock-frames', '/adblock-frame', '/adblock-frame-ad', '/adblock-frame-allowed', '/side-ads-fixture'}:
            filename = 'adblock-frames.html' if path == '/adblock-frames' else 'adblock-frame.html'
            self.send_bytes((FIXTURES / filename).read_bytes(), 'text/html; charset=utf-8', no_store=True)
            return
        if path in {'/ad-banner.js', '/analytics.js', '/content.js'}:
            self.send_bytes(b'/* Successful fixture resource request. */', 'text/javascript')
            return
        if path == '/redirect-adblock':
            destination = parse_qs(urlsplit(self.path).query).get('host', ['localhost'])[0]
            if destination not in {'localhost', '127.0.0.1'}:
                self.send_error(400); return
            self.send_response(302)
            self.send_header('Location', f'http://{destination}:{self.server.server_port}/adblock?run=redirect')
            self.end_headers()
            return
        if path == '/identity':
            self.send_bytes(json.dumps({'userAgent': self.headers.get('User-Agent', '')}).encode(), 'application/json')
            return
        if path == '/fullscreen':
            self.send_bytes((FIXTURES / 'fullscreen.html').read_bytes(), 'text/html; charset=utf-8')
            return
        if path == '/media':
            self.send_bytes((FIXTURES / 'media.html').read_bytes(), 'text/html; charset=utf-8')
            return
        if path == '/media-captions.vtt':
            self.send_bytes((FIXTURES / 'media-captions.vtt').read_bytes(), 'text/vtt')
            return
        if path.startswith('/media-files/'):
            self.media(path)
            return
        if self.path.startswith("/download"):
            payload = b"Personal Browser download verification.\n"
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Disposition", 'attachment; filename="browser-test.txt"')
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path.startswith("/two"):
            self.page("Second page", '<p id="result">Navigation succeeded.</p><a href="/one">Back to the first page</a>')
            return
        self.page("Browser foundation", '''<nav><a id="next" href="/two">Next page</a><a id="popup" href="/two" target="_blank">Open in new tab</a><a id="download" href="/download">Download a file</a></nav>
        <section><h2>Keep your place</h2><label>Draft <input id="draft" placeholder="Type something, then switch tabs"></label></section>
        <section><h2>Website dialogs</h2><button onclick="alert('A message from the test website')">Alert</button> <button onclick="document.getElementById('answer').textContent=confirm('Continue with the test?')">Confirm</button> <span id="answer"></span></section>
        <section><h2>File upload</h2><input id="upload" type="file" onchange="document.getElementById('file-name').textContent=this.files[0]?.name"><p id="file-name"></p></section>
        <section><form method="post" action="/submitted"><label>Note <input name="note" value="A test note"></label> <button type="submit">Submit test form</button></form></section>''')

    def do_POST(self):
        length = min(int(self.headers.get("Content-Length", "0")), 10000)
        value = parse_qs(self.rfile.read(length).decode()).get("note", [""])[0]
        self.page("Form received", f'<p id="submitted">{html.escape(value)}</p>')

    def do_HEAD(self):
        self.media(urlsplit(self.path).path, head=True)

    def send_bytes(self, data, content_type, no_store=False):
        self.send_response(200)
        self.send_header('Content-Type', content_type)
        if no_store: self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def media(self, path, head=False):
        name = path.removeprefix('/media-files/')
        if name not in {'avc-aac.mp4', 'silent.mp4', 'hevc.mp4', 'tone.wav'} or not (MEDIA / name).is_file():
            self.send_error(404, 'Generate fixtures with scripts/generate-media-fixtures.swift first')
            return
        data = (MEDIA / name).read_bytes()
        start, end = 0, len(data) - 1
        requested_range = self.headers.get('Range')
        if requested_range:
            match = re.fullmatch(r'bytes=(\d*)-(\d*)', requested_range)
            if not match or not any(match.groups()):
                self.send_error(416); return
            if match[1]:
                start = int(match[1]); end = min(int(match[2]), end) if match[2] else end
            else:
                start = max(0, len(data) - int(match[2]))
            if start > end:
                self.send_error(416); return
        self.send_response(206 if requested_range else 200)
        self.send_header('Content-Type', 'audio/wav' if name.endswith('.wav') else 'video/mp4')
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Length', str(end - start + 1))
        if requested_range: self.send_header('Content-Range', f'bytes {start}-{end}/{len(data)}')
        self.end_headers()
        if not head:
            try: self.wfile.write(data[start:end + 1])
            except (BrokenPipeError, ConnectionResetError): pass

    def page(self, title, body):
        data = PAGE.format(title=title, body=body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8768)
    parser.add_argument("--bind", default="127.0.0.1", help="Explicit fixture interface; use a LAN address for device QA.")
    args = parser.parse_args()
    server = ThreadingHTTPServer((args.bind, args.port), Handler)
    print(f"Browser QA fixture at http://{args.bind}:{server.server_port}/one", flush=True)
    server.serve_forever()
