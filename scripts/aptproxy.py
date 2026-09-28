#!/usr/bin/env python3
"""Минимальный HTTP-прокси для apt телефона: только GET/HEAD по http://, слушает 127.0.0.1."""
import http.server
import shutil
import socketserver
import urllib.error
import urllib.request


class Proxy(http.server.BaseHTTPRequestHandler):
    def _go(self, head=False):
        if not self.path.startswith("http://"):
            self.send_error(400, "only absolute http:// URLs")
            return
        req = urllib.request.Request(self.path, method="HEAD" if head else "GET")
        for k in ("Range", "If-Modified-Since", "If-Range"):
            if self.headers.get(k):
                req.add_header(k, self.headers[k])
        try:
            resp = urllib.request.urlopen(req, timeout=60)
            code = resp.status
        except urllib.error.HTTPError as e:
            resp, code = e, e.code
        self.send_response(code)
        for k, v in resp.headers.items():
            if k.lower() not in ("connection", "transfer-encoding"):
                self.send_header(k, v)
        self.send_header("Connection", "close")
        self.end_headers()
        if not head:
            shutil.copyfileobj(resp, self.wfile)

    def do_GET(self):
        self._go()

    def do_HEAD(self):
        self._go(head=True)

    def log_message(self, *a):
        pass


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


Server(("127.0.0.1", 8899), Proxy).serve_forever()
