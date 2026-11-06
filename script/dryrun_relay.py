#!/usr/bin/env python3
"""Dry run only: plays the Reactive Network on the three local anvil chains, with real local txs,
so that script/loop_logger.py can be exercised end to end before the live loop.

  1. the agent asks for $3 on the local Base Sepolia chain and is refused (origin tx: Short);
  2. the Short log is handed to the coordinator on local Lasna as the system contract would
     (react(), sent from 0x8888...8888; reactive tx);
  3. the grant callback the coordinator requested is delivered to the front on local Base Sepolia
     from the callback proxy's address, with the coordinator's address injected (destination tx);
  4. the stand-in system contract records it, so getCallbacks(reactive tx) returns it.
Prints the origin tx hash. Uses anvil impersonation (--unlocked): no key at all. Refuses to run
unless every RPC URL is local.
"""
import json
import os
import subprocess
import sys

CAST = os.environ.get("CAST", os.path.expanduser("~/.foundry/bin/cast"))
SYSTEM = "0x8888888888888888888888888888888888888888"
PROXY_BASE = "0x476F44b11F5C942c58f4c8E3d0300E5710743585"
LOGREC = "(uint256,address,uint256,uint256,uint256,uint256,bytes,uint256,uint256,uint256,uint256,uint256)"


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


def main():
    dep = json.load(open(os.environ.get("DEPLOYMENTS_FILE", "deployments/dryrun.json")))
    assert dep["dryRun"], "not a dry-run deployment"
    rc, wallet, front = dep["coordinator"], dep["base"]["wallet"], dep["base"]["front"]
    agent, payee = os.environ["AGENT_ADDRESS"], os.environ["PAYEE_ADDRESS"]

    # 1. origin: refused payment -> Short
    o = send_as("BASE_SEPOLIA_RPC_URL", agent, wallet, "pay(address,uint256,bytes32)", payee, "3000000", "0x" + "11" * 32)
    short_t0 = offline("keccak", "Short(uint64,uint256,uint64)")
    lg = next(l for l in o["logs"] if l["topics"][0].lower() == short_t0.lower() and l["address"].lower() == wallet.lower())
    rec = f"(84532,{wallet},{int(short_t0, 16)},0,0,0,{lg['data']},{int(o['blockNumber'], 16)},1,0,0,0)"

    # 2. reactive: the system contract calls react() on the coordinator
    before = int(cast("LASNA_RPC_URL", "call", SYSTEM, "callbacks()(uint256)").split()[0])
    r = send_as("LASNA_RPC_URL", SYSTEM, rc, f"react({LOGREC})", rec)
    reactive_tx = r["transactionHash"]
    after = int(cast("LASNA_RPC_URL", "call", SYSTEM, "callbacks()(uint256)").split()[0])

    # 3. destination: the proxy delivers the grant callback(s) to the Base Sepolia front
    for i in range(before, after):
        out = json.loads(cast("LASNA_RPC_URL", "call", SYSTEM, "request(uint256)((uint256,address,uint64,bytes))", str(i), "--json"))[0]
        chain_id = int(out[0])
        payload = out[3]
        if chain_id != 84532:
            continue
        inner = offline("decode-calldata", "deliver(address,bytes)", payload).splitlines()[1]
        d = send_as("BASE_SEPOLIA_RPC_URL", PROXY_BASE, front, "deliver(address,bytes)", rc, inner)
        # 4. the system contract records the callback for getCallbacks()
        send_as("LASNA_RPC_URL", SYSTEM, SYSTEM, "recordCallback(uint256,address,uint256,uint256)",
                str(int(reactive_tx, 16)), rc, str(chain_id), str(int(d["transactionHash"], 16)))
    print(o["transactionHash"])


if __name__ == "__main__":
    main()
