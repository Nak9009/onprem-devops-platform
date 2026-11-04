#!/usr/bin/env python3
"""
kubernetes/applications/sample-api/app.py
Lightweight zero-dependency HTTP microservice for testing the CI/CD + GitOps pipeline.
Exposes /healthz, /readyz, /metrics, and /api/v1/info on port 8080.
"""

import json
import os
import socket
from http.server import BaseHTTPRequestHandler, HTTPServer

APP_VERSION = os.environ.get("APP_VERSION", "1.0.0")
APP_ENV = os.environ.get("APP_ENV", "dev")


class ApiHandler(BaseHTTPRequestHandler):
    def _send_json(self, status_code: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        if self.path in ("/healthz", "/readyz"):
            self._send_json(200, {"status": "ok", "version": APP_VERSION, "env": APP_ENV})
        elif self.path == "/metrics":
            metrics = (
                "# HELP api_up Whether the sample API service is healthy\n"
                "# TYPE api_up gauge\n"
                f'api_up{{env="{APP_ENV}",version="{APP_VERSION}"}} 1\n'
            ).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Content-Length", str(len(metrics)))
            self.end_headers()
            self.wfile.write(metrics)
        else:
            self._send_json(
                200,
                {
                    "service": "api",
                    "version": APP_VERSION,
                    "environment": APP_ENV,
                    "hostname": socket.gethostname(),
                },
            )


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", 8080), ApiHandler)
    print(f"Starting sample-api v{APP_VERSION} ({APP_ENV}) on :8080...")
    server.serve_forever()

