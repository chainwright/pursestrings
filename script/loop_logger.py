#!/usr/bin/env python3
"""Read-only logger for the live loop: origin tx -> reactive tx (Lasna) -> getCallbacks -> destination tx.

It never sends a transaction and needs no key. It reads RPC URLs from the environment variables
LASNA_RPC_URL, BASE_SEPOLIA_RPC_URL and UNICHAIN_SEPOLIA_RPC_URL (names only; the URLs are never
printed) and the deployed addresses from DEPLOYMENTS_FILE (default deployments/latest.json).

    loop_logger.py trace --path topup --chain base --tx 0x...   # after `Loop.s.sol pay` refused
    loop_logger.py trace --path donor --chain base --tx 0x...   # the Short that needs a reclaim
    loop_logger.py trace --path stop  --chain base --tx 0x...   # after `Loop.s.sol stop`
    loop_logger.py summary                                      # median / p95 per path
    loop_logger.py last-tx --fn pay --chain base                # hash of the last Loop.s.sol call

How a loop is matched (one loop at a time; not in the 2 h before 00:00 UTC, when pre-grants run):
  1. the coordinator event on Lasna that this path must produce:
       topup  GrantSent for the origin chain and the origin's UTC day (not tomorrow's pre-grant)
       donor  ReclaimSent from another chain, then Credited (RECLAIM), then that GrantSent
       stop   Frozen (epoch e)
     A candidate must pass two floors, so a loop can't match the loop before it (W1 gate P0-3:
     the Lasna search starts ~35 s before the origin, and a previous loop's GrantSent or Frozen
     on the same chain used to be taken):
       - its Lasna block time >= the origin's block time - LOOP_CLOCK_SKEW_SEC (default 2);
       - its grant id (topup, donor) or epoch (stop) > the largest one already recorded in
         LOOPS_FILE by a loop with a different origin tx.
     Among those, the first event emitted by the reactive tx that carries the origin itself (the
     reactive tx's input holds the origin tx hash inside its LogRecord; seen live on 07.11) is
     taken at once: link "origin-tx". An event from a later reactive tx (a Cron tick that served
     the want, say) is taken only if no linked one has appeared LOOP_LINK_GRACE_SEC (default 90)
     after it was first seen: link "floors". The donor path's Credited and GrantSent come from
     later reactive txs by design and are searched from the block of the step before.
  2. the callback(s) that ANSWER it, found among getCallbacks(reactive tx) by reading each
     destination receipt for the wallet event that confirms the step applied:
       topup, donor  GrantApplied with that grant's id, from the origin chain's wallet
       stop          EpochAck(e, frozen = true) from every wallet
     Every other callback of the reactive tx (a heartbeat re-read, a callback to the other chain)
     is recorded with role "other" and does not count.
  3. complete = every required answer was found; GrantNotApplied for the grant is reported as a
     failure. latencySec = the last answer's block time - the origin's block time (timestamps of
     two different chains: ±1 s). A negative latency means an earlier loop was matched: the
     record is marked incomplete with a failure, never counted.

`summary` keeps one record per origin tx (the last one written), so a re-traced origin is not
counted twice.

Costs are recorded twice: what the receipts show (gas used x effective gas price), and the fee by
the documented formula (DOCS_BRIEF section 5): Lasna max(price, basefee) x (gas + 100k); callbacks
max(price, basefee) x 1.1 x (gas + extraGas), extraGas 80k on the L2s. Both are to be checked
against the reserves/debt the network actually charges.
Each trace is appended as one JSON line to live/loops.jsonl (LOOPS_FILE overrides).
"""
import argparse
import json
import os
import re
import statistics
import subprocess
import sys
import time

CAST = os.environ.get("CAST", os.path.expanduser("~/.foundry/bin/cast"))
SYSTEM = "0x8888888888888888888888888888888888888888"
# getCallbacks is served by the Lasna service contract at 0x…ffffff, not by the system
# contract 0x8888…: there it returns [] (checked live 07.11 on reactive tx 0xe72a…76ff).
# The anvil dry run keeps its stand-in index at 0x8888…, so dryrun.sh overrides this.
CALLBACK_INDEX = os.environ.get("LASNA_CALLBACK_INDEX", "0x0000000000000000000000000000000000ffffff")
CHAINS = {"base": ("BASE_SEPOLIA_RPC_URL", 84532, 0), "unichain": ("UNICHAIN_SEPOLIA_RPC_URL", 1301, 1)}
RPC_BY_CHAIN_ID = {84532: "BASE_SEPOLIA_RPC_URL", 1301: "UNICHAIN_SEPOLIA_RPC_URL", 5318007: "LASNA_RPC_URL"}
EVENTS = {
    "GrantSent": "GrantSent(uint256,uint8,uint64,uint256,uint64)",
    "ReclaimSent": "ReclaimSent(uint256,uint8,uint64,uint256)",
    "Credited": "Credited(uint8,uint8,uint64,uint256)",
    "Frozen": "Frozen(uint64)",
}
OUT = os.environ.get("LOOPS_FILE", "live/loops.jsonl")
SKEW = int(os.environ.get("LOOP_CLOCK_SKEW_SEC", "2"))
LINK_GRACE = int(os.environ.get("LOOP_LINK_GRACE_SEC", "90"))
POLL = int(os.environ.get("LOOP_POLL_SEC", "15"))


def rpc(env):
    url = os.environ.get(env)
    if not url:
        sys.exit(f"set {env}")
    return url


def cast(*args, env):
    r = subprocess.run([CAST, *args, "--rpc-url", rpc(env)], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"cast {args[0]} failed: {r.stderr.strip()[:300]}")
    return r.stdout.strip()


def h(x):
    return int(x, 16) if isinstance(x, str) and x.startswith("0x") else int(x)


def receipt(tx, env):
    r = json.loads(cast("receipt", tx, "--json", env=env))
    # Public L2 RPCs sit behind load balancers: a receipt can arrive from a node that
    # already has it while the next call lands on one that hasn't seen the block yet
    # (seen live on Unichain Sepolia 07.11: "block 0x400cf68 not found"). Retry briefly.
    for attempt in range(10):
        try:
            b = json.loads(cast("block", str(h(r["blockNumber"])), "--json", env=env))
            break
        except RuntimeError:
            if attempt == 9:
                raise
            time.sleep(2)
    gas, price = h(r["gasUsed"]), h(r.get("effectiveGasPrice", "0x0"))
    return {
        "logs": [{"address": l["address"], "topics": l["topics"], "data": l["data"]} for l in r.get("logs", [])],
        "tx": tx,
        "block": h(r["blockNumber"]),
        "ts": h(b["timestamp"]),
        "status": h(r["status"]),
        "gasUsed": gas,
        "gasPrice": price,
        "paidWei": gas * price,
        "baseFee": h(b.get("baseFeePerGas", "0x0")),
    }


LOGS_CHUNK = int(os.environ.get("LOGS_CHUNK", "500"))


def logs(rc, sig, from_block):
    """Coordinator logs from from_block to the head, fetched in chunks: public RPCs cap the
    eth_getLogs block range (Base Sepolia: 200), and a donor loop can span ~8,000 Lasna blocks.
    A refused chunk is halved and retried, down to 25 blocks."""
    head = int(cast("block-number", env="LASNA_RPC_URL"))
    res, start, size = [], from_block, LOGS_CHUNK
    while start <= head:
        end = min(head, start + size - 1)
        try:
            out = cast("logs", "--json", "--from-block", str(start), "--to-block", str(end), "--address", rc, sig,
                       env="LASNA_RPC_URL")
        except RuntimeError:
            if size <= 25:
                raise
            size //= 2
            continue
        res.extend(json.loads(out) if out else [])
        start = end + 1
    return res


def words(data):
    d = data[2:]
    return [int(d[i:i + 64], 16) for i in range(0, len(d), 64)]


def callbacks(reactive_tx):
    sig = "getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])"
    out = cast("call", CALLBACK_INDEX, sig, str(h(reactive_tx)), "--json", env="LASNA_RPC_URL")
    try:
        rows = json.loads(out)[0]
    except Exception:
        return {"raw": out}
    if isinstance(rows, str):
        return {"raw": rows}
    res = []
    for row in rows:
        blk, sender, idx, chain_id, dest_tx, err = row
        res.append({"block": int(blk), "sender": sender, "index": int(idx), "chainId": int(chain_id),
                    "destTx": "0x%064x" % int(dest_tx), "error": err})
    return res


_block_ts, _tx_input = {}, {}


def lasna_block_ts(n):
    if n not in _block_ts:
        _block_ts[n] = int(cast("block", str(n), "--field", "timestamp", env="LASNA_RPC_URL"), 0)
    return _block_ts[n]


def carries_origin(reactive_tx, origin_tx):
    """True if the reactive tx's input holds the origin tx hash (its LogRecord's txHash)."""
    if reactive_tx not in _tx_input:
        try:
            _tx_input[reactive_tx] = cast("tx", reactive_tx, "input", env="LASNA_RPC_URL").lower()
        except RuntimeError:
            _tx_input[reactive_tx] = ""
    return origin_tx.lower().removeprefix("0x") in _tx_input[reactive_tx]


def choose(cands, floor_ts, min_word0, now, first_seen, grace=None):
    """The candidate a loop may take, or None to keep polling. Pure, for the tests.

    cands: logs already filtered by the path's predicate, in chain order, each with "ts" (Lasna
    block time), "w0" (grant id / epoch) and "linked" (emitted by the reactive tx carrying the
    origin). first_seen: (tx hash, log index) -> when this trace first saw it, kept by the
    caller. A candidate older than the origin (minus the clock skew) or with a grant id / epoch
    a recorded loop already used is never taken. A linked one is taken at once; otherwise the
    earliest passing one once it has waited `grace` seconds without a linked one appearing."""
    grace = LINK_GRACE if grace is None else grace
    ok = [c for c in cands if c["ts"] >= floor_ts and c["w0"] > min_word0]
    for c in ok:
        if c["linked"]:
            return c, "origin-tx"
    for c in ok:
        seen = first_seen.setdefault((c["transactionHash"], c.get("logIndex")), now)
        if now - seen >= grace:
            return c, "floors"
    return None


def find(rc, name, from_block, pred, deadline, origin=None, min_word0=-1, link=True):
    """Polls for the first coordinator `name` event that passes `pred` and the floors (see the
    module doc). origin: the origin receipt (time floor and tx link); None for the donor path's
    later steps, which are ordered by from_block only."""
    sig = EVENTS[name]
    first_seen = {}
    floor_ts = origin["ts"] - SKEW if origin else -1
    while time.time() < deadline:
        cands = []
        for lg in logs(rc, sig, from_block):
            w = words(lg["data"])
            if not pred(w):
                continue
            c = dict(lg)
            c["w0"] = w[0]
            c["ts"] = lasna_block_ts(h(lg["blockNumber"])) if origin else 0
            c["linked"] = bool(origin and link and carries_origin(lg["transactionHash"], origin["tx"]))
            cands.append(c)
        got = choose(cands, floor_ts, min_word0, time.time(), first_seen, grace=LINK_GRACE if link else 0)
        if got:
            lg, how = got
            lg["link"] = how if origin else "after the step before"
            return lg
        time.sleep(POLL)
    return None


LABEL_ID = re.compile(r"^GrantApplied#(\d+)$")
LABEL_EPOCH = re.compile(r"^EpochAck\((\d+), frozen\)")


def recorded_floors(path, origin_tx):
    """The largest grant id and epoch already used by recorded loops with another origin tx.
    Reads the fields written since P0-3 (grantId, epoch) and, for older records, the answer
    labels. A missing file gives (-1, -1)."""
    gid, ep = -1, -1
    if not os.path.exists(path):
        return gid, ep
    with open(path) as f:
        lines = f.readlines()
    for line in lines:
        line = line.strip()
        if not line:
            continue
        r = json.loads(line)
        if r.get("origin", {}).get("tx", "").lower() == origin_tx.lower():
            continue
        if r.get("grantId") is not None:
            gid = max(gid, int(r["grantId"]))
        if r.get("epoch") is not None:
            ep = max(ep, int(r["epoch"]))
        for label in list(r.get("answers", {})) + list(r.get("failures", [])):
            m = LABEL_ID.match(label) or re.match(r"^GrantNotApplied#(\d+)$", label)
            if m:
                gid = max(gid, int(m.group(1)))
            m = LABEL_EPOCH.match(label)
            if m:
                ep = max(ep, int(m.group(1)))
    return gid, ep


def fee_lasna(r):
    return max(r["gasPrice"], r["baseFee"]) * (r["gasUsed"] + 100_000)


def fee_callback(r):
    return max(r["gasPrice"], r["baseFee"]) * 11 * (r["gasUsed"] + 80_000) // 10


def offline(*args):
    r = subprocess.run([CAST, *args], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"cast {args[0]} failed: {r.stderr.strip()[:300]}")
    return r.stdout.strip()


def answers_in(rcpt, wanted):
    """Which of the wanted wallet events this destination receipt contains.
    wanted: list of (label, wallet address, topic0, topic1 or None, predicate on data words or None)."""
    found = []
    for lg in rcpt.get("logs", []):
        for label, addr, t0, t1, pred in wanted:
            if lg["address"].lower() != addr.lower() or not lg["topics"] or lg["topics"][0].lower() != t0:
                continue
            if t1 is not None and (len(lg["topics"]) < 2 or int(lg["topics"][1], 16) != t1):
                continue
            if pred is not None and not pred(words(lg["data"])):
                continue
            found.append(label)
    return found


def lasna_block_before(ts):
    """A Lasna block at or before time ts. The public Lasna RPC prunes old blocks, so
    `cast find-block` (a binary search from block 1) fails there. Step back from the
    latest block by elapsed time at the measured 1.064 s/block, with a 5% + 30-block margin."""
    latest = int(cast("block-number", env="LASNA_RPC_URL"))
    latest_ts = int(cast("block", "latest", "--field", "timestamp", env="LASNA_RPC_URL"), 0)
    back = int(max(0, latest_ts - ts) / 1.064 * 1.05) + 30
    return max(0, latest - back)


def trace(a):
    dep = json.load(open(os.environ.get("DEPLOYMENTS_FILE", "deployments/latest.json")))
    rc = dep["coordinator"]
    wallets = [dep["base"]["wallet"], dep["unichain"]["wallet"]]
    env, chain_id, idx = CHAINS[a.chain]
    origin = receipt(a.tx, env)
    origin_day = origin["ts"] // 86400
    lasna_from = lasna_block_before(origin["ts"])
    deadline = time.time() + a.timeout_min * 60
    t_applied = offline("keccak", "GrantApplied(uint256,uint64,uint256,uint64)").lower()
    t_not_applied = offline("keccak", "GrantNotApplied(uint256,uint8,uint64)").lower()
    t_epoch_ack = offline("keccak", "EpochAck(uint64,bool,uint64)").lower()

    # 1. the coordinator events this loop must produce; the last one carries the callback(s)
    #    whose wallet-side answer ends the loop
    # floors: nothing a recorded loop (another origin tx) already used, nothing before the origin
    min_gid, min_epoch = recorded_floors(OUT, a.tx)
    if a.path == "topup":
        # today's grant to the origin chain (not tomorrow's pre-grant)
        steps = [find(rc, "GrantSent", lasna_from, lambda w: w[1] == idx and w[2] == origin_day, deadline,
                      origin=origin, min_word0=min_gid)]
    elif a.path == "stop":
        steps = [find(rc, "Frozen", lasna_from, lambda w: True, deadline, origin=origin, min_word0=min_epoch)]
    else:  # donor
        # ReclaimSent ids share the grant id counter (nextId), so the grant floor applies to both
        ask = find(rc, "ReclaimSent", lasna_from, lambda w: w[1] != idx and w[2] == origin_day, deadline,
                   origin=origin, min_word0=min_gid)
        cred = ask and find(rc, "Credited", h(ask["blockNumber"]), lambda w: w[0] == 1, deadline)
        grant = cred and find(
            rc, "GrantSent", h(cred["blockNumber"]), lambda w: w[1] == idx and w[2] == origin_day, deadline,
            min_word0=max(min_gid, words(ask["data"])[0])
        )
        steps = [ask, cred, grant]

    # 2. what answers the loop: the wallet event(s) that confirm the grant / the freeze applied
    last = steps[-1]
    wanted, failure = [], []
    if last:
        w = words(last["data"])
        if a.path in ("topup", "donor"):
            gid = w[0]
            wanted = [(f"GrantApplied#{gid}", wallets[idx], t_applied, gid, None)]
            failure = [(f"GrantNotApplied#{gid}", wallets[idx], t_not_applied, gid, None)]
        else:
            e = w[0]
            wanted = [(f"EpochAck({e}, frozen) on {n}", wallets[c], t_epoch_ack, e, lambda d: d[0] == 1)
                      for c, n in enumerate(("base", "unichain"))]

    rec = {"path": a.path, "chain": a.chain, "origin": origin, "reactive": [], "answers": {}, "failures": [],
           "links": [lg.get("link") if lg else None for lg in steps],
           "floors": {"grantIdAbove": min_gid, "epochAbove": min_epoch, "lasnaTsFrom": origin["ts"] - SKEW}}
    if last:
        rec["grantId" if a.path in ("topup", "donor") else "epoch"] = words(last["data"])[0]
    seen_dest = {}
    for k, lg in enumerate(steps):
        if not lg:
            continue
        rtx = lg["transactionHash"]
        rr = receipt(rtx, "LASNA_RPC_URL")
        rr["feeFormulaWei"] = fee_lasna(rr)
        is_last = k == len(steps) - 1
        while True:
            cbs = callbacks(rtx)
            dests = []
            if isinstance(cbs, list):
                for cb in cbs:
                    d = dict(cb)
                    denv = RPC_BY_CHAIN_ID.get(cb["chainId"])
                    if denv and int(cb["destTx"], 16) != 0:
                        try:
                            dr = seen_dest.get(cb["destTx"]) or receipt(cb["destTx"], denv)
                            seen_dest[cb["destTx"]] = dr
                            dr["feeFormulaWei"] = fee_callback(dr)
                            d["receipt"] = {kk: vv for kk, vv in dr.items() if kk != "logs"}
                            got = answers_in(dr, wanted) if is_last else []
                            bad = answers_in(dr, failure) if is_last else []
                            d["role"] = "answer" if got else ("failed answer" if bad else "other")
                            d["walletEvents"] = got + bad
                            for g in got:
                                rec["answers"].setdefault(g, {"destTx": cb["destTx"], "ts": dr["ts"]})
                            for b in bad:
                                if b not in rec["failures"]:
                                    rec["failures"].append(b)
                        except RuntimeError as e:
                            d["receiptError"] = str(e)
                    dests.append(d)
            else:
                dests = cbs
            done = (not is_last) or len(rec["answers"]) == len(wanted) or rec["failures"]
            if done or time.time() >= deadline:
                break
            time.sleep(15)
        rec["reactive"].append({"receipt": rr, "callbacks": dests})

    rec["complete"] = bool(wanted) and len(rec["answers"]) == len(wanted) and not rec["failures"]
    rec["latencySec"] = (max(v["ts"] for v in rec["answers"].values()) - origin["ts"]) if rec["complete"] else None
    if rec["latencySec"] is not None and rec["latencySec"] < 0:
        # an answer from before the origin: an earlier loop was matched; never count it
        rec["failures"].append(f"negative latency {rec['latencySec']} s: matched an earlier loop")
        rec["complete"], rec["latencySec"] = False, None
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "a") as f:
        f.write(json.dumps(rec) + "\n")
    print(json.dumps({
        "path": rec["path"], "chain": rec["chain"], "complete": rec["complete"], "latencySec": rec["latencySec"],
        "answers": rec["answers"], "failures": rec["failures"],
        "reactiveTxs": [st["receipt"]["tx"] for st in rec["reactive"]],
        "otherCallbacks": [d.get("destTx") for st in rec["reactive"]
                           for d in (st["callbacks"] if isinstance(st["callbacks"], list) else [])
                           if d.get("role") == "other"],
    }, indent=1))


def summary(_):
    if not os.path.exists(OUT):
        sys.exit(f"no {OUT} yet")
    by, last_by_origin, n = {}, {}, 0
    with open(OUT) as f:
        lines = f.readlines()
    for line in lines:
        if not line.strip():
            continue
        r = json.loads(line)
        n += 1
        last_by_origin[r["origin"]["tx"].lower()] = r  # a re-traced origin: keep the last record
    for r in last_by_origin.values():
        by.setdefault(r["path"], []).append(r)
    if n != len(last_by_origin):
        print(f"{OUT}: {n} records, {len(last_by_origin)} origins ({n - len(last_by_origin)} re-trace(s) dropped, "
              f"the last record per origin kept)")
    for path, rs in sorted(by.items()):
        lat = sorted(r["latencySec"] for r in rs if r["latencySec"] is not None)
        lasna = [s["receipt"]["feeFormulaWei"] for r in rs for s in r["reactive"]]
        cbs = [d["receipt"]["feeFormulaWei"] for r in rs for s in r["reactive"]
               for d in (s["callbacks"] if isinstance(s["callbacks"], list) else []) if "receipt" in d]
        p95 = lat[min(len(lat) - 1, int(round(0.95 * (len(lat) - 1))))] if lat else None
        print(f"{path}: runs {len(rs)}, complete {len(lat)}, latency median "
              f"{statistics.median(lat) if lat else None} s, p95 {p95} s; "
              f"reactive txs {len(lasna)} (formula mean {statistics.mean(lasna) / 1e18 if lasna else 0:.6f} lREACT); "
              f"callbacks {len(cbs)} (formula mean {statistics.mean(cbs) / 1e18 if cbs else 0:.8f} ETH)")


def last_tx(a):
    _, chain_id, _ = CHAINS[a.chain]
    root = os.environ.get("FOUNDRY_BROADCAST", "broadcast")
    f = os.path.join(root, "Loop.s.sol", str(chain_id), f"{a.script_fn}-latest.json")
    if not os.path.exists(f):
        sys.exit(f"no broadcast record {f}")
    rs = json.load(open(f))["receipts"]
    if not rs:
        sys.exit(f"no receipts in {f}")
    print(rs[-1]["transactionHash"])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    t = sub.add_parser("trace")
    t.add_argument("--path", choices=["topup", "donor", "stop"], required=True)
    t.add_argument("--chain", choices=list(CHAINS), required=True)
    t.add_argument("--tx", required=True)
    t.add_argument("--timeout-min", type=float, default=120)
    t.set_defaults(fn=trace)
    s = sub.add_parser("summary")
    s.set_defaults(fn=summary)
    lt = sub.add_parser("last-tx")
    lt.add_argument("--fn", dest="script_fn", required=True, help="the Loop.s.sol function, e.g. pay or stop")
    lt.add_argument("--chain", choices=list(CHAINS), required=True)
    lt.set_defaults(fn=last_tx)
    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
