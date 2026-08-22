#!/usr/bin/env python3
"""run-local.py — the client front end on your Mac, with live reload.

    python3 run-local.py --watch    front-end work: edit the generator, see it
    python3 run-local.py            just look at what is on disk
    python3 run-local.py --build    rebuild the council files first
    python3 run-local.py --port 9000

EDIT THE GENERATOR, NOT THE PAGE
--------------------------------
`index.html` is written by `build_platform.py` in CouncilIntel. Editing the
page directly works until the next rebuild and then vanishes without a word —
which is how an entire tab, the peer ranks and the debt trend came to exist
only in the published file and not in the thing that produces it.

`--watch` closes that loop: save `build_platform.py`, the page rebuilds, the
browser reloads a few seconds later, back on the tab you were on. It is the
mode to use for front-end work; the others are for looking.

Standard library only, nothing to install, no build step — same promise as the
rest of the estate. Stop it with Ctrl-C.

WHY NOT `python3 -m http.server`
--------------------------------
Three things it gets wrong for this site, each of which costs a few minutes
every time and is invisible while it is happening.

**It caches.** `index.html` is 3MB and the browser is delighted to keep it.
You edit, you refresh, you see the old page and conclude the edit did nothing.
Safari makes this worse: Cmd+Shift+R opens Reader view rather than forcing a
reload, so the usual escape hatch is not there. Everything here is served
`no-store`, so a plain Cmd+R is always enough.

**It cannot tell you the page moved.** This reloads by itself the moment
`index.html` or the council data changes on disk — and puts you back on the
tab and the scroll position you were on, because being thrown back to Market
pulse after every edit to the Exposure table is how you stop making small
edits.

**It serves stale council data without saying so.** `--build` regenerates the
per-council files from CouncilIntel before starting, and the banner says how
old they are either way. Reviewing the front end against month-old figures
and concluding a panel is broken is a real way to lose an afternoon.

WHAT IT DOES NOT DO
-------------------
It never writes to the repository and never pushes. `gh-pages` is what
publishes; this is a preview of your working tree and nothing more. The live
reload is injected into the response, not into the file, so what you commit
stays exactly what you wrote.
"""
from __future__ import annotations

import argparse
import functools
import http.server
import json
import os
import socket
import subprocess
import sys
import threading
import time
import webbrowser
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
COUNCILS = os.path.join(HERE, "councils")
INDEX = os.path.join(HERE, "index.html")
# CouncilIntel is expected beside this repo, the same way batch.py expects this
# repo beside it. Override if yours lives somewhere else.
INTEL = os.environ.get("COUNCILINTEL_DIR", os.path.join(os.path.dirname(HERE),
                                                        "CouncilIntel"))
PORT = int(os.environ.get("STREAM_PORT", "8030"))

# Injected into index.html on its way out, never written to disk.
LIVE = """
<script>
/* Local preview only — injected by run-local.py, not part of the site. */
(function () {
  var KEY = 'devReloadState';
  try {
    var s = JSON.parse(sessionStorage.getItem(KEY) || 'null');
    if (s) {
      sessionStorage.removeItem(KEY);
      // Put the page back where it was. Without this every edit throws you
      // to Market pulse and you stop making small edits.
      if (s.tab) {
        var b = document.querySelector('nav.tabs button[data-v="' + s.tab + '"]');
        if (b) b.click();
      }
      if (s.y) setTimeout(function () { window.scrollTo(0, s.y); }, 120);
    }
  } catch (e) {}

  var seen = null;
  function poll() {
    fetch('/__watch', { cache: 'no-store' })
      .then(function (r) { return r.json(); })
      .then(function (d) {
        if (seen === null) { seen = d.v; return; }
        if (d.v === seen) return;
        try {
          var tab = document.querySelector('nav.tabs button[aria-selected="true"]');
          sessionStorage.setItem(KEY, JSON.stringify({
            tab: tab ? tab.dataset.v : null,
            y: window.scrollY | 0
          }));
        } catch (e) {}
        location.reload();
      })
      .catch(function () { /* server stopped — say nothing, keep trying */ });
  }
  setInterval(poll, 1000);
  poll();
})();
</script>
"""


def fingerprint():
    """What the page watches. Cheap enough to stat every second."""
    bits = []
    for p in (INDEX, os.path.join(COUNCILS, "index.json"),
              os.path.join(COUNCILS, "upcoming.json")):
        try:
            bits.append(f"{os.path.getmtime(p):.3f}")
        except OSError:
            bits.append("-")
    return ":".join(bits)


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=HERE, **k)

    def do_GET(self):
        if self.path.split("?")[0] == "/__watch":
            body = json.dumps({"v": fingerprint()}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self._nocache()
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path.split("?")[0] in ("/", "/index.html"):
            return self._index()
        return super().do_GET()

    def _index(self):
        try:
            html = open(INDEX, "rb").read()
        except OSError as e:
            self.send_error(500, f"cannot read index.html: {e}")
            return
        inject = LIVE.encode()
        i = html.rfind(b"</body>")
        html = (html[:i] + inject + html[i:]) if i != -1 else html + inject
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(html)))
        self._nocache()
        self.end_headers()
        self.wfile.write(html)

    def end_headers(self):
        # Belt and braces: everything, not just the page. A cached
        # councils/index.json is the same lost afternoon as a cached page.
        if not self._sent_nocache:
            self._nocache()
        super().end_headers()

    _sent_nocache = False

    def _nocache(self):
        self._sent_nocache = True
        self.send_header("Cache-Control", "no-store, must-revalidate")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")

    def log_message(self, fmt, *args):
        # The watch poll is once a second and would bury everything else.
        if "__watch" in (args[0] if args else ""):
            return
        sys.stderr.write("  %s\n" % (fmt % args))


def build():
    """Regenerate the per-council files from CouncilIntel."""
    mg = os.path.join(INTEL, "monitor")
    if not os.path.isdir(mg):
        print(f"\n  No CouncilIntel at {INTEL} — skipping the rebuild.")
        print("  Set COUNCILINTEL_DIR if it lives somewhere else.\n")
        return False
    print(f"\n  Rebuilding the council files from {INTEL} …\n")
    r = subprocess.run([sys.executable, "-m", "mg.site_data", "--out", COUNCILS],
                       cwd=mg)
    if r.returncode != 0:
        print("\n  The rebuild failed. Serving whatever is already on disk.\n")
        return False
    return True


def build_page(quiet=False):
    """Regenerate index.html from the generator that owns it."""
    site = os.path.join(INTEL, "monitor", "site")
    gen = os.path.join(site, "build_platform.py")
    if not os.path.isfile(gen):
        if not quiet:
            print(f"\n  No build_platform.py at {gen} — skipping.\n")
        return False
    if not quiet:
        print("\n  Rebuilding index.html …\n")
    r = subprocess.run([sys.executable, gen, "--out", INDEX], cwd=site,
                       capture_output=quiet, text=True)
    if r.returncode != 0:
        print("\n  The page rebuild FAILED — the page on disk is unchanged.")
        if quiet and r.stderr:
            print("  " + r.stderr.strip().splitlines()[-1][:160])
        print()
        return False
    if quiet:
        print("  index.html rebuilt — the page will reload itself")
    return True


def watch_generator():
    """Rebuild the page whenever the generator changes.

    Without this the loop is broken for the file you are actually editing.
    `index.html` is GENERATED by build_platform.py in CouncilIntel, so editing
    the page directly is work that survives until the next rebuild and then
    disappears. Watching the generator means you edit the right file and still
    get the page in front of you a few seconds later.
    """
    site = os.path.join(INTEL, "monitor", "site")
    gen = os.path.join(site, "build_platform.py")
    if not os.path.isfile(gen):
        print(f"  watch: no generator at {gen} — not watching")
        return
    last = os.path.getmtime(gen)
    while True:
        time.sleep(1.0)
        try:
            now = os.path.getmtime(gen)
        except OSError:
            continue
        if now == last:
            continue
        last = now
        # Editors write in bursts; let the file settle before reading it.
        time.sleep(0.4)
        print("\n  build_platform.py changed — rebuilding the page…")
        build_page(quiet=True)


def data_age():
    try:
        d = json.load(open(os.path.join(COUNCILS, "index.json"), encoding="utf-8"))
    except Exception:                                          # noqa: BLE001
        return "no council data — run with --build"
    mt = os.path.getmtime(os.path.join(COUNCILS, "index.json"))
    days = (time.time() - mt) / 86400
    when = ("built today" if days < 1 else
            "built yesterday" if days < 2 else
            f"built {int(days)} days ago")
    n = d.get("councils")
    return (f"{n if isinstance(n, int) else '?'} councils, "
            f"{d.get('papers', 0):,} papers · {when} "
            f"({datetime.fromtimestamp(mt).strftime('%a %d %b %H:%M')})")


def _page_line():
    """Say what the page on disk actually is. An empty Market pulse is a valid
    page and looks like a quiet week, so it is called out rather than left to
    be noticed on the tab."""
    try:
        html = open(INDEX, encoding="utf-8", errors="replace").read()
    except OSError as e:
        return f"unreadable — {e}"
    mt = os.path.getmtime(INDEX)
    cards = html.count('"rung"')
    return (f"{len(html.encode('utf-8', 'replace')) // 1024:,} KB, "
            f"{cards if cards else 'NO'} pulse cards · built "
            f"{datetime.fromtimestamp(mt).strftime('%a %d %b %H:%M')}")


def free(port):
    with socket.socket() as s:
        s.settimeout(0.4)
        return s.connect_ex(("127.0.0.1", port)) != 0


def main():
    ap = argparse.ArgumentParser(
        description="Preview the client front end locally, with live reload.")
    ap.add_argument("--build", "-b", action="store_true",
                    help="rebuild the council files from CouncilIntel first")
    ap.add_argument("--page", "-p", action="store_true",
                    help="rebuild index.html from build_platform.py first")
    ap.add_argument("--watch", "-w", action="store_true",
                    help="rebuild index.html whenever build_platform.py changes")
    ap.add_argument("--port", type=int, default=PORT)
    ap.add_argument("--no-open", action="store_true",
                    help="do not open a browser")
    a = ap.parse_args()

    if not os.path.isfile(INDEX):
        sys.exit(f"No index.html in {HERE} — is this the right folder?")
    if a.build:
        build()
    if a.page or a.watch:
        build_page()
    if not free(a.port):
        sys.exit(f"\n  Port {a.port} is already in use. Stop that server, or "
                 f"pass --port.\n")

    url = f"http://localhost:{a.port}/"
    print(f"\n{'=' * 66}")
    print("  PWLBpulse — local preview")
    print(f"{'=' * 66}\n")
    print(f"  serving   {HERE}")
    print(f"  page      {_page_line()}")
    print(f"  data      {data_age()}")
    print(f"  reload    on, watching index.html and councils/"
          + (" and build_platform.py" if a.watch else ""))
    print(f"  caching   off — a plain Cmd+R is always enough\n")
    print(f"  open      {url}\n")
    if a.watch:
        print("  Edit build_platform.py in CouncilIntel — the page rebuilds and")
        print("  reloads itself, back on the tab and scroll position you were on.")
    else:
        print("  index.html is GENERATED by build_platform.py in CouncilIntel.")
        print("  Editing it here works until the next rebuild and then vanishes —")
        print("  run with --watch to edit the generator and see it live instead.")
    print("  Ctrl-C to stop.\n")

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", a.port), Handler)
    if a.watch:
        threading.Thread(target=watch_generator, daemon=True).start()
    if not a.no_open:
        threading.Timer(0.6, functools.partial(webbrowser.open, url)).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n  stopped\n")


if __name__ == "__main__":
    main()
