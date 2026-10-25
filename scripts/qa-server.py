#!/usr/bin/env python3
"""Loopback-only fixture for native browser tests. No external service or credentials."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit
from pathlib import Path
import re
import argparse
import html
import json

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / 'scripts' / 'fixtures'
MEDIA = ROOT / 'build' / 'media-fixtures'

PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>{title}</title>
<style>body{{font:18px -apple-system,sans-serif;max-width:800px;margin:70px auto;padding:24px;color:#172536;background:#f7f9fc}}h1{{font-size:44px}}a{{color:#246bce}}input,button{{font:inherit;padding:10px}}section{{margin:28px 0;padding:24px;background:white;border-radius:12px}}nav{{display:flex;gap:24px}}</style></head>
<body><p>Personal Browser · Local test page</p><h1>{title}</h1>{body}</body></html>"""

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlsplit(self.path).path
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

    def send_bytes(self, data, content_type):
        self.send_response(200)
        self.send_header('Content-Type', content_type)
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
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"Browser QA fixture at http://127.0.0.1:{server.server_port}/one", flush=True)
    server.serve_forever()
