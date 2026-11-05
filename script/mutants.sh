#!/usr/bin/env bash
# Mutation check for the Pursestrings protocol spike.
#
# Runs the invariant suite (test/Pursestrings.invariant.t.sol:PursestringsInvariantTest) against
# the real contracts (MUTANT=0) and against each deliberately broken variant (MUTANT=1..11, see
# test/mutants/Mutants.sol). The real contracts must pass; every mutant must fail.
#
# Every run gets the same budget, the same seed and its own fresh failure-persistence directory,
# so no run can pass or fail by replaying a counterexample saved by an earlier run.
#
#   script/mutants.sh                    # default budget: 512 runs x depth 300, seed 0x5eed
#   RUNS=128 DEPTH=150 script/mutants.sh # quicker
#   SEED=0x2 script/mutants.sh
#
# Exit code 0 only if the real contracts pass and every mutant fails.
set -u
cd "$(dirname "$0")/.."

FORGE="${FORGE:-$(command -v forge || echo "$HOME/.foundry/bin/forge")}"
RUNS="${RUNS:-512}"
DEPTH="${DEPTH:-300}"
SEED="${SEED:-0x5eed}"
STAMP="$(date +%Y%m%d-%H%M%S)"
PERSIST_ROOT="cache/mutants/$STAMP"
mkdir -p "$PERSIST_ROOT"

NAMES=(
  "real contracts"
  "wallet: no dedup of coordinator messages (rule 4)"
  "core: credit a reclaim when it is sent (rule 2)"
  "wallet: reclaim shrinks spent, not only unspent (rule 3)"
  "wallet: ignore the epoch on grants (rule 6)"
  "wallet: ignore the day number on grants"
  "core: refund a cancel when it is sent (rule 5)"
  "core: credit returns at head, no wait/re-read (reorgs)"
  "core: no dedup of credits (rule 4)"
  "wallet: pressing chain does not freeze locally (STOP)"
  "core: wait, then credit without re-reading the fact"
  "wallet: credit allowance although the vault transfer failed"
)

echo "Invariant suite: runs=$RUNS depth=$DEPTH seed=$SEED (calls per invariant = runs x depth)"
echo "Fresh failure-persistence dirs under $PERSIST_ROOT"
echo
printf "%-4s %-62s %-6s %-7s %s\n" "id" "variant" "result" "secs" "a failing invariant, as reported (shrunk sequence length)"

bad=0
for m in $(seq 0 11); do
  dir="$PERSIST_ROOT/m$m"
  mkdir -p "$dir"
  start=$(date +%s)
  out=$(MUTANT=$m FOUNDRY_INVARIANT_RUNS=$RUNS FOUNDRY_INVARIANT_DEPTH=$DEPTH \
        FOUNDRY_INVARIANT_FAILURE_PERSIST_DIR="$dir" \
        "$FORGE" test --match-contract PursestringsInvariantTest --fuzz-seed "$SEED" -vv 2>&1)
  code=$?
  secs=$(( $(date +%s) - start ))
  first=$(printf "%s\n" "$out" | grep -E "^\[FAIL" | head -1 | sed -E 's/^\[FAIL: //; s/\] invariant_/ @ invariant_/; s/\(\).*$//; s/; counterexample.*//')
  seqlen=$(printf "%s\n" "$out" | awk '/^\[FAIL/{f=1;n=0;next} f&&/sender=/{n++} f&&/^\[(PASS|FAIL)/{exit} END{print n}')
  if [ "$m" -eq 0 ]; then
    if [ $code -eq 0 ]; then res="PASS"; else res="FAIL"; bad=1; fi
  else
    if [ $code -ne 0 ] && [ -n "$first" ]; then res="KILLED"; else res="SURVIVED"; bad=1; fi
  fi
  printf "%-4s %-62s %-6s %-7s %s\n" "M$m" "${NAMES[$m]}" "$res" "$secs" "${first:+$first ($seqlen calls)}"
done

echo
if [ $bad -eq 0 ]; then
  echo "OK: real contracts pass, all 11 mutants killed."
else
  echo "NOT OK: see the table above."
fi
exit $bad
