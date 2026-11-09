#!/usr/bin/env python3
"""The checker a stranger can run: did the agents' wallets, all chains together, send out more
budget token on a day than that day's cap? Read-only: no key, no transaction.

    python3 script/checker.py                     # today (UTC)
    python3 script/checker.py --day 2026-11-09    # one past UTC day (repeat --day for more)
    python3 script/checker.py --day 2026-11-09 --cap-usd 20 --json

What it counts: the budget token's own ERC-20 Transfer logs whose `from` is one of the deployment's
wallets, on every chain in the deployment file, within the UTC day by each chain's block time (the
wallet's day). Never the wallet's own counter (its Paid events or buckets). A transfer from a wallet
to that wallet's own vault is a return of unused allowance, reported apart and not counted as
spent. Everything else that leaves a wallet is spent.

The day's block range on each chain is found from block timestamps (bisection), not from block
counts: Base Sepolia makes a block every 0.2 s and Unichain Sepolia every 1 s. Logs are queried in
chunks that each public RPC accepts (Base Sepolia 200 blocks, Unichain Sepolia 1000) and paced to
its rate limit; a full Base Sepolia day is ~2,160 queries, about 2 minutes.

The cap of day d is the coordinator's capOfDay(d) on Lasna, unless --cap-usd is given. A day the
coordinator never opened has cap 0, so anything spent on it is over.

Prints per day "Over: $0.00" or the overspend, and "can still leave" = cap - spent. Exit 0 if no
day is over, 1 if any is, 2 on an RPC or setup error.

RPC URLs: BASE_SEPOLIA_RPC_URL, UNICHAIN_SEPOLIA_RPC_URL, LASNA_RPC_URL; for a live deployment an
unset one falls back to the chain's public RPC. Addresses: DEPLOYMENTS_FILE (default
deployments/latest.json).
"""
import argparse
import datetime
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evm_rpc as E  # noqa: E402

DECIMALS = 6


def wallets_of(dep):
    """[(name, chainId, token, wallet, vault)] for every wallet in the deployment file: each
    top-level entry with a chainId and a wallet (or a `wallets` list of {wallet, vault})."""
    out = []
    for name, v in sorted(dep.items()):
        if not isinstance(v, dict) or "chainId" not in v or "token" not in v:
            continue
        pairs = v.get("wallets") or ([{"wallet": v["wallet"], "vault": v.get("vault")}] if "wallet" in v else [])
        for p in pairs:
            out.append((name, int(v["chainId"]), v["token"], p["wallet"], p.get("vault")))
    return out


def tally(logs, vault_of):
    """Pure: Transfer logs -> per wallet {"spent", "returned", "payments", "returns"}.
    vault_of: wallet (lowercase) -> its vault (lowercase or None). Logs from other senders are
    ignored (the query already filters on `from`, this is belt and braces)."""
    res = {w: {"spent": 0, "returned": 0, "payments": 0, "returns": 0} for w in vault_of}
    for lg in logs:
        t = lg["topics"]
        if len(t) < 3 or t[0].lower() != E.TOPIC_TRANSFER:
            continue
        frm, to = E.topic_addr(t[1]), E.topic_addr(t[2])
        if frm not in res:
            continue
        value = E.words(lg["data"])[0]
        if vault_of[frm] and to == vault_of[frm]:
            res[frm]["returned"] += value
            res[frm]["returns"] += 1
        else:
            res[frm]["spent"] += value
            res[frm]["payments"] += 1
    return res


def verdict(spent_total, cap):
    """Pure: (over, can_still_leave), both >= 0, in token base units."""
    return max(0, spent_total - cap), max(0, cap - spent_total)


def usd(units):
    return "$%d.%02d" % (units // 10 ** DECIMALS, (units % 10 ** DECIMALS) // 10 ** (DECIMALS - 2))


def day_number(s):
    d = datetime.datetime.strptime(s, "%Y-%m-%d").replace(tzinfo=datetime.timezone.utc)
    return int(d.timestamp()) // E.DAY


def day_label(d):
    return datetime.datetime.fromtimestamp(d * E.DAY, datetime.timezone.utc).strftime("%Y-%m-%d")


def check_day(d, dep, rpcs, cap_override, lasna):
    start, end = d * E.DAY, (d + 1) * E.DAY
    chains, spent_total = [], 0
    by_chain = {}
    for name, chain_id, token, wallet, vault in wallets_of(dep):
        by_chain.setdefault((name, chain_id, token), []).append((wallet, vault))
    for (name, chain_id, token), ws in by_chain.items():
        rpc = rpcs[chain_id]
        head = rpc.head()
        b0 = rpc.first_block_at_or_after(start, head)
        b1 = min(head, rpc.first_block_at_or_after(end, head) - 1)
        partial = rpc.block_ts(head) < end
        logs = []
        if b0 <= b1:
            # topic 1 (`from`) is an OR list of every wallet on this chain
            logs = rpc.get_logs(token, [E.TOPIC_TRANSFER, ["0x" + E.addr_word(w) for w, _ in ws]], b0, b1)
        vault_of = {w.lower(): (v.lower() if v else None) for w, v in ws}
        t = tally(logs, vault_of)
        for w, _ in ws:
            r = t[w.lower()]
            spent_total += r["spent"]
            chains.append({"chain": name, "chainId": chain_id, "wallet": w, "token": token,
                           "blocks": [b0, b1], "partialDay": partial, "spent": r["spent"],
                           "payments": r["payments"], "returnedToVault": r["returned"], "returns": r["returns"]})
    if cap_override is not None:
        cap, cap_src = cap_override, "--cap-usd"
    else:
        cap = E.call_uint(lasna, dep["coordinator"], "capOfDay(uint64)", d)[0]
        cap_src = "coordinator capOfDay on Lasna"
    over, left = verdict(spent_total, cap)
    return {"day": day_label(d), "dayNumber": d, "cap": cap, "capSource": cap_src, "spent": spent_total,
            "over": over, "canStillLeave": left, "chains": chains}


def print_report(r):
    print(f"day {r['day']} (UTC, day {r['dayNumber']}): cap {usd(r['cap'])} ({r['capSource']})")
    for c in r["chains"]:
        note = " (day still running)" if c["partialDay"] else ""
        print(f"  {c['chain']:<9} wallet {c['wallet']}  blocks {c['blocks'][0]}..{c['blocks'][1]}{note}")
        print(f"            out {usd(c['spent'])} in {c['payments']} transfer(s); "
              f"returned to its vault {usd(c['returnedToVault'])} in {c['returns']}")
    print(f"  all chains: spent {usd(r['spent'])} of {usd(r['cap'])}; can still leave {usd(r['canStillLeave'])}")
    print(f"  Over: {usd(r['over'])}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--day", action="append", help="UTC day YYYY-MM-DD (repeatable); default today")
    ap.add_argument("--cap-usd", type=float, help="use this cap instead of the coordinator's capOfDay")
    ap.add_argument("--json", action="store_true", help="print one JSON object instead of the report")
    a = ap.parse_args()
    dep = json.load(open(os.environ.get("DEPLOYMENTS_FILE", "deployments/latest.json")))
    dry = bool(dep.get("dryRun"))
    try:
        rpcs = {cid: E.rpc_for(cid, dry) for _, cid, _, _, _ in wallets_of(dep)}
        for cid, rpc in rpcs.items():
            got = int(rpc.call("eth_chainId", []), 16)
            if got != cid:
                sys.exit(f"RPC for chain {cid} answers chain id {got}")
        cap = None if a.cap_usd is None else int(round(a.cap_usd * 10 ** DECIMALS))
        lasna = None if cap is not None else E.rpc_for(int(dep.get("lasnaChainId", 5318007)), dry)
        days = [day_number(s) for s in a.day] if a.day else [int(time.time()) // E.DAY]
        reports = [check_day(d, dep, rpcs, cap, lasna) for d in days]
    except E.RpcError as e:
        print(f"RPC error: {e}", file=sys.stderr)
        sys.exit(2)
    if a.json:
        print(json.dumps({"reports": reports, "overAny": any(r["over"] for r in reports),
                          "rpcRequests": {str(k): v.requests for k, v in rpcs.items()}}))
    else:
        for r in reports:
            print_report(r)
    sys.exit(1 if any(r["over"] for r in reports) else 0)


if __name__ == "__main__":
    main()
