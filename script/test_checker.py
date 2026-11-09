#!/usr/bin/env python3
"""Offline tests for script/checker.py and script/evm_rpc.py. No network, no key.

    python3 script/test_checker.py

- the arithmetic: what counts as spent (any transfer out of a wallet except to its own vault),
  "Over" and "can still leave" at, under and over the cap, the dollar formatting;
- the log fetching against a fake RPC that behaves like the public ones: a 200-block range
  limit (refused ranges are split and retried), a per-second rate limit (refused items are
  retried), JSON-RPC batches;
- the day's block range from timestamps (bisection), with irregular block times;
- a whole check_day over two fake chains.
"""
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import checker as C  # noqa: E402
import evm_rpc as E  # noqa: E402

W1, W2, V1, V2 = "0x" + "a1" * 20, "0x" + "a2" * 20, "0x" + "d1" * 20, "0x" + "d2" * 20
PAYEE, X = "0x" + "b1" * 20, "0x" + "e1" * 20
TOKEN = "0x" + "c1" * 20


def tlog(frm, to, value, block=1, idx=0, token=TOKEN):
    return {"address": token, "topics": [E.TOPIC_TRANSFER, "0x" + E.addr_word(frm), "0x" + E.addr_word(to)],
            "data": "0x" + E.word(value), "blockNumber": hex(block), "logIndex": hex(idx)}


class Arithmetic(unittest.TestCase):
    def test_spent_excludes_returns_to_the_own_vault(self):
        logs = [tlog(W1, PAYEE, 1_000_000), tlog(W1, V1, 2_500_000), tlog(W1, PAYEE, 3_000_000),
                tlog(W1, V2, 400_000),          # another wallet's vault is not this wallet's return: spent
                tlog(X, PAYEE, 99_000_000)]     # not one of our wallets: ignored
        r = C.tally(logs, {W1: V1, W2: V2})
        self.assertEqual(r[W1], {"spent": 4_400_000, "returned": 2_500_000, "payments": 3, "returns": 1})
        self.assertEqual(r[W2], {"spent": 0, "returned": 0, "payments": 0, "returns": 0})

    def test_a_wallet_without_a_vault_counts_everything(self):
        self.assertEqual(C.tally([tlog(W1, V1, 5)], {W1: None})[W1]["spent"], 5)

    def test_non_transfer_logs_are_ignored(self):
        lg = tlog(W1, PAYEE, 7)
        lg["topics"][0] = E.TOPIC_PAID
        self.assertEqual(C.tally([lg], {W1: V1})[W1]["spent"], 0)

    def test_over_and_left(self):
        self.assertEqual(C.verdict(17_000_000, 20_000_000), (0, 3_000_000))
        self.assertEqual(C.verdict(20_000_000, 20_000_000), (0, 0))
        self.assertEqual(C.verdict(20_000_001, 20_000_000), (1, 0))
        self.assertEqual(C.verdict(5_000_000, 0), (5_000_000, 0))  # a day the coordinator never opened

    def test_usd(self):
        self.assertEqual(C.usd(0), "$0.00")
        self.assertEqual(C.usd(17_000_000), "$17.00")
        self.assertEqual(C.usd(1_330_000), "$1.33")
        self.assertEqual(C.usd(1), "$0.00")        # below a cent: shown as $0.00 ...
        self.assertNotEqual(C.verdict(20_000_001, 20_000_000)[0], 0)  # ... but the exit code still says over

    def test_days(self):
        self.assertEqual(C.day_number("2026-11-09"), 20766)
        self.assertEqual(C.day_label(20766), "2026-11-09")

    def test_wallets_of(self):
        with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "deployments", "latest.json")) as f:
            dep = json.load(f)
        ws = C.wallets_of(dep)
        self.assertEqual([(n, c) for n, c, _, _, _ in ws], [("base", 84532), ("unichain", 1301)])
        self.assertEqual(ws[0][3], dep["base"]["wallet"])
        self.assertEqual(ws[0][4], dep["base"]["vault"])


class FakeChain(E.Rpc):
    """A chain of `n` blocks with timestamps ts[i] and logs placed on blocks; eth_getLogs refuses
    ranges wider than `limit` and every `refuse_every`-th request for rate."""

    def __init__(self, ts, logs, limit=200, refuse_every=0, chain_id=None):
        super().__init__("fake://", chain_id=chain_id, rate=10 ** 6)
        self.ts_list, self.logs, self.limit, self.refuse_every = ts, logs, limit, refuse_every
        self.n_requests = 0
        self.ranges = []

    def _post(self, body, k):
        items = body if isinstance(body, list) else [body]
        out = []
        for it in items:
            self.n_requests += 1
            if self.refuse_every and self.n_requests % self.refuse_every == 0:
                out.append({"id": it["id"], "error": {"code": -32007, "message": "25/second request limit reached"}})
                continue
            out.append({"id": it["id"], **self._answer(it["method"], it["params"])})
        return out if isinstance(body, list) else out[0]

    def _answer(self, m, p):
        if m == "eth_blockNumber":
            return {"result": hex(len(self.ts_list) - 1)}
        if m == "eth_getBlockByNumber":
            return {"result": {"timestamp": hex(self.ts_list[int(p[0], 16)])}}
        if m == "eth_chainId":
            return {"result": hex(self.chain_id or 1)}
        if m == "eth_call":
            return {"result": "0x" + E.word(20_000_000)}
        if m == "eth_getLogs":
            f = p[0]
            a, b = int(f["fromBlock"], 16), int(f["toBlock"], 16)
            if b - a + 1 > self.limit:
                return {"error": {"code": -32614, "message": f"eth_getLogs is limited to a {self.limit} range"}}
            self.ranges.append((a, b))
            senders = f["topics"][1]
            senders = senders if isinstance(senders, list) else [senders]
            return {"result": [l for l in self.logs if a <= int(l["blockNumber"], 16) <= b
                               and l["address"] == f["address"] and l["topics"][1] in senders]}
        raise AssertionError(m)


E.time.sleep = lambda s: None  # the fake RPC's rate refusals need no real waiting


class Fetching(unittest.TestCase):
    def test_chunks_split_and_retry_until_every_log_is_found(self):
        logs = [tlog(W1, PAYEE, 1, block=b) for b in (0, 199, 200, 777, 1999, 2000, 4321)]
        ch = FakeChain(list(range(5000)), logs, limit=150, refuse_every=7)
        got = ch.get_logs(TOKEN, [E.TOPIC_TRANSFER, ["0x" + E.addr_word(W1)]], 0, 4999, chunk=200, batch_size=5)
        self.assertEqual([int(l["blockNumber"], 16) for l in got], [0, 199, 200, 777, 1999, 2000, 4321])
        covered = sorted(ch.ranges)
        self.assertEqual(covered[0][0], 0)
        self.assertEqual(covered[-1][1], 4999)
        for (a0, b0), (a1, _) in zip(covered, covered[1:]):
            self.assertEqual(a1, b0 + 1)  # no gap, no overlap
        self.assertTrue(all(b - a + 1 <= 150 for a, b in covered))

    def test_first_block_at_or_after_with_irregular_times(self):
        ts, t = [], 1_000_000
        for i in range(30_000):
            t += 1 if i % 7 else 3
            ts.append(t)
        ch = FakeChain(ts, [])
        for target in (ts[0] - 5, ts[0], ts[1234] - 1, ts[1234], ts[29_999], ts[29_999] + 1):
            b = ch.first_block_at_or_after(target)
            want = next((i for i, x in enumerate(ts) if x >= target), len(ts))
            self.assertEqual(b, want, target)
        self.assertLess(ch.n_requests, 120)

    def test_check_day_over_two_chains(self):
        d = 20766
        start = d * 86400
        # chain A: one block per 0.5 s ... modelled as 2 blocks per second
        ts_a = [start - 600 + i // 2 for i in range(2 * (86400 + 1200))]
        ts_b = [start - 600 + i for i in range(86400 + 1200)]
        in_day_a = ts_a.index(start)
        last_a = max(i for i, x in enumerate(ts_a) if x < start + 86400)
        logs_a = [tlog(W1, PAYEE, 5_000_000, block=in_day_a - 1),   # the day before: not counted
                  tlog(W1, PAYEE, 6_000_000, block=in_day_a),
                  tlog(W1, V1, 9_000_000, block=in_day_a + 50),      # a return to its vault
                  tlog(W1, PAYEE, 4_000_000, block=last_a),
                  tlog(W1, PAYEE, 7_000_000, block=last_a + 1)]      # the next day: not counted
        logs_b = [tlog(W2, PAYEE, 10_000_001, block=ts_b.index(start + 3600), token="0x" + "c2" * 20)]
        dep = {"coordinator": "0x" + "f1" * 20,
               "a": {"chainId": 11, "token": TOKEN, "wallet": W1, "vault": V1},
               "b": {"chainId": 12, "token": "0x" + "c2" * 20, "wallet": W2, "vault": V2}}
        rpcs = {11: FakeChain(ts_a, logs_a, limit=1000, refuse_every=11, chain_id=11),
                12: FakeChain(ts_b, logs_b, limit=1000, chain_id=12)}
        r = C.check_day(d, dep, rpcs, None, FakeChain([0], []))
        self.assertEqual(r["cap"], 20_000_000)
        self.assertEqual([c["spent"] for c in r["chains"]], [10_000_000, 10_000_001])
        self.assertEqual(r["chains"][0]["returnedToVault"], 9_000_000)
        self.assertEqual((r["spent"], r["over"], r["canStillLeave"]), (20_000_001, 1, 0))
        r = C.check_day(d, dep, rpcs, 25_000_000, None)
        self.assertEqual((r["over"], r["canStillLeave"], r["capSource"]), (0, 4_999_999, "--cap-usd"))


if __name__ == "__main__":
    unittest.main(verbosity=1)
