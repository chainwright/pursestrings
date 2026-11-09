#!/usr/bin/env python3
"""A small agent for the demo API (demo/api.py): 402 -> pay -> retry -> data.

    python3 demo/agent.py --chain base --resource "/v1/snapshot?n=1"
    python3 demo/agent.py --chain base --resource "/v1/snapshot?n=9" --wait-min 10

  1. GET the resource. HTTP 402 carries a quote: price, payee, callId, accepted chains.
  2. Checks the quote (its chain accepted, price <= --max-usd, payee = --expect-payee if given),
     then pays through its SpendWallet: Loop.s.sol payCall(chain, payee, price, callId), broadcast
     by forge with AGENT_PRIVATE_KEY read inside forge (never here, never on a command line).
  3. GET again with X-Payment: <chainId>:<txHash>:<callId> and X-Payment-Claim: <the quote's
     claim> (kept out of the log: it is what makes the payment this agent's to redeem).
       200   -> the data; exit 0.
       amber -> "budget on its way, retry in ~N s": with --wait-min left it waits N s and pays the
                same quote again (a refused pay moved no money); otherwise exit 10.
       red   -> "cap reached" (or stopped / not allowed / coordinator paused): exit 11.
       any other answer (payment rejected): exit 12.
     If forge fails, the agent stops (exit 4) instead of paying again blind: the tx may still land.
Each step is one JSON line on stdout and in DEMO_AGENT_LOG (default cache/demo/agent.jsonl).
"""
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
BIN = os.environ.get("FOUNDRY_BIN", os.path.expanduser("~/.foundry/bin"))
CHAINS = {"base": (0, 84532), "unichain": (1, 1301)}
DECIMALS = 6


def http_get(url, headers=None):
    req = urllib.request.Request(url, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def forge_pay(chain, payee, amount, call_id):
    """One SpendWallet.pay through forge; returns the tx hash from forge's broadcast record."""
    idx, chain_id = CHAINS[chain]
    r = subprocess.run([os.path.join(BIN, "forge"), "script", "script/Loop.s.sol", "--sig",
                        "payCall(uint256,address,uint256,bytes32)", str(idx), payee, str(amount), call_id,
                        "--broadcast"], capture_output=True, text=True, timeout=600, cwd=ROOT)
    if r.returncode != 0 or "ONCHAIN EXECUTION COMPLETE & SUCCESSFUL" not in r.stdout:
        raise RuntimeError("forge payCall failed: " + " | ".join((r.stdout + r.stderr).strip().splitlines()[-4:]))
    root = os.environ.get("FOUNDRY_BROADCAST", os.path.join(ROOT, "broadcast"))
    if not os.path.isabs(root):
        root = os.path.join(ROOT, root)
    rec = json.load(open(os.path.join(root, "Loop.s.sol", str(chain_id), "payCall-latest.json")))
    return rec["receipts"][-1]["transactionHash"]


def run(a, get=http_get, pay=forge_pay, sleep=time.sleep, now=time.time):
    log_path = os.environ.get("DEMO_AGENT_LOG", os.path.join(ROOT, "cache", "demo", "agent.jsonl"))
    os.makedirs(os.path.dirname(log_path), exist_ok=True)

    def log(**kw):
        kw = {"t": int(now()), "chain": a.chain, "resource": a.resource, **kw}
        with open(log_path, "a") as f:
            f.write(json.dumps(kw) + "\n")
        print(json.dumps(kw), flush=True)

    url = a.api.rstrip("/") + a.resource
    code, q = get(url)
    if code == 200:
        log(step="data", free=True, data=q)
        return 0
    if code != 402 or "callId" not in q:
        log(step="unexpected", http=code, body=q)
        return 12
    _, chain_id = CHAINS[a.chain]
    if chain_id not in [c["chainId"] for c in q.get("chains", [])]:
        log(step="quote refused", why=f"chain {chain_id} not accepted")
        return 12
    if q["price"] > int(round(a.max_usd * 10 ** DECIMALS)):
        log(step="quote refused", why=f"price {q['priceUsd']} above --max-usd {a.max_usd}")
        return 12
    if a.expect_payee and q["payee"].lower() != a.expect_payee.lower():
        log(step="quote refused", why="unexpected payee", payee=q["payee"])
        return 12
    log(step="402", price=q["price"], priceUsd=q["priceUsd"], payee=q["payee"], callId=q["callId"])
    deadline = now() + a.wait_min * 60
    pays = 0
    while True:
        try:
            tx = pay(a.chain, q["payee"], q["price"], q["callId"])
        except (RuntimeError, subprocess.TimeoutExpired) as e:
            log(step="pay failed", error=str(e)[:300])
            return 4
        pays += 1
        code, body = get(url, {"X-Payment": f"{chain_id}:{tx}:{q['callId']}", "X-Payment-Claim": q.get("claim", "")})
        if code == 200:
            log(step="data", tx=tx, pays=pays, paid=body.get("paid"), rows=len(body["data"]["rows"]))
            return 0
        state = body.get("state")
        if state == "amber":
            log(step="amber", tx=tx, pays=pays, message=body.get("message"), why=body.get("why"),
                retryAfterSec=body.get("retryAfterSec"))
            wait = float(body.get("retryAfterSec") or 5)
            if now() + wait > deadline:
                return 10
            sleep(wait)
            continue
        if state == "red":
            log(step="red", tx=tx, pays=pays, message=body.get("message"), why=body.get("why"))
            return 11
        log(step="rejected", tx=tx, http=code, body=body)
        return 12


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--api", default=os.environ.get("DEMO_API_URL", "http://127.0.0.1:8402"))
    ap.add_argument("--resource", default="/v1/snapshot?n=1")
    ap.add_argument("--chain", choices=list(CHAINS), required=True)
    ap.add_argument("--max-usd", type=float, default=10.0, help="never pay a quote above this")
    ap.add_argument("--expect-payee", default=os.environ.get("PAYEE_ADDRESS"))
    ap.add_argument("--wait-min", type=float, default=0.0, help="how long to keep retrying on amber")
    sys.exit(run(ap.parse_args()))


if __name__ == "__main__":
    main()
