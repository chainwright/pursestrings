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
  1. the coordinator event on Lasna, at or after the origin block's time, that this path must
     produce (a heuristic: Reactive's RPC may offer a direct origin-tx link, to check):
       topup  GrantSent for the origin chain and the origin's UTC day (not tomorrow's pre-grant)
       donor  ReclaimSent from another chain, then Credited (RECLAIM), then that GrantSent
       stop   Frozen (epoch e)
  2. the callback(s) that ANSWER it, found among getCallbacks(reactive tx) by reading each
     destination receipt for the wallet event that confirms the step applied:
       topup, donor  GrantApplied with that grant's id, from the origin chain's wallet
       stop          EpochAck(e, frozen = true) from every wallet
     Every other callback of the reactive tx (a heartbeat re-read, a callback to the other chain)
     is recorded with role "other" and does not count.
  3. complete = every required answer was found; GrantNotApplied for the grant is reported as a
     failure. latencySec = the last answer's block time - the origin's block time (timestamps of
     two different chains: ±1 s).

Costs are recorded twice: what the receipts show (gas used x effective gas price), and the fee by
the documented formula (DOCS_BRIEF section 5): Lasna max(price, basefee) x (gas + 100k); callbacks
max(price, basefee) x 1.1 x (gas + extraGas), extraGas 80k on the L2s. Both are to be checked
against the reserves/debt the network actually charges.
Each trace is appended as one JSON line to live/loops.jsonl (LOOPS_FILE overrides).
"""
import argparse
import json
import os
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
    b = json.loads(cast("block", str(h(r["blockNumber"])), "--json", env=env))
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


def logs(rc, sig, from_block):
    out = cast("logs", "--json", "--from-block", str(from_block), "--to-block", "latest", "--address", rc, sig,
               env="LASNA_RPC_URL")
    return json.loads(out) if out else []


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


def find(rc, name, from_block, pred, deadline):
    sig = EVENTS[name]
    while time.time() < deadline:
        for lg in logs(rc, sig, from_block):
            if pred(words(lg["data"])):
                return lg
        time.sleep(15)
    return None


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
    if a.path == "topup":
        # today's grant to the origin chain (not tomorrow's pre-grant)
        steps = [find(rc, "GrantSent", lasna_from, lambda w: w[1] == idx and w[2] == origin_day, deadline)]
    elif a.path == "stop":
        steps = [find(rc, "Frozen", lasna_from, lambda w: True, deadline)]
    else:  # donor
        ask = find(rc, "ReclaimSent", lasna_from, lambda w: w[1] != idx and w[2] == origin_day, deadline)
        cred = ask and find(rc, "Credited", h(ask["blockNumber"]), lambda w: w[0] == 1, deadline)
        grant = cred and find(
            rc, "GrantSent", h(cred["blockNumber"]), lambda w: w[1] == idx and w[2] == origin_day, deadline
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

    rec = {"path": a.path, "chain": a.chain, "origin": origin, "reactive": [], "answers": {}, "failures": []}
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
    by = {}
    for line in open(OUT):
        r = json.loads(line)
        by.setdefault(r["path"], []).append(r)
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
