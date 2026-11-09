#!/usr/bin/env python3
"""Minimal read-only JSON-RPC client, Python standard library only. Used by script/checker.py and
the demo API (demo/api.py). It never signs and never sends a transaction: the only methods it
calls are eth_blockNumber, eth_getBlockByNumber, eth_getLogs, eth_getTransactionReceipt, eth_call
and eth_chainId.

Public-RPC limits measured on 09.11.2026 (read-only probes):
  - Base Sepolia (https://sepolia.base.org): eth_getLogs "is limited to a 200 range" (HTTP 413,
    -32614), "25/second request limit" (HTTP 429 or -32007 per batch item); blocks every 0.2 s,
    so a UTC day is ~432,000 blocks, ~2,160 log queries.
  - Unichain Sepolia (https://sepolia.unichain.org): "block range greater than 1000 max" (HTTP 400);
    blocks every 1 s.
A range refusal halves the chunk and retries it; a rate refusal waits and retries.
"""
import collections
import json
import threading
import time
import urllib.error
import urllib.request

# keccak256 of the event signatures in src/interfaces/IPursestrings.sol and ERC-20, and the
# selectors of the views read here (computed with `cast keccak` / `cast sig`; the tests re-check
# them against cast when it is installed).
TOPIC_TRANSFER = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
TOPIC_PAID = "0xeeb0574dc6b7f4afdf7af225c5eda6cdbafc564664ace95a38e12814594b6f7e"
TOPIC_REFUSED = "0x8d113fd950359a9bd15a700269818d92d001a2d82fdba58ddd59fc9ee395749c"
TOPIC_SHORT = "0xb01930c34f8d3ecc7ed7f0487c27dada1785cf8e7a300350785efaa6388a50b0"
SIGS = {
    TOPIC_TRANSFER: "Transfer(address,address,uint256)",
    TOPIC_PAID: "Paid(bytes32,address,uint256,uint64,uint64)",
    TOPIC_REFUSED: "Refused(bytes32,uint8)",
    TOPIC_SHORT: "Short(uint64,uint256,uint64)",
}
SEL = {
    "capOfDay(uint64)": "0x32d07896",
    "poolOf(uint64)": "0x2f9f5d82",
    "buckets(uint64)": "0xa0c383e8",
    "today()": "0xb74e452b",
    "frozen()": "0x054f7d9c",
    "debt(address)": "0x9b6c56ec",
}
SYSTEM = "0x8888888888888888888888888888888888888888"

DAY = 86400
PUBLIC_RPC = {84532: "https://sepolia.base.org", 1301: "https://sepolia.unichain.org",
              5318007: "https://lasna-rpc.rnk.dev/"}
RPC_ENV = {84532: "BASE_SEPOLIA_RPC_URL", 1301: "UNICHAIN_SEPOLIA_RPC_URL", 5318007: "LASNA_RPC_URL"}
LOG_RANGE = {84532: 200, 1301: 1000}   # blocks per eth_getLogs (inclusive count)
RATE = {84532: 20}                      # requests per second we allow ourselves (limit 25)
DEFAULT_RANGE, DEFAULT_RATE = 2000, 40


class RpcError(Exception):
    pass


class RangeTooLarge(RpcError):
    pass


def _is_range_error(code, msg):
    m = (msg or "").lower()
    return code == -32614 or "range" in m


def _is_rate_error(code, msg):
    m = (msg or "").lower()
    return code in (-32007, -32005, 429) or any(k in m for k in ("rate limit", "/second", "too many requests",
                                                                  "request limit"))


class Rpc:
    """One endpoint. `call` for single requests, `batch` for a JSON-RPC batch; both pace
    themselves to `rate` requests per second and retry rate refusals."""

    def __init__(self, url, chain_id=None, rate=None, timeout=30, retries=8):
        self.url, self.chain_id, self.timeout, self.retries = url, chain_id, timeout, retries
        self.rate = rate or RATE.get(chain_id, DEFAULT_RATE)
        self._sent = collections.deque()
        self._lock = threading.Lock()
        self._ts = {}
        self.requests = 0

    # -- transport
    def _pace(self, k):
        with self._lock:
            while True:
                now = time.time()
                while self._sent and now - self._sent[0] > 1.0:
                    self._sent.popleft()
                if len(self._sent) + k <= self.rate or not self._sent:
                    for _ in range(k):
                        self._sent.append(now)
                    self.requests += k
                    return
                time.sleep(max(0.02, 1.0 - (now - self._sent[0]) + 0.01))

    def _post(self, body, k):
        self._pace(k)
        req = urllib.request.Request(self.url, json.dumps(body).encode(),
                                     {"Content-Type": "application/json", "User-Agent": "pursestrings-readonly"})
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            raw = e.read()[:500].decode("utf-8", "replace")
            try:
                j = json.loads(raw)
                err = j.get("error", j) if isinstance(j, dict) else {}
            except ValueError:
                err = {}
            code, msg = err.get("code", e.code), err.get("message", raw)
            if e.code == 429 or _is_rate_error(code, msg):
                raise _Retry(msg)
            if e.code in (400, 413) and _is_range_error(code, msg):
                raise RangeTooLarge(msg)
            raise RpcError(f"HTTP {e.code}: {msg[:200]}")
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            raise _Retry(str(e))

    def call(self, method, params):
        for attempt in range(self.retries):
            try:
                r = self._post({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}, 1)
            except _Retry:
                time.sleep(1.1 * (attempt + 1))
                continue
            if "error" in r:
                code, msg = r["error"].get("code"), r["error"].get("message", "")
                if _is_rate_error(code, msg):
                    time.sleep(1.1 * (attempt + 1))
                    continue
                if _is_range_error(code, msg):
                    raise RangeTooLarge(msg)
                raise RpcError(f"{method}: {code} {msg[:200]}")
            return r.get("result")
        raise RpcError(f"{method}: still refused after {self.retries} tries")

    def batch(self, calls):
        """calls: [(method, params)]. Returns results in order. Items refused for rate are
        retried; an item refused for range raises RangeTooLarge(index list) via the result slot."""
        out = [None] * len(calls)
        todo = list(range(len(calls)))
        for attempt in range(self.retries):
            if not todo:
                return out
            body = [{"jsonrpc": "2.0", "id": i, "method": calls[i][0], "params": calls[i][1]} for i in todo]
            try:
                r = self._post(body, len(body))
            except _Retry:
                time.sleep(1.1 * (attempt + 1))
                continue
            if isinstance(r, dict):  # the whole batch refused
                err = r.get("error", {})
                if _is_rate_error(err.get("code"), err.get("message")):
                    time.sleep(1.1 * (attempt + 1))
                    continue
                raise RpcError(f"batch refused: {str(err)[:200]}")
            again, got = [], set()
            for item in r:
                i = item.get("id")
                if "error" in item:
                    code, msg = item["error"].get("code"), item["error"].get("message", "")
                    if _is_rate_error(code, msg):
                        again.append(i)
                    elif _is_range_error(code, msg):
                        out[i] = RangeTooLarge(msg)
                    else:
                        raise RpcError(f"{calls[i][0]}: {code} {msg[:200]}")
                else:
                    out[i] = item.get("result")
                got.add(i)
            got -= set(again)
            missing = [i for i in todo if i not in got and i not in again]
            todo = again + missing
            if todo:
                time.sleep(1.1)
        if todo:
            raise RpcError(f"batch: {len(todo)} items still refused after {self.retries} tries")
        return out

    # -- helpers
    def head(self):
        return int(self.call("eth_blockNumber", []), 16)

    def block_ts(self, n):
        if n not in self._ts:
            b = self.call("eth_getBlockByNumber", [hex(n), False])
            if b is None:
                raise RpcError(f"block {n} not served")
            self._ts[n] = int(b["timestamp"], 16)
        return self._ts[n]

    def receipt(self, tx):
        return self.call("eth_getTransactionReceipt", [tx])

    def eth_call(self, to, data):
        return self.call("eth_call", [{"to": to, "data": data}, "latest"])

    def first_block_at_or_after(self, ts, head=None):
        """The first block whose timestamp is >= ts (head + 1 if none yet). Brackets from the head
        by the recent block time, then bisects: about 20-30 block reads, never a scan."""
        head = self.head() if head is None else head
        if self.block_ts(head) < ts:
            return head + 1
        back = min(head, 1000)
        dt = max(1e-3, (self.block_ts(head) - self.block_ts(head - back)) / back) if back else 1.0
        guess = max(0, head - int((self.block_ts(head) - ts) / dt) - 10)
        lo, step = guess, 64
        while lo > 0 and self.block_ts(lo) >= ts:
            lo, step = max(0, lo - step), step * 4
        if self.block_ts(lo) >= ts:
            return lo  # lo == 0
        hi = guess + 20
        step = 64
        while hi < head and self.block_ts(hi) < ts:
            hi, step = min(head, hi + step), step * 4
        # invariant: ts(lo) < ts <= ts(hi)
        while hi - lo > 1:
            mid = (lo + hi) // 2
            if self.block_ts(mid) >= ts:
                hi = mid
            else:
                lo = mid
        return hi

    def get_logs(self, address, topics, from_block, to_block, chunk=None, batch_size=None):
        """Every log of `address` matching `topics` in [from_block, to_block], in chain order.
        Queried in chunks of `chunk` blocks (the chain's public limit by default), several chunks
        per JSON-RPC batch; a chunk refused for its range is split in two and retried."""
        chunk = chunk or LOG_RANGE.get(self.chain_id, DEFAULT_RANGE)
        batch_size = batch_size or max(1, min(20, self.rate))
        ranges = [(s, min(to_block, s + chunk - 1)) for s in range(from_block, to_block + 1, chunk)]
        logs = []
        while ranges:
            part, ranges = ranges[:batch_size], ranges[batch_size:]
            res = self.batch([("eth_getLogs", [{"address": address, "topics": topics,
                                                "fromBlock": hex(a), "toBlock": hex(b)}]) for a, b in part])
            for (a, b), r in zip(part, res):
                if isinstance(r, RangeTooLarge):
                    if a == b:
                        raise r
                    m = (a + b) // 2
                    ranges = [(a, m), (m + 1, b)] + ranges
                else:
                    logs.extend(r or [])
        logs.sort(key=lambda l: (int(l["blockNumber"], 16), int(l["logIndex"], 16)))
        return logs


class _Retry(Exception):
    pass


# -- ABI helpers
def word(n):
    return "%064x" % n


def addr_word(a):
    return "0" * 24 + a.lower().removeprefix("0x")


def topic_addr(t):
    return "0x" + t[-40:].lower()


def words(data):
    d = (data or "0x")[2:]
    return [int(d[i:i + 64], 16) for i in range(0, len(d), 64)]


def call_uint(rpc, to, sig, *args):
    data = SEL[sig] + "".join(addr_word(a) if isinstance(a, str) else word(a) for a in args)
    return words(rpc.eth_call(to, data))


def rpc_for(chain_id, dry_run):
    """The RPC URL for a chain: its environment variable, or (live deployments only) the public RPC."""
    import os
    url = os.environ.get(RPC_ENV.get(chain_id, ""), "")
    if not url and not dry_run:
        url = PUBLIC_RPC.get(chain_id, "")
    if not url:
        raise RpcError(f"set {RPC_ENV.get(chain_id, 'an RPC URL')} for chain {chain_id}")
    return Rpc(url, chain_id)
