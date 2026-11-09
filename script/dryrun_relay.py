#!/usr/bin/env python3
"""Dry run only: plays the Reactive Network on the three local anvil chains, with real local txs,
so that script/loop_logger.py can be exercised end to end before the live loop.

    dryrun_relay.py topup [amount]      the agent on Base Sepolia is refused for amount
                                        (default $3; Short)
    dryrun_relay.py stop                the owner presses STOP on Unichain Sepolia (StopPressed)
    dryrun_relay.py deliver <chain> <tx>  relay an origin tx that already happened (an agent
                                        retry's Short, say; chain = base | unichain)
    ... --answer-back                   also hand the wallets' answers (GrantApplied, EpochAck)
                                        back to the coordinator, one level deep

For the origin event it then:
  1. hands the wallet's log to the coordinator on local Lasna as the system contract would
     (react(), sent from 0x8888...8888: the reactive tx);
  2. delivers every callback the coordinator requested to the right front, from that chain's
     callback-proxy address, with the coordinator's address injected (destination txs). The
     callbacks that answer the loop (applyGrant / applyEpoch) go first; every other callback (a
     heartbeat re-read, say) goes 30 s later, so a logger that took "the latest callback of the
     reactive tx" would report a latency at least 30 s too long;
  3. records each in the stand-in system contract, so getCallbacks(reactive tx) returns them.
The LogRecord carries the origin tx hash and block hash, as Reactive's does live (07.11: the
reactive tx's input holds the origin tx hash), so the logger's origin-tx link is exercised.
Prints the origin tx hash. Uses anvil impersonation (--unlocked): no key at all. Refuses to run
unless every RPC URL is local.
"""
import json
import os
import subprocess
import sys

CAST = os.environ.get("CAST", os.path.expanduser("~/.foundry/bin/cast"))
SYSTEM = "0x8888888888888888888888888888888888888888"
PROXIES = {84532: "0x476F44b11F5C942c58f4c8E3d0300E5710743585", 1301: "0x775c9B990ADe401060B78D0e98684eEf8d2466C1"}
ENVS = {84532: "BASE_SEPOLIA_RPC_URL", 1301: "UNICHAIN_SEPOLIA_RPC_URL"}
KEYS = {84532: "base", 1301: "unichain"}
LOGREC = "(uint256,address,uint256,uint256,uint256,uint256,bytes,uint256,uint256,uint256,uint256,uint256)"
ANSWERS = ("applyGrant(uint256,uint64,uint256,uint64)", "applyEpoch(uint64,bool,uint64)")


def url(env):
    u = os.environ[env]
    if not (u.startswith("http://127.0.0.1:") or u.startswith("http://localhost:")):
        sys.exit(f"{env} is not local: the relay only runs in the dry run")
    return u


def cast(env, *args):
    r = subprocess.run([CAST, *args, "--rpc-url", url(env)], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"cast {args[0]} failed: {r.stderr.strip()[:400]}")
    return r.stdout.strip()


def offline(*args):
    r = subprocess.run([CAST, *args], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"cast {args[0]} failed: {r.stderr.strip()[:400]}")
    return r.stdout.strip()


def send_as(env, who, to, sig, *args):
    cast(env, "rpc", "anvil_impersonateAccount", who)
    cast(env, "rpc", "anvil_setBalance", who, "0x56BC75E2D63100000")
    out = json.loads(cast(env, "send", to, sig, *args, "--from", who, "--unlocked", "--json"))
    assert int(out["status"], 16) == 1, f"{sig} reverted"
    return out


def later(seconds):
    for env in ("LASNA_RPC_URL", "BASE_SEPOLIA_RPC_URL", "UNICHAIN_SEPOLIA_RPC_URL"):
        cast(env, "rpc", "evm_increaseTime", str(seconds))
        cast(env, "rpc", "evm_mine")


def relay(dep, chain, wallet, o, lg):
    """Hands one wallet log (lg, from origin receipt o) to the coordinator as a react() and
    delivers every callback it requested. Returns the destination receipts."""
    rc = dep["coordinator"]
    topics = [int(t, 16) for t in lg["topics"]] + [0, 0, 0]
    rec = (f"({chain},{wallet},{topics[0]},{topics[1]},{topics[2]},{topics[3]},{lg['data']},"
           f"{int(o['blockNumber'], 16)},1,{int(o['blockHash'], 16)},{int(o['transactionHash'], 16)},"
           f"{int(lg.get('logIndex', '0x0'), 16)})")

    # 2. reactive tx
    before = int(cast("LASNA_RPC_URL", "call", SYSTEM, "callbacks()(uint256)").split()[0])
    reactive_tx = send_as("LASNA_RPC_URL", SYSTEM, rc, f"react({LOGREC})", rec)["transactionHash"]
    after = int(cast("LASNA_RPC_URL", "call", SYSTEM, "callbacks()(uint256)").split()[0])

    # 3. destination txs: answers first, the rest 30 s later
    reqs = []
    for i in range(before, after):
        out = json.loads(cast("LASNA_RPC_URL", "call", SYSTEM, "request(uint256)((uint256,address,uint64,bytes))",
                              str(i), "--json"))[0]
        inner = offline("decode-calldata", "deliver(address,bytes)", out[3]).splitlines()[1]
        is_answer = any(inner.lower().startswith(offline("sig", s).lower()) for s in ANSWERS)
        reqs.append((not is_answer, int(out[0]), inner))
    delayed, dests = False, []
    for not_answer, chain_id, inner in sorted(reqs, key=lambda r: r[0]):
        if not_answer and not delayed:
            later(30)
            delayed = True
        front = dep[KEYS[chain_id]]["front"]
        d = send_as(ENVS[chain_id], PROXIES[chain_id], front, "deliver(address,bytes)", rc, inner)
        send_as("LASNA_RPC_URL", SYSTEM, SYSTEM, "recordCallback(uint256,address,uint256,uint256)",
                str(int(reactive_tx, 16)), rc, str(chain_id), str(int(d["transactionHash"], 16)))
        dests.append((chain_id, d))
    return dests


def main():
    args = [x for x in sys.argv[1:] if x != "--answer-back"]
    answer_back = "--answer-back" in sys.argv[1:]
    path = args[0] if args else "topup"
    dep = json.load(open(os.environ.get("DEPLOYMENTS_FILE", "deployments/dryrun.json")))
    assert dep["dryRun"], "not a dry-run deployment"

    # 1. origin
    if path == "topup":
        chain, wallet = 84532, dep["base"]["wallet"]
        amount = args[1] if len(args) > 1 else "3000000"
        o = send_as(ENVS[chain], os.environ["AGENT_ADDRESS"], wallet, "pay(address,uint256,bytes32)",
                    os.environ["PAYEE_ADDRESS"], amount, "0x" + os.urandom(32).hex())
        t0 = offline("keccak", "Short(uint64,uint256,uint64)")
    elif path == "deliver":
        chain = {"base": 84532, "unichain": 1301}[args[1]]
        wallet = dep[KEYS[chain]]["wallet"]
        o = json.loads(cast(ENVS[chain], "receipt", args[2], "--json"))
        sigs = ("Short(uint64,uint256,uint64)", "LowWater(uint64,uint256,uint64)", "StopPressed(uint64)")
        tops = {offline("keccak", x).lower() for x in sigs}
        t0 = next(l["topics"][0] for l in o["logs"]
                  if l["address"].lower() == wallet.lower() and l["topics"][0].lower() in tops)
    else:
        chain, wallet = 1301, dep["unichain"]["wallet"]
        owner = offline("wallet", "address", "--mnemonic", "test test test test test test test test test test test junk",
                        "--mnemonic-index", "0")
        o = send_as(ENVS[chain], owner, wallet, "pressStop()")
        t0 = offline("keccak", "StopPressed(uint64)")
    lg = next(l for l in o["logs"] if l["topics"][0].lower() == t0.lower() and l["address"].lower() == wallet.lower())
    dests = relay(dep, chain, wallet, o, lg)

    # 4. (--answer-back) the wallets' answers (GrantApplied, EpochAck) go back to the coordinator,
    #    as the live network does, so it sees the grant answered and may serve that chain again.
    #    One level only: the callbacks those reacts request are delivered, their answers are not.
    if answer_back:
        back = {offline("keccak", x).lower() for x in ("GrantApplied(uint256,uint64,uint256,uint64)",
                                                        "EpochAck(uint64,bool,uint64)")}
        for chain_id, d in dests:
            w = dep[KEYS[chain_id]]["wallet"]
            for l in d["logs"]:
                if l["address"].lower() == w.lower() and l["topics"][0].lower() in back:
                    relay(dep, chain_id, w, d, l)
    print(o["transactionHash"])


if __name__ == "__main__":
    main()
