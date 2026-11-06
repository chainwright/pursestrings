#!/usr/bin/env bash
# Mutation check for the Pursestrings protocol spike.
#
# Runs the FULL `forge test` suite (invariants, directed scenarios, liveness, Reactive glue, gas,
# coverage walk, assumption demo) at the DEFAULT budget from foundry.toml, on two seeds, against:
#   - the real contracts (M0): must pass on every seed;
#   - hook mutants M1..M17 (test/mutants/Mutants.sol, MUTANT=<n>): seen by the tests built on
#     the network model (the glue and gas suites build the real contracts and pass unchanged);
#   - patch mutants Y*/Z* (script/patch_mutants.py): applied to a copy of the source, so every
#     suite sees them.
# Every mutant must fail on every seed.
#
# Every run gets its own fresh failure-persistence directory, so no run can pass or fail by
# replaying a counterexample saved by an earlier run. Patch mutants run in their own copy of the
# project under cache/mutants/<stamp>/ (gitignored); src/ is never modified.
#
# For each mutant the table lists every check that failed (across both seeds) and whether any of
# them was (a) "paid out more than the owner's cap": a real over-cap payout counted by the token.
#
#   script/mutants.sh                              # everything, seeds 0x5eed and 0x1234 (30-60 min)
#   SEEDS="0x1 0x2 0x3" script/mutants.sh
#   ONLY="0 4 Y6 Z3" script/mutants.sh             # a subset
#   RUNS=512 DEPTH=300 script/mutants.sh           # a larger invariant budget
#
# Exit code 0 only if the real contracts pass and every mutant fails on every seed.
set -u
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

FORGE="${FORGE:-$(command -v forge || echo "$HOME/.foundry/bin/forge")}"
SEEDS="${SEEDS:-0x5eed 0x1234}"
PATCH_IDS="$(python3 script/patch_mutants.py list | cut -f1 | tr '\n' ' ')"
ONLY="${ONLY:-$(seq 0 17 | tr '\n' ' ') $PATCH_IDS}"
STAMP="$(date +%Y%m%d-%H%M%S)"
PERSIST_ROOT="$ROOT/cache/mutants/$STAMP"
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

# Shrinking a counterexample doesn't change whether a mutant is killed, only how long forge spends
# minimizing it; cap it so the whole run stays practical.
extra_env=("FOUNDRY_INVARIANT_SHRINK_RUN_LIMIT=${SHRINK:-50}")
budget="default (foundry.toml)"
if [ -n "${RUNS:-}" ]; then extra_env+=("FOUNDRY_INVARIANT_RUNS=$RUNS"); budget="runs=$RUNS"; fi
if [ -n "${DEPTH:-}" ]; then extra_env+=("FOUNDRY_INVARIANT_DEPTH=$DEPTH"); budget="$budget depth=${DEPTH}"; fi

echo "Suite: full forge test; invariant budget: $budget; seeds: $SEEDS"
echo "Fresh failure-persistence dirs under cache/mutants/$STAMP"
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

describe() {
  case "$1" in
    [0-9]*) echo "${NAMES[$1]}" ;;
    *) python3 script/patch_mutants.py list | awk -F'\t' -v id="$1" '$1 == id { print $2 }' ;;
  esac
}

printf "%-4s %-74s %-10s %-10s %-6s %s\n" "id" "variant" "seed1" "seed2" "over?" "failing checks (union over seeds)"
bad=0
for m in $ONLY; do
  results=(); checks=""; over=0
  dir="$ROOT"; mutant_env="MUTANT=0"
  case "$m" in
    [0-9]*) mutant_env="MUTANT=$m" ;;
    *)
      dir="$PERSIST_ROOT/$m/proj"
      mkdir -p "$dir"
      cp -R "$ROOT/src" "$ROOT/test" "$ROOT/foundry.toml" "$ROOT/remappings.txt" "$dir/"
      ln -s "$ROOT/lib" "$dir/lib"
      if ! python3 script/patch_mutants.py apply "$m" "$dir"; then
        printf "%-4s %-74s %s\n" "$m" "$(describe "$m")" "PATCH DOES NOT APPLY"
        bad=1
        continue
      fi
      ;;
  esac
  for seed in $SEEDS; do
    pdir="$PERSIST_ROOT/$m-$seed"
    mkdir -p "$pdir"
    out=$(cd "$dir" && env "$mutant_env" FOUNDRY_INVARIANT_FAILURE_PERSIST_DIR="$pdir" "${extra_env[@]}" \
          "$FORGE" test --fuzz-seed "$seed" --json 2>/dev/null)
    read -r nfail o list <<<"$(printf "%s" "$out" | summarize)"
    if [ "$o" = "1" ]; then over=1; fi
    if [ "$m" = "0" ]; then
      if [ "$nfail" = "0" ]; then results+=("PASS"); else results+=("FAIL($nfail)"); bad=1; fi
    else
      if [ "$nfail" -gt 0 ] 2>/dev/null; then results+=("KILLED($nfail)"); else results+=("SURVIVED"); bad=1; fi
    fi
    [ "$list" != "-" ] && checks="$checks;$list"
  done
  uniq=$(printf "%s" "$checks" | tr ';' '\n' | sed '/^$/d' | sort -u | paste -sd ';' - | sed 's/;/; /g')
  if [ "$m" = "0" ]; then ov="-"; elif [ $over -eq 1 ]; then ov="YES"; else ov="no"; fi
  label="$m"; case "$m" in [0-9]*) label="M$m" ;; esac
  printf "%-4s %-74s %-10s %-10s %-6s %s\n" "$label" "$(describe "$m")" "${results[0]:-}" "${results[1]:-}" "$ov" "${uniq:--}"
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
