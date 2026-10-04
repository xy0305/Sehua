from http.server import BaseHTTPRequestHandler,HTTPServer
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def do_GET(self):
  if self.path=='/redirect':
   self.send_response(302);self.send_header('Location','/ed2k');self.end_headers();return
  code=403 if self.path=='/forbidden' else 200
  mime='text/html' if self.path=='/html' else 'application/octet-stream'
  body=b'<html>permission</html>' if self.path=='/html' else (b'\x50\x4b\x03\x04\x00' if self.path=='/binary' else b"ed2k://|file|www.98T.la@[AlinaxMei] My best friend's Asian girlfriend got a creampie.mp4|1776335157|F9521F774DC30A5FE980E23DCDEF19C7|/")
  if self.path=='/headers' and ('iPhone' not in self.headers.get('User-Agent','') or self.headers.get('Referer')!='http://127.0.0.1:18763/thread'):code=400
  self.send_response(code);self.send_header('Content-Type',mime);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
HTTPServer(('127.0.0.1',18763),Handler).serve_forever()
