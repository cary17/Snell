#!/usr/bin/env python3
"""Single production image v3-v5 interop via Mihomo; CI runs as root.

Default v3 TLS, v5 QUIC, v6 forwarding and stability/performance tests are
deferred, not removed from the server. UDP relay below is not QUIC acceptance.
"""
import hashlib
import http.server
import ipaddress
import json
import os
from pathlib import Path
import socket
import socketserver
import struct
import subprocess
import sys
import tempfile
import threading
import time


IMAGE = os.environ["SNELL_TEST_IMAGE"]
CLIENT = os.environ.get("SNELL_CLIENT_IMAGE",
                        "metacubex/mihomo@sha256:739edd73a352d6beb82fad6790ef9d417a4d6f061584cc3cab1bd4536d1c60e5")
PAYLOAD = bytes(range(256)) * 4096
RESULTS = Path(os.environ.get("SNELL_TEST_RESULTS") or tempfile.mkdtemp(prefix="snell-forwarding-")).resolve()
RESULTS.mkdir(parents=True, exist_ok=True)
DNS_QUERIES = []


def docker(*args, check=True):
    return subprocess.run(["docker", *args], check=check, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=40).stdout.strip()


def recv(sock, size):
    data = b""
    while len(data) < size:
        part = sock.recv(size - len(data))
        if not part:
            raise EOFError("SOCKS peer closed")
        data += part
    return data


def address(host):
    try:
        ip = ipaddress.ip_address(host)
        return bytes([1 if ip.version == 4 else 4]) + ip.packed
    except ValueError:
        name = host.encode("ascii")
        return b"\x03" + bytes([len(name)]) + name


def socks(port, host, target_port, command=1):
    sock = socket.create_connection(("127.0.0.1", port), timeout=8)
    try:
        sock.sendall(b"\x05\x01\x00")
        assert recv(sock, 2) == b"\x05\x00"
        sock.sendall(bytes([5, command, 0]) + address(host) + struct.pack("!H", target_port))
        header = recv(sock, 4)
        assert header[:2] == b"\x05\x00", header
        if header[3] == 1:
            bound = socket.inet_ntop(socket.AF_INET, recv(sock, 4))
        elif header[3] == 4:
            bound = socket.inet_ntop(socket.AF_INET6, recv(sock, 16))
        else:
            bound = recv(sock, recv(sock, 1)[0]).decode()
        return sock, (bound, struct.unpack("!H", recv(sock, 2))[0])
    except BaseException:
        sock.close()
        raise


class HTTP(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", str(len(PAYLOAD)))
        self.end_headers()
        self.wfile.write(PAYLOAD)

    def log_message(self, *_):
        pass


class HTTP6(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET6


class Echo(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        sock.sendto(data, self.client_address)


class DNS(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        end = 12
        while data[end]:
            end += data[end] + 1
        end += 5
        query_type = struct.unpack("!H", data[end - 4:end - 2])[0]
        DNS_QUERIES.append(query_type)
        answer = b""
        if query_type == 1:
            answer = b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 30, 4) + socket.inet_aton("127.0.0.1")
        reply = data[:2] + struct.pack("!HHHHH", 0x8180, 1, bool(answer), 0, 0) + data[12:end] + answer
        sock.sendto(reply, self.client_address)


def http_check(proxy_port, host, port):
    conn, _ = socks(proxy_port, host, port)
    with conn:
        conn.sendall(b"GET / HTTP/1.0\r\nHost: snell-test.invalid\r\n\r\n")
        response = bytearray()
        while part := conn.recv(65536):
            response.extend(part)
    assert b"\r\n\r\n" in response, "No complete HTTP response through proxy"
    body = response.split(b"\r\n\r\n", 1)[1]
    assert hashlib.sha256(body).digest() == hashlib.sha256(PAYLOAD).digest(), (
        f"HTTP payload mismatch: received={len(body)} expected={len(PAYLOAD)}")


def udp_check(proxy_port, target_port):
    control, relay = socks(proxy_port, "0.0.0.0", 0, command=3)
    with control, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(8)
        packet = b"\0\0\0" + address("127.0.0.1") + struct.pack("!H", target_port)
        payload = b"snell-alpine-udp-echo" * 20
        sock.sendto(packet + payload, ("127.0.0.1", relay[1]))
        reply, _ = sock.recvfrom(65535)
        assert reply == packet + payload


def supports_dns(version):
    return not version.startswith(("v3.", "v4.0."))


def probe(version):
    fixtures = [http.server.ThreadingHTTPServer(("127.0.0.1", 0), HTTP),
                HTTP6(("::1", 0), HTTP), socketserver.ThreadingUDPServer(("127.0.0.1", 0), Echo),
                socketserver.ThreadingUDPServer(("127.0.0.1", 53), DNS)]
    for fixture in fixtures:
        threading.Thread(target=fixture.serve_forever, daemon=True).start()
    try:
        for _ in range(60):
            try:
                with socket.create_connection(("127.0.0.1", 1080), timeout=0.2):
                    break
            except OSError:
                time.sleep(0.2)
        time.sleep(0.5)
        for _ in range(5):
            http_check(1080, "127.0.0.1", fixtures[0].server_address[1])
        print("TCP 5x1MiB passed", flush=True)
        http_check(1080, "::1", fixtures[1].server_address[1])
        print("IPv6 passed", flush=True)
        udp_check(1080, fixtures[2].server_address[1])
        print("UDP passed", flush=True)
        if supports_dns(version):
            before = len(DNS_QUERIES)
            http_check(1080, "snell-test.invalid", fixtures[0].server_address[1])
            assert len(DNS_QUERIES) > before, "Custom server DNS was not used"
            print("DNS passed", flush=True)
    finally:
        for fixture in fixtures:
            fixture.shutdown()
            fixture.server_close()


def main():
    server, client = f"snell-e2e-server-{os.getpid()}", f"snell-e2e-client-{os.getpid()}"
    rows = []
    version = "v" + docker("run", "--rm", "--platform", "linux/amd64", "--entrypoint", "cat", IMAGE, "/snell-version").removeprefix("v")
    expected = os.environ.get("SNELL_TEST_VERSION", version)
    assert version.removeprefix("v") == expected.removeprefix("v"), "Image version mismatch"
    assert version.startswith(("v3.", "v4.", "v5.")), "Forwarding acceptance only covers v3-v5; v6 deferred"
    docker("run", "--rm", "--platform", "linux/amd64", "--entrypoint", "/snell/snell-server", IMAGE, "--version")
    try:
        for version in [version]:
            cases = ["plain", "http"]  # v3 TLS is deliberately not a default test.
            if version.startswith("v5"):
                cases.append("egress")
            for case in os.environ.get("SNELL_TEST_CASES", " ".join(cases)).split():
                snell_port, proxy_port = 32000, 1080
                extra = ["-e", f"OBFS={case}", "-e", "HOST=example.com"] if case in ("http", "tls") else []
                if case == "egress":
                    extra += ["-e", "EGRESS_INTERFACE=lo"]
                proxy = {"name": "snell", "type": "snell", "server": "127.0.0.1", "port": snell_port,
                         "psk": "RegressionOnlyPsk16", "version": int(version[1]), "udp": True,
                         "reuse": not version.startswith("v3")}
                if case in ("http", "tls"):
                    proxy["obfs-opts"] = {"mode": case, "host": "example.com"}
                config = RESULTS / f"{version}-{case}.json"
                config.write_text(json.dumps({"socks-port": proxy_port, "allow-lan": False, "ipv6": True,
                                              "mode": "rule", "log-level": "info", "proxies": [proxy],
                                              "rules": ["MATCH,snell"]}))
                try:
                    docker("run", "-d", "--platform", "linux/amd64", "--name", server, "--network", "none",
                           "-e", f"LISTEN=127.0.0.1:{snell_port}", "-e", "PSK=RegressionOnlyPsk16", "-e", "IPV6=true",
                           "-e", "DNS=127.0.0.1", *extra, IMAGE)
                    docker("run", "-d", "--name", client, "--network", f"container:{server}", "-v", f"{config}:/config.json:ro",
                           CLIENT, "-f", "/config.json")
                    pid = docker("inspect", "--format", "{{.State.Pid}}", server)
                    result = subprocess.run(["nsenter", "-t", pid, "-n", sys.executable,
                                             str(Path(__file__).resolve()), "--probe", version],
                                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                            text=True, timeout=90)
                    (RESULTS / f"{version}-{case}-probe.log").write_text(result.stdout)
                    assert result.returncode == 0, result.stdout.strip()
                    row = f"{version}\t{case}\tPASS: TCP 5x1MiB, IPv6, UDP" + (", DNS" if supports_dns(version) else "")
                    rows.append(row)
                    print(row, flush=True)
                except Exception as exc:
                    row = f"{version}\t{case}\tFAIL: {type(exc).__name__}: {str(exc).splitlines()[-1] if str(exc) else 'check failed'}"
                    rows.append(row)
                    print(row, flush=True)
                finally:
                    for name in (client, server):
                        (RESULTS / f"{version}-{case}-{name.split('-')[2]}.log").write_text(docker("logs", name, check=False))
                        docker("rm", "-f", name, check=False)
    finally:
        (RESULTS / "results.tsv").write_text("\n".join(rows) + "\n")

    if any("\tFAIL:" in row for row in rows):
        raise SystemExit(1)

if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--probe":
        probe(sys.argv[2])
    else:
        main()
