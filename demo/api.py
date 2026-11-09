#!/usr/bin/env python3
"""Demo pay-per-call API for Pursestrings: our own minimal 402 flow, no outside facilitator.
It is NOT x402-compatible (no x402 headers, no facilitator, no signed authorization); real x402
is future work.

    python3 demo/api.py [--port 8402] [--unit-usd 1]

The flow:
  1. GET /v1/snapshot?n=K without payment -> HTTP 402 with a quote: price (K x the unit price),
     payee, a fresh callId (32 random bytes), the accepted chains and the expiry.
  2. The agent calls its SpendWallet: pay(payee, price, callId).
  3. The agent repeats the request with the headers  X-Payment: <chainId>:<txHash>:<callId>  and
     X-Payment-Claim: <claim>, the secret that came with its quote. The callId is public once the
     pay is on-chain; the claim is not, so someone watching the chain can't present the agent's
     payment first and take the data. The API reads that transaction's receipt from the chain itself and serves data only if, in
     a successful tx:
       - a wallet REGISTERED for that chain (the deployment file) emitted Paid(callId, payee,
         amount) with exactly the quoted payee and amount, and
       - the budget token's own contract emitted, as the first token Transfer after that Paid
         log, Transfer(from = that same wallet, to = payee, value = amount): the real tokens moved;
       - the callId was issued by this API, has not expired and was never used before.
     The callId is then recorded as used (on disk, so a restart does not reopen it).
     A Paid event from any other contract, a transfer from an unregistered address, a wrong
     amount or payee, a replayed tx or callId: no data (HTTP 402 or 409, with the reason).
  4. If the wallet refused the pay (Refused(callId) in the receipt), the API answers 402 with one
     of the two states the dashboard shows:
       amber "budget on its way, retry in ~N s": the wallet was short and the day still has
             budget for this call; N from the measured paths (top-up from the coordinator's
             pool: 2 s median live, so ~5 s; reclaim from another chain: ~30 min, retry every 310 s);
       red   "cap reached": the day's remaining budget (cap - spent, all chains) is below the
             price; or the owner pressed STOP; or the payee / per-call cap is not allowed; or the
             coordinator is paused (unfunded) and no allowance can move.
     The amber/red hint reads the coordinator (cap, pool, frozen) and each wallet's bucket for
     today; it is a hint for the agent. The spending check that counts is script/checker.py,
     which sums real token Transfer logs.

Read-only on chain: the API never holds a key and never sends a transaction. RPC URLs from
BASE_SEPOLIA_RPC_URL / UNICHAIN_SEPOLIA_RPC_URL / LASNA_RPC_URL (public RPCs for a live
deployment if unset); addresses from DEPLOYMENTS_FILE; payee from PAYEE_ADDRESS (or --payee).
"""
import argparse
import hmac
import json
import os
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "script"))
import evm_rpc as E  # noqa: E402

DECIMALS = 6
# SpendWallet refusal reasons (src/SpendWallet.sol)
R_FROZEN, R_PAYEE, R_CAP, R_SHORT = 1, 2, 3, 4
# measured live, 09.11 (live/SERIES_2026-11-09.md): top-up median 2 s / p95 3 s; donor median 30.4 min
TOPUP_RETRY_SEC = 5
DONOR_RETRY_SEC = 310      # the wallet re-arms Short after 300 s
DONOR_ETA_SEC = 1830


def usd(units):
    return "$%d.%02d" % (units // 10 ** DECIMALS, (units % 10 ** DECIMALS) // 10 ** (DECIMALS - 2))


# ----------------------------------------------------------------------------- acceptance (pure)

def _lower(x):
    return (x or "").lower()


def judge(receipt, quote, call_id, chain_id, registry, used, now):
    """Decides one payment claim from a transaction receipt. Pure: no I/O.

    receipt: eth_getTransactionReceipt result (or None); quote: the quote issued for call_id
    (or None); registry: {chainId: {"token": addr, "wallets": {addr, ...}}}; used: set of used
    callIds (lowercase hex).
    Returns ("paid", info) | ("refused", info) | ("rejected", reason)."""
    cid = _lower(call_id)
    if quote is None:
        return "rejected", "unknown callId: not issued by this API"
    if cid in used:
        return "rejected", "callId already used (replay)"
    if now > quote["expiresAt"]:
        return "rejected", "quote expired"
    reg = registry.get(chain_id)
    if reg is None:
        return "rejected", f"chain {chain_id} not accepted"
    if receipt is None:
        return "rejected", "transaction not found on that chain"
    if int(receipt.get("status", "0x0"), 16) != 1:
        return "rejected", "transaction failed"
    wallets = {_lower(w) for w in reg["wallets"]}
    token = _lower(reg["token"])
    logs = sorted(receipt.get("logs", []), key=lambda l: int(l.get("logIndex", "0x0"), 16))

    def is_ev(lg, topic):
        t = lg.get("topics") or []
        return len(t) >= 2 and _lower(t[0]) == topic and _lower(t[1]) == cid

    paid_any = [lg for lg in logs if is_ev(lg, E.TOPIC_PAID)]
    paid = [lg for lg in paid_any if _lower(lg["address"]) in wallets]
    if not paid:
        refused = [lg for lg in logs if is_ev(lg, E.TOPIC_REFUSED) and _lower(lg["address"]) in wallets]
        if refused:
            w = _lower(refused[0]["address"])
            reason = E.words(refused[0]["data"])[0]
            shorts = [lg for lg in logs if _lower(lg["address"]) == w and (lg.get("topics") or [""])[0].lower()
                      == E.TOPIC_SHORT]
            info = {"wallet": w, "reason": reason, "shortEmitted": bool(shorts)}
            if shorts:
                day, short_by, _ = E.words(shorts[0]["data"])[:3]
                info.update(day=day, shortBy=short_by)
            return "refused", info
        if paid_any:
            return "rejected", "Paid event from an unregistered address (not one of our wallets)"
        return "rejected", "no Paid or Refused for this callId from a registered wallet"
    why = "no Paid matched"
    for p in paid:
        w = _lower(p["address"])
        if E.topic_addr(p["topics"][2]) != _lower(quote["payee"]):
            why = "Paid to the wrong payee"
            continue
        if E.words(p["data"])[0] != quote["amount"]:
            why = "Paid amount differs from the quoted price"
            continue
        # the real token movement: the first budget-token Transfer after this Paid log
        idx = int(p.get("logIndex", "0x0"), 16)
        nxt = next((lg for lg in logs if int(lg.get("logIndex", "0x0"), 16) > idx and _lower(lg["address"]) == token
                    and (lg.get("topics") or [""])[0].lower() == E.TOPIC_TRANSFER), None)
        if nxt is None:
            why = "no token Transfer follows the Paid event"
            continue
        t = nxt["topics"]
        if len(t) < 3 or E.topic_addr(t[1]) != w:
            why = "token Transfer is not from the paying wallet"
            continue
        if E.topic_addr(t[2]) != _lower(quote["payee"]):
            why = "token Transfer goes to another address than the payee"
            continue
        if E.words(nxt["data"])[0] != quote["amount"]:
            why = "token Transfer amount differs from the quoted price"
            continue
        return "paid", {"wallet": w, "amount": quote["amount"], "tx": receipt.get("transactionHash"),
                        "block": int(receipt.get("blockNumber", "0x0"), 16)}
    return "rejected", why


def classify(info, price, ctx):
    """Amber or red for a refused pay. Pure. info: from judge(); ctx: {"cap", "spent", "pool",
    "frozen", "paused"} for today, all chains (None values = unreadable)."""
    reason = info.get("reason")
    if reason == R_FROZEN or ctx.get("frozen"):
        return {"state": "red", "why": "stopped", "message": "STOP is in force: the owner froze spending"}
    if reason == R_PAYEE:
        return {"state": "red", "why": "payee", "message": "this payee is not on the wallet's allowlist"}
    if reason == R_CAP:
        return {"state": "red", "why": "per-call cap", "message": "the price is above the wallet's per-call cap"}
    cap, spent = ctx.get("cap"), ctx.get("spent")
    if cap is not None and spent is not None:
        left = max(0, cap - spent)
        if price > left:
            return {"state": "red", "why": "cap reached",
                    "message": f"cap reached: {usd(left)} can still leave today, this call costs {usd(price)}",
                    "canStillLeave": left}
    if ctx.get("paused"):
        return {"state": "red", "why": "coordinator paused",
                "message": "the coordinator is paused (unfunded): no allowance moves until it is funded"}
    short_by = info.get("shortBy", price)
    pool = ctx.get("pool")
    if pool is not None and pool >= short_by:
        return {"state": "amber", "why": "top-up", "retryAfterSec": TOPUP_RETRY_SEC,
                "message": f"budget on its way, retry in ~{TOPUP_RETRY_SEC} s"}
    return {"state": "amber", "why": "reclaim from another chain", "retryAfterSec": DONOR_RETRY_SEC,
            "etaSec": DONOR_ETA_SEC,
            "message": f"budget on its way (from another chain, ~{DONOR_ETA_SEC // 60} min), "
                       f"retry in ~{DONOR_RETRY_SEC} s"}


# ----------------------------------------------------------------------------- the service

class Service:
    def __init__(self, dep, payee, unit, ttl, state_file, rpcs, lasna, min_conf=0):
        self.dep, self.payee, self.unit, self.ttl = dep, payee.lower(), unit, ttl
        self.rpcs, self.lasna, self.min_conf = rpcs, lasna, min_conf
        self.state_file = state_file
        self.lock = threading.Lock()
        self.quotes, self.used = {}, set()
        if state_file and os.path.exists(state_file):
            with open(state_file) as f:
                st = json.load(f)
            self.used = set(st.get("used", []))
            self.quotes = st.get("quotes", {})
        self.registry = {}
        self.chain_names = {}
        for name, v in dep.items():
            if isinstance(v, dict) and "chainId" in v and "wallet" in v:
                cid = int(v["chainId"])
                ws = [x["wallet"] for x in v.get("wallets", [])] or [v["wallet"]]
                self.registry[cid] = {"token": v["token"], "wallets": set(w.lower() for w in ws)}
                self.chain_names[cid] = name

    def _save(self):
        if not self.state_file:
            return
        os.makedirs(os.path.dirname(self.state_file) or ".", exist_ok=True)
        tmp = self.state_file + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"used": sorted(self.used), "quotes": self.quotes}, f)
        os.replace(tmp, self.state_file)

    def quote(self, resource, n):
        cid = "0x" + os.urandom(32).hex()
        q = {"callId": cid, "resource": resource, "amount": n * self.unit, "payee": self.payee,
             "claim": os.urandom(16).hex(), "issuedAt": int(time.time()), "expiresAt": int(time.time()) + self.ttl}
        with self.lock:
            self.quotes[cid] = q
            self._save()
        return q

    def offer(self, q):
        return {"error": "payment required", "price": q["amount"], "priceUsd": usd(q["amount"]),
                "payee": q["payee"], "callId": q["callId"], "claim": q["claim"], "expiresAt": q["expiresAt"],
                "chains": [{"chain": self.chain_names[c], "chainId": c, "token": r["token"]}
                           for c, r in sorted(self.registry.items())],
                "how": "call SpendWallet.pay(payee, price, callId) on one of the chains, then repeat this "
                       "request with the headers X-Payment: <chainId>:<txHash>:<callId> and "
                       "X-Payment-Claim: <claim> (keep the claim private)",
                "note": "our own 402 flow, not x402"}

    def context(self, chain_id, day):
        """Today's cap / spent / pool / frozen / paused, read from the chains (a hint; None if
        unreadable)."""
        ctx = {"cap": None, "spent": None, "pool": None, "frozen": None, "paused": None}
        try:
            spent = 0
            for cid, reg in self.registry.items():
                for w in reg["wallets"]:
                    allowance_spent = E.call_uint(self.rpcs[cid], w, "buckets(uint64)", day)
                    spent += allowance_spent[1]
            ctx["spent"] = spent
        except E.RpcError:
            pass
        if self.lasna is not None:
            rc = self.dep["coordinator"]
            try:
                ctx["cap"] = E.call_uint(self.lasna, rc, "capOfDay(uint64)", day)[0]
                ctx["pool"] = E.call_uint(self.lasna, rc, "poolOf(uint64)", day)[0]
                ctx["frozen"] = bool(E.call_uint(self.lasna, rc, "frozen()")[0])
                ctx["paused"] = E.call_uint(self.lasna, E.SYSTEM, "debt(address)", rc)[0] > 0
            except E.RpcError:
                pass
        return ctx

    def settle(self, resource, header, claim=""):
        """(http status, body) for a request carrying X-Payment (and X-Payment-Claim)."""
        try:
            chain_s, tx, cid = header.strip().split(":")
            chain_id = int(chain_s)
            assert tx.startswith("0x") and len(tx) == 66 and cid.startswith("0x") and len(cid) == 66
        except (ValueError, AssertionError):
            return 400, {"error": "X-Payment must be <chainId>:<txHash>:<callId>"}
        cid = cid.lower()
        rpc = self.rpcs.get(chain_id)
        if rpc is None:
            return 402, {"error": "payment rejected", "reason": f"chain {chain_id} not accepted"}
        with self.lock:  # one settlement at a time: a callId can't be accepted twice by a race
            q = self.quotes.get(cid)
            if q is not None and q["resource"] != resource:
                return 402, {"error": "payment rejected", "reason": "callId was quoted for another resource"}
            if q is not None and cid not in self.used and not hmac.compare_digest(str(claim or ""), q["claim"]):
                return 402, {"error": "payment rejected", "reason": "X-Payment-Claim does not match the quote"}
            try:
                rcpt = rpc.receipt(tx)
                if rcpt is not None and self.min_conf:
                    if rpc.head() - int(rcpt["blockNumber"], 16) + 1 < self.min_conf:
                        return 402, {"error": "payment not final yet", "retryAfterSec": 2}
            except E.RpcError as e:
                return 503, {"error": "chain not readable", "detail": str(e)[:200]}
            verdict, info = judge(rcpt, q, cid, chain_id, self.registry, self.used, int(time.time()))
            if verdict == "paid":
                self.used.add(cid)
                self._save()
                return 200, {"data": demo_data(resource), "paid": {**info, "amountUsd": usd(info["amount"]),
                                                                    "callId": cid, "chainId": chain_id}}
        if verdict == "refused":
            day = info.get("day")
            if day is None:
                b = rpc.call("eth_getBlockByNumber", [rcpt["blockNumber"], False])
                day = int(b["timestamp"], 16) // E.DAY
            st = classify(info, q["amount"], self.context(chain_id, day))
            return 402, {"error": "payment refused by the wallet", **st, "refused": info, "callId": cid,
                         "price": q["amount"], "priceUsd": usd(q["amount"])}
        code = 409 if "replay" in info else 402
        return code, {"error": "payment rejected", "reason": info}


def demo_data(resource):
    """The paid-for content: a small, deterministic stand-in for a data feed."""
    n = int(dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(resource).query)).get("n", "1"))
    return {"resource": resource, "rows": [{"i": i, "pair": "ETH/USD", "note": "demo row"} for i in range(n)],
            "servedAt": int(time.time())}


def units_of(resource):
    q = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(resource).query))
    try:
        n = int(q.get("n", "1"))
    except ValueError:
        return None
    return n if 1 <= n <= 100 else None


def make_handler(svc):
    class H(BaseHTTPRequestHandler):
        def _send(self, code, body):
            raw = json.dumps(body, indent=1).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def log_message(self, fmt, *args):  # one line per request on stderr
            sys.stderr.write("api %s %s\n" % (self.command, fmt % args))

        def do_GET(self):
            path = urllib.parse.urlsplit(self.path).path
            if path == "/health":
                return self._send(200, {"ok": True})
            if path == "/v1/status":
                return self._send(200, {"payee": svc.payee, "unitUsd": usd(svc.unit), "usedCallIds": len(svc.used),
                                        "chains": {svc.chain_names[c]: {"chainId": c, "token": r["token"],
                                                                        "wallets": sorted(r["wallets"])}
                                                   for c, r in svc.registry.items()}})
            if path != "/v1/snapshot":
                return self._send(404, {"error": "not found"})
            n = units_of(self.path)
            if n is None:
                return self._send(400, {"error": "n must be an integer 1..100"})
            pay = self.headers.get("X-Payment")
            if not pay:
                return self._send(402, svc.offer(svc.quote(self.path, n)))
            code, body = svc.settle(self.path, pay, self.headers.get("X-Payment-Claim", ""))
            self._send(code, body)

    return H


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=int(os.environ.get("DEMO_API_PORT", "8402")))
    ap.add_argument("--payee", default=os.environ.get("PAYEE_ADDRESS"))
    ap.add_argument("--unit-usd", type=float, default=1.0, help="price of one row (default $1)")
    ap.add_argument("--quote-ttl-sec", type=int, default=3600)
    ap.add_argument("--min-confirmations", type=int, default=0)
    ap.add_argument("--state-file", default=os.environ.get("DEMO_API_STATE", "cache/demo/api_state.json"))
    a = ap.parse_args()
    if not a.payee:
        sys.exit("set PAYEE_ADDRESS or --payee")
    dep = json.load(open(os.environ.get("DEPLOYMENTS_FILE", "deployments/latest.json")))
    dry = bool(dep.get("dryRun"))
    svc = Service(dep, a.payee, int(round(a.unit_usd * 10 ** DECIMALS)), a.quote_ttl_sec, a.state_file, {}, None,
                  a.min_confirmations)
    svc.rpcs = {cid: E.rpc_for(cid, dry) for cid in svc.registry}
    try:
        svc.lasna = E.rpc_for(int(dep.get("lasnaChainId", 5318007)), dry)
    except E.RpcError:
        svc.lasna = None
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), make_handler(svc))
    print(f"demo API on http://127.0.0.1:{a.port}/v1/snapshot?n=1 (payee {svc.payee}, "
          f"{usd(svc.unit)} a row; chains {sorted(svc.registry)})", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
