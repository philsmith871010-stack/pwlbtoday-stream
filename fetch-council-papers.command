#!/bin/bash
#
# Downloads the council papers PWLBtoday has asked for, into your Google Drive
# folder, with the exact filenames the platform expects.
#
# PWLBtoday watches every ModernGov council's committee calendar and works out
# which papers matter. It cannot download them itself — the councils' document
# servers refuse requests from data centres — so this does that one step from
# your Mac, where they are served normally.
#
# It is deliberately dull. It reads a list, downloads what is missing, names
# each file exactly as the platform expects, and stops. Running it twice is
# harmless: anything already on disk is skipped.
#
# Nothing is sent anywhere. No credentials, no API keys, no account. The files
# land in a folder Google Drive already syncs, and the platform reads them there.
#
# INSTALLING IT
#   Paste the one line in INSTALL at the bottom of this file into Terminal, once.
#   It puts a "Get Council Papers" icon on your Desktop and makes it runnable.
#   Installing by curl rather than by browser download matters: a browser marks
#   the file as quarantined and macOS then refuses to open it. curl does not, so
#   there is no "unidentified developer" box to argue with.
#
# AFTER THAT
#   Double-click the Desktop icon whenever the ops page shows papers waiting, or
#   leave it to the schedule (see SCHEDULING at the bottom of this file).
#
# Uses only curl, which every Mac has. No Homebrew, no Python, no jq.

set -uo pipefail

MANIFEST_URL="${MANIFEST_URL:-https://philsmith871010-stack.github.io/pwlbtoday-stream/fetch-manifest.tsv}"
# Only fetch what is actually needed. The list knows about thousands of papers
# across every council and every date; almost none of them are wanted today.
# Three settings, each a superset of the one before:
#
#   high      the live window at the committees where money is decided —
#             roughly seven papers a day once you are current. The default.
#   reading   everything the platform could ever open: every fallback link of
#             every document type it reads, for every council. About 900 more
#             than "high" and the right setting for a one-off catch-up.
#   all       every paper on the list, including thousands the platform has no
#             use for. Hours, and gigabytes. Rarely the right answer.
#
#     WANT=reading ./fetch-council-papers.command
WANT="${WANT:-high}"
# The tiers nest, so asking for "reading" must also take "high" — otherwise the
# widest setting silently skips the most urgent papers.
tier_wanted() {
  case "$WANT" in
    all)     return 0 ;;
    reading) case "${1:-normal}" in high|reading) return 0 ;; *) return 1 ;; esac ;;
    *)       [ "${1:-normal}" = "$WANT" ] ;;
  esac
}
# Limit to one council if you want, by name or part of it:
#     COUNCIL=Lincoln ./fetch-council-papers.command
# Leave it unset and you get everything on the list, which is the usual case.
COUNCIL="${COUNCIL:-}"
# Same identity the rest of the platform uses, with a contact address that
# reaches someone. A council seeing this in its logs can look us up or write
# to us; that is the whole point of the line.
UA="PWLBtoday/1.0 (+https://pwlbtoday.org; UK local-authority treasury monitor; admin@pwlbtoday.org)"
DELAY="${DELAY:-1}"

bold=$'\033[1m'; dim=$'\033[2m'; grn=$'\033[32m'; ylw=$'\033[33m'
red=$'\033[31m'; cyn=$'\033[36m'; off=$'\033[0m'

# ---------------------------------------------------------------- destination
SYNCED=0
find_drive() {
  # The folder that matters is the one Drive is already syncing, and that is
  # decided by how Drive was set up, not by which paths exist. Two shapes:
  #
  #   Folder backup  — you point Drive at an ordinary folder like
  #                    ~/Documents/PWLBtoday Council Papers and it uploads it.
  #                    The files stay where they are; Drive shows them under
  #                    "Computers", not "My Drive".
  #   Mirrored drive — ~/Library/CloudStorage/GoogleDrive-*/My Drive is itself
  #                    the cloud, so anything written there is in My Drive.
  #
  # Ours is the first, so the existing Documents folder wins. Checking for it
  # before the CloudStorage mount is the whole fix: the mount exists on this Mac
  # too, and preferring it would drop the papers into My Drive/Council Papers
  # while the backup kept syncing an empty Documents folder.
  # This sets DEST and SYNCED directly rather than printing the path, because
  # the obvious DEST="$(find_drive)" runs the function in a subshell: SYNCED=1
  # is set in the child and thrown away when it exits, so the parent always
  # believed Drive was missing and told everyone to upload by hand.
  local c
  local backup="$HOME/Documents/PWLBtoday Council Papers"
  if [ -d "$backup" ]; then DEST="$backup"; SYNCED=1; return; fi

  for c in "$HOME"/Library/CloudStorage/GoogleDrive-*/"My Drive" \
           "$HOME/Google Drive/My Drive" \
           "$HOME/Google Drive"; do
    [ -d "$c" ] && { DEST="$c/Council Papers"; SYNCED=1; return; }
  done
  # No Drive at all. Create the Documents folder anyway and say so loudly — a
  # silent fallback would leave the papers sitting on one Mac while the platform
  # waited for files that were never coming.
  DEST="$backup"
}

if [ -n "${DEST:-}" ]; then SYNCED=1; else find_drive; fi
mkdir -p "$DEST" || { echo "${red}Cannot create $DEST${off}"; exit 1; }
echo "${cyn}Saving to:${off} $DEST"
if [ "$SYNCED" -eq 0 ] && [ -z "${DEST_OVERRIDE:-}" ]; then
  echo "${ylw}Google Drive is not installed on this Mac, so nothing will upload by itself.${off}"
  echo "${ylw}When this finishes, drag the folder above into your Council Papers folder"
  echo "on drive.google.com. Everything else is automatic.${off}"
fi

# ------------------------------------------------------------------- manifest
# Tab-separated so this needs no JSON parser: filename, url, council, title.
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
if ! curl -fsSL --max-time 60 -A "$UA" "$MANIFEST_URL" -o "$TMP"; then
  echo "${red}Could not read the list of papers.${off}"
  echo "  ${dim}$MANIFEST_URL${off}"
  echo "  ${ylw}Check your internet connection and try again.${off}"
  exit 1
fi

total=0; pending=0
while IFS=$'\t' read -r fname url council title priority; do
  [ -z "${fname:-}" ] && continue
  case "$fname" in \#*) continue;; esac
  tier_wanted "${priority:-normal}" || continue
  if [ -n "$COUNCIL" ]; then
    case "$(printf '%s' "$council" | tr 'A-Z' 'a-z')" in
      *"$(printf '%s' "$COUNCIL" | tr 'A-Z' 'a-z')"*) ;; *) continue;;
    esac
  fi
  total=$((total+1))
  [ -f "$DEST/$fname" ] || pending=$((pending+1))
done < "$TMP"

if [ "$total" -eq 0 ]; then
  echo "${grn}Nothing waiting. Everything PWLBtoday needs has been fetched.${off}"; exit 0
fi
echo "${cyn}$total papers wanted ($WANT${COUNCIL:+, $COUNCIL}), $((total-pending)) already here, $pending to fetch.${off}"
[ "$pending" -eq 0 ] && { echo "${grn}Nothing to do.${off}"; exit 0; }

# ------------------------------------------------------------------ download
LOG="$DEST/_fetch-log-$(date +%Y-%m-%d).txt"
ok=0; refused=0; failed=0; n=0

while IFS=$'\t' read -r fname url council title priority; do
  [ -z "${fname:-}" ] && continue
  case "$fname" in \#*) continue;; esac
  tier_wanted "${priority:-normal}" || continue
  if [ -n "$COUNCIL" ]; then
    case "$(printf '%s' "$council" | tr 'A-Z' 'a-z')" in
      *"$(printf '%s' "$COUNCIL" | tr 'A-Z' 'a-z')"*) ;; *) continue;;
    esac
  fi
  [ -f "$DEST/$fname" ] && continue
  n=$((n+1))
  label="$council — $title"

  # Download to .part and rename on success, so an interrupted run never leaves
  # a half-file that looks complete.
  # A sixth of these URLs are plain http. Ask for https first — it works on
  # most of those hosts and means the paper is not fetched in clear — and fall
  # back to the council's own URL if it does not.
  # Two flags earn their place here.
  #
  # -c/-b give curl a cookie jar for the request. Several committee systems
  # hand out a session cookie partway through a redirect chain and then check
  # for it on the next hop. Without a jar the cookie is dropped, the check
  # fails, a fresh session is issued, and the chain never terminates: Exeter
  # cost 62 papers and about two minutes each that way, all recorded as "000"
  # because curl gave up before any status came back.
  #
  # --max-redirs 10 turns whatever is left of that into a fast, honest answer.
  # No council publishes a paper ten redirects deep.
  JAR="$(mktemp)"
  try_url="${url/#http:\/\//https://}"
  code=$(curl -sSL --max-time 120 --max-redirs 10 -A "$UA" -c "$JAR" -b "$JAR" \
              -w '%{http_code}' -o "$DEST/$fname.part" "$try_url" 2>/dev/null) || code="000"
  if [ "$code" != "200" ] && [ "$try_url" != "$url" ]; then
    code=$(curl -sSL --max-time 120 --max-redirs 10 -A "$UA" -c "$JAR" -b "$JAR" \
                -w '%{http_code}' -o "$DEST/$fname.part" "$url" 2>/dev/null) || code="000"
  fi
  rm -f "$JAR"
  size=0
  [ -f "$DEST/$fname.part" ] && size=$(wc -c < "$DEST/$fname.part" | tr -d ' ')

  if [ "$code" = "200" ] && [ "$size" -ge 1024 ]; then
    mv "$DEST/$fname.part" "$DEST/$fname"
    ok=$((ok+1))
    printf '%s[%d/%d]%s %s  %s(%d KB)%s\n' "$dim" "$n" "$pending" "$off" "$label" "$dim" "$((size/1024))" "$off"
    printf '%s\tOK\t%s\t%s\n' "$(date +%FT%T)" "$fname" "$size" >> "$LOG"
  else
    rm -f "$DEST/$fname.part"
    if [ "$code" = "403" ] || [ "$code" = "401" ]; then
      refused=$((refused+1))
      printf '%s[%d/%d]%s %s  %sREFUSED (%s)%s\n' "$dim" "$n" "$pending" "$off" "$label" "$ylw" "$code" "$off"
    else
      failed=$((failed+1))
      # A 200 that is only a few hundred bytes is an error page wearing a .pdf
      # name. Better to fail loudly than hand the platform a login screen
      # labelled as a treasury report.
      why="http $code"; [ "$code" = "200" ] && why="only $size bytes — not a real document"
      printf '%s[%d/%d]%s %s  %sFAILED — %s%s\n' "$dim" "$n" "$pending" "$off" "$label" "$red" "$why" "$off"
    fi
    printf '%s\tFAIL\t%s\t%s\n' "$(date +%FT%T)" "$fname" "$code" >> "$LOG"
  fi
  [ "$n" -lt "$pending" ] && sleep "$DELAY"
done < "$TMP"

# The record of what is on disk, written fresh every run.
#
# The daily logs above cannot serve as that record: only the last couple
# survive on Drive, so anything downloaded before them is invisible and the
# queue reports papers as missing that are sitting here. That has twice sent
# someone hunting a broken fetcher that was working correctly. One overwritten
# listing is always complete, and the far side reads it instead of asking a
# human to run `find`.
ls -1 "$DEST"/*.pdf 2>/dev/null | while read -r f; do basename "$f"; done \
  > "$DEST/_papers-on-disk.txt"

echo
echo "${cyn}Done. $ok fetched, $refused refused, $failed failed.${off}"
echo "${dim}$(wc -l < "$DEST/_papers-on-disk.txt" | tr -d ' ') papers on disk (recorded in _papers-on-disk.txt).${off}"
if [ "$refused" -gt 0 ]; then
  echo "${ylw}Refused means the council's server declined — often temporary.${off}"
  echo "${ylw}Run again later; anything already here is skipped.${off}"
fi
if [ "$SYNCED" -eq 1 ]; then
  echo "${dim}Google Drive will sync these up shortly. Nothing else to do.${off}"
elif [ "$ok" -gt 0 ]; then
  echo "${ylw}Now drag these into Council Papers on drive.google.com.${off}"
  open "$DEST" 2>/dev/null || true
fi

# --------------------------------------------------------------------- INSTALL
# Paste this one line into Terminal, once. It puts the icon on your Desktop and
# makes it double-clickable. Re-run it any time to get the newest version.
#
#   curl -fsSL https://philsmith871010-stack.github.io/pwlbtoday-stream/fetch-council-papers.command -o ~/Desktop/"Get Council Papers.command" && chmod +x ~/Desktop/"Get Council Papers.command"
#
# ------------------------------------------------------------------ SCHEDULING
# To have it run itself every morning at 07:30, paste this into Terminal once:
#
#   (crontab -l 2>/dev/null; echo "30 7 * * * /bin/bash \"$HOME/Desktop/Get Council Papers.command\" >/dev/null 2>&1") | crontab -
#
# To stop it later:   crontab -e   and delete that line.
