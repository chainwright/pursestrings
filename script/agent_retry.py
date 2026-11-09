#!/usr/bin/env python3
"""The agent's side of the donor path: keep asking until the allowance arrives.

    agent_retry.py --chain base                      # pay $1 every 310 s until served, then pay it
    agent_retry.py --chain base --amount 1000000 --every-sec 310 --timeout-min 80

Why: a short chain's want lives 40 min after its last Short or LowWater (wantTtl, TestnetConfig).
A donor credit lands after the 30-min L2 wait plus the time until the next react (up to one Cron,
~17.7 min), so a single ask can lapse before it is served (our review put that at ~40 %). Each
refused `pay` here emits a fresh Short (the wallet re-arms Short after SHORT_REARM = 300 s, hence
310 s), which keeps the want alive and hands the coordinator a react right after the wait.

Loop: read today's unspent allowance on the wallet; while it is below --amount, send
`Loop.s.sol pay(chain, amount)` (refused, Short), wait --every-sec, repeat. Once unspent >= amount,
send the same pay once more: it must be PAID (the "refused -> served -> paid" moment). Each attempt
is appended as one JSON line to AGENT_LOG (default live/agent_retry.jsonl): time, tx hash, and
which wallet events its receipt holds (Short, LowWater, Paid, Refused).

Exit codes: 0 served and paid; 2 not served before --timeout-min (the run book says what to check);
3 the final pay was refused although the allowance had arrived; 4 a pay landed after forge gave up
but its outcome could not be read (stopped rather than pay twice); 1 setup error.
Late landing: before each pay the agent's nonce (AGENT_ADDRESS) and the block are read. If forge
fails, the nonce is watched for LATE_WAIT_SEC (default 120); if it moved, the wallet's events since
that block decide the outcome, so a mined pay is never counted as a failed ask.
Lapse handling: if an attempt fails (an RPC hiccup) the next one is tried after 30 s instead of
--every-sec, and a warning is printed when more than WANT_TTL_SEC (default 2400) passed since the
last Short, because the coordinator has then dropped the want and the next Short opens a new one.

It sends transactions only through forge (`--broadcast`), with AGENT_PRIVATE_KEY read inside the
script by vm.envUint: the key is never on a command line or printed. RPC URLs and the deployment
file come from the same environment as Loop.s.sol and loop_logger.py.
"""
import argparse
import json
import os
import subprocess
import sys
import time

BIN = os.environ.get("FOUNDRY_BIN", os.path.expanduser("~/.foundry/bin"))
FORGE, CAST = os.path.join(BIN, "forge"), os.environ.get("CAST", os.path.join(BIN, "cast"))
CHAINS = {"base": (0, "BASE_SEPOLIA_RPC_URL", 84532), "unichain": (1, "UNICHAIN_SEPOLIA_RPC_URL", 1301)}
EVENTS = {
    "Short": "Short(uint64,uint256,uint64)",
    "LowWater": "LowWater(uint64,uint256,uint64)",
    "Paid": "Paid(bytes32,address,uint256,uint64,uint64)",
    "Refused": "Refused(bytes32,uint8)",
}
WANT_TTL = int(os.environ.get("WANT_TTL_SEC", "2400"))
LATE_WAIT = int(os.environ.get("LATE_WAIT_SEC", "120"))
LOG_CHUNK = 1000


def run(cmd, timeout=300):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def cast_call(rpc, to, sig, *args):
    r = run([CAST, "call", to, sig, *args, "--rpc-url", rpc])
    if r.returncode != 0:
        raise RuntimeError(f"cast call {sig} failed: {r.stderr.strip()[:200]}")
    return int(r.stdout.strip().split()[0], 0)


def unspent(rpc, wallet):
    day = cast_call(rpc, wallet, "today()(uint64)")
    return cast_call(rpc, wallet, "unspentOf(uint64)(uint256)", str(day))


def topics():
    out = {}
    for name, sig in EVENTS.items():
        r = run([CAST, "keccak", sig])
        out[r.stdout.strip().lower()] = name
    return out


def agent_nonce(rpc, agent):
    r = run([CAST, "nonce", agent, "--rpc-url", rpc])
    if r.returncode != 0:
        raise RuntimeError(f"cast nonce failed: {r.stderr.strip()[:200]}")
    return int(r.stdout.strip())


def block_number(rpc):
    r = run([CAST, "block-number", "--rpc-url", rpc])
    if r.returncode != 0:
        raise RuntimeError(f"cast block-number failed: {r.stderr.strip()[:200]}")
    return int(r.stdout.strip())


def landed_late(rpc, agent, wallet, nonce0, block0, tops, wait_sec=None):
    """forge gave up on a pay, but the tx may still be mined (07:0x UTC 09.11: mined 37 s later and
    paid $1, while the run logged "ask failed"). Wait up to wait_sec for the agent's nonce to pass
    nonce0. Not advanced -> None (a real failure). Advanced -> (tx hash or None, [wallet events])
    read from the wallet's logs since block0, in chunks (Base Sepolia makes ~5 blocks a second)."""
    end = time.time() + (LATE_WAIT if wait_sec is None else wait_sec)
    while agent_nonce(rpc, agent) <= nonce0:
        if time.time() >= end:
            return None
        time.sleep(10)
    tx, evs, head = None, [], block_number(rpc)
    for lo in range(block0, head + 1, LOG_CHUNK):
        r = run([CAST, "logs", "--from-block", str(lo), "--to-block", str(min(lo + LOG_CHUNK - 1, head)),
                 "--address", wallet, "--json", "--rpc-url", rpc])
        if r.returncode != 0:
            raise RuntimeError(f"cast logs failed: {r.stderr.strip()[:200]}")
        for l in json.loads(r.stdout or "[]"):
            t = l["topics"][0].lower() if l.get("topics") else ""
            if t in tops:
                tx = l.get("transactionHash", tx)
                evs.append(tops[t])
    return tx, evs


def pay_once(chain_idx, chain_id, rpc, wallet, amount, tops):
    """One Loop.s.sol pay. Returns (tx hash, [wallet events in its receipt])."""
    r = run([FORGE, "script", "script/Loop.s.sol", "--sig", "pay(uint256,uint256)", str(chain_idx), str(amount),
             "--broadcast"], timeout=600)
    if r.returncode != 0 or "ONCHAIN EXECUTION COMPLETE & SUCCESSFUL" not in r.stdout:
        tail = "\n".join((r.stdout + r.stderr).strip().splitlines()[-6:])
        raise RuntimeError(f"forge pay failed:\n{tail}")
    root = os.environ.get("FOUNDRY_BROADCAST", "broadcast")
    rec = json.load(open(os.path.join(root, "Loop.s.sol", str(chain_id), "pay-latest.json")))
    tx = rec["receipts"][-1]["transactionHash"]
    rc = run([CAST, "receipt", tx, "--json", "--rpc-url", rpc])
    if rc.returncode != 0:
        raise RuntimeError(f"cast receipt failed: {rc.stderr.strip()[:200]}")
    logs = json.loads(rc.stdout).get("logs", [])
    evs = [tops[l["topics"][0].lower()] for l in logs
           if l["address"].lower() == wallet.lower() and l["topics"] and l["topics"][0].lower() in tops]
    return tx, evs


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--chain", choices=list(CHAINS), required=True)
    ap.add_argument("--amount", type=int, default=1_000_000, help="USDC base units per ask (default $1)")
    ap.add_argument("--every-sec", type=float, default=310, help="between asks (default 310: Short re-arms at 300)")
    ap.add_argument("--timeout-min", type=float, default=80)
    ap.add_argument("--no-final-pay", action="store_true", help="stop once served, without the final pay")
    a = ap.parse_args()
    os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))  # forge, like the other scripts

    idx, rpc_env, chain_id = CHAINS[a.chain]
    rpc = os.environ.get(rpc_env)
    if not rpc:
        sys.exit(f"set {rpc_env}")
    dep = json.load(open(os.environ.get("DEPLOYMENTS_FILE", "deployments/latest.json")))
    wallet = dep[a.chain]["wallet"]
    agent = os.environ.get("AGENT_ADDRESS")
    if not agent:
        print("warning: AGENT_ADDRESS unset, so a pay that forge gives up on but that still lands is "
              "logged as failed (and may be followed by a second pay)", file=sys.stderr)
    log_path = os.environ.get("AGENT_LOG", "live/agent_retry.jsonl")
    os.makedirs(os.path.dirname(log_path) or ".", exist_ok=True)
    tops = topics()

    def log(**kw):
        kw = {"t": int(time.time()), "chain": a.chain, "amount": a.amount, **kw}
        with open(log_path, "a") as f:
            f.write(json.dumps(kw) + "\n")
        print(json.dumps(kw), flush=True)

    def attempt():
        """One pay. (tx, events) if it was mined, also when forge gave up first; (False, None) if not."""
        while True:
            try:
                nonce0 = agent_nonce(rpc, agent) if agent else None
                block0 = block_number(rpc)
                break
            except RuntimeError as e:
                log(step="read failed", error=str(e)[:200])
                time.sleep(30)
        try:
            return pay_once(idx, chain_id, rpc, wallet, a.amount, tops)
        except (RuntimeError, subprocess.TimeoutExpired) as e:
            late = None
            if agent:
                try:
                    late = landed_late(rpc, agent, wallet, nonce0, block0, tops)
                except RuntimeError as e2:
                    late = (None, ["unknown"])
                    log(step="late check failed", error=str(e2)[:200])
            if late is None:
                log(step="ask failed", error=str(e)[:300])
                return False, None
            log(step="ask landed after forge gave up", tx=late[0], events=late[1])
            if "unknown" in late[1]:
                # the nonce moved but its outcome is unread: never risk a second payment blind
                print("the agent's tx was mined but its events could not be read; stopping. Check the "
                      "wallet's Paid/Refused logs, then rerun.", file=sys.stderr)
                sys.exit(4)
            return late

    start = time.time()
    deadline = start + a.timeout_min * 60
    last_short = None
    asks = 0
    while True:
        try:
            have = unspent(rpc, wallet)
        except RuntimeError as e:
            log(step="read failed", error=str(e)[:200])
            time.sleep(30)
            continue
        if have >= a.amount:
            log(step="served", unspent=have, asks=asks, waitedSec=int(time.time() - start))
            break
        if time.time() >= deadline:
            log(step="timeout", unspent=have, asks=asks, waitedSec=int(time.time() - start))
            print(f"not served within {a.timeout_min} min after {asks} asks. Check the coordinator's reserves "
                  "and debt (a coordinator in debt gets no react), the donor's held allowance and when it last "
                  "asked (a chain that asked within 40 min is no donor), then loop_logger.py trace.",
                  file=sys.stderr)
            sys.exit(2)
        t0 = time.time()
        if last_short is not None and t0 - last_short > WANT_TTL:
            print(f"warning: {int(t0 - last_short)} s since the last Short, past the {WANT_TTL} s want TTL: the "
                  "coordinator has dropped the want; this ask opens a new one", file=sys.stderr)
        tx, evs = attempt()
        if tx is False:
            time.sleep(min(30, max(0, deadline - time.time())))
            continue
        asks += 1
        if "Short" in evs:
            last_short = time.time()
        if "Paid" in evs:
            # served between the read and the pay: that pay was the paid one
            log(step="paid", tx=tx, events=evs, asks=asks, waitedSec=int(time.time() - start))
            return
        log(step="ask", tx=tx, events=evs, asks=asks)
        time.sleep(max(0, min(a.every_sec - (time.time() - t0), deadline - time.time())))

    if a.no_final_pay:
        return
    tx, evs = attempt()
    if tx is False:
        sys.exit(3)
    log(step="paid" if "Paid" in evs else "final pay refused", tx=tx, events=evs, asks=asks,
        waitedSec=int(time.time() - start))
    if "Paid" not in evs:
        sys.exit(3)


if __name__ == "__main__":
    main()
