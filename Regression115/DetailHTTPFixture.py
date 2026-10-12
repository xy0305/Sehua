from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import time
class Handler(BaseHTTPRequestHandler):
 def log_message(self, *args): pass
 def do_GET(self):
  if self.path.startswith('/slow'):
   time.sleep(6)
  if self.path.startswith('/image'):
   time.sleep(4)
   data=b'x'
  else:
   tag='SLOW' if self.path.startswith('/slow') else 'FAST'
   data=("<html><body><div class='message'>"+tag+" complete body</div></body></html>").encode()
  try:
   self.send_response(200);self.send_header('Content-Type','text/html; charset=utf-8');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
  except (BrokenPipeError, ConnectionResetError): pass
# Match the existing AttachmentHTTPFixture: macOS runner reverse-DNS lookup
# in HTTPServer.server_bind can block before the first response.
class LocalServer(ThreadingHTTPServer):
 def server_bind(self):
  self.socket.bind(self.server_address)
  self.server_name='localhost'
  self.server_port=self.server_address[1]
LocalServer(('127.0.0.1',18764),Handler).serve_forever()
