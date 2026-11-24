#!/usr/bin/env python3
"""Verify retained PCM/retry ownership through actual Hybrid and Socket sources.

A loopback server records real WebSocket PCM independently of client callbacks.
No microphone, provider API, credentials, app launch hooks, or timing overrides.
"""
import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
import hashlib
from pathlib import Path
import json
import socketserver
import struct
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
CASES = ("cold", "outage", "bounded-primary", "healthy", "sent-fail", "multi-fail",
         "pending-online", "pending-offline", "stop-restart", "expired")


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, mode):
        super().__init__(("127.0.0.1", 0), Handler)
        self.mode = mode
        self.wire = []
        self.errors = []
        self.lock = threading.Lock()


class Handler(socketserver.StreamRequestHandler):
    def frame(self, opcode, payload=b""):
        size = len(payload)
        if size < 126:
            header = bytes([0x80 | opcode, size])
        elif size < 65_536:
            header = bytes([0x80 | opcode, 126]) + struct.pack("!H", size)
        else:
            header = bytes([0x80 | opcode, 127]) + struct.pack("!Q", size)
        self.wfile.write(header + payload)
        self.wfile.flush()

    def event(self, **value):
        self.frame(1, json.dumps(value).encode())

    def handle(self):
        self.request.settimeout(36)
        try:
            request = self.rfile.readline().decode().split()
            if len(request) < 2:
                return
            path = request[1].strip("/")
            headers = {}
            while line := self.rfile.readline():
                if line == b"\r\n":
                    break
                key, value = line.decode().split(":", 1)
                headers[key.lower()] = value.strip()
            accept = base64.b64encode(hashlib.sha1(
                (headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()
            ).digest()).decode()
            self.wfile.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                              "Connection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n").encode())
            self.wfile.flush()
            with self.server.lock:
                attempt = 1 + sum(entry["path"] == path for entry in self.server.wire)
                record = {"path": path, "attempt": attempt, "pcm": [], "confirmed": [],
                          "events": [], "connected_at": time.monotonic()}
                self.server.wire.append(record)
            configured = False
            while True:
                initial = self.rfile.read(2)
                if len(initial) != 2:
                    return
                opcode, length = initial[0] & 15, initial[1] & 127
                if length == 126:
                    length = struct.unpack("!H", self.rfile.read(2))[0]
                elif length == 127:
                    length = struct.unpack("!Q", self.rfile.read(8))[0]
                if length > 1_048_576:
                    raise ValueError("Unexpected oversized test frame")
                mask = self.rfile.read(4) if initial[1] & 128 else b""
                payload = self.rfile.read(length)
                if len(payload) != length:
                    return
                if mask:
                    payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
                if opcode == 8:
                    return
                if opcode == 9:
                    self.frame(10, payload)
                elif opcode == 2:
                    if not configured or len(payload) != 2_560:
                        raise ValueError("PCM must follow configuration and contain one 80ms chunk")
                    marker = struct.unpack("<h", payload[:2])[0]
                    if payload != struct.pack("<h", marker) * 1_280:
                        raise ValueError("PCM marker bytes were corrupted")
                    record["pcm"].append(marker)
                    record["events"].append("pcm")
                    self.event(event="audio", marker=marker)
                elif opcode == 1:
                    text = payload.decode()
                    record["events"].append(text)
                    if text == "configure":
                        if configured:
                            raise ValueError("Duplicate opening configuration")
                        configured = True
                        if path == "catchup" and attempt == 1 and self.server.mode in (
                                "pending-online", "pending-offline", "stop-restart", "expired"):
                            return  # Fails before readiness or any PCM upload.
                        time.sleep(.08)
                        self.event(event="ready")
                    elif text in ("", "finalize"):
                        if not configured:
                            raise ValueError("End-of-audio preceded configuration")
                        partial = (20 if attempt == 1 else 10) if (
                            path == "catchup" and ((self.server.mode == "sent-fail" and attempt == 1)
                            or (self.server.mode == "multi-fail" and attempt <= 2))) else None
                        record["confirmed"] = record["pcm"][:partial]
                        self.event(event="progress" if partial is not None else "finished",
                                   markers=record["confirmed"])
                        if partial is not None:
                            return
                    elif text != "keepalive":
                        raise ValueError("Unexpected test text frame")
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass
        except Exception as error:
            with self.server.lock:
                self.server.errors.append(str(error))


def verify_wire(mode, wire):
    primary = [entry["pcm"] for entry in wire if entry["path"] == "primary"]
    sides = [entry for entry in wire if entry["path"] == "catchup"]
    expected = [0] * 3 + list(range(4_000, 4_040)) + [0] * 3
    if mode in ("cold", "outage", "bounded-primary"):
        count = 1_000 if mode == "bounded-primary" else 312
        retained = [0 if index % 3 == 0 else 4_000 + index for index in range(count)][-750:]
        assert [marker for stream in primary for marker in stream] == retained + [12_000]
        assert not sides
    elif mode in ("expired", "stop-restart"):
        assert len(sides) == 1 and not sides[0]["pcm"]
        assert [marker for stream in primary for marker in stream] == ([8_000] if mode == "stop-restart" else [])
    else:
        assert all(not stream for stream in primary)
        assert [marker for side in sides for marker in side["confirmed"]] == expected
        uploaded = [side["pcm"] for side in sides]
        if mode == "sent-fail":
            assert uploaded == [expected, expected[20:]]
        elif mode == "multi-fail":
            assert uploaded == [expected, expected[20:], expected[30:]]
        elif mode in ("pending-online", "pending-offline"):
            assert uploaded == [[], expected]
        else:
            assert uploaded == [expected]
    # An EOF on catch-up always follows its accepted PCM and occurs once.
    for side in sides:
        if side["pcm"]:
            assert side["events"].count("") == 1
            assert "pcm" not in side["events"][side["events"].index("") + 1:]


def run_case(binary, mode, should_pass):
    with Server(mode) as server:
        threading.Thread(target=server.serve_forever, daemon=True).start()
        result = subprocess.run([str(binary), "ws://127.0.0.1:" + str(server.server_address[1]), mode],
                                capture_output=True, text=True, timeout=42)
        server.shutdown()
        wire, errors = server.wire[:], server.errors[:]
    if should_pass:
        if result.returncode or errors:
            raise RuntimeError(mode + "\n" + result.stdout + result.stderr + repr(errors))
        verify_wire(mode, wire)
        return result.stdout.strip()
    if result.returncode != 1 or "FAIL:" not in result.stdout:
        raise RuntimeError("Negative control did not fail a runtime assertion: " + mode
                           + "\n" + result.stdout + result.stderr)
    return "PASS: deliberate replay regression rejected in " + mode


def compile_variant(work, name, source):
    swift = work / (name + ".swift")
    swift.write_text(source)
    binary = work / name
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-default-isolation", "MainActor",
                    "-parse-as-library", "-module-cache-path", str(work / "modules"),
                    str(ROOT / "Lively/Model/Language.swift"),
                    str(ROOT / "Lively/Networking/SpeechEngine.swift"),
                    str(ROOT / "Lively/Networking/SonioxReconnect.swift"),
                    str(ROOT / "Lively/Networking/HybridSpeechEngine.swift"), str(swift),
                    str(Path(__file__).with_name("SocketReplayRegression.swift")), "-o", str(binary)],
                   check=True, timeout=90)
    return binary


def replace_once(source, old, new):
    if source.count(old) != 1:
        raise RuntimeError("Update replay mutation anchor: " + old)
    return source.replace(old, new)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--negative-controls", action="store_true")
    args = parser.parse_args()
    source = (ROOT / "Lively/Networking/ResilientSocket.swift").read_text()
    print("Socket source SHA256: " + hashlib.sha256(source.encode()).hexdigest(), flush=True)
    with tempfile.TemporaryDirectory(prefix="lively-socket-replay-") as directory:
        work = Path(directory)
        binary = compile_variant(work, "actual", source)
        with ThreadPoolExecutor(max_workers=len(CASES)) as pool:
            for output in pool.map(lambda mode: run_case(binary, mode, True), CASES):
                print(output, flush=True)
        if args.negative_controls:
            mutations = [
                ("five-second-truncation", "speech.forEach { enqueueAudio($0, on: connection) }",
                 "speech.suffix(62).forEach { enqueueAudio($0, on: connection) }", "outage"),
                ("sent-suffix-forgotten", "connection.stream.isCatchUp || connection === primary",
                 "!connection.stream.isCatchUp && connection === primary", "sent-fail"),
                ("offline-wait-forgotten", "catchUpRetries.removeAll { $0.deadline <= now }",
                 "catchUpRetries.removeAll { $0.deadline <= now || !networkAvailable }", "pending-offline"),
                ("finalized-prefix-repeated", "connection.unconfirmed.removeFirst(done)",
                 "if !connection.stream.isCatchUp { connection.unconfirmed.removeFirst(done) }", "sent-fail"),
                ("restart-leaks-delayed-replay", "        clearCatchUpRetries()\n", "", "stop-restart"),
            ]
            for name, old, new, mode in mutations:
                # Both stop and a fresh start must forget the previous session.
                changed = source.replace(old, new) if name == "restart-leaks-delayed-replay" else replace_once(source, old, new)
                if changed == source:
                    raise RuntimeError("Missing mutation anchor: " + name)
                mutant = compile_variant(work, name, changed)
                print(name + ": " + run_case(mutant, mode, False), flush=True)


if __name__ == "__main__":
    main()
