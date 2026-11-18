#!/usr/bin/env python3
"""Exercise the actual ResilientSocket against a loopback WebSocket server.

Uses only Python's standard library and the macOS Swift SDK. No cloud requests,
microphone, account credentials, injected production hooks, or app QA UI.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import socketserver
import struct
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]


class WebSocketServer(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), Handler)
        self.connections = []
        self.wire_events = []
        self.errors = []
        self.lock = threading.Lock()


class Handler(socketserver.StreamRequestHandler):
    def frame(self, opcode, payload=b""):
        if len(payload) < 126:
            header = bytes([0x80 | opcode, len(payload)])
        elif len(payload) < 65_536:
            header = bytes([0x80 | opcode, 126]) + struct.pack("!H", len(payload))
        else:
            header = bytes([0x80 | opcode, 127]) + struct.pack("!Q", len(payload))
        self.wfile.write(header + payload)
        self.wfile.flush()

    def event(self, **value):
        self.frame(1, json.dumps(value).encode())

    def handle(self):
        self.request.settimeout(15)
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
                self.server.connections.append(path)
                attempt = self.server.connections.count(path)
                events = {"path": path, "events": [], "connected_at": time.time(), "received_at": []}
                self.server.wire_events.append(events)
            time.sleep(.25)  # Server readiness deliberately lags the handshake.
            if path == "retry-timeout" or (path == "retry-paused" and attempt == 1):
                self.event(event="retry")
                return
            if path not in ("handshake", "no-ready"):
                self.event(event="ready")
            markers = []
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
                    raise ValueError("Unexpected oversized local frame")
                mask = self.rfile.read(4) if initial[1] & 128 else b""
                data = self.rfile.read(length)
                if len(data) != length:
                    return
                if mask:
                    data = bytes(value ^ mask[index % 4] for index, value in enumerate(data))
                if opcode == 8:
                    return
                if opcode == 9:
                    self.frame(10, data)
                elif opcode == 2:
                    if not configured:
                        raise ValueError("PCM arrived before opening configuration")
                    marker = struct.unpack("<h", data[:2])[0]
                    events["events"].append(("pcm", marker))
                    events["received_at"].append(time.time())
                    markers.append(marker)
                    self.event(event="audio", marker=marker)
                elif opcode == 1:
                    text = data.decode()
                    if text == "configure":
                        if configured:
                            raise ValueError("Repeated opening configuration")
                        configured = True
                    elif text in ("finalize", ""):
                        if not configured:
                            raise ValueError("Finalize arrived before configuration")
                        events["events"].append(("finalize" if text else "eof", None))
                        # The final reply must survive pause; immediate stop
                        # would close the session before this response exists.
                        time.sleep(.15)
                        self.event(event="final", markers=markers[:])
                    elif text != "keepalive":
                        raise ValueError("Unexpected local text frame")
        except (BrokenPipeError, ConnectionResetError):
            pass  # The client intentionally closes on stop.
        except Exception as error:
            with self.server.lock:
                self.server.errors.append(str(error))


def run_variant(work, source, name, expected_pass):
    if expected_pass:
        print("Socket source SHA256: " + hashlib.sha256(source.encode()).hexdigest(), flush=True)
    socket_source = work / (name + "-socket.swift")
    socket_source.write_text(source)
    binary = work / name
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-default-isolation", "MainActor",
                    "-parse-as-library", "-module-cache-path", str(work / "modules"),
                    str(ROOT / "Lively/Model/Language.swift"),
                    str(ROOT / "Lively/Networking/SpeechEngine.swift"), str(socket_source),
                    str(Path(__file__).with_name("SocketLifecycleRegression.swift")),
                    "-o", str(binary)], check=True, timeout=90)
    with WebSocketServer() as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        result = subprocess.run([str(binary), "ws://127.0.0.1:" + str(server.server_address[1])],
                                capture_output=True, text=True, timeout=35)
        server.shutdown()
        connections, errors, wire = server.connections[:], server.errors[:], server.wire_events[:]
    eof_streams = [stream["events"] for stream in wire if stream["path"] == "eof"]
    eof_ordered = all(sum(event == "eof" for event, _ in stream) == 1
                      and all(event != "pcm" for event, _ in stream[next(
                          index for index, (event, _) in enumerate(stream) if event == "eof") + 1:])
                      for stream in eof_streams)
    def pcm_streams(path):
        return [[marker for event, marker in stream["events"] if event == "pcm"]
                for stream in wire if stream["path"] == path]

    windows = []
    for line in result.stdout.splitlines():
        if line.startswith("OFFLINE_WINDOW "):
            _, path, began, ended = line.split()
            windows.append((path, float(began), float(ended)))
    quiet_offline = all(
        not (began < stream["connected_at"] < ended)
        and all(not (began < received < ended) for received in stream["received_at"])
        for path, began, ended in windows for stream in wire
        if stream["path"] == path or stream["path"].startswith(path + "/")
    )
    expected_bounded = [0 if index % 3 == 0 else 4_000 + index for index in range(250, 1_000)]
    wire_ok = (connections.count("warm") == 1 and connections.count("eof") == 3
               and connections.count("handshake") == 1 and connections.count("prewarm") == 1
               and connections.count("no-ready") == 1 and "stopped" not in connections and eof_ordered
               and pcm_streams("suspend") == [[0, 4_000, 0], [0, 4_000, 0, 0, 5_000, 6_000, 0]]
               and pcm_streams("paused-suspend") == [[0, 7_000, 0], [0, 7_000, 0]]
               and pcm_streams("suspend-setup") == [[0, 0, 0, 4_000, 5_000, 6_000, 0, 0, 0]]
               and pcm_streams("bounded") == [[]]
               and pcm_streams("bounded/catchup") == [expected_bounded]
               and pcm_streams("retry-paused") == [[], [0, 0, 0, 4_000, 5_000, 6_000, 0, 0, 0]]
               and pcm_streams("eof-suspend") == [[0, 4_000, 0], [0, 4_000, 0, 0, 7_000, 0, 8_000]]
               and connections.count("retry-timeout") >= 2 and not any(pcm_streams("retry-timeout"))
               and {path for path, _, _ in windows} == {"suspend", "paused-suspend", "suspend-setup", "bounded", "eof-suspend"}
               and quiet_offline)
    passed = result.returncode == 0 and wire_ok and not errors
    if expected_pass:
        print(result.stdout, end="")
        if not passed:
            raise RuntimeError(result.stderr + "\nLocal server connections: " + str(connections)
                               + "; errors: " + str(errors) + "; wire: " + str(wire))
        print("PASS: server independently verified ordered PCM, bounded replay, offline silence, connection counts, and stop invalidation")
    elif passed or (result.returncode != 0 and "FAIL:" not in result.stdout):
        raise RuntimeError("Negative control did not fail meaningfully: " + name + "\n"
                           + result.stdout + result.stderr + str(connections) + str(errors))
    else:
        print("PASS: " + name + " detected deliberate corruption")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--negative-controls", action="store_true")
    args = parser.parse_args()
    source = (ROOT / "Lively/Networking/ResilientSocket.swift").read_text()
    variants = [("socket-lifecycle", source, True)]
    if args.negative_controls:
        for name, old, new in [
            ("pause-discards-accepted-audio", "isPaused = true\n        hedgeTask?.cancel()",
             "isPaused = true\n        backlog.removeAll()\n        hedgeTask?.cancel()"),
            ("paused-send-accepted", "func send(_ chunk: Data) {\n        guard isRunning, !isPaused else { return }", "func send(_ chunk: Data) {\n        guard isRunning else { return }"),
            ("warm-resume-reconnects", "guard wasPaused, isRunning else {", "guard false, isRunning else {"),
            ("eof-pause-drops-final-reply", "if let end = dialect.endOfAudioMessage { primary.send(end) }\n            schedulePauseDrainDeadline()",
             "stop()\n            schedulePauseDrainDeadline()"),
            ("rapid-eof-resume-discards-final", "isResumingAfterDrain = true\n            schedulePauseDrainDeadline()",
             "start()\n            schedulePauseDrainDeadline()"),
            ("path-loss-discards-unfinalized-pcm", "hedgeTask?.cancel()\n                dropStandby()\n                tearDownPrimary(keepingAudio: true)",
             "hedgeTask?.cancel()\n                dropStandby()\n                tearDownPrimary(keepingAudio: false)"),
            ("offline-primary-keeps-uploading", "hedgeTask?.cancel()\n                dropStandby()\n                tearDownPrimary(keepingAudio: true)",
             "hedgeTask?.cancel()\n                dropStandby()"),
            ("paused-path-restore-reconnects", "else if isRunning, !isPaused, primary == nil || status == .reconnecting {",
             "else if isRunning, primary == nil || status == .reconnecting {"),
            ("no-primary-resume-discards-backlog", "guard let primary else {\n            connect()\n            return\n        }",
             "guard let primary else {\n            start()\n            return\n        }"),
            ("offline-start-opens-socket", "guard networkAvailable else {\n            status = .reconnecting\n            return\n        }", ""),
            ("paused-retry-discards-backlog", "if isPaused, backlog.isEmpty || !networkAvailable {", "if isPaused {"),
            ("offline-backlog-unbounded", "private static let maxBacklog = 750", "private static let maxBacklog = 1_500"),
            ("paused-retry-resets-drain-deadline", "private func connect() {\n        guard isRunning else { return }",
             "private func connect() {\n        guard isRunning else { return }\n        if isPaused {\n            pauseDrainTask?.cancel()\n            pauseDrainTask = nil\n            schedulePauseDrainDeadline()\n        }"),
            ("path-loss-retains-obsolete-eof-drain", "if !networkAvailable {\n                isResumingAfterDrain = false\n                keepaliveTask?.cancel()\n                keepaliveTask = nil\n                if !isPaused {\n                    pauseDrainTask?.cancel()\n                    pauseDrainTask = nil\n                }",
             "if !networkAvailable {\n                keepaliveTask?.cancel()\n                keepaliveTask = nil"),
        ]:
            if old not in source:
                raise RuntimeError("Update mutation anchor: " + name)
            variants.append((name, source.replace(old, new), False))
        old = "guard let connection, !connection.isClosed, !Task.isCancelled else { return }"
        if old not in source:
            raise RuntimeError("Update stale-setup mutation anchor")
        # Retain cancelled setup work so dropping its invalidation guard is
        # observable even when ARC would otherwise release the old connection.
        retained = source.replace("connection.tasks.append(Task { [weak self, weak connection] in",
                                  "connection.tasks.append(Task { [weak self, weak connection, retainedConnection = connection] in", 1)
        variants.append(("stale-setup-opens-after-stop",
                         retained.replace(old, "guard let connection = Optional(retainedConnection) else { return }"), False))
    with tempfile.TemporaryDirectory(prefix="lively-socket-lifecycle-") as directory:
        for name, actual, positive in variants:
            run_variant(Path(directory), actual, name, positive)


if __name__ == "__main__":
    main()
