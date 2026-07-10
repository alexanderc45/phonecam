#!/usr/bin/env python3
"""
BeamNG Phone Camera — relay server.

Does three jobs:
  1. Serves the web client (../web) over HTTP(S) so the phone can load it.
  2. Accepts a WebSocket connection from the phone and receives telemetry.
  3. Forwards every telemetry message, unchanged, as a UDP datagram to
     BeamNG.drive (the Lua mod listens on udp_host:udp_port).

The payload is passed through verbatim (JSON text) — all math happens on
the phone (Euler -> quaternion) and in the Lua mod (frame conversion),
so this server stays a dumb, low-latency pipe.

Usage:
    pip install websockets
    python relay_server.py                       # defaults: http 8080, ws 8081, udp 127.0.0.1:4444
    python relay_server.py --udp-host 192.168.1.50   # game runs on another PC
    python relay_server.py --cert cert.pem --key key.pem   # HTTPS/WSS (needed for iOS)
"""

import argparse
import asyncio
import functools
import http.server
import pathlib
import socket
import ssl
import sys
import threading

try:
    import websockets
except ImportError:
    sys.exit("Missing dependency: run  pip install websockets")

# When frozen into a PyInstaller onefile exe, bundled data (the web client)
# is unpacked to a temp dir exposed as sys._MEIPASS; otherwise use the repo.
if getattr(sys, "frozen", False):
    WEB_DIR = pathlib.Path(sys._MEIPASS) / "web"  # type: ignore[attr-defined]
else:
    WEB_DIR = pathlib.Path(__file__).resolve().parent.parent / "web"


def lan_ip() -> str:
    """Best-effort LAN IP discovery: open a UDP socket toward a public
    address (no packets are actually sent) and read the chosen source IP."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("8.8.8.8", 80))
            return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"


def print_qr(url: str) -> None:
    """Render the phone URL as an ASCII QR code in the console so players
    can scan it instead of typing an IP address. Optional dependency —
    silently skipped if qrcode isn't installed or the console can't
    display the block characters."""
    try:
        import qrcode

        qr = qrcode.QRCode(border=1)
        qr.add_data(url)
        qr.print_ascii(invert=True)
    except Exception:
        pass


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    """Static file handler for the web client; silences per-request logging."""

    def log_message(self, *args):
        pass


def start_http_server(port: int, ssl_ctx: ssl.SSLContext | None) -> None:
    handler = functools.partial(QuietHandler, directory=str(WEB_DIR))
    httpd = http.server.ThreadingHTTPServer(("0.0.0.0", port), handler)
    if ssl_ctx:
        httpd.socket = ssl_ctx.wrap_socket(httpd.socket, server_side=True)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()


async def main() -> None:
    ap = argparse.ArgumentParser(description="Phone -> BeamNG telemetry relay")
    ap.add_argument("--http-port", type=int, default=8080, help="web client port (default 8080)")
    ap.add_argument("--ws-port", type=int, default=8081, help="WebSocket port (default 8081)")
    ap.add_argument("--udp-host", default="127.0.0.1", help="where BeamNG runs (default 127.0.0.1)")
    ap.add_argument("--udp-port", type=int, default=4444, help="UDP port the Lua mod listens on (default 4444)")
    ap.add_argument("--cert", help="TLS certificate (PEM) — enables HTTPS/WSS")
    ap.add_argument("--key", help="TLS private key (PEM)")
    args = ap.parse_args()

    ssl_ctx = None
    if args.cert and args.key:
        ssl_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ssl_ctx.load_cert_chain(args.cert, args.key)

    # Fire-and-forget UDP socket toward BeamNG. UDP is the right transport
    # here: stale orientation frames are worthless, so no retransmits wanted.
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp_target = (args.udp_host, args.udp_port)

    stats = {"packets": 0}

    async def ws_handler(websocket):
        peer = websocket.remote_address[0]
        print(f"[ws] phone connected from {peer}")
        try:
            async for message in websocket:
                if isinstance(message, str):
                    message = message.encode("utf-8")
                udp.sendto(message, udp_target)
                stats["packets"] += 1
        except websockets.ConnectionClosed:
            pass
        finally:
            print(f"[ws] phone disconnected ({peer})")

    async def report_rate():
        while True:
            await asyncio.sleep(5)
            if stats["packets"]:
                print(f"[udp] {stats['packets'] / 5:.0f} packets/s -> {udp_target[0]}:{udp_target[1]}")
                stats["packets"] = 0

    start_http_server(args.http_port, ssl_ctx)

    scheme = "https" if ssl_ctx else "http"
    ip = lan_ip()
    url = f"{scheme}://{ip}:{args.http_port}"
    print("=" * 60)
    print("BeamNG Phone Camera relay is running")
    print(f"  1. On your phone (same Wi-Fi), open:  {url}")
    print("     ...or scan this QR code:")
    print_qr(url)
    print(f"  2. Telemetry: WebSocket :{args.ws_port}  ->  UDP {udp_target[0]}:{udp_target[1]}")
    print("  3. Start BeamNG, enable free camera (Shift+C), tap 'Start streaming'")
    print("Press Ctrl+C to stop.")
    print("=" * 60)

    async with websockets.serve(ws_handler, "0.0.0.0", args.ws_port, ssl=ssl_ctx):
        await report_rate()  # runs forever


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\nStopped.")
    except Exception as exc:  # keep the console window readable when the
        print(f"\nERROR: {exc}")  # exe was double-clicked and something
        if getattr(sys, "frozen", False):  # failed (e.g. port already in use)
            input("Press Enter to close...")
        raise
