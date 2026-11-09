#!/usr/bin/env python3
"""Pursestrings "Drawstring" live dashboard: a tiny READ-ONLY server, Python standard library only.

    python3 dashboard/server.py --port 8917   # then open http://127.0.0.1:8917/ (live mode)

It polls three public RPCs (Base Sepolia, Unichain Sepolia, Lasna), keeps today's logs with a
cursor (the settled part on disk under cache/, the last SETTLE blocks re-read every poll), reads
the contracts' views at the head block, rebuilds today's loops (origin -> Lasna react -> callback)
and serves one JSON snapshot at /api/state plus the static page in web/. The same web/ folder,
served by any static host, is the replay build: it shows the recorded series of 09.11 and never
calls /api/state (web/mode.js says which one it is; this server answers /mode.js itself).

It never signs and never sends a transaction: the only RPC methods it calls are eth_blockNumber,
eth_getBlockByNumber, eth_getLogs, eth_getTransactionByHash, eth_getTransactionReceipt, eth_call
and eth_chainId. It holds no key.

Why a server and not the browser: all three RPCs answer CORS, but a Base Sepolia day is ~230k
blocks at 200 blocks per getLogs (~2,300 requests at <= 25/s). One poller with a cursor keeps the
page instant and the public RPC's rate limit respected however many tabs are open.

Counting rules are the repo's (script/checker.py, script/loop_logger.py); see dashboard/NOTES.md.
"""
import argparse
import datetime
import http.server
import json
import os
import socketserver
import statistics
import sys
import threading
import time
import traceback
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(REPO, "script"))
import evm_rpc as E  # noqa: E402  (the repo's own read-only JSON-RPC client, script/evm_rpc.py)

DAY = 86400
SETTLE = 64            # blocks behind head re-read every poll (same margin as checker.py)
DECIMALS = 6
LASNA_ID = 5318007
SYSTEM = "0x8888888888888888888888888888888888888888"
LASNA_CHUNK = 10000    # Lasna's public RPC accepted 20,000-block log ranges (probed 09.11)
BACKFILL_SLICE = {84532: 8000, 1301: 20000, LASNA_ID: 40000}   # blocks per poll while catching up

# event topics (cast keccak, see NOTES.md)
T = {
    "Short": "0xb01930c34f8d3ecc7ed7f0487c27dada1785cf8e7a300350785efaa6388a50b0",
    "LowWater": "0x1dd01b2e64a32a777e5fdf60c62f8ad5c2ba14f3e482ff2dda488968e1ecaca4",
    "GrantApplied": "0x0a8c5ccc12ae54096ccca3a0d85a040168265377923657d8f7953eebbde4841c",
    "GrantNotApplied": "0x21be72e38a5f999fede1b02b8e8c965b0156e9265115d9ccd0329783f930e84c",
    "Reclaimed": "0x1a459dc14172af1e2a56b0c6bb688e095a1f791c4892f33dd5672657aa87215e",
    "EpochAck": "0x349384d3608f2b8785238052604c92c08bcf763b5f5e29e67bcc6c1831d39f03",
    "StopPressed": "0xbac4811e874486c963d74b3eb406fe5118539a24d53cdeaf872b3455efa8b4f6",
    "Paid": "0xeeb0574dc6b7f4afdf7af225c5eda6cdbafc564664ace95a38e12814594b6f7e",
    "Refused": "0x8d113fd950359a9bd15a700269818d92d001a2d82fdba58ddd59fc9ee395749c",
    "GrantSent": "0x5f2a7a100bf23fb41573209ace8ee8b5c133c253093e7dec77456129662f30a0",
    "ReclaimSent": "0x7de229f357a33d23b4ec4909f7af0b2abb3fcdd06a77754faa6e0d4614bc8641",
    "Credited": "0x32bec65cc692fc454f08ea2e8e57ea47620e09adc0f7be365c88476f4da2af89",
    "Frozen": "0x5e20151a99b0432a9ac06d33b91b77d3134ce0638cc70d7df042947ca48a2caf",
    "Unfrozen": "0x00e0b27291b4bb0e6c7545029576112a23b434d46c7fa6ede05ddd8c1dff88c9",
    "Unstop": "0x30d4f1a8a120a18ac9a54f9569485d15db09399c096fed882ebb15db95de2eaf",
    "Transfer": E.TOPIC_TRANSFER,
}
NAME_OF = {v: k for k, v in T.items()}
SEL = {
    "cap()": "0x355274ea", "epoch()": "0x900cf0cf", "frozen()": "0x054f7d9c", "today()": "0xb74e452b",
    "capOfDay(uint64)": "0x32d07896", "poolOf(uint64)": "0x2f9f5d82", "heldOf(uint64,uint8)": "0x31487e5a",
    "isOpen(uint64)": "0x703f3cf6", "reserves(address)": "0xd66bd524", "debt(address)": "0x9b6c56ec",
    "unspentOf(uint64)": "0x07d66173", "stranded()": "0xc1da4e4a", "balanceOf(address)": "0x70a08231",
}
R_SHORT = 4  # SpendWallet refusal reason

CHAIN_META = {
    84532: {"key": "base", "name": "Base Sepolia", "short": "Base", "explorer": "https://sepolia.basescan.org/tx/",
            "rpc": "https://sepolia.base.org", "range": 200, "rate": 18},
    1301: {"key": "unichain", "name": "Unichain Sepolia", "short": "Unichain", "explorer": "https://sepolia.uniscan.xyz/tx/",
           "rpc": "https://sepolia.unichain.org", "range": 1000, "rate": 20},
}
LASNA_META = {"key": "lasna", "name": "Lasna", "explorer": "https://lasna.reactscan.net/tx/", "rpc": "https://lasna-rpc.rnk.dev/"}


def usd(units):
    return units / 10 ** DECIMALS


def hexi(x):
    return int(x, 16) if isinstance(x, str) else int(x)


def utc(ts, fmt="%H:%M:%S"):
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime(fmt)


def call_data(sig, *args):
    return SEL[sig] + "".join(E.addr_word(a) if isinstance(a, str) else E.word(a) for a in args)


def slim(lg):
    return {"address": lg["address"].lower(), "topics": [t.lower() for t in lg["topics"]], "data": lg["data"],
            "block": hexi(lg["blockNumber"]), "tx": lg["transactionHash"].lower(), "logIndex": hexi(lg["logIndex"])}


def lkey(lg):
    return lg["tx"] + ":" + str(lg["logIndex"])


class Source:
    """One chain: today's logs of a fixed address set (and optionally Transfer logs out of the wallet),
    read with a cursor. `sync` advances it; logs within SETTLE of the head are re-read every time, so a
    short reorg replaces them. New logs seen after the first catch-up are returned as `fresh`."""

    def __init__(self, chain_id, url, addresses, chunk, rate=None, transfer=None):
        self.cid = chain_id
        self.rpc = E.Rpc(url, chain_id, rate=rate)
        self.addresses = [a.lower() for a in addresses]
        self.chunk = chunk
        self.transfer = transfer   # (token, [wallets]) or None
        self.day = None
        self.b0 = None
        self.up_to = None
        self.logs = {}
        self.caught_up = False
        self.head = None
        self.head_ts = None

    def reset(self, day, head):
        self.day = day
        self.b0 = self.rpc.first_block_at_or_after(day * DAY, head)
        self.up_to = self.b0 - 1
        self.logs = {}
        self.caught_up = False

    def _fetch(self, a, b):
        out = [slim(x) for x in self.rpc.get_logs(self.addresses, [], a, b, chunk=self.chunk)]
        if self.transfer:
            token, wallets = self.transfer
            topics = [E.TOPIC_TRANSFER, ["0x" + E.addr_word(w) for w in wallets]]
            out += [slim(x) for x in self.rpc.get_logs(token, topics, a, b, chunk=self.chunk)]
        return out

    def sync(self, day):
        head = self.rpc.head()
        self.head = head
        self.head_ts = self.rpc.block_ts(head)
        if self.day != day:
            self.reset(day, head)
        fresh = []
        if not self.caught_up:
            a = self.up_to + 1
            b = min(head, a + BACKFILL_SLICE.get(self.cid, 20000) - 1)
            if a <= b:
                for lg in self._fetch(a, b):
                    self.logs[lkey(lg)] = lg
                self.up_to = b
            if self.up_to >= head - SETTLE:
                self.caught_up = True
            return fresh
        a = max(self.b0, self.up_to - SETTLE + 1)
        got = self._fetch(a, head) if a <= head else []
        keep = {k: v for k, v in self.logs.items() if v["block"] < a}
        for lg in got:
            k = lkey(lg)
            if k not in self.logs:
                fresh.append(lg)
            keep[k] = lg
        self.logs = keep
        self.up_to = head
        return fresh

    def progress(self):
        if self.caught_up or self.head is None or self.b0 is None:
            return 1.0
        span = max(1, self.head - self.b0)
        return max(0.0, min(1.0, (self.up_to - self.b0 + 1) / span))

    def by_block(self):
        return sorted(self.logs.values(), key=lambda l: (l["block"], l["logIndex"]))

    # disk cache of the settled part, so a restart doesn't re-read the whole day
    def dump(self):
        settled = self.up_to - SETTLE
        return {"day": self.day, "b0": self.b0, "upTo": settled,
                "logs": [l for l in self.logs.values() if l["block"] <= settled],
                "ts": {str(k): v for k, v in list(self.rpc._ts.items())[-3000:]}}

    def load(self, d, day):
        if not d or d.get("day") != day:
            return
        self.day, self.b0, self.up_to = d["day"], d["b0"], d["upTo"]
        self.logs = {lkey(l): l for l in d["logs"]}
        self.rpc._ts.update({int(k): v for k, v in d.get("ts", {}).items()})


class Dashboard:
    def __init__(self, dep, cache_dir):
        self.dep = dep
        self.cache_dir = cache_dir
        self.rc = dep["coordinator"].lower()
        self.console = dep.get("console", "").lower()
        self.chains = []   # [{key, cid, idx, wallet, vault, token, src, meta}]
        names = [k for k, v in dep.items() if isinstance(v, dict) and "chainId" in v]
        # coordinator chain index: the order of Deploy.s.sol (base 0, unichain 1, as loop_logger.py)
        order = {"base": 0, "unichain": 1}
        for name in sorted(names, key=lambda n: order.get(n, 99)):
            v = dep[name]
            cid = int(v["chainId"])
            meta = CHAIN_META[cid]
            addrs = [v["wallet"]] + ([self.console] if name == "base" and self.console else [])
            src = Source(cid, os.environ.get(E.RPC_ENV.get(cid, ""), "") or meta["rpc"], addrs, meta["range"],
                         rate=meta["rate"], transfer=(v["token"], [v["wallet"]]))
            self.chains.append({"key": meta["key"], "cid": cid, "idx": order[name], "wallet": v["wallet"].lower(),
                                "vault": v["vault"].lower(), "token": v["token"].lower(), "src": src, "meta": meta})
        self.lasna = Source(LASNA_ID, os.environ.get("LASNA_RPC_URL", "") or LASNA_META["rpc"], [self.rc], LASNA_CHUNK,
                            rate=20)
        self.tx_input = {}
        self.verified = {}       # tx -> True/False (receipt re-read)
        self.lock = threading.Lock()
        self.snapshot = {"ok": False, "status": "starting", "seq": 0}
        self.events = []         # [{seq, ...}]
        self.seq = 0
        self.errors = 0
        self.last_error = None
        self._load_cache()

    # ------------------------------------------------------------------ cache
    def _cache_file(self):
        return os.path.join(self.cache_dir, "cursor.json")

    def _load_cache(self):
        try:
            d = json.load(open(self._cache_file()))
        except (FileNotFoundError, ValueError):
            return
        day = int(time.time()) // DAY
        for c in self.chains:
            c["src"].load(d.get(str(c["cid"])), day)
        self.lasna.load(d.get(str(LASNA_ID)), day)
        self.tx_input.update(d.get("txInput", {}))

    def _save_cache(self):
        d = {str(c["cid"]): c["src"].dump() for c in self.chains if c["src"].day is not None and c["src"].up_to is not None}
        if self.lasna.day is not None:
            d[str(LASNA_ID)] = self.lasna.dump()
        d["txInput"] = self.tx_input
        tmp = self._cache_file() + ".tmp"
        with open(tmp, "w") as f:
            json.dump(d, f)
        os.replace(tmp, self._cache_file())

    # ------------------------------------------------------------------ poll
    def poll_once(self):
        day = int(time.time()) // DAY
        fresh = {}
        for c in self.chains:
            fresh[c["key"]] = c["src"].sync(day)
        fresh["lasna"] = self.lasna.sync(day)
        if not (all(c["src"].caught_up for c in self.chains) and self.lasna.caught_up):
            # catching up: advance the cursors only; the page draws nothing chain-derived until done
            with self.lock:
                self.snapshot = {"ok": True, "ready": False, "seq": self.seq, "day": utc(day * DAY, "%Y-%m-%d"),
                                 "progress": {c["key"]: round(c["src"].progress(), 3) for c in self.chains}
                                 | {"lasna": round(self.lasna.progress(), 3)},
                                 "readAtUtc": utc(min(c["src"].head_ts for c in self.chains), "%H:%M:%S")}
            return
        views = self.read_views(day)
        snap, events = self.build(day, views, fresh)
        with self.lock:
            for ev in events:
                self.seq += 1
                ev["seq"] = self.seq
                self.events.append(ev)
            self.events = self.events[-400:]
            snap["seq"] = self.seq
            self.snapshot = snap

    def run(self, interval):
        n = 0
        while True:
            t0 = time.time()
            try:
                self.poll_once()
                self.errors = 0
                n += 1
                if n % 10 == 1:
                    self._save_cache()
            except Exception as e:  # keep serving the last good snapshot; say so on the page
                self.errors += 1
                self.last_error = f"{type(e).__name__}: {str(e)[:200]}"
                traceback.print_exc()
                with self.lock:
                    self.snapshot = dict(self.snapshot, rpcError=self.last_error, rpcErrorAt=int(time.time()))
            busy = not (all(c["src"].caught_up for c in self.chains) and self.lasna.caught_up)
            time.sleep(0.05 if busy else max(0.5, interval - (time.time() - t0)))

    # ------------------------------------------------------------------ views
    def read_views(self, day):
        L = self.lasna.rpc
        lh = hex(self.lasna.head)
        calls = [("cap()",), ("epoch()",), ("frozen()",), ("today()",), ("capOfDay(uint64)", day), ("poolOf(uint64)", day),
                 ("isOpen(uint64)", day)] + [("heldOf(uint64,uint8)", day, c["idx"]) for c in self.chains]
        batch = [("eth_call", [{"to": self.rc, "data": call_data(*c)}, lh]) for c in calls]
        batch += [("eth_call", [{"to": SYSTEM, "data": call_data("reserves(address)", self.rc)}, lh]),
                  ("eth_call", [{"to": SYSTEM, "data": call_data("debt(address)", self.rc)}, lh])]
        r = [E.words(x)[0] if x and x != "0x" else 0 for x in L.batch(batch)]
        n = len(self.chains)
        co = {"cap": r[0], "epoch": r[1], "frozen": bool(r[2]), "today": r[3], "capOfDay": r[4], "pool": r[5],
              "isOpen": bool(r[6]), "held": {c["key"]: r[7 + i] for i, c in enumerate(self.chains)},
              "reserves": r[7 + n], "debt": r[8 + n], "lasnaBlock": self.lasna.head, "lasnaTs": self.lasna.head_ts}
        ch = {}
        for c in self.chains:
            src = c["src"]
            wd = src.head_ts // DAY   # the wallet's day is its own chain's clock
            hb = hex(src.head)
            b = [("eth_call", [{"to": c["wallet"], "data": call_data("unspentOf(uint64)", wd)}, hb]),
                 ("eth_call", [{"to": c["wallet"], "data": call_data("frozen()")}, hb]),
                 ("eth_call", [{"to": c["wallet"], "data": call_data("epoch()")}, hb]),
                 ("eth_call", [{"to": c["wallet"], "data": call_data("stranded()")}, hb]),
                 ("eth_call", [{"to": c["token"], "data": call_data("balanceOf(address)", c["wallet"])}, hb]),
                 ("eth_call", [{"to": c["token"], "data": call_data("balanceOf(address)", c["vault"])}, hb])]
            v = [E.words(x)[0] if x and x != "0x" else 0 for x in src.rpc.batch(b)]
            ch[c["key"]] = {"unspent": v[0], "frozen": bool(v[1]), "epoch": v[2], "stranded": v[3], "walletBal": v[4],
                            "vaultBal": v[5], "block": src.head, "ts": src.head_ts}
        return {"coordinator": co, "chains": ch}

    def lasna_input(self, tx):
        if tx not in self.tx_input:
            t = self.lasna.rpc.call("eth_getTransactionByHash", [tx])
            self.tx_input[tx] = (t or {}).get("input", "").lower()
        return self.tx_input[tx]

    # ------------------------------------------------------------------ build
    def build(self, day, views, fresh):
        ready = all(c["src"].caught_up for c in self.chains) and self.lasna.caught_up
        by_key = {c["key"]: c for c in self.chains}
        co = views["coordinator"]

        # --- decode L2 logs
        payments, returns, origins, applied, not_applied, acks, reclaimed, shorts, refused, unstops = \
            [], [], {}, {}, {}, {}, {}, [], [], []
        for c in self.chains:
            src, k = c["src"], c["key"]
            for lg in src.by_block():
                t0 = lg["topics"][0] if lg["topics"] else ""
                w = E.words(lg["data"])
                if lg["address"] == c["token"] and t0 == T["Transfer"]:
                    frm, to = E.topic_addr(lg["topics"][1]), E.topic_addr(lg["topics"][2])
                    if frm != c["wallet"]:
                        continue
                    rec = {"chain": k, "units": w[0], "usd": usd(w[0]), "tx": lg["tx"], "block": lg["block"]}
                    (returns if to == c["vault"] else payments).append(rec)
                elif lg["address"] == c["wallet"]:
                    name = NAME_OF.get(t0)
                    if name in ("Short", "LowWater", "StopPressed"):
                        ts = w[2] if name != "StopPressed" else w[0]
                        o = {"chain": k, "kind": name, "tx": lg["tx"], "block": lg["block"], "ts": ts,
                             "amount": w[1] if name != "StopPressed" else 0}
                        origins.setdefault(lg["tx"], o)
                        if name == "Short":
                            shorts.append(o)
                    elif name == "GrantApplied":
                        applied[(k, int(lg["topics"][1], 16))] = {"tx": lg["tx"], "ts": w[2], "amount": w[1], "day": w[0]}
                    elif name == "GrantNotApplied":
                        not_applied[(k, int(lg["topics"][1], 16))] = {"tx": lg["tx"], "ts": w[1], "reason": w[0]}
                    elif name == "EpochAck":
                        acks[(k, int(lg["topics"][1], 16), bool(w[0]))] = {"tx": lg["tx"], "ts": w[1]}
                    elif name == "Reclaimed":
                        reclaimed[(k, int(lg["topics"][1], 16))] = {"tx": lg["tx"], "ts": w[2], "amount": w[1]}
                    elif name == "Refused":
                        refused.append({"chain": k, "tx": lg["tx"], "block": lg["block"], "reason": w[0]})
                elif lg["address"] == self.console and t0 == T["Unstop"]:
                    unstops.append({"tx": lg["tx"], "block": lg["block"], "epoch": w[1]})

        # block times for payments (Transfer carries none)
        for p in payments:
            p["ts"] = by_key[p["chain"]]["src"].rpc.block_ts(p["block"])
            p["utc"] = utc(p["ts"])
        payments.sort(key=lambda p: (p["ts"], p["block"]))

        # --- decode Lasna coordinator logs, grouped per reactive tx
        idx_key = {c["idx"]: c["key"] for c in self.chains}
        ltx = {}
        for lg in self.lasna.by_block():
            name = NAME_OF.get(lg["topics"][0] if lg["topics"] else "")
            if not name:
                continue
            w = E.words(lg["data"])
            ev = {"name": name, "w": w, "block": lg["block"], "logIndex": lg["logIndex"], "tx": lg["tx"]}
            if name in ("GrantSent", "ReclaimSent", "Credited"):
                ev["chain"] = idx_key.get(w[1] if name != "Credited" else w[1])
            ltx.setdefault(lg["tx"], []).append(ev)
        for tx, evs in ltx.items():
            ts = self.lasna.rpc.block_ts(evs[0]["block"])
            for ev in evs:
                ev["ts"] = ts

        # --- link each reactive tx to the origin whose hash its input carries (loop_logger: "origin-tx")
        interesting = [tx for tx, evs in ltx.items() if any(e["name"] in ("GrantSent", "ReclaimSent", "Frozen") for e in evs)]
        origin_hex = {tx[2:]: org for tx, org in origins.items()}
        linked = {}
        for tx in interesting:
            inp = self.lasna_input(tx)
            for h, o in origin_hex.items():
                if h in inp:
                    linked[tx] = o
                    break

        loops = self.build_loops(day, origins, ltx, linked, applied, not_applied, acks, reclaimed)

        # --- ✓ only after our own receipt re-read (a few per poll)
        budget = 8
        for lp in loops:
            if not lp["complete"]:
                continue
            ok = True
            for st in lp["steps"]:
                tx, ck = st[2], st[1]
                if tx not in self.verified and budget > 0:
                    budget -= 1
                    rpc = self.lasna.rpc if ck == "lasna" else by_key[ck]["src"].rpc
                    try:
                        r = rpc.receipt(tx)
                        self.verified[tx] = bool(r) and hexi(r["status"]) == 1 and self._expected_log(r, lp, st)
                    except E.RpcError:
                        pass
                ok = ok and self.verified.get(tx) is True
            lp["verified"] = ok

        # --- grants in flight (debited from the pool, not yet answered on the chain), today's only
        inflight = {c["key"]: [] for c in self.chains}
        for tx, evs in ltx.items():
            for e in evs:
                if e["name"] == "GrantSent" and e["w"][2] == day and e["chain"]:
                    gid = e["w"][0]
                    if (e["chain"], gid) not in applied and (e["chain"], gid) not in not_applied:
                        inflight[e["chain"]].append({"gid": gid, "units": e["w"][3], "lasnaTx": tx, "ts": e["ts"]})

        # --- per-chain picture
        cap_today = co["capOfDay"] if co["isOpen"] else co["cap"]
        spent_total = sum(p["units"] for p in payments)
        paused = co["debt"] > 0 or co["reserves"] == 0
        stats = self.stats(loops)
        chains_out, money_total, now = [], 0, int(time.time())
        open_donor = {lp["chain"] for lp in loops if lp["path"] == "chain-to-chain" and not lp["complete"]}
        for c in self.chains:
            k, v = c["key"], views["chains"][c["key"]]
            spent = sum(p["units"] for p in payments if p["chain"] == k)
            held = co["held"].get(k, 0)
            fly = sum(g["units"] for g in inflight[k])
            pending = held - v["unspent"] - spent - fly       # returned to the vault, waiting to be credited
            # plate: frozen > red/amber (an unanswered Short in the last 6 min) > open
            last_short = max((s for s in shorts if s["chain"] == k), key=lambda s: s["ts"], default=None)
            last_grant_ts = max([a["ts"] for (ck, _), a in applied.items() if ck == k] + [0])
            waiting = last_short and last_short["ts"] > last_grant_ts and now - last_short["ts"] < 360 and not v["frozen"]
            coin = 0
            plate = "open"
            if v["frozen"]:
                plate = "frozen"
            elif waiting:
                coin = usd(last_short["amount"] + v["unspent"])   # the refused price: shortBy + unspent then
                if paused:
                    plate = "held"
                elif usd(max(0, cap_today - spent_total)) < coin:
                    plate = "red"
                else:
                    plate = "amber"
            money = v["walletBal"] + v["vaultBal"]
            money_total += money
            chains_out.append({
                "key": k, "chainId": c["cid"], "name": c["meta"]["name"], "short": c["meta"]["short"],
                "explorer": c["meta"]["explorer"], "wallet": c["wallet"], "vault": c["vault"],
                "loop": usd(v["unspent"]), "knot": usd(max(0, pending)), "inflight": usd(fly), "held": usd(held),
                "spent": usd(spent), "payments": sum(1 for p in payments if p["chain"] == k),
                "returned": usd(sum(r["units"] for r in returns if r["chain"] == k)),
                "frozen": v["frozen"], "epoch": v["epoch"], "vault_": usd(v["vaultBal"]), "wallet_": usd(v["walletBal"]),
                "money": usd(money), "stranded": usd(v["stranded"]), "plate": plate, "coin": coin,
                "donor": k in open_donor, "booksGap": usd(min(0, pending)), "block": v["block"], "headTs": v["ts"],
            })

        unspent_live = sum(ch["loop"] for ch in chains_out if not ch["frozen"])
        can_leave = usd(max(0, cap_today - spent_total))
        any_frozen = co["frozen"] or any(ch["frozen"] for ch in chains_out)
        if any_frozen:
            headline = {"label": "MOST STILL POSSIBLE DURING FREEZE", "usd": unspent_live,
                        "sub": "$%.2f left in today's budget · %s" % (can_leave, "frozen" if all(ch["frozen"] for ch in chains_out) else "freezing")}
        elif paused:
            headline = {"label": "CAN STILL LEAVE TODAY · AFTER RESUME", "usd": can_leave,
                        "sub": "$%.2f waits on the spool · right now $%.2f can move" % (usd(co["pool"]), unspent_live)}
        else:
            headline = {"label": "CAN STILL LEAVE TODAY", "usd": can_leave, "sub": "of $%.2f today · all chains" % usd(cap_today)}

        heads = {c["key"]: {"block": c["src"].head, "ts": c["src"].head_ts} for c in self.chains}
        heads["lasna"] = {"block": self.lasna.head, "ts": self.lasna.head_ts}
        read_at = min(h["ts"] for h in heads.values())
        inflight_all = [dict(g, chain=k) for k, gs in inflight.items() for g in gs]
        snap = {
            "ok": True, "ready": ready, "mode": "live", "generatedAt": now,
            "progress": {c["key"]: round(c["src"].progress(), 3) for c in self.chains} | {"lasna": round(self.lasna.progress(), 3)},
            "day": utc(day * DAY, "%Y-%m-%d"), "dayNumber": day, "readAt": read_at, "readAtUtc": utc(read_at, "%H:%M:%S"),
            "heads": heads,
            "deployment": {"coordinator": self.rc, "console": self.console, "lasnaExplorer": LASNA_META["explorer"]},
            "coordinator": {"cap": usd(co["cap"]), "capToday": usd(cap_today), "dayOpen": co["isOpen"], "pool": usd(co["pool"]),
                            "epoch": co["epoch"], "frozen": co["frozen"], "reserves": co["reserves"] / 1e18,
                            "debt": co["debt"] / 1e18, "paused": paused, "today": co["today"]},
            "chains": chains_out, "payments": [{k: p[k] for k in ("chain", "usd", "tx", "block", "utc", "ts")} for p in payments],
            "loops": loops, "stats": stats, "inflight": inflight_all,
            "checker": {"spent": usd(spent_total), "cap": usd(cap_today), "over": usd(max(0, spent_total - cap_today)),
                        "canStillLeave": can_leave, "partial": True,
                        "perChain": {ch["key"]: {"out": ch["spent"], "n": ch["payments"], "returned": ch["returned"]} for ch in chains_out},
                        "capSource": "coordinator capOfDay on Lasna" if co["isOpen"] else "coordinator cap() (day not opened yet)"},
            "headline": headline, "heldOnChain": usd(money_total),
            "unstops": len(unstops),
        }

        # --- events for motion: only logs first seen after the catch-up (never history)
        events = []
        if ready:
            for c in self.chains:
                k = c["key"]
                for lg in fresh.get(k, []):
                    t0 = lg["topics"][0] if lg["topics"] else ""
                    w = E.words(lg["data"])
                    if lg["address"] == c["token"] and t0 == T["Transfer"]:
                        if E.topic_addr(lg["topics"][1]) == c["wallet"] and E.topic_addr(lg["topics"][2]) != c["vault"]:
                            events.append({"type": "paid", "chain": k, "usd": usd(w[0]), "tx": lg["tx"]})
                    elif lg["address"] == c["wallet"]:
                        name = NAME_OF.get(t0)
                        if name == "GrantApplied":
                            events.append({"type": "grantApplied", "chain": k, "gid": int(lg["topics"][1], 16), "usd": usd(w[1]), "tx": lg["tx"]})
                        elif name == "EpochAck":
                            events.append({"type": "epochAck", "chain": k, "epoch": int(lg["topics"][1], 16), "frozen": bool(w[0]), "tx": lg["tx"]})
                        elif name == "StopPressed":
                            events.append({"type": "stopPressed", "chain": k, "tx": lg["tx"]})
                        elif name == "Short":
                            events.append({"type": "short", "chain": k, "tx": lg["tx"]})
            for lg in fresh.get("lasna", []):
                name = NAME_OF.get(lg["topics"][0] if lg["topics"] else "")
                w = E.words(lg["data"])
                if name == "GrantSent":
                    events.append({"type": "grantSent", "chain": idx_key.get(w[1]), "gid": w[0], "usd": usd(w[3]), "tx": lg["tx"]})
                elif name == "Frozen":
                    events.append({"type": "frozen", "epoch": w[0], "tx": lg["tx"]})
                elif name == "Unfrozen":
                    events.append({"type": "unfrozen", "epoch": w[0], "tx": lg["tx"]})
        return snap, events

    def _expected_log(self, r, lp, st):
        """The re-read receipt holds the event this step stands for (address + topic0 [+ id])."""
        label, ck, tx = st[0], st[1], st[2]
        logs = [(l["address"].lower(), [t.lower() for t in l["topics"]], l["data"]) for l in r.get("logs", [])]
        if ck == "lasna":
            want = {"top-up": ("GrantSent",), "chain-to-chain": ("ReclaimSent", "GrantSent"), "STOP": ("Frozen",)}[lp["path"]]
            return any(a == self.rc and tp and NAME_OF.get(tp[0]) in want for a, tp, _ in logs)
        wallet = next(c["wallet"] for c in self.chains if c["key"] == ck)
        if label in ("origin", "press"):
            want = ("StopPressed",) if label == "press" else ("Short", "LowWater")
        elif label.startswith("GrantApplied#"):
            gid = int(label.split("#")[1])
            return any(a == wallet and tp and tp[0] == T["GrantApplied"] and int(tp[1], 16) == gid for a, tp, _ in logs)
        elif label.startswith("EpochAck("):
            e = int(label[9:label.index(",")])
            return any(a == wallet and tp and tp[0] == T["EpochAck"] and int(tp[1], 16) == e and E.words(d)[0] == 1
                       for a, tp, d in logs)
        elif label == "reclaim":
            want = ("Reclaimed",)
        else:
            return False
        return any(a == wallet and tp and NAME_OF.get(tp[0]) in want for a, tp, _ in logs)

    # ------------------------------------------------------------------ loops
    def build_loops(self, day, origins, ltx, linked, applied, not_applied, acks, reclaimed):
        short = {c["key"]: c["meta"]["short"] for c in self.chains}
        loops, used_grants = [], set()
        lasna_events = sorted((e for evs in ltx.values() for e in evs), key=lambda e: (e["block"], e["logIndex"]))

        def mk(o, path, kind, what, steps, complete, failures=None):
            lat = max(s[3] for s in steps) if complete else None
            return {"path": path, "kind": kind, "chain": o["chain"], "ts": o["ts"], "utc": utc(o["ts"]), "originTx": o["tx"],
                    "what": what, "steps": steps, "complete": complete, "latencySec": lat,
                    "actual": fmt_lat(lat) if complete else ("failed" if failures else "…"), "failures": failures or [],
                    "verified": False}

        # 1. donor loops first: origin Short -> ReclaimSent (linked) -> Reclaimed on the donor ->
        #    Credited(RECLAIM) -> GrantSent to the origin chain -> GrantApplied
        for tx, evs in sorted(ltx.items(), key=lambda kv: kv[1][0]["block"]):
            o = linked.get(tx)
            rs = [e for e in evs if e["name"] == "ReclaimSent"]
            if not o or o["kind"] not in ("Short", "LowWater") or not rs:
                continue
            r = rs[0]
            rid, donor = r["w"][0], r["chain"]
            steps = [["origin", o["chain"], o["tx"], 0], ["react", "lasna", tx, evs[0]["ts"] - o["ts"]]]
            rc = reclaimed.get((donor, rid))
            if rc:
                steps.append(["reclaim", donor, rc["tx"], rc["ts"] - o["ts"]])
            cred = next((e for e in lasna_events if e["name"] == "Credited" and e["w"][0] == 1 and e["chain"] == donor
                         and e["block"] >= r["block"]), None)
            grant = cred and next((e for e in lasna_events if e["name"] == "GrantSent" and e["chain"] == o["chain"]
                                   and e["w"][0] > rid and (e["block"], e["logIndex"]) > (cred["block"], cred["logIndex"])
                                   and e["tx"] not in used_grants), None)
            done = False
            failures = []
            gid = None
            if grant:
                used_grants.add(grant["tx"])
                gid = grant["w"][0]
                steps.append(["react", "lasna", grant["tx"], grant["ts"] - o["ts"]])
                a = applied.get((o["chain"], gid))
                if a:
                    steps.append(["GrantApplied#%d" % gid, o["chain"], a["tx"], a["ts"] - o["ts"]])
                    done = True
                elif (o["chain"], gid) in not_applied:
                    failures.append("GrantNotApplied#%d" % gid)
            give = "+%d s" % (rc["ts"] - o["ts"]) if rc else "…"
            what = "%s on %s → Lasna → %s gives up $%.0f (%s) → L2 finality wait → %s on %s" % (
                "Short" if o["kind"] == "Short" else "paid, running low", short[o["chain"]], short.get(donor, "?"), usd(rc["amount"]) if rc else usd(r["w"][3]), give,
                ("GrantApplied#%d" % gid) if gid else "grant", short[o["chain"]])
            loops.append(mk(o, "chain-to-chain", "donor", what, steps, done, failures))

        # 2. top-up loops: origin Short / LowWater -> GrantSent (same reactive tx) -> GrantApplied
        for tx, evs in ltx.items():
            o = linked.get(tx)
            if not o or o["kind"] not in ("Short", "LowWater") or tx in used_grants:
                continue
            if any(e["name"] == "ReclaimSent" for e in evs):
                continue
            g = next((e for e in evs if e["name"] == "GrantSent" and e["chain"] == o["chain"]), None)
            if not g:
                continue
            gid = g["w"][0]
            steps = [["origin", o["chain"], o["tx"], 0], ["react", "lasna", tx, g["ts"] - o["ts"]]]
            a = applied.get((o["chain"], gid))
            failures = []
            if a:
                steps.append(["GrantApplied#%d" % gid, o["chain"], a["tx"], a["ts"] - o["ts"]])
            elif (o["chain"], gid) in not_applied:
                failures.append("GrantNotApplied#%d" % gid)
            refusal = o["kind"] == "Short"
            what = ("pay refused (Short) on %s" if refusal else "paid, running low on %s") % short[o["chain"]] + \
                " → Lasna react → GrantApplied#%d on %s" % (gid, short[o["chain"]])
            loops.append(mk(o, "top-up", "refusal" if refusal else "refill ahead", what, steps, bool(a), failures))

        # 3. STOP loops: StopPressed -> Frozen(e) -> EpochAck(e, frozen) on every chain
        for tx, evs in ltx.items():
            o = linked.get(tx)
            f = next((e for e in evs if e["name"] == "Frozen"), None)
            if not o or o["kind"] != "StopPressed" or not f:
                continue
            e = f["w"][0]
            steps = [["press", o["chain"], o["tx"], 0], ["react", "lasna", tx, f["ts"] - o["ts"]]]
            done = True
            for c in self.chains:
                a = acks.get((c["key"], e, True))
                if a:
                    steps.append(["EpochAck(%d, frozen)" % e, c["key"], a["tx"], a["ts"] - o["ts"]])
                else:
                    done = False
            what = "STOP pressed on %s → Lasna react → EpochAck(%d, frozen) on %s" % (
                short[o["chain"]], e, ", on ".join(c["meta"]["short"] for c in self.chains))
            loops.append(mk(o, "STOP", "stop", what, steps, done))

        loops.sort(key=lambda lp: (lp["ts"], lp["originTx"]))
        n = {"top-up": 0, "chain-to-chain": 0, "STOP": 0}
        for lp in loops:
            n[lp["path"]] += 1
            lp["id"] = {"top-up": "T", "chain-to-chain": "D", "STOP": "S"}[lp["path"]] + str(n[lp["path"]])
        return loops

    @staticmethod
    def stats(loops):
        out = []
        for path in ("top-up", "chain-to-chain", "STOP"):
            lat = sorted(lp["latencySec"] for lp in loops if lp["path"] == path and lp["latencySec"] is not None)
            if not lat:
                out.append({"label": path, "value": "no loop today yet", "n": 0})
                continue
            med, mx = statistics.median(lat), lat[-1]   # small n: median and max, not percentiles
            f = (lambda s: "%.1f min" % (s / 60)) if path == "chain-to-chain" else (lambda s: "%g s" % s)
            out.append({"label": path, "value": "median %s · max %s" % (f(med), f(mx)), "n": len(lat), "median": med, "max": mx})
        return out


def fmt_lat(s):
    if s is None:
        return "…"
    if s < 120:
        return "%d s" % s
    return "%d min %d s" % (s // 60, s % 60)


# ---------------------------------------------------------------------- HTTP
def make_handler(dash, web_root):
    class H(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *a, **kw):
            super().__init__(*a, directory=web_root, **kw)

        def log_message(self, fmt, *args):
            pass

        def end_headers(self):
            self.send_header("Cache-Control", "no-store")
            super().end_headers()

        def do_POST(self):          # read-only: nothing to post
            self.send_error(405)

        def do_GET(self):
            u = urllib.parse.urlparse(self.path)
            if u.path == "/mode.js":   # the static file says "replay build"; served from here, the page is live
                body = b"window.PS_SERVER = true;\n"
                self.send_response(200)
                self.send_header("Content-Type", "text/javascript")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if u.path == "/api/state":
                q = urllib.parse.parse_qs(u.query)
                with dash.lock:
                    snap = dict(dash.snapshot)
                    since = q.get("since", [None])[0]
                    snap["events"] = [e for e in dash.events if since is not None and e["seq"] > int(since)]
                body = json.dumps(snap).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            return super().do_GET()
    return H


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=8917)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--interval", type=float, default=3.0, help="seconds between polls once caught up")
    ap.add_argument("--deployments", default=None,
                    help="deployment file (default: the repo's deployments/latest.json)")
    a = ap.parse_args()
    dep_file = a.deployments or os.path.join(REPO, "deployments", "latest.json")
    dep = json.load(open(dep_file))
    if dep.get("dryRun"):
        sys.exit("dry-run deployment file: this dashboard reads live testnets only")
    os.makedirs(os.path.join(HERE, "cache"), exist_ok=True)
    dash = Dashboard(dep, os.path.join(HERE, "cache"))
    threading.Thread(target=dash.run, args=(a.interval,), daemon=True).start()
    socketserver.ThreadingTCPServer.allow_reuse_address = True
    srv = http.server.ThreadingHTTPServer((a.host, a.port), make_handler(dash, os.path.join(HERE, "web")))
    print(f"Pursestrings dashboard (read-only), live mode on http://{a.host}:{a.port}/  "
          f"deployments: {os.path.relpath(dep_file)}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
