# File: Tools/DiscordKitLoadTests/scripts/test_local_peer.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Deterministic HTTP framing and validation checks for the local load peer."""
import http.client
import errno
import json
import os
from pathlib import Path
import selectors
import signal
import socket
import ssl
import subprocess
import sys
import threading
import time
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

    def test_versioned_chunk_controls_keep_identical_immediate_payloads(self):
        """Native chunk controls vary client configuration, retaining the same immediate wire body."""
        for case in ("transport.body64KiBChunk257V1", "transport.body64KiBChunk65536V1"):
            with self.subTest(case=case), make_server(65_536, case) as server:
                worker = threading.Thread(target=server.serve_forever)
                worker.start()
                connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=5)
                try:
                    for _ in range(2):
                        connection.request("GET", "/payload")
                        response = connection.getresponse()
                        self.assertEqual(response.status, 200)
                        self.assertEqual(response.getheader("Content-Length"), "65536")
                        self.assertEqual(response.read(), b"x" * 65_536)
                    self.assertEqual(server.metrics()["acceptedConnections"], 1)
                finally:
                    connection.close()
                    server.shutdown()
                    worker.join()

    def test_versioned_chunk_controls_reject_payload_identity_changes(self):
        """A versioned fixed-size identity rejects any different body size before socket allocation."""
        for case in ("transport.body64KiBChunk257V1", "transport.body64KiBChunk65536V1"):
            for size in (0, 65_535, 65_537):
                with self.subTest(case=case, size=size), self.assertRaises(ValueError):
                    make_server(size, case)

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


@unittest.skipUnless(os.name == "posix" and hasattr(signal, "pthread_sigmask"),
                     "signal-mask inheritance requires POSIX pthread_sigmask")
class LocalPeerShutdownTests(unittest.TestCase):
    """The CLI owns graceful SIGTERM shutdown even when its parent masks that signal."""

    def test_cli_sigterm_shutdown(self):
        """Ordinary startup returns one exact metrics receipt and closes its listener."""
        self.assert_cli_shutdown(blocked_sigterm=False)

    def test_cli_sigterm_shutdown_with_inherited_blocked_signal(self):
        """A masked parent cannot leave the peer alive after the harness requests shutdown."""
        self.assert_cli_shutdown(blocked_sigterm=True)

    def assert_cli_shutdown(self, *, blocked_sigterm):
        """Exec through a single-threaded launcher; never alter the test runner's signal mask."""
        launcher = (
            "import os, signal, sys\n"
            "mask = {signal.SIGTERM} if sys.argv[1] == 'blocked' else set()\n"
            "signal.pthread_sigmask(signal.SIG_SETMASK, mask)\n"
            "os.execv(sys.executable, [sys.executable, *sys.argv[2:]])\n"
        )
        arguments = [sys.executable, "-c", launcher, "blocked" if blocked_sigterm else "unblocked",
                     str(Path(__file__).with_name("local_peer.py")), "--payload-bytes", "65536",
                     "--timing-case", "transport.body64KiBChunk257V1"]
        peer = subprocess.Popen(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE)
        port = None
        forced_kill = False
        terminated_before_cleanup = False
        try:
            # Read the startup line with a real deadline rather than a blocking readline.
            announcement = b""
            deadline = time.monotonic() + 5
            with selectors.DefaultSelector() as selector:
                selector.register(peer.stdout, selectors.EVENT_READ)
                while b"\n" not in announcement:
                    self.assertTrue(selector.select(max(0, deadline - time.monotonic())),
                                    "peer did not announce its port within five seconds")
                    chunk = os.read(peer.stdout.fileno(), 64)
                    self.assertTrue(chunk, "peer exited before announcing its port")
                    announcement += chunk
                    self.assertLessEqual(len(announcement), 64, "unexpected startup output")
            self.assertEqual(len(announcement.splitlines()), 1)
            port = int(announcement.strip())
            self.assertTrue(1 <= port <= 65535)

            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
            try:
                connection.request("GET", "/payload", headers={"Connection": "close"})
                response = connection.getresponse()
                self.assertEqual(response.status, 200)
                self.assertEqual(response.read(), b"x" * 65536)
            finally:
                connection.close()

            peer.terminate()
            try:
                output, errors = peer.communicate(timeout=3)
                terminated_before_cleanup = True
            except subprocess.TimeoutExpired:
                self.fail("peer remained alive three seconds after SIGTERM")
            self.assertEqual(peer.returncode, 0)
            self.assertEqual(errors, b"")
            self.assertEqual(json.loads(output), dict(acceptedConnections=1, activeConnections=0,
                                                     peakConnections=1))
        finally:
            if peer.poll() is None:
                forced_kill = True
                peer.kill()
            peer.communicate(timeout=5)
            self.assertIsNotNone(peer.returncode, "peer cleanup did not reap its child")
            port_closed = None
            if port is not None:
                with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
                    probe.settimeout(1)
                    port_closed = probe.connect_ex(("127.0.0.1", port)) == errno.ECONNREFUSED
                self.assertTrue(port_closed, "peer listener remained open after process cleanup")
            print(json.dumps(dict(fixture="local-peer-sigterm", blockedSIGTERM=blocked_sigterm,
                                  terminatedBeforeCleanup=terminated_before_cleanup,
                                  forcedKill=forced_kill, exitCode=peer.returncode,
                                  reaped=peer.returncode is not None, portClosed=port_closed)), flush=True)


if __name__ == "__main__":
    unittest.main()
