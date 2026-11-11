# File: Tools/DiscordKitLoadTests/scripts/test_local_peer.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Deterministic HTTP framing and validation checks for the local load peer."""
import http.client
from pathlib import Path
import ssl
import threading
import unittest
from local_peer import make_server


class LocalPeerTests(unittest.TestCase):
    """Verify empty/nonempty framing, keepalive reuse, and fixed payload bounds."""

    def test_payload_and_reuse(self):
        """Two requests on one connection return exactly the configured body."""
        for size in (0, 1024):
            with self.subTest(size=size), make_server(size) as server:
                worker = threading.Thread(target=server.serve_forever)
                worker.start()
                connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=5)
                try:
                    for _ in range(2):
                        connection.request("GET", "/payload")
                        response = connection.getresponse()
                        self.assertEqual(response.status, 200)
                        self.assertEqual(response.read(), b"x" * size)
                    self.assertEqual(server.metrics(), dict(acceptedConnections=1, activeConnections=1, peakConnections=1))
                finally:
                    connection.close()
                    server.shutdown()
                    worker.join()

    def test_invalid_limits(self):
        """Negative and oversized payloads fail before binding any listener."""
        for size in (-1, 1_048_577):
            with self.assertRaises(ValueError):
                make_server(size)

    def test_timing_payloads_and_uploads(self):
        """Streamed/large bodies and all upload sizes retain framing and bounded input validation."""
        for case, response_size, upload_size in (
                ("transport.streamedBody", 65_536, 0), ("transport.largeBody", 1_048_576, 0),
                ("transport.smallUpload", 256, 256), ("transport.streamedUpload", 256, 65_536),
                ("transport.largeUpload", 256, 1_048_576), ("transport.delayedHeaders", 256, 0),
                ("transport.delayedBody", 256, 0)):
            with self.subTest(case=case), make_server(response_size, case) as server:
                worker = threading.Thread(target=server.serve_forever)
                worker.start()
                connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=5)
                try:
                    connection.request("POST" if upload_size else "GET", "/payload",
                                       body=b"x" * upload_size if upload_size else None)
                    response = connection.getresponse()
                    self.assertEqual(response.status, 200)
                    self.assertEqual(response.read(), b"x" * response_size)
                finally:
                    connection.close()
                    server.shutdown()
                    worker.join()

    def test_bad_upload_and_malformed_response(self):
        """Bad uploads fail explicitly; malformed bodies keep valid framing with wrong contents."""
        for case, method, body, status in (("transport.smallUpload", "POST", b"bad", 400),
                                          ("transport.smallUpload", "POST", b"y" * 256, 400),
                                          ("transport.malformedBody", "GET", None, 200)):
            with self.subTest(case=case, status=status), make_server(256, case) as server:
                worker = threading.Thread(target=server.serve_forever)
                worker.start()
                connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=5)
                try:
                    connection.request(method, "/payload", body=body)
                    response = connection.getresponse()
                    self.assertEqual(response.status, status)
                    payload = response.read()
                    if status == 200:
                        self.assertEqual(payload, b"y" * 256)
                finally:
                    connection.close()
                    server.shutdown()
                    worker.join()

    def test_verified_tls_loopback(self):
        """Private fixture TLS requires its explicit trust root and verifies the loopback hostname."""
        resources = Path(__file__).resolve().parents[3] / "Tests/DiscordNIOTransportTests/Resources"
        certificate = str(resources / "localhost-cert.pem")
        key = str(resources / "localhost-key.pem")
        context = ssl.create_default_context(cafile=certificate)
        with make_server(256, "transport.smallBody", certificate, key) as server:
            worker = threading.Thread(target=server.serve_forever)
            worker.start()
            connection = http.client.HTTPSConnection("localhost", server.server_port, timeout=5, context=context)
            try:
                connection.request("GET", "/payload")
                response = connection.getresponse()
                self.assertEqual(response.status, 200)
                self.assertEqual(response.read(), b"x" * 256)
            finally:
                connection.close()
                server.shutdown()
                worker.join()

    def test_invalid_timing_and_tls_configuration(self):
        """Unknown cases and partial TLS configuration fail before binding a listener."""
        with self.assertRaises(ValueError):
            make_server(256, "unknown")
        with self.assertRaises(ValueError):
            make_server(256, tls_cert="certificate-only")


if __name__ == "__main__":
    unittest.main()
