# Numarası vekil-numara.txt'te yazan faturanın GET'ine 500 döner, diğer her isteği simülatöre iletir. Yalnız test içindir.
import http.server, urllib.request, urllib.error

TARGET = "http://erp-simulator:8080"

class Vekil(http.server.BaseHTTPRequestHandler):
    def forward(self):
        try:
            number = open("/vekil/vekil-numara.txt").read().strip()
        except OSError:
            number = ""
        if self.command == "GET" and number and self.path.split("?")[0].endswith("/" + number):
            self.answer(500, b'{"title":"ERP internal error"}', "application/problem+json")
            return
        body = self.read_body()
        request = urllib.request.Request(TARGET + self.path, data=body, method=self.command,
                                         headers={"Content-Type": self.headers.get("Content-Type", "application/json")})
        try:
            with urllib.request.urlopen(request, timeout=60) as r:
                self.answer(r.status, r.read(), r.headers.get("Content-Type", "application/json"))
        except urllib.error.HTTPError as e:
            self.answer(e.code, e.read(), e.headers.get("Content-Type", "application/json"))

    def read_body(self):
        # .NET'in HttpClient'ı JSON gövdesini parça parça (chunked) gönderir, Content-Length olmaz.
        if "chunked" in (self.headers.get("Transfer-Encoding") or ""):
            chunks = []
            while True:
                size = int(self.rfile.readline().strip() or b"0", 16)
                if size == 0:
                    self.rfile.readline()
                    return b"".join(chunks)
                chunks.append(self.rfile.read(size))
                self.rfile.readline()
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else None

    def answer(self, status, body, content_type):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_GET = do_POST = do_PUT = forward

    def log_message(self, *args):
        pass

http.server.ThreadingHTTPServer(("", 8090), Vekil).serve_forever()
