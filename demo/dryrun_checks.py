#!/usr/bin/env python3
"""Dry run only (script/dryrun.sh): attacks on the demo API with real local transactions.

    dryrun_checks.py replay   the agent's last paid call again (same X-Payment) -> must be 409;
                              and the same paid tx offered for a fresh callId -> must be refused
    dryrun_checks.py onlooker the agent pays a fresh quote ($1, impersonated on anvil); someone who
                              saw the tx (callId public, claim not) presents it first -> refused;
                              the agent then redeems it with its claim -> served
    dryrun_checks.py fake     deploys test/mocks/FakePaid.sol on local Base Sepolia from an
                              address that is no wallet of ours, and in one tx emits a Paid
                              identical to SpendWallet's for a fresh quote AND moves that many real
                              budget tokens to the payee -> no data may be served

Exit 0 when the API refused every attack. Uses anvil impersonation (no key) and refuses to run
unless the RPC URL is local. DEMO_API_URL, DEMO_AGENT_LOG, DEPLOYMENTS_FILE as in dryrun.sh.
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from agent import http_get  # noqa: E402

CAST = os.environ.get("CAST", os.path.expanduser("~/.foundry/bin/cast"))
ATTACKER = "0x00000000000000000000000000000000a77ac4e7"


def url():
    u = os.environ["BASE_SEPOLIA_RPC_URL"]
    if not (u.startswith("http://127.0.0.1:") or u.startswith("http://localhost:")):
        sys.exit("BASE_SEPOLIA_RPC_URL is not local: these checks only run in the dry run")
    return u


def cast(*args):
    # the RPC flag right after the subcommand: after `--create <code>` it would be a constructor argument
    r = subprocess.run([CAST, args[0], "--rpc-url", url(), *args[1:]], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"cast {args[0]} failed: {r.stderr.strip()[:300]}")
    return r.stdout.strip()


def api(resource, header=None, claim=""):
    hs = {"X-Payment": header, "X-Payment-Claim": claim} if header else None
    return http_get(os.environ["DEMO_API_URL"].rstrip("/") + resource, hs)


def replay():
    rows = [json.loads(l) for l in open(os.environ["DEMO_AGENT_LOG"])]
    last = [r for r in rows if r.get("step") == "data" and r.get("paid")][-1]
    res, tx, cid = last["resource"], last["tx"], last["paid"]["callId"]
    code, body = api(res, f"{last['paid']['chainId']}:{tx}:{cid}")
    print(f"   replay of the paid call {cid[:10]}… -> HTTP {code}: {body.get('reason')}")
    ok = code == 409
    code, q = api(res)
    code, body = api(res, f"{last['paid']['chainId']}:{tx}:{q['callId']}", q["claim"])
    print(f"   the same paid tx for a fresh callId -> HTTP {code}: {body.get('reason')}")
    return ok and code == 402 and "data" not in body


def fake():
    dep = json.load(open(os.environ.get("DEPLOYMENTS_FILE", "deployments/dryrun.json")))
    assert dep["dryRun"], "not a dry-run deployment"
    token, chain_id = dep["base"]["token"], dep["base"]["chainId"]
    art = json.load(open(os.path.join(HERE, "..", "out", "FakePaid.sol", "FakePaid.json")))
    cast("rpc", "anvil_impersonateAccount", ATTACKER)
    cast("rpc", "anvil_setBalance", ATTACKER, "0x56BC75E2D63100000")
    made = json.loads(cast("send", "--from", ATTACKER, "--unlocked", "--json", "--create",
                           art["bytecode"]["object"]))
    fake_addr = made["contractAddress"]
    res = "/v1/snapshot?n=2"
    code, q = api(res)
    assert code == 402, (code, q)
    payee_before = int(cast("call", token, "balanceOf(address)(uint256)", q["payee"]).split()[0])
    out = json.loads(cast("send", fake_addr, "fake(address,address,uint256,bytes32)", token, q["payee"],
                          str(q["price"]), q["callId"], "--from", ATTACKER, "--unlocked", "--json"))
    assert int(out["status"], 16) == 1
    moved = int(cast("call", token, "balanceOf(address)(uint256)", q["payee"]).split()[0]) - payee_before
    code, body = api(res, f"{chain_id}:{out['transactionHash']}:{q['callId']}", q["claim"])
    print(f"   FakePaid at {fake_addr}: Paid event for callId {q['callId'][:10]}… and ${moved / 1e6:.2f} of real "
          f"tokens to the payee -> HTTP {code}: {body.get('reason')}")
    return code == 402 and "data" not in body and moved == q["price"] and "unregistered" in body.get("reason", "")


def onlooker():
    dep = json.load(open(os.environ.get("DEPLOYMENTS_FILE", "deployments/dryrun.json")))
    assert dep["dryRun"], "not a dry-run deployment"
    wallet, chain_id, agent = dep["base"]["wallet"], dep["base"]["chainId"], os.environ["AGENT_ADDRESS"]
    res = "/v1/snapshot?n=1"
    code, q = api(res)
    assert code == 402, (code, q)
    cast("rpc", "anvil_impersonateAccount", agent)
    out = json.loads(cast("send", wallet, "pay(address,uint256,bytes32)", q["payee"], str(q["price"]), q["callId"],
                          "--from", agent, "--unlocked", "--json"))
    assert int(out["status"], 16) == 1
    hdr = f"{chain_id}:{out['transactionHash']}:{q['callId']}"
    c1, b1 = api(res, hdr)                       # the onlooker: no claim
    c2, b2 = api(res, hdr, "ab" * 16)            # the onlooker guessing
    c3, b3 = api(res, hdr, q["claim"])           # the agent
    print(f"   onlooker presents the agent's paid tx -> HTTP {c1}: {b1.get('reason')}; guessed claim -> HTTP {c2}; "
          f"the agent with its claim -> HTTP {c3}, paid {b3.get('paid', {}).get('amountUsd')}")
    return c1 == 402 and c2 == 402 and "data" not in b1 and "data" not in b2 and c3 == 200


if __name__ == "__main__":
    fn = {"replay": replay, "fake": fake, "onlooker": onlooker}[sys.argv[1]]
    sys.exit(0 if fn() else 1)
