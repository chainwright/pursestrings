#!/usr/bin/env bash
# Mutation check for the Pursestrings protocol spike.
#
# Runs the safety suite against the real contracts (MUTANT=0) and against each deliberately
# broken variant (MUTANT=1..17, see test/mutants/Mutants.sol). The suite is:
#   - test/Pursestrings.invariant.t.sol:PursestringsInvariantTest  (fuzz, invariants a b c e s + backing)
#   - test/Directed.t.sol:DirectedTest                             (one deterministic scenario per rule)
# at the DEFAULT budget from foundry.toml (what `forge test` runs), with two seeds.
# The real contracts must pass on every seed; every mutant must fail on every seed.
#
# Every run gets its own fresh failure-persistence directory, so no run can pass or fail by
# replaying a counterexample saved by an earlier run.
#
# For each mutant the table lists every check that failed (across both seeds) and whether any of
# them was (a) "paid out more than the owner's cap": that is, whether the break led to a real
# over-cap payout, counted by the token.
#
#   script/mutants.sh                              # default budget, seeds 0x5eed and 0x1234
#   SEEDS="0x1 0x2 0x3" script/mutants.sh
#   RUNS=512 DEPTH=300 script/mutants.sh           # a larger invariant budget
#   ONLY="0 4 13" script/mutants.sh                # a subset
#
# Exit code 0 only if the real contracts pass and every mutant fails on every seed.
set -u
cd "$(dirname "$0")/.."

FORGE="${FORGE:-$(command -v forge || echo "$HOME/.foundry/bin/forge")}"
SEEDS="${SEEDS:-0x5eed 0x1234}"
ONLY="${ONLY:-$(seq 0 17)}"
STAMP="$(date +%Y%m%d-%H%M%S)"
PERSIST_ROOT="cache/mutants/$STAMP"
mkdir -p "$PERSIST_ROOT"

NAMES=(
  "real contracts"
  "wallet: no dedup of coordinator messages (rule 4)"
  "core: credit a reclaim when it is sent (rule 2)"
  "wallet: reclaim counts spent allowance (rule 3)"
  "wallet: ignore the epoch on grants (rule 6)"
  "wallet: ignore the day number on grants"
  "core: refund a cancel when it is sent (rule 5)"
  "core: credit returns at head, no wait/re-read (rule 2)"
  "core: no dedup of credits (rule 4)"
  "wallet: pressing chain does not freeze locally (STOP)"
  "core: wait, then credit without re-reading the fact"
  "wallet: credit allowance although the vault transfer failed"
  "core: grant sent before the reserve is debited (rule 1)"
  "core: STOP never propagated to other chains (X1)"
  "core: unstop ignores the epoch it names (X2)"
  "core: re-read credited without the age check (X3)"
  "core: re-read asked without the core-side wait (X11)"
  "core: stale cap message re-applied (X9)"
)

budget="default (foundry.toml)"
extra_env=()
if [ -n "${RUNS:-}" ]; then extra_env+=("FOUNDRY_INVARIANT_RUNS=$RUNS"); budget="runs=$RUNS"; fi
if [ -n "${DEPTH:-}" ]; then extra_env+=("FOUNDRY_INVARIANT_DEPTH=$DEPTH"); budget="$budget depth=${DEPTH}"; fi

echo "Suite: PursestringsInvariantTest + DirectedTest; invariant budget: $budget; seeds: $SEEDS"
echo "Fresh failure-persistence dirs under $PERSIST_ROOT"
echo

summarize() {
  # stdin: forge --json output. Prints "<n_failed> <overspent 0/1> <check;check;...>"
  python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("-1 0 forge-output-unreadable"); sys.exit()
failed, over = [], 0
for suite in d.values():
    for name, r in suite["test_results"].items():
        if r["status"] != "Success":
            reason = (r.get("reason") or "").split(":")[0].strip()
            failed.append(name.replace("()", "") + " [" + reason + "]")
            if "(a) paid out" in (r.get("reason") or ""):
                over = 1
print(len(failed), over, ";".join(failed) if failed else "-")
'
}

printf "%-4s %-58s %-10s %-10s %-6s %s\n" "id" "variant" "seed1" "seed2" "over?" "failing checks (union over seeds)"
bad=0
for m in $ONLY; do
  results=(); checks=""; over=0
  for seed in $SEEDS; do
    dir="$PERSIST_ROOT/m$m-$seed"
    mkdir -p "$dir"
    out=$(env MUTANT="$m" FOUNDRY_INVARIANT_FAILURE_PERSIST_DIR="$dir" ${extra_env[@]+"${extra_env[@]}"} \
          "$FORGE" test --match-contract 'PursestringsInvariantTest|DirectedTest' --fuzz-seed "$seed" --json 2>/dev/null)
    read -r nfail o list <<<"$(printf "%s" "$out" | summarize)"
    if [ "$o" = "1" ]; then over=1; fi
    if [ "$m" -eq 0 ]; then
      if [ "$nfail" = "0" ]; then results+=("PASS"); else results+=("FAIL($nfail)"); bad=1; fi
    else
      if [ "$nfail" -gt 0 ] 2>/dev/null; then results+=("KILLED($nfail)"); else results+=("SURVIVED"); bad=1; fi
    fi
    [ "$list" != "-" ] && checks="$checks;$list"
  done
  uniq=$(printf "%s" "$checks" | tr ';' '\n' | sed '/^$/d' | sort -u | paste -sd ';' - | sed 's/;/; /g')
  if [ "$m" -eq 0 ]; then ov="-"; elif [ $over -eq 1 ]; then ov="YES"; else ov="no"; fi
  printf "%-4s %-58s %-10s %-10s %-6s %s\n" "M$m" "${NAMES[$m]}" "${results[0]:-}" "${results[1]:-}" "$ov" "${uniq:--}"
done

echo
echo "over? = YES if any failing check was (a) 'paid out more than the owner's cap for the day',"
echo "        i.e. the broken rule led to a real over-cap payout counted by the token."
if [ $bad -eq 0 ]; then
  echo "OK: real contracts pass on every seed, every mutant is killed on every seed."
else
  echo "NOT OK: see the table above."
fi
exit $bad
