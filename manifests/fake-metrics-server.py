#!/usr/bin/env python3
"""
fake-metrics-server.py
Minimal HTTP server that:
  - Exposes /metrics  (Prometheus format) with a configurable queue_depth_total gauge
  - Exposes /set?queue_depth=N  to update the gauge value at runtime
  - Exposes /health for readiness probes

Used by BOTH demo paths:
  - Native HPA: Prometheus scrapes → Adapter translates → HPA consumes
  - KEDA: Prometheus scrapes → KEDA Prometheus scaler consumes directly

The intentional simplicity means the demo focuses on the autoscaler behaviour,
not on the application logic.
"""
import http.server
import threading
import os

# Global queue depth — manipulated via /set endpoint in demos
queue_depth = float(os.environ.get("INITIAL_QUEUE_DEPTH", "10"))
lock = threading.Lock()
PORT = int(os.environ.get("PORT", "8080"))

METRICS_TEMPLATE = """\
# HELP queue_depth_total Number of items currently in the processing queue
# TYPE queue_depth_total gauge
queue_depth_total{{namespace="{ns}",pod="{pod}"}} {value}
"""

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # suppress default access log noise

    def do_GET(self):
        global queue_depth
        if self.path == "/health":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")

        elif self.path == "/metrics":
            ns = os.environ.get("POD_NAMESPACE", "demo")
            pod = os.environ.get("POD_NAME", "fake-metrics-0")
            with lock:
                value = queue_depth
            body = METRICS_TEMPLATE.format(ns=ns, pod=pod, value=value).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        elif self.path.startswith("/set"):
            from urllib.parse import urlparse, parse_qs
            qs = parse_qs(urlparse(self.path).query)
            try:
                val = float(qs["queue_depth"][0])
            except (KeyError, ValueError, IndexError):
                self.send_response(400)
                self.end_headers()
                self.wfile.write(b"bad request: ?queue_depth=N required")
                return
            with lock:
                queue_depth = val
            body = f"queue_depth set to {val}\n".encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        else:
            self.send_response(404)
            self.end_headers()

if __name__ == "__main__":
    print(f"Fake metrics server listening on :{PORT}")
    print(f"  /metrics         - Prometheus scrape endpoint")
    print(f"  /set?queue_depth=N - Update queue depth")
    print(f"  /health          - Readiness probe")
    server = http.server.ThreadingHTTPServer(("", PORT), Handler)
    server.serve_forever()
