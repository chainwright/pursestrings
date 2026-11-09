#!/usr/bin/env python3
"""agent_retry.py with every forge/cast call faked: a pay that forge gives up on but that is mined
anyway must count as that pay (one pay, logged paid), never as a failed ask followed by a second pay.
Run: python3 script/test_agent_retry.py   (no network, no keys)"""
import importlib.util, json, os, sys, tempfile, types

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("agent_retry", os.path.join(HERE, "agent_retry.py"))
ar = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ar)
ar.time.sleep = lambda s: None
R = lambda out="", rc=0: types.SimpleNamespace(returncode=rc, stdout=out, stderr="")
PAID = "0x" + "aa" * 32


def fake(mined):
    st = {"nonce": 5, "unspent": 0, "pays": 0}

    def run(cmd, timeout=300):
        tool, verb = os.path.basename(cmd[0]), cmd[1]
        if tool == "forge":
            st["pays"] += 1
            if mined:
                st["nonce"] += 1
                st["unspent"] = 0
            return R("receipt wait timed out", 1)
        if verb == "keccak":
            return R(PAID if cmd[2].startswith("Paid(") else "0x" + cmd[2].encode().hex()[:64])
        if verb == "call":
            return R("1" if cmd[3].startswith("today") else str(st["unspent"]))
        if verb == "nonce":
            return R(str(st["nonce"]))
        if verb == "block-number":
            return R("100")
        if verb == "logs":
            return R(json.dumps([{"topics": [PAID], "transactionHash": "0xlate"}] if mined else []))
        raise AssertionError(f"unexpected call {cmd}")
    return run, st


def main_with(mined, d):
    run, st = fake(mined)
    ar.run, ar.LATE_WAIT = run, 0
    os.environ.update(BASE_SEPOLIA_RPC_URL="x", AGENT_ADDRESS="0x" + "11" * 20,
                      AGENT_LOG=os.path.join(d, f"log_{mined}.jsonl"),
                      DEPLOYMENTS_FILE=os.path.join(d, "dep.json"))
    sys.argv = ["agent_retry.py", "--chain", "base", "--timeout-min", "0.0005"]
    try:
        ar.main()
        code = 0
    except SystemExit as e:
        code = e.code
    steps = [json.loads(l)["step"] for l in open(os.environ["AGENT_LOG"])]
    return code, st["pays"], steps


with tempfile.TemporaryDirectory() as d:
    json.dump({"base": {"wallet": "0x" + "22" * 20}}, open(os.path.join(d, "dep.json"), "w"))
    code, pays, steps = main_with(True, d)
    assert (code, pays) == (0, 1), (code, pays, steps)
    assert steps == ["ask landed after forge gave up", "paid"], steps
    code, pays, steps = main_with(False, d)
    assert code == 2 and "paid" not in steps and steps[0] == "ask failed", (code, steps)
print("agent_retry: 2/2 ok (late-mined pay counted once; real failure stays a failed ask)")
