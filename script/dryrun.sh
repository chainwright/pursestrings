#!/usr/bin/env bash
# Dry run of the whole deployment, with no network at all.
#
# Starts three local anvil chains with the REAL chain ids (Lasna 5318007, Base Sepolia 84532,
# Unichain Sepolia 1301), puts a stand-in system contract at 0x8888...8888 on the Lasna one
# (test/mocks/MockSystem.sol: records subscriptions and callback requests), then runs exactly the
# live scripts against them:
#   1. script/Deploy.s.sol --broadcast   (DRY_RUN=true: a test token instead of USDC)
#   2. script/Check.s.sol                (wiring on every chain)
#   3. script/Check.s.sol simulateLoop() (Short -> react -> grant callback -> wallet ->
#                                         GrantApplied -> react, with the proxy impersonated)
#   4. script/dryrun_relay.py + script/loop_logger.py: two top-ups on the same chain back to back and
#      a STOP as real local txs (anvil impersonation of the system contract and the proxies),
#      traced by the live-loop logger. The relay delivers non-answer callbacks (heartbeats) 30 s
#      after the answers, and the check asserts the logger matched the grant / the epoch acks, not
#      the latest callback, and the second top-up's own grant, not the first's.
#      The STOP is traced twice and must be counted once.
#   4b. script/agent_retry.py: the agent keeps asking on Unichain Sepolia until the grant
#      lands, then pays; an ask that is never served exits 2.
#   4c. demo/api.py + demo/agent.py: 402 -> pay -> data; a replay, a fake Paid (backed by real
#      tokens from a non-wallet) and an onlooker without the quote's claim are refused; an over-allowance call gets amber, is served once the
#      grant lands; a call above what is left of the cap gets red; script/checker.py: Over $0.00.
#   5. script/Loop.s.sol: the live-loop driver (pay, setCap, fundReserves, fundVault, stop), and the
#      second payee for the video (setPayee, fundPayee, returnPayee back to the deployer)
# The deployer key is anvil's public development key, derived into an environment variable and
# never printed. Broadcast logs go to cache/dryrun/ and addresses to deployments/dryrun.json
# (both gitignored). The anvils are stopped on exit.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN="${FOUNDRY_BIN:-$HOME/.foundry/bin}"
FORGE="$BIN/forge"; CAST="$BIN/cast"; ANVIL="$BIN/anvil"
P_LASNA=18545; P_BASE=18546; P_UNI=18547
mkdir -p cache/dryrun

pids=()
cleanup() { for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT

"$ANVIL" -q --chain-id 5318007 -p $P_LASNA & pids+=($!)
"$ANVIL" -q --chain-id 84532 -p $P_BASE & pids+=($!)
"$ANVIL" -q --chain-id 1301 -p $P_UNI & pids+=($!)
for p in $P_LASNA $P_BASE $P_UNI; do
  for _ in $(seq 1 50); do "$CAST" chain-id --rpc-url "http://127.0.0.1:$p" >/dev/null 2>&1 && break; sleep 0.2; done
done

export LASNA_RPC_URL="http://127.0.0.1:$P_LASNA"
export LASNA_CALLBACK_INDEX=0x8888888888888888888888888888888888888888   # the stand-in records callbacks there
export BASE_SEPOLIA_RPC_URL="http://127.0.0.1:$P_BASE"
export UNICHAIN_SEPOLIA_RPC_URL="http://127.0.0.1:$P_UNI"

"$FORGE" build -q
code=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["deployedBytecode"]["object"])' out/MockSystem.sol/MockSystem.json)
"$CAST" rpc --rpc-url "$LASNA_RPC_URL" anvil_setCode 0x8888888888888888888888888888888888888888 "$code" >/dev/null

# anvil's public development mnemonic; the derived key only ever lives in this environment
DEPLOYER_PRIVATE_KEY="$("$CAST" wallet private-key "test test test test test test test test test test test junk" 0)"
export DEPLOYER_PRIVATE_KEY
AGENT_PRIVATE_KEY="$("$CAST" wallet private-key "test test test test test test test test test test test junk" 1)"
export AGENT_PRIVATE_KEY
AGENT_ADDRESS="$("$CAST" wallet address --mnemonic "test test test test test test test test test test test junk" --mnemonic-index 1)"
export AGENT_ADDRESS
export PAYEE_ADDRESS=0x000000000000000000000000000000000000bEEF
export DRY_RUN=true
export DEPLOYMENTS_FILE=deployments/dryrun.json
export FOUNDRY_BROADCAST=cache/dryrun/broadcast

# run a forge step; on failure show its tail and stop; on success show the lines matching $1
step() {
  local pattern="$1"; shift
  local out
  if ! out="$("$@" 2>&1)"; then printf "%s\n" "$out" | tail -25; echo "FAILED: $*"; exit 1; fi
  printf "%s\n" "$out" | grep -E "$pattern" || true
}

echo "== 1. deploy (Lasna + Base Sepolia + Unichain Sepolia, local)"
step "deployer|predicted|coordinator|written|ONCHAIN EXECUTION" "$FORGE" script script/Deploy.s.sol --broadcast --slow
echo "== 2. wiring checks"
step "wiring" "$FORGE" script script/Check.s.sol
echo "== 3. simulated loop through the deployed contracts"
step "^  (subscriptions|grant|allowance|dry-run)" "$FORGE" script script/Check.s.sol --sig "simulateLoop()"
echo "== 4. logger end to end on local txs (script/dryrun_relay.py plays the Reactive Network)"
export LOOPS_FILE=cache/dryrun/loops.jsonl
: > "$LOOPS_FILE"
check_trace() {  # $1 = expected answers, $2 = an answer that must NOT be matched (optional);
                 # asserts complete, latency 0..30 s (the late callback is not the answer), links shown
  python3 -c '
import json, sys
t = json.loads(sys.stdin.read()); n = int(sys.argv[1]); bad = sys.argv[2] if len(sys.argv) > 2 else None
ok = t["complete"] and len(t["answers"]) == n and t["latencySec"] is not None and 0 <= t["latencySec"] < 30
ok = ok and (bad is None or bad not in t["answers"])
print("   matched", list(t["answers"]), "latency", t["latencySec"], "s; other callbacks", len(t["otherCallbacks"]))
sys.exit(0 if ok else 1)' "$@" || { echo "FAILED: logger matching"; exit 1; }
}
origin="$(python3 script/dryrun_relay.py topup --answer-back)"
python3 script/loop_logger.py trace --path topup --chain base --tx "$origin" --timeout-min 0.5 | check_trace 1
first="$(python3 -c 'import json,sys; print(list(json.loads(open(sys.argv[1]).readlines()[-1])["answers"])[0])' "$LOOPS_FILE")"
echo "   a second top-up on the same chain right away: the previous loop's grant is inside the"
echo "   logger's search window and must not be taken"
origin="$(python3 script/dryrun_relay.py topup 5000000 --answer-back)"
python3 script/loop_logger.py trace --path topup --chain base --tx "$origin" --timeout-min 0.5 | check_trace 1 "$first"
python3 -c '
import json, sys
r = json.loads(open(sys.argv[1]).readlines()[-1])
assert r["links"] == ["origin-tx"], r["links"]
print("   linked by the origin tx hash in the reactive tx input:", r["links"], "grant", r["grantId"], "> floor", r["floors"]["grantIdAbove"])
' "$LOOPS_FILE" || { echo "FAILED: origin-tx link"; exit 1; }

echo "== 4b. agent retry (script/agent_retry.py): refused -> keeps asking -> served -> paid"
export AGENT_LOG=cache/dryrun/agent_retry.jsonl
: > "$AGENT_LOG"
python3 script/agent_retry.py --chain unichain --every-sec 3 --timeout-min 3 > cache/dryrun/agent_retry.out 2>&1 &
apid=$!; pids+=($apid)
for _ in $(seq 1 180); do [ "$(grep -c '"step": "ask"' "$AGENT_LOG")" -ge 2 ] && break; sleep 1; done
short_tx="$(python3 -c '
import json, sys
print(next(r["tx"] for r in map(json.loads, open(sys.argv[1])) if r.get("step") == "ask" and "Short" in r["events"]))
' "$AGENT_LOG")" || { tail -5 cache/dryrun/agent_retry.out; echo "FAILED: no refused ask with Short"; exit 1; }
echo "   asks so far: $(grep -c '"step": "ask"' "$AGENT_LOG") (the first with Short); the grant lands now"
python3 script/dryrun_relay.py deliver unichain "$short_tx" >/dev/null
if ! wait "$apid"; then tail -5 cache/dryrun/agent_retry.out; echo "FAILED: agent retry did not finish paid"; exit 1; fi
python3 -c '
import json, sys
rs = [json.loads(l) for l in open(sys.argv[1])]
steps = [r["step"] for r in rs]
assert steps[-2:] == ["served", "paid"] and steps.count("ask") >= 2 and "Paid" in rs[-1]["events"], steps
print("   steps", steps, "-> paid", rs[-1]["tx"][:12] + "…")
' "$AGENT_LOG" || { echo "FAILED: agent retry log"; exit 1; }
set +e
python3 script/agent_retry.py --chain unichain --amount 9000000 --every-sec 1 --timeout-min 0.1 > cache/dryrun/agent_timeout.out 2>&1
rc=$?
set -e
if [ "$rc" != 2 ]; then tail -5 cache/dryrun/agent_timeout.out; echo "FAILED: unserved ask must exit 2 (got $rc)"; exit 1; fi
echo "   not served before its timeout: exit 2, as the run book expects"
python3 script/loop_logger.py paid-sum --chain unichain --from-block 0 | python3 -c '
import json, sys
r = json.loads(sys.stdin.read())
assert r["payments"] == 1 and list(r["paidPerDay"].values()) == [1.0], r
print("   checker (paid-sum): Unichain Sepolia paid", r["paidPerDay"], "in", r["payments"], "payment")
' || { echo "FAILED: paid-sum"; exit 1; }

echo "== 4c. demo API (demo/api.py, our own 402 flow) and its agent (demo/agent.py) on Base Sepolia"
P_API=18402
export DEMO_API_URL="http://127.0.0.1:$P_API" DEMO_API_STATE=cache/dryrun/demo_api_state.json
export DEMO_AGENT_LOG=cache/dryrun/demo_agent.jsonl
echo '{}' > "$DEMO_API_STATE"; : > "$DEMO_AGENT_LOG"
python3 demo/api.py --port $P_API > cache/dryrun/demo_api.out 2>&1 & pids+=($!)
for _ in $(seq 1 50); do curl -sf "$DEMO_API_URL/health" >/dev/null && break; sleep 0.2; done
curl -sf "$DEMO_API_URL/health" >/dev/null || { tail -5 cache/dryrun/demo_api.out; echo "FAILED: demo API did not start"; exit 1; }
agent_last() {  # $1 = expected exit code; the rest = demo/agent.py args. Shows the agent's last step.
  local want="$1"; shift
  set +e; python3 demo/agent.py --chain base "$@" > cache/dryrun/demo_agent.out 2>&1; local rc=$?; set -e
  python3 -c '
import json, sys
r = json.loads(open(sys.argv[1]).readlines()[-1])
print("   %-24s -> %s (exit %s)%s" % (r["resource"], r["step"], sys.argv[2],
      "; " + r["message"] if r.get("message") else ("; paid " + r["paid"]["amountUsd"] + " in pay #" + str(r["pays"]) if r.get("paid") else "")))' \
    "$DEMO_AGENT_LOG" "$rc"
  [ "$rc" = "$want" ] || { tail -5 cache/dryrun/demo_agent.out; echo "FAILED: agent exit $rc, expected $want"; exit 1; }
}
echo "   a. 402 -> pay -> data"
agent_last 0 --resource "/v1/snapshot?n=1"
echo "   b. attacks on the API: replay, a fake Paid backed by real tokens from a non-wallet, an onlooker"
python3 demo/dryrun_checks.py replay || { echo "FAILED: replay check"; exit 1; }
python3 demo/dryrun_checks.py fake || { echo "FAILED: fake-Paid check"; exit 1; }
python3 demo/dryrun_checks.py onlooker || { echo "FAILED: onlooker check"; exit 1; }
echo "   c. over allowance: amber (budget on its way), the grant lands, the agent retries and is served"
python3 demo/agent.py --chain base --resource "/v1/snapshot?n=9" --wait-min 3 > cache/dryrun/demo_amber.out 2>&1 &
dpid=$!; pids+=($dpid)
for _ in $(seq 1 180); do grep -q '"step": "amber"' "$DEMO_AGENT_LOG" && break; sleep 1; done
amber_tx="$(python3 -c '
import json, sys
print(next(r["tx"] for r in map(json.loads, open(sys.argv[1])) if r.get("step") == "amber"))' "$DEMO_AGENT_LOG")" \
  || { tail -5 cache/dryrun/demo_amber.out; echo "FAILED: no amber answer"; exit 1; }
grep '"step": "amber"' "$DEMO_AGENT_LOG" | head -1 | python3 -c 'import json,sys; r=json.loads(sys.stdin.read()); print("   amber:", r["message"])'
python3 script/dryrun_relay.py deliver base "$amber_tx" >/dev/null
if ! wait "$dpid"; then tail -5 cache/dryrun/demo_amber.out; echo "FAILED: amber call not served after the grant"; exit 1; fi
python3 -c '
import json, sys
r = json.loads(open(sys.argv[1]).readlines()[-1])
assert r["step"] == "data" and r["pays"] >= 2 and r["paid"]["amount"] == 9000000, r
print("   served after %d pays (the refused ones moved no money): paid %s" % (r["pays"], r["paid"]["amountUsd"]))' \
  "$DEMO_AGENT_LOG" || { echo "FAILED: amber log"; exit 1; }
echo "   d. a call bigger than what is left of today's cap: red"
agent_last 11 --resource "/v1/snapshot?n=10"
echo "   e. the checker (script/checker.py): token Transfer logs out of every wallet today vs the cap"
python3 script/checker.py | sed 's/^/   /'
python3 script/checker.py --json | python3 -c '
import json, sys
r = json.loads(sys.stdin.read())["reports"][0]
# 1 (agent retry, Unichain) + 1 + 1 (onlooker check) + 9 (demo, Base); the fake Paid moved tokens
# from a non-wallet: not counted
assert r["spent"] == 12000000 and r["over"] == 0 and r["cap"] == 20000000, r
' || { echo "FAILED: checker"; exit 1; }

origin="$(python3 script/dryrun_relay.py stop)"
python3 script/loop_logger.py trace --path stop --chain unichain --tx "$origin" --timeout-min 0.5 | check_trace 2
python3 -c '
import json, sys
r = json.loads(open(sys.argv[1]).readlines()[-1])
assert r["links"] == ["origin-tx"] and r["epoch"] >= 1, r
' "$LOOPS_FILE" || { echo "FAILED: STOP link/epoch"; exit 1; }
echo "   the same origin traced twice is counted once:"
python3 script/loop_logger.py trace --path stop --chain unichain --tx "$origin" --timeout-min 0.5 | check_trace 2
python3 script/loop_logger.py summary | tee cache/dryrun/summary.txt
grep -q "re-trace(s) dropped" cache/dryrun/summary.txt && grep -q "stop: runs 1, complete 1" cache/dryrun/summary.txt \
  || { echo "FAILED: summary dedupe"; exit 1; }
echo "== 5. loop driver (script/Loop.s.sol) on the local chains"
ok() { if grep -q "ONCHAIN EXECUTION COMPLETE & SUCCESSFUL"; then echo "   $1: ok"; else echo "   $1: FAILED"; exit 1; fi; }
"$FORGE" script script/Loop.s.sol --sig "pay(uint256,uint256)" 1 1000000 --broadcast 2>&1 | ok "pay (refused, Short) on Unichain Sepolia"
"$FORGE" script script/Loop.s.sol --sig "setCap(uint256)" 30000000 --broadcast 2>&1 | ok "setCap 30 USD on the console"
"$FORGE" script script/Loop.s.sol --sig "fundReserves(uint256,uint256)" 1000000000000000000 0 --broadcast 2>&1 | ok "fundReserves 1 lREACT to the coordinator"
"$FORGE" script script/Loop.s.sol --sig "fundVault(uint256,uint256)" 0 0 --broadcast 2>&1 | ok "fundVault (0, plumbing only)"
"$FORGE" script script/Loop.s.sol --sig "stop(uint256)" 1 --broadcast 2>&1 | ok "STOP pressed on Unichain Sepolia"
"$FORGE" script script/Loop.s.sol --sig "fundAgent(uint256,uint256)" 0 500000000000000 --broadcast 2>&1 | ok "fundAgent 0.0005 ETH on Base Sepolia"
stop_tx="$(python3 script/loop_logger.py last-tx --fn stop --chain unichain)"
echo "   last STOP tx (for the logger): $stop_tx"
echo "   a second payee (the video's API-seller stand-in): allow, fund its gas, and get its tokens back"
PAYEE_PRIVATE_KEY="$("$CAST" wallet private-key "test test test test test test test test test test test junk" 2)"
export PAYEE_PRIVATE_KEY
P2="$("$CAST" wallet address --mnemonic "test test test test test test test test test test test junk" --mnemonic-index 2)"
DEPLOYER_ADDRESS="$("$CAST" wallet address --mnemonic "test test test test test test test test test test test junk" --mnemonic-index 0)"
export DEPLOYER_ADDRESS
W0="$(python3 -c 'import json; print(json.load(open("deployments/dryrun.json"))["base"]["wallet"])')"
T0="$(python3 -c 'import json; print(json.load(open("deployments/dryrun.json"))["base"]["token"])')"
[ "$("$CAST" call "$W0" 'payeeAllowed(address)(bool)' "$P2" --rpc-url "$BASE_SEPOLIA_RPC_URL")" = false ] \
  || { echo "FAILED: the second payee is allowed before setPayee"; exit 1; }
"$FORGE" script script/Loop.s.sol --sig "setPayee(uint256,address,bool)" 0 "$P2" true --broadcast 2>&1 | ok "setPayee (second payee) on Base Sepolia"
[ "$("$CAST" call "$W0" 'payeeAllowed(address)(bool)' "$P2" --rpc-url "$BASE_SEPOLIA_RPC_URL")" = true ] \
  || { echo "FAILED: setPayee did not allow the second payee"; exit 1; }
[ "$("$CAST" call "$W0" 'payeeAllowed(address)(bool)' "$PAYEE_ADDRESS" --rpc-url "$BASE_SEPOLIA_RPC_URL")" = true ] \
  || { echo "FAILED: the first payee must stay allowed"; exit 1; }
PAYEE_ADDRESS="$P2" "$FORGE" script script/Loop.s.sol --sig "fundPayee(uint256,uint256)" 0 200000000000000 --broadcast 2>&1 | ok "fundPayee 0.0002 ETH on Base Sepolia"
"$CAST" send "$T0" 'mint(address,uint256)' "$P2" 3000000 --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url "$BASE_SEPOLIA_RPC_URL" >/dev/null
before="$("$CAST" call "$T0" 'balanceOf(address)(uint256)' "$DEPLOYER_ADDRESS" --rpc-url "$BASE_SEPOLIA_RPC_URL" | cut -d' ' -f1)"
"$FORGE" script script/Loop.s.sol --sig "returnPayee(uint256)" 0 --broadcast 2>&1 | ok "returnPayee: the payee's tokens back to the deployer"
after="$("$CAST" call "$T0" 'balanceOf(address)(uint256)' "$DEPLOYER_ADDRESS" --rpc-url "$BASE_SEPOLIA_RPC_URL" | cut -d' ' -f1)"
left="$("$CAST" call "$T0" 'balanceOf(address)(uint256)' "$P2" --rpc-url "$BASE_SEPOLIA_RPC_URL" | cut -d' ' -f1)"
[ "$((after - before))" = 3000000 ] && [ "$left" = 0 ] \
  || { echo "FAILED: returnPayee moved $((after - before)), payee left $left"; exit 1; }
echo "   returnPayee moved 3000000 back; the payee holds 0"
echo "dry run complete"

