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

How a reactive tx is matched to an origin tx (a heuristic; Reactive's RPC may offer a direct link,
to check with reactivedevs): the first coordinator event on Lasna, at or after the origin block's
time, that this path must produce:
    topup  GrantSent for the origin chain
    donor  ReclaimSent (the ask), then a Credited of kind RECLAIM, then GrantSent for the origin chain
    stop   Frozen
For each matched reactive tx, getCallbacks(tx) on the system contract lists the destination txs.

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
    out = cast("call", SYSTEM, sig, str(h(reactive_tx)), "--json", env="LASNA_RPC_URL")
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


def trace(a):
    dep = json.load(open(os.environ.get("DEPLOYMENTS_FILE", "deployments/latest.json")))
    rc = dep["coordinator"]
    env, chain_id, idx = CHAINS[a.chain]
    origin = receipt(a.tx, env)
    lasna_from = h(cast("find-block", str(origin["ts"]), env="LASNA_RPC_URL")) - 2
    deadline = time.time() + a.timeout_min * 60
    steps = []
    if a.path == "topup":
        lg = find(rc, "GrantSent", lasna_from, lambda w: w[1] == idx, deadline)
        steps = [lg]
    elif a.path == "stop":
        steps = [find(rc, "Frozen", lasna_from, lambda w: True, deadline)]
    else:  # donor
        ask = find(rc, "ReclaimSent", lasna_from, lambda w: w[1] != idx, deadline)
        cred = ask and find(rc, "Credited", h(ask["blockNumber"]), lambda w: w[0] == 1, deadline)
        grant = cred and find(rc, "GrantSent", h(cred["blockNumber"]), lambda w: w[1] == idx, deadline)
        steps = [ask, cred, grant]
    rec = {"path": a.path, "chain": a.chain, "origin": origin, "reactive": [], "complete": all(steps)}
    for lg in steps:
        if not lg:
            continue
        rtx = lg["transactionHash"]
        rr = receipt(rtx, "LASNA_RPC_URL")
        rr["feeFormulaWei"] = fee_lasna(rr)
        cbs = callbacks(rtx)
        while isinstance(cbs, list) and not cbs and time.time() < deadline:
            time.sleep(15)
            cbs = callbacks(rtx)
        dests = []
        if isinstance(cbs, list):
            for cb in cbs:
                denv = RPC_BY_CHAIN_ID.get(cb["chainId"])
                d = dict(cb)
                if denv and int(cb["destTx"], 16) != 0:
                    try:
                        dr = receipt(cb["destTx"], denv)
                        dr["feeFormulaWei"] = fee_callback(dr)
                        d["receipt"] = dr
                    except RuntimeError as e:
                        d["receiptError"] = str(e)
                dests.append(d)
        else:
            dests = cbs
        rec["reactive"].append({"receipt": rr, "callbacks": dests})
    ends = [d["receipt"]["ts"] for s in rec["reactive"] for d in (s["callbacks"] if isinstance(s["callbacks"], list) else [])
            if "receipt" in d]
    rec["latencySec"] = (max(ends) - origin["ts"]) if ends and rec["complete"] else None
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "a") as f:
        f.write(json.dumps(rec) + "\n")
    print(json.dumps({"path": rec["path"], "chain": rec["chain"], "complete": rec["complete"],
                      "latencySec": rec["latencySec"], "reactiveTxs": [s["receipt"]["tx"] for s in rec["reactive"]],
                      "destinationTxs": [d.get("destTx") for s in rec["reactive"]
                                         for d in (s["callbacks"] if isinstance(s["callbacks"], list) else [])]},
                     indent=1))


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
