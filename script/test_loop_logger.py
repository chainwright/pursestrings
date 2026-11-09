#!/usr/bin/env python3
"""Offline tests for script/loop_logger.py's matching (W1 gate P0-3, P0-4). No network, no key.

    python3 script/test_loop_logger.py

The H12 case from the gate: the Lasna search window opens ~35 s before the origin, so the
previous loop's GrantSent (or Frozen) on the same chain is in it. Before P0-3 the logger took the
first event passing the path predicate, i.e. the previous loop's.
"""
import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import loop_logger as L  # noqa: E402

# temp files in the project's gitignored cache/, not the system temp dir
TMP = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "cache", "test_loop_logger")
os.makedirs(TMP, exist_ok=True)


def cand(tx, ts, w0, linked, log_index="0x0"):
    return {"transactionHash": tx, "logIndex": log_index, "ts": ts, "w0": w0, "linked": linked}


def record(path, origin_tx, answers=(), grant_id=None, epoch=None, latency=2):
    r = {"path": path, "chain": "base", "origin": {"tx": origin_tx, "ts": 1000}, "reactive": [],
         "answers": {a: {"destTx": "0x1", "ts": 1002} for a in answers}, "failures": [],
         "complete": bool(answers), "latencySec": latency if answers else None}
    if grant_id is not None:
        r["grantId"] = grant_id
    if epoch is not None:
        r["epoch"] = epoch
    return r


class Choose(unittest.TestCase):
    def test_previous_loops_grant_in_window_is_not_taken(self):
        # loop 1's GrantSent#3 at t=970 (30 s before the origin at 1000), loop 2's #4 at 1002
        prev, mine = cand("0xprev", 970, 3, False), cand("0xmine", 1002, 4, True)
        got = L.choose([prev, mine], floor_ts=1000 - 2, min_word0=-1, now=0, first_seen={})
        self.assertEqual(got[0]["transactionHash"], "0xmine")
        self.assertEqual(got[1], "origin-tx")

    def test_id_floor_blocks_a_recorded_grant_even_inside_the_time_window(self):
        # the previous loop's grant landed within the 2-s skew (or clocks disagree)
        prev = cand("0xprev", 999, 3, False)
        mine = cand("0xmine", 1003, 4, False)
        first = {}
        self.assertIsNone(L.choose([prev, mine], 998, 3, now=100, first_seen=first, grace=90))
        got = L.choose([prev, mine], 998, 3, now=190, first_seen=first, grace=90)
        self.assertEqual((got[0]["transactionHash"], got[1]), ("0xmine", "floors"))

    def test_unlinked_waits_for_grace_and_a_linked_one_wins_meanwhile(self):
        tick = cand("0xtick", 1010, 5, False)
        first = {}
        self.assertIsNone(L.choose([tick], 998, -1, now=10, first_seen=first, grace=90))
        linked = cand("0xreact", 1050, 6, True)
        got = L.choose([tick, linked], 998, -1, now=50, first_seen=first, grace=90)
        self.assertEqual(got[0]["transactionHash"], "0xreact")

    def test_unlinked_taken_after_grace(self):
        tick = cand("0xtick", 1010, 5, False)
        first = {}
        L.choose([tick], 998, -1, now=10, first_seen=first, grace=90)
        got = L.choose([tick], 998, -1, now=100, first_seen=first, grace=90)
        self.assertEqual((got[0]["transactionHash"], got[1]), ("0xtick", "floors"))

    def test_stop_epoch_floor(self):
        old = cand("0xold", 1001, 1, True)  # a linked Frozen(1) can't happen twice, but be strict
        new = cand("0xnew", 1003, 3, True)
        got = L.choose([old, new], 998, 2, now=0, first_seen={})
        self.assertEqual(got[0]["w0"], 3)

    def test_nothing_passes(self):
        self.assertIsNone(L.choose([cand("0xa", 900, 9, True)], 998, -1, now=0, first_seen={}))


class Floors(unittest.TestCase):
    def setUp(self):
        self.f = tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False, dir=TMP)

    def tearDown(self):
        self.f.close()
        os.unlink(self.f.name)

    def write(self, *recs):
        for r in recs:
            self.f.write(json.dumps(r) + "\n")
        self.f.flush()

    def test_missing_file(self):
        self.assertEqual(L.recorded_floors(self.f.name + ".none", "0xa"), (-1, -1))

    def test_labels_of_old_records_and_new_fields(self):
        self.write(record("topup", "0xa", ["GrantApplied#1"]),
                   record("stop", "0xb", ["EpochAck(1, frozen) on base", "EpochAck(1, frozen) on unichain"]),
                   record("topup", "0xc", grant_id=7),  # incomplete, but its grant id is known
                   record("stop", "0xd", epoch=3))
        self.assertEqual(L.recorded_floors(self.f.name, "0xz"), (7, 3))

    def test_a_retrace_of_the_same_origin_ignores_its_own_records(self):
        self.write(record("topup", "0xA", ["GrantApplied#1"]), record("topup", "0xB", grant_id=4))
        self.assertEqual(L.recorded_floors(self.f.name, "0xb"), (1, -1))  # case-insensitive

    def test_live_loops_file_of_07_11(self):
        live = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "live", "loops.jsonl")
        if os.path.exists(live):
            self.assertEqual(L.recorded_floors(live, "0xnew"), (1, 1))


class Summary(unittest.TestCase):
    def test_dedupe_by_origin_keeps_the_last(self):
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False, dir=TMP) as f:
            for r in (record("topup", "0xf1af", []), record("topup", "0xF1AF", ["GrantApplied#1"]),
                      record("stop", "0x2422", ["EpochAck(1, frozen) on base"]),
                      record("stop", "0x2422", ["EpochAck(1, frozen) on base"])):
                f.write(json.dumps(r) + "\n")
        old = L.OUT
        try:
            L.OUT = f.name
            buf = io.StringIO()
            with redirect_stdout(buf):
                L.summary(None)
        finally:
            L.OUT = old
            os.unlink(f.name)
        out = buf.getvalue()
        self.assertIn("4 records, 2 origins (2 re-trace(s) dropped", out)
        self.assertIn("topup: runs 1, complete 1", out)
        self.assertIn("stop: runs 1, complete 1", out)


class Cron(unittest.TestCase):
    def test_next_tick(self):
        self.assertEqual(L.next_tick(7_890_001), 7_890_001)
        self.assertEqual(L.next_tick(7_890_002), 7_891_001)
        self.assertEqual(L.next_tick(7_891_000), 7_891_001)

    def test_ours_in_block(self):
        rc = "0x7B8111CDF7001721469c584Fa9613369F0E7aC1E"
        blk = {"transactions": [
            {"hash": "0xours", "to": L.SYSTEM, "input": "0xcebbda8d" + "00" * 12 + rc[2:].lower()},
            {"hash": "0xother", "to": L.SYSTEM, "input": "0xcebbda8d" + "11" * 32},
            {"hash": "0xelse", "to": "0x" + "12" * 20, "input": rc.lower()},
        ]}
        self.assertEqual(L.ours_in_block(blk, rc), ["0xours"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
