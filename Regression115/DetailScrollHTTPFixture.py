"""Loopback-only long Discuz fixture; no credentials and no write routes."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
from io import BytesIO
from PIL import Image, ImageDraw
import json, threading, time
counts = {}
lock = threading.Lock()
media = {}
for i in range(12):
    frames = []
    for frame in range(2):
        image = Image.new('RGB', (300, 600 + (i % 4) * 150), (35 + i * 12, 90 + frame * 50, 150))
        ImageDraw.Draw(image).text((20, 30), f'IMAGE {i} FRAME {frame}', fill='white')
        frames.append(image)
    output = BytesIO()
    if i % 2 == 0:
        frames[0].save(output, 'GIF', save_all=True, append_images=frames[1:], duration=150, loop=0)
    else:
        frames[0].save(output, 'JPEG')
    media[f'/media/{i}'] = output.getvalue()

def post(pid, body):
    return f'<div id="post_{pid}"><div class="message">{body}</div></div>'

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        self.send_error(405)
    def do_GET(self):
        parsed = urlparse(self.path)
        page = int(parse_qs(parsed.query).get('page', ['1'])[0])
        key = f'page{page}' if parsed.path == '/forum.php' else parsed.path
        with lock:
            counts[key] = counts.get(key, 0) + 1
            count = counts[key]
        status, mime = 200, 'text/html; charset=utf-8'
        if parsed.path == '/stats':
            with lock: data = json.dumps(counts).encode()
            mime = 'application/json'
        elif parsed.path in media:
            # Slower than a fast swipe: exercise departing consumers/cancellation.
            time.sleep(.25)
            data = media[parsed.path]
            mime = 'image/gif' if int(parsed.path.rsplit('/', 1)[1]) % 2 == 0 else 'image/jpeg'
        elif parsed.path == '/forum.php' and page == 1:
            body = ''.join(f'<p>SCROLL ROW {i} native selectable text</p><img src="/media/{i}"><p>AFTER IMAGE {i}</p>' for i in range(12))
            data = ('<html><body><h1 id="thread_subject">SCROLL TOP</h1>' + post(7901, body) + '<a href="forum.php?mod=viewthread&amp;tid=79&amp;page=2">下一页</a></body></html>').encode()
        elif parsed.path == '/forum.php' and page == 2 and count == 1:
            # Invalid completed page, not a WebKit HTTP-error navigation whose
            # displayed document is platform-dependent. Production must retain
            # the current page and offer a bounded explicit retry.
            data = b'<html><body>controlled empty reply page</body></html>'
        elif parsed.path == '/forum.php' and page == 2:
            data = ('<html><body>' + post(7901, '<p>duplicate original must not append</p>') + post(7902, '<p>PAGE TWO REPLY</p>') + '</body></html>').encode()
        else:
            data = b'ready'
        try:
            self.send_response(status)
            self.send_header('Content-Type', mime)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError): pass
ThreadingHTTPServer(('127.0.0.1', 18766), Handler).serve_forever()
