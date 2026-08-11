#!/bin/bash
#
# Reads the front page of every council paper you have downloaded, and writes a
# small index of what each one actually is.
#
# WHY THIS EXISTS
#   We pick each council's "current" treasury strategy, accounts and outturn
#   from the document's title. Titles lie: an appendix of last year's prudential
#   indicators looks like a strategy, and the pension fund's accounts look like
#   the council's. The only way to be sure is to open the paper — but the papers
#   are 100KB of text each and there are thousands of them, so opening all of
#   them centrally is not sensible.
#
#   A paper says what it is on its first page. This pulls that first page out of
#   every PDF, on your Mac, where the files already are, and writes one compact
#   file. That file syncs to Drive and the platform reads it — a few megabytes
#   instead of gigabytes, and every "current paper" pick gets checked against
#   what the document actually says.
#
#   Nothing is uploaded except the extracted text. No PDFs leave your Mac beyond
#   the Drive sync you already have.
#
# RUNNING IT
#   Paste this into Terminal:
#
#     curl -fsSL https://philsmith871010-stack.github.io/pwlbtoday-stream/extract-headers.command | bash
#
#   First run installs one small Python package (pypdf) and takes a few minutes.
#   After that it only reads papers it has not seen, so it finishes in seconds.

set -uo pipefail

DEST="${DEST:-$HOME/Documents/PWLBtoday Council Papers}"
OUT="${OUT:-$DEST/_headers.jsonl}"
CHARS="${CHARS:-2000}"

cyn=$'\033[36m'; grn=$'\033[32m'; ylw=$'\033[33m'; dim=$'\033[2m'; off=$'\033[0m'

[ -d "$DEST" ] || { echo "${ylw}No papers folder at:${off} $DEST"; exit 1; }
echo "${cyn}Reading from:${off} $DEST"

PY="$(command -v python3 || true)"
[ -n "$PY" ] || { echo "${ylw}Python 3 not found. macOS ships it with Xcode command line tools:"
                  echo "  xcode-select --install${off}"; exit 1; }

if ! "$PY" -c "import pypdf" >/dev/null 2>&1; then
  echo "${dim}Installing pypdf (one time)…${off}"
  "$PY" -m pip install --quiet --user --disable-pip-version-check pypdf 2>/dev/null \
    || "$PY" -m pip install --quiet --break-system-packages pypdf 2>/dev/null \
    || { echo "${ylw}Could not install pypdf. Try:  python3 -m pip install --user pypdf${off}"; exit 1; }
fi

DEST="$DEST" OUT="$OUT" CHARS="$CHARS" "$PY" <<'PYEOF'
import json, logging, os, sys, warnings
warnings.filterwarnings("ignore")
# pypdf narrates every malformed PDF to stderr ("EOF marker not found", "Object
# stream not found"). Council PDFs are full of that and none of it is
# actionable — a run that prints it looks like it is failing when it is working.
# The per-file error is recorded in the index instead, where it can be counted.
logging.getLogger("pypdf").setLevel(logging.CRITICAL)
from pypdf import PdfReader

dest = os.environ["DEST"]; out = os.environ["OUT"]; n_chars = int(os.environ["CHARS"])

# Anything already indexed is skipped, so a second run costs nothing. Keyed on
# filename because that is what the platform joins on.
done = {}
if os.path.exists(out):
    for line in open(out, encoding="utf-8"):
        try:
            r = json.loads(line); done[r["filename"]] = True
        except Exception:
            pass

pdfs = sorted(f for f in os.listdir(dest)
              if f.lower().endswith(".pdf") and not f.startswith("."))
todo = [f for f in pdfs if f not in done]
print(f"{len(pdfs):,} papers, {len(done):,} already indexed, {len(todo):,} to read.")
if not todo:
    print("Nothing to do."); sys.exit(0)

ok = bad = 0
with open(out, "a", encoding="utf-8") as fh:
    for i, f in enumerate(todo, 1):
        try:
            r = PdfReader(os.path.join(dest, f))
            # First two pages: councils put the report title on page 1 and the
            # recommendation on page 2, and between them they say what the paper
            # is and which financial year it covers.
            txt = ""
            for pg in r.pages[:2]:
                txt += (pg.extract_text() or "") + "\n"
                if len(txt) >= n_chars:
                    break
            fh.write(json.dumps({"filename": f, "pages": len(r.pages),
                                 "head": " ".join(txt.split())[:n_chars]}) + "\n")
            ok += 1
        except Exception as e:                               # noqa: BLE001
            # A paper we cannot read is recorded as such rather than skipped —
            # otherwise every run retries it forever and the count never settles.
            fh.write(json.dumps({"filename": f, "error": type(e).__name__}) + "\n")
            bad += 1
        if i % 100 == 0 or i == len(todo):
            print(f"   {i:,}/{len(todo):,}   {ok:,} read, {bad:,} unreadable")

print(f"\nDone. {ok:,} papers indexed, {bad:,} could not be read.")
print(f"Written to: {out}")
PYEOF

echo "${grn}Google Drive will sync that file up. Nothing else to do.${off}"
