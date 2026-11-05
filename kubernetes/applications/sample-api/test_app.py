#!/usr/bin/env python3
"""
Unit tests for kubernetes/applications/sample-api/app.py
Executed automatically in Jenkins Stage 3 ('3. Unit Tests').
"""

import json
import threading
import unittest
import urllib.request
from http.server import HTTPServer

import app as sample_app


class SampleApiTestCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.server = HTTPServer(("127.0.0.1", 0), sample_app.ApiHandler)
        cls.port = cls.server.server_port
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()

    def _get(self, path: str):
        with urllib.request.urlopen(f"http://127.0.0.1:{self.port}{path}", timeout=3) as resp:
            return resp.status, resp.headers.get("Content-Type", ""), resp.read().decode("utf-8")

    def test_healthz_and_readyz(self) -> None:
        for endpoint in ("/healthz", "/readyz"):
            status, content_type, body = self._get(endpoint)
            self.assertEqual(status, 200)
            self.assertIn("application/json", content_type)
            data = json.loads(body)
            self.assertEqual(data["status"], "ok")

    def test_prometheus_metrics(self) -> None:
        status, content_type, body = self._get("/metrics")
        self.assertEqual(status, 200)
        self.assertIn("text/plain", content_type)
        self.assertIn("api_up{", body)

    def test_service_info_payload(self) -> None:
        status, _, body = self._get("/api/v1/info")
        self.assertEqual(status, 200)
        data = json.loads(body)
        self.assertEqual(data["service"], "api")
        self.assertIn("version", data)
        self.assertIn("hostname", data)


if __name__ == "__main__":
    unittest.main()

