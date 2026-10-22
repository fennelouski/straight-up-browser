from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import argparse, json, os

html = b"""<meta name='viewport' content='width=device-width,initial-scale=1'>
<title>Local domain fixture</title><style>body{margin:0;background:#eaeaea;height:2400px}
.top,.bottom{position:fixed;left:0;width:100%;height:90px;pointer-events:none}
.top{top:0;background:#ef3030}.bottom{bottom:0;background:#2040ef}
button{position:fixed;left:0;top:180px;width:100%;height:40px;border:0;border-top:2px solid black;background:white}</style>
<div class='top'></div><div class='bottom'></div><button>Stationary Edge</button>
<p style='padding-top:300px'>Local domain fixture. No scripts or external resources.</p>"""

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = html
        if self.path.startswith('/alternate'):
            body = body.replace(b'#ef3030', b'#20cf40').replace(b'#2040ef', b'#efcf20')
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *_): pass

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
state = {'pid': os.getpid(), 'url': 'http://127.0.0.1:' + str(server.server_port) + '/fixture', 'state': 'running'}
parser = argparse.ArgumentParser(description='Loopback-only synthetic Browser mobile acceptance pages')
parser.add_argument('--state-file', type=Path, required=True)
path = parser.parse_args().state_file
path.write_text(json.dumps(state, indent=2)+'\n')
print(json.dumps(state), flush=True)
try: server.serve_forever()
except KeyboardInterrupt: pass
finally:
    server.server_close()
    state['state'] = 'ended'
    path.write_text(json.dumps(state, indent=2)+'\n')
