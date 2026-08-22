# pwlbtoday-stream

**PWLBpulse · CouncilIntel** — the client front end. One page, six tabs:

- **Market pulse** — the live markets · economics · council-news stream,
  newest first.
- **Councils** — search a council for its assembled position: where it stands
  against its peers, what we know, its calendar and its document trail.
- **Exposure** — every council with figures, ranked by what it owes against
  what it spends. Statutory returns, not our reading of the papers.
- **Coverage** — the operations view: what we hold, what has been read, what
  is still a gap.
- **Approach** — what the platform is for and how it is built.
- **Health** — whether the numbers here can be trusted today.

Live page: https://philsmith871010-stack.github.io/pwlbtoday-stream/

## Preview it locally

```bash
python3 run-local.py            # http://localhost:8030
python3 run-local.py --build    # rebuild the council files first
```

Standard library only. It reloads by itself when `index.html` or the council
data changes on disk, and puts you back on the tab and scroll position you
were on. Nothing is cached, so a plain Cmd+R is always enough — which matters
in Safari, where Cmd+Shift+R opens Reader view rather than forcing a reload.

It never writes to the repository and never pushes. `gh-pages` is what
publishes; this is a preview of your working tree.

## Where the page comes from

`index.html` is **generated** by `monitor/site/build_platform.py` in the
CouncilIntel repo. Edit that, not this — a hand edit here survives until the
next rebuild and then vanishes without a word.

```bash
cd ~/CouncilIntel/monitor/site
python3 build_platform.py --out ~/pwlbtoday-stream/index.html
```

Pulse data comes from the pwlbtoday-watch archive; council data from
CouncilIntel. The per-council files under `councils/` are written separately
by `monitor/mg/site_data.py` and fetched by the page on demand, which is why
Exposure and "Where it stands" show current figures without a page rebuild:

```bash
cd ~/CouncilIntel/monitor
python3 -m mg.site_data --out ~/pwlbtoday-stream/councils
```

`python3 sweep/batch.py --publish-only` does that step and pushes.

The standalone council explorer remains at `/councils/` as a deep-link
fallback. Times UK.
