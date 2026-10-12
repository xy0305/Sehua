from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import time, threading, json
counts={};lock=threading.Lock()
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def do_GET(self):
  path=self.path.split('?')[0]
  with lock: counts[path]=counts.get(path,0)+1; count=counts[path]
  status=200;typ='text/html; charset=utf-8'
  if path=='/stats':
   with lock: data=json.dumps(counts).encode()
   typ='application/json'
  elif path.startswith('/net-image'):
   time.sleep(.8);data=b'GIF89a-retained-original-bytes';typ='image/gif'
   if 'retry' in path and count==1:status=503
  elif path=='/slow-media':
   time.sleep(5);data=b'GIF89a-retained-original-bytes';typ='image/gif'
  else:
   media="<img src='/slow-media'><iframe src='/slow-media'></iframe>"
   message="<div class='message' id='m'>complete body<img src='/net-image-original.gif'></div>"
   script=''
   if path=='/late':
    script="<script>setTimeout(()=>{document.querySelector('#m').innerHTML='FINAL body<img src=\"/net-image-late.gif\">'},1500);setTimeout(()=>{document.body.insertAdjacentHTML('beforeend','<a class=\"attachment\" href=\"/file.torrent\">FINAL attachment</a>')},2200)</script>"
   elif path=='/empty-late':
    message="<div class='message' id='m'></div>"
    script="<script>setTimeout(()=>{document.querySelector('#m').innerHTML='FINAL body<img src=\"/net-image-late.gif\">'},2200)</script>"
   elif path=='/permission':
    script="<script>setTimeout(()=>{document.querySelector('#m').innerHTML='<div class=\"locked\">隐藏内容需回复</div><a href=\"/buy\">购买主题</a>'},1500)</script>"
   elif path=='/load-late':
    script="<script>window.addEventListener('load',()=>{setTimeout(()=>{document.querySelector('#m').innerHTML='FINAL load dependent body<img src=\"/net-image-load.gif\">'},1200)})</script>"
   elif path=='/restricted':
    message='<div id="messagetext">请先登录，权限不足</div>';media=''
   elif path=='/ready':
    message='ready';media=''
   data=('<html><body>'+message+media+script+'</body></html>').encode()
  try:
   self.send_response(status);self.send_header('Content-Type',typ);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
  except (BrokenPipeError,ConnectionResetError):pass
class LocalServer(ThreadingHTTPServer):
 def server_bind(self):
  self.socket.bind(self.server_address);self.server_name='localhost';self.server_port=self.server_address[1]
LocalServer(('127.0.0.1',18765),Handler).serve_forever()
