#!/usr/bin/env python3
"""Offline tests for the dashboard. No network, no key.

    python3 dashboard/test_dashboard.py

- the replay data (dashboard/web/data.js) is the committed record of 09.11.2026: every loop's hashes,
  origin time, actual latency and wording against live/series_2026-11-09.jsonl, and the 12 payments
  against the committed broadcasts and live/SERIES_2026-11-09.md;
- the path stats are median and max (small n), in the replay data and in the live server's stats;
- the static build defaults to replay (mode.js), and the copy has the agreed wording.
"""
import json
import os
import re
import statistics
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
WEB = os.path.join(HERE, "web")
sys.path.insert(0, HERE)
import server as S  # noqa: E402

LOW_WATER = S.T["LowWater"]
SHORT = S.T["Short"]


def read(*p):
    with open(os.path.join(*p), encoding="utf-8") as f:
        return f.read()


DATA = read(WEB, "data.js")
LOOP_RE = re.compile(
    r'\{ id: "(?P<id>[TDS]\d+)", path: "(?P<path>[^"]+)", kind: "[^"]+", chain: "(?P<chain>\w+)", ts: (?P<ts>\d+), '
    r'utc: "[^"]+", actual: "(?P<actual>[^"]+)",\s*what: "(?P<what>[^"]+)",\s*steps: \[(?P<steps>.*?)\] \}', re.S)
STEP_RE = re.compile(r'\["(?P<label>[^"]+)", (?:"(?P<ck>\w+)"|L), "(?P<tx>0x[0-9a-f]{64})", (?P<off>-?\d+)\]')
PAY_RE = re.compile(r'\{ chain: "(\w+)", usd: (\d+), tx: "(0x[0-9a-f]{64})", block: (\d+), utc: "[^"]+" \}')


def series():
    out = {}
    with open(os.path.join(REPO, "live", "series_2026-11-09.jsonl"), encoding="utf-8") as f:
        for line in f:
            r = json.loads(line)
            out[r["origin"]["tx"]] = (r, line)
    return out


class ReplayData(unittest.TestCase):
    def setUp(self):
        self.loops = [m.groupdict() for m in LOOP_RE.finditer(DATA)]
        self.series = series()

    def test_all_18_loops_are_the_recorded_ones(self):
        self.assertEqual([l["id"] for l in self.loops],
                         ["T%d" % i for i in range(1, 11)] + ["D1", "D2", "D3"] + ["S%d" % i for i in range(1, 6)])
        for lp in self.loops:
            steps = [m.groupdict() for m in STEP_RE.finditer(lp["steps"])]
            self.assertGreaterEqual(len(steps), 3, lp["id"])
            origin = steps[0]["tx"]
            self.assertIn(origin, self.series, lp["id"] + ": origin not in live/series_2026-11-09.jsonl")
            rec, raw = self.series[origin]
            self.assertEqual(int(lp["ts"]), rec["origin"]["ts"], lp["id"])
            self.assertEqual(lp["chain"], rec["chain"], lp["id"])
            for st in steps:
                self.assertIn(st["tx"], raw, "%s: %s not in the recorded trace" % (lp["id"], st["tx"]))
            self.assertEqual(lp["actual"], S.fmt_lat(rec["latencySec"]), lp["id"])
            self.assertEqual(max(int(s["off"]) for s in steps), rec["latencySec"], lp["id"])

    def test_wording_follows_the_origin_event(self):
        # one wording per origin event, the same as the live server's (server.py build_loops)
        for lp in self.loops:
            rec, _ = self.series[STEP_RE.search(lp["steps"]).group("tx")]
            topics = [l["topics"][0] for l in rec["origin"]["logs"] if l["topics"]]
            if lp["path"] == "STOP":
                self.assertTrue(lp["what"].startswith("STOP pressed on "), lp["id"])
            elif LOW_WATER in topics:
                self.assertTrue(lp["what"].startswith("paid, running low on "), lp["id"] + ": " + lp["what"])
            else:
                self.assertIn(SHORT, topics, lp["id"])
                self.assertTrue(lp["what"].startswith("pay refused (Short) on "), lp["id"] + ": " + lp["what"])

    def test_payments_are_the_committed_ones(self):
        pays = PAY_RE.findall(DATA)
        self.assertEqual(len(pays), 12)
        self.assertEqual(sum(int(p[1]) for p in pays), 17)
        series_md = read(REPO, "live", "SERIES_2026-11-09.md")
        bdir = os.path.join(REPO, "broadcast", "Loop.s.sol", "84532")
        broadcasts = "".join(read(bdir, f) for f in os.listdir(bdir) if f.endswith(".json"))
        for chain, _, tx, block in pays:
            self.assertEqual(chain, "base")
            self.assertTrue(tx in series_md or tx in broadcasts, tx)
            if tx in broadcasts:
                self.assertIn(hex(int(block)), broadcasts, tx)

    def test_stats_are_median_and_max_of_the_record(self):
        lat = {"top-up": [], "chain-to-chain": [], "STOP": []}
        name = {"topup": "top-up", "donor": "chain-to-chain", "stop": "STOP"}
        for rec, _ in self.series.values():
            lat[name[rec["path"]]].append(rec["latencySec"])
        want = {k: S.Dashboard.stats([{"path": k, "latencySec": x} for x in v])[[
            "top-up", "chain-to-chain", "STOP"].index(k)] for k, v in lat.items()}
        for label, value, n in re.findall(r'\{ label: "([^"]+)", value: "([^"]+)", n: (\d+) \}', DATA):
            self.assertEqual(value, want[label]["value"], label)
            self.assertEqual(int(n), want[label]["n"], label)


class LiveStats(unittest.TestCase):
    def test_median_and_max(self):
        st = S.Dashboard.stats([{"path": "STOP", "latencySec": s} for s in (2, 3, 2, 2, 2)])
        self.assertEqual(st[2]["value"], "median 2 s · max 3 s")
        self.assertEqual(st[0]["value"], "no loop today yet")
        st = S.Dashboard.stats([{"path": "chain-to-chain", "latencySec": s} for s in (1873, 1822, 1824)])
        self.assertEqual(st[1]["value"], "median 30.4 min · max 31.2 min")
        self.assertEqual(statistics.median([1873, 1822, 1824]), 1824)


class StaticBuild(unittest.TestCase):
    def test_replay_is_the_default(self):
        self.assertRegex(read(WEB, "mode.js"), r"window\.PS_SERVER = false;")
        app = read(WEB, "app.js")
        self.assertIn('let MODE = "replay";', app)
        self.assertIn("replay · recorded 09.11 · real txs", read(WEB, "index.html"))

    def test_copy(self):
        web = "".join(read(WEB, f) for f in ("index.html", "app.js", "data.js", "style.css"))
        for bad in ("p50", "p95", "of cord, everywhere", "Short on Base → Lasna → Unichain"):
            self.assertNotIn(bad, web)
        self.assertIn("px of cord on this screen", web)
        css = read(WEB, "style.css")
        self.assertIn("--ink-3: #636970;", css)
        self.assertEqual(css.count("--ink-3: #8C939A;"), 2)
        self.assertIn(".debug { display: none; }", css)


if __name__ == "__main__":
    unittest.main(verbosity=1)
