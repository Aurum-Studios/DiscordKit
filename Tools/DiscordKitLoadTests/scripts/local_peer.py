#!/usr/bin/env python3
# File: Tools/DiscordKitLoadTests/scripts/local_peer.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Credential-free loopback HTTP/1.1 peer for the separate transport load package."""
import argparse
import json
import signal
import ssl
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class LoadServer(ThreadingHTTPServer):
    """Bound the listener backlog; clients separately cap active connections."""
    request_queue_size = 512
    daemon_threads = True

    def __init__(self, *args, **kwargs):
        """Initialize bounded socket counters before the listener accepts any peer."""
        self.connection_lock = threading.RLock()
        self.accepted_connections = 0
        self.active_connections = 0
        self.peak_connections = 0
        super().__init__(*args, **kwargs)

    def get_request(self):
        """Count physical accepted sockets, including keepalive idle connections."""
        request, address = super().get_request()
        with self.connection_lock:
            self.accepted_connections += 1
            self.active_connections += 1
            self.peak_connections = max(self.peak_connections, self.active_connections)
        return request, address

    def shutdown_request(self, request):
        """Close an accepted socket before releasing its active connection count."""
        try:
            super().shutdown_request(request)
        finally:
            with self.connection_lock:
                self.active_connections -= 1

    def metrics(self):
        """Snapshot bounded aggregate counts without identity/address metric labels."""
        with self.connection_lock:
            return dict(acceptedConnections=self.accepted_connections,
                        activeConnections=self.active_connections,
                        peakConnections=self.peak_connections)

    def handle_error(self, request, client_address):
        """Keep expected cancellation/disconnect errors out of identity-bearing logs."""


class PayloadHandler(BaseHTTPRequestHandler):
    """Serve an exact fixed payload and avoid request/identity diagnostic labels."""
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        """Return a fixed response compatible with connection reuse and empty bodies."""
        self.respond()

    def do_POST(self):
        """Validate one bounded upload without retaining more than a 16 KiB chunk."""
        expected = {"transport.smallUpload": 256, "transport.streamedUpload": 65_536,
                    "transport.largeUpload": 1_048_576}.get(self.server.timing_case, 0)
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = -1
        if length != expected or not 0 <= length <= 1_048_576:
            self.send_error(400)
            self.close_connection = True
            return
        remaining = length
        while remaining:
            chunk = self.rfile.read(min(remaining, 16_384))
            if not chunk or chunk != b"x" * len(chunk):
                self.send_error(400)
                self.close_connection = True
                return
            remaining -= len(chunk)
        self.respond()

    def respond(self):
        """Apply finite fixture delays/chunks while preserving exact HTTP framing."""
        payload = self.server.payload
        case = self.server.timing_case
        if case == "transport.delayedHeaders":
            time.sleep(0.002)
        elif case == "transport.timedOut":
            time.sleep(0.050)
        if case == "transport.malformedBody":
            payload = b"y" * len(payload)
        self.send_response(200)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Content-Type", "application/octet-stream")
        self.end_headers()
        try:
            if case in ("transport.delayedBody", "transport.cancelled"):
                time.sleep(0.002)
            chunk_size = 1024 if case == "transport.streamedBody" else max(1, len(payload))
            for offset in range(0, len(payload), chunk_size):
                self.wfile.write(payload[offset:offset + chunk_size])
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            # Cancellation owns socket teardown; no peer exception/path is logged.
            self.close_connection = True

    def log_message(self, format, *args):
        """Suppress peer/path/header logging in both successes and failures."""


def make_server(payload_bytes, timing_case=None, tls_cert=None, tls_key=None):
    """Bind IPv4 loopback with a bounded payload; caller owns server shutdown."""
    if not 0 <= payload_bytes <= 1_048_576:
        raise ValueError("payload bytes outside local peer limit")
    cases = {"transport.empty", "transport.smallBody", "transport.streamedBody",
             "transport.largeBody", "transport.smallUpload", "transport.streamedUpload",
             "transport.largeUpload", "transport.delayedHeaders", "transport.delayedBody",
             "transport.malformedBody", "transport.cancelled", "transport.timedOut",
             "transport.body64KiBChunk257V1", "transport.body64KiBChunk65536V1"}
    if timing_case is not None and timing_case not in cases:
        raise ValueError("unknown timing case")
    if timing_case in {"transport.body64KiBChunk257V1", "transport.body64KiBChunk65536V1"} and payload_bytes != 65_536:
        raise ValueError("versioned chunk controls require exactly 65536 response bytes")
    if bool(tls_cert) != bool(tls_key):
        raise ValueError("TLS requires both certificate and key")
    server = LoadServer(("127.0.0.1", 0), PayloadHandler)
    server.payload = b"x" * payload_bytes
    server.timing_case = timing_case
    if tls_cert:
        try:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.minimum_version = ssl.TLSVersion.TLSv1_2
            context.load_cert_chain(tls_cert, tls_key)
            server.socket = context.wrap_socket(server.socket, server_side=True)
        except Exception:
            server.server_close()
            raise
    return server


def main():
    """Publish the bound port once, then serve until the owning harness terminates."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--payload-bytes", type=int, required=True)
    parser.add_argument("--timing-case")
    parser.add_argument("--tls-cert")
    parser.add_argument("--tls-key")
    args = parser.parse_args()
    with make_server(args.payload_bytes, args.timing_case, args.tls_cert, args.tls_key) as server:
        def terminate(signum, frame):
            """Publish aggregate socket evidence and exit after the owner closes its client."""
            deadline = time.monotonic() + 1.0
            while server.metrics()["activeConnections"] and time.monotonic() < deadline:
                time.sleep(0.005)
            print(json.dumps(server.metrics()), flush=True)
            raise SystemExit(0)

        signal.signal(signal.SIGTERM, terminate)
        print(server.server_port, flush=True)
        server.serve_forever()


if __name__ == "__main__":
    main()
