#!/usr/bin/env python3
import json, os, glob, time
from http.server import HTTPServer, BaseHTTPRequestHandler

MEM = "/opt/ffactory/system_memory.json"
LOGS = "/opt/ffactory/logs"

def load_mem():
    try:
        with open(MEM, "r") as f:
            return json.load(f)
    except Exception:
        return {"events": [], "services": {}, "health_history": []}

def summarize(d):
    svc = d.get("services", {})
    bad_keys = []
    for k, v in svc.items():
        st = v.get("status", "")
        if st in ("still-bad", "restart-failed") or st == "" and v.get("restart_count", 0) > 0:
            bad_keys.append(k)
    return {
        "ts": int(time.time()),
        "project": "ffactory",
        "ok_count": len(svc) - len(bad_keys),
        "bad_count": len(bad_keys),
        "bad_services": sorted(bad_keys),
    }

class H(BaseHTTPRequestHandler):
    def _json(self, obj, code=200):
        j = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(j)))
        self.end_headers()
        self.wfile.write(j)

    def do_GET(self):
        if self.path in ("/healthz", "/live", "/ready"):
            d = load_mem()
            s = summarize(d)
            code = 200 if s["bad_count"] == 0 else 503
            self._json(s, code)
            return

        if self.path == "/summary":
            self._json(summarize(load_mem()))
            return

        if self.path == "/json":
            d = load_mem()
            self._json(d)
            return

        if self.path == "/report.html":
            files = sorted(glob.glob(os.path.join(LOGS, "health_*.html")))
            if not files:
                self.send_response(404); self.end_headers(); return
            p = files[-1]
            try:
                b = open(p, "rb").read()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(b)))
                self.end_headers()
                self.wfile.write(b)
            except Exception:
                self.send_response(500); self.end_headers()
            return

        self.send_response(404); self.end_headers()

def main():
    addr = ("0.0.0.0", 9191)
    httpd = HTTPServer(addr, H)
    httpd.serve_forever()

if __name__ == "__main__":
    main()
