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
#      the latest callback, and the second top-up's own grant, not the first's (W1 gate P0-3).
#      The STOP is traced twice and must be counted once (P0-4).
#   5. script/Loop.s.sol: the live-loop driver (pay, setCap, fundReserves, fundVault, stop)
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
echo "   (P0-3) a second top-up on the same chain right away: the previous loop's grant is inside the"
echo "   logger's search window and must not be taken"
origin="$(python3 script/dryrun_relay.py topup 5000000 --answer-back)"
python3 script/loop_logger.py trace --path topup --chain base --tx "$origin" --timeout-min 0.5 | check_trace 1 "$first"
python3 -c '
import json, sys
r = json.loads(open(sys.argv[1]).readlines()[-1])
assert r["links"] == ["origin-tx"], r["links"]
print("   linked by the origin tx hash in the reactive tx input:", r["links"], "grant", r["grantId"], "> floor", r["floors"]["grantIdAbove"])
' "$LOOPS_FILE" || { echo "FAILED: origin-tx link"; exit 1; }

origin="$(python3 script/dryrun_relay.py stop)"
python3 script/loop_logger.py trace --path stop --chain unichain --tx "$origin" --timeout-min 0.5 | check_trace 2
python3 -c '
import json, sys
r = json.loads(open(sys.argv[1]).readlines()[-1])
assert r["links"] == ["origin-tx"] and r["epoch"] >= 1, r
' "$LOOPS_FILE" || { echo "FAILED: STOP link/epoch"; exit 1; }
echo "   (P0-4) the same origin traced twice is counted once:"
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
echo "dry run complete"

