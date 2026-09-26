#!/usr/bin/env python3
"""Headless Firefox check of the built app (lot G6b), Playwright-free, Python 3 stdlib only.

Serves client/dist/ (``npm run build`` after ``vm/scripts/build.sh``), opens a wrapper page whose
load event is held for ``--hold`` seconds (an image the server answers late) around the app with
``?autoshot=<pulls>``, so that ``firefox --headless --screenshot`` shoots after the shot; the page's
console goes to stdout (``devtools.console.stdout.content``) and is printed with timestamps.

    python3 client/vm/scripts/browser-check.py [--pulls=-600,-392] [--hold=40] [--out=shot.png]
                                               [--firefox=/path/to/firefox] [--timeout=180]

``--firefox`` names the binary (default ``$FIREFOX``, else ``firefox`` on PATH); ``--timeout`` is how
long Firefox may run past ``--hold`` before it is killed (exit status 1, no screenshot). The page's
console lines are printed live, the screenshot path at the end; the exit status is 0 only when
Firefox exited 0 and wrote the screenshot.

Written by G6b without a browser to run it (the sandbox refused to launch Firefox), made
configurable by H1 (whose sandbox refused too): unverified where Firefox cannot be launched.
"""

from __future__ import annotations

import argparse
import functools
import http.server
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

DIST = Path(__file__).resolve().parents[2] / "dist"


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map, ".wasm": "application/wasm", ".js": "text/javascript"}
    wrapper = ""
    hold = 0.0

    def do_GET(self):  # noqa: N802 (http.server's name)
        if self.path.startswith("/check.html"):
            return self.reply(200, "text/html", self.wrapper.encode())
        if self.path.startswith("/hold"):
            time.sleep(self.hold)
            return self.reply(200, "image/svg+xml", b'<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>')
        return super().do_GET()

    def reply(self, code: int, kind: str, body: bytes) -> None:
        self.send_response(code)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args) -> None:
        pass


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--pulls", default="-600,-392", help="px,py[;px,py...] released in order")
    parser.add_argument("--hold", type=float, default=40.0, help="seconds before the screenshot")
    parser.add_argument("--out", default="browser-check.png")
    parser.add_argument("--firefox", default=os.environ.get("FIREFOX", "firefox"), help="Firefox binary (default $FIREFOX, else PATH)")
    parser.add_argument("--timeout", type=float, default=180.0, help="seconds Firefox may run past --hold before it is killed")
    args = parser.parse_args()
    firefox = shutil.which(args.firefox)
    if firefox is None:
        sys.exit(f"firefox not found ({args.firefox!r}): pass --firefox <path> or set $FIREFOX")
    if not (DIST / "vm" / "pkg").is_dir():
        sys.exit("client/dist/vm/pkg missing: run client/vm/scripts/build.sh, then npm run build")

    Handler.hold = args.hold
    Handler.wrapper = (
        '<!doctype html><body style="margin:0">'
        f'<iframe src="/?autoshot={args.pulls}" style="border:0;width:1280px;height:720px"></iframe>'
        '<img src="/hold" alt=""></body>'
    )
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Handler, directory=str(DIST)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{server.server_address[1]}/check.html"
    out = Path(args.out).resolve()

    killed = threading.Event()

    def kill() -> None:
        killed.set()
        proc.kill()

    with tempfile.TemporaryDirectory() as profile:
        Path(profile, "user.js").write_text('user_pref("devtools.console.stdout.content", true);\n')
        cmd = [firefox, "--headless", "--no-remote", "--profile", profile,
               "--window-size", "1280,760", "--screenshot", str(out), url]
        t0 = time.monotonic()
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        assert proc.stdout is not None
        watchdog = threading.Timer(args.hold + args.timeout, kill)
        watchdog.start()
        try:
            for line in proc.stdout:
                if "console" in line.lower() or "shot" in line or "level" in line or "outputs" in line or "vm:" in line:
                    print(f"[{time.monotonic() - t0:7.2f} s] {line.rstrip()}")
            proc.wait()
        finally:
            watchdog.cancel()
    server.shutdown()
    if killed.is_set():
        sys.exit(f"firefox killed after {args.hold + args.timeout:.0f} s (--hold + --timeout); no screenshot")
    print(f"screenshot: {out} (firefox exit {proc.returncode})")
    sys.exit(0 if proc.returncode == 0 and out.is_file() else 1)


if __name__ == "__main__":
    main()
