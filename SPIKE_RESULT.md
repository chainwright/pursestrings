# Week-1 gate, part 1: protocol spike result (05.11.2026, revised after three rounds of judge reviews)

**Verdict: gate part 1 passes, with gaps.** The production Solidity for the coordinator and wallets passed 6 invariants under our own fault model of the network: reorder, drop, duplicate, delay, partitions, dead chains, and reorgs, both instant and on branches that stay readable for up to just under the chain's confirmation wait. It also passed 25 deterministic scenarios, one or more per rule (`test/Directed.t.sol`), and 6 production-timing tests (`test/ProductionTiming.t.sol`). The mutation gate now runs the full `forge test` suite. All 36 deliberate rule breaks (17 hook mutants, 19 source-patch mutants) are caught at the default budget on 2 seeds. 12 lead to a real over-cap payout: 6 shown by the fuzz invariant on its own, 1 more by the seeded coverage walk, 5 only by a scenario written for that rule. The gaps:
- There is no per-chain block clock (the model has one clock).
- There is no API fake-event test.
- The Reactive adapter runs end to end with a mock system contract, but it is not fuzzed: the fuzz still feeds the core through the test's own decoder.
- Nothing has run on a live network.
- Safety rests on every chain's reorgs being shallower than its confirmation wait.

What this spike is not: a deployment. There are no keys, no network transactions, and no measured latency or cost. The fuzz is our model of Reactive, not Reactive itself.

How to rerun: `forge build && forge test` (default profile, about 30 s), then `script/mutants.sh` (30–60 min depending on the machine). For the larger coverage walk: `WALK_STEPS=40000 forge test --match-contract PursestringsCoverageWalk -vv`.

## What was built

| File | Role |
|---|---|
| `src/BudgetCore.sol` | The rule as it runs on Lasna. It keeps per-day books, `pool[d] + Σ held[d][chain] == capOfDay[d]`, plus the waiting list (with a TTL), reclaims with timeouts, a per-chain floor, STOP epochs, pending credits that wait for confirmation, per-chain timing (wait, timeouts, want TTL), at most one unanswered grant per chain, and a Cron-driven heartbeat to every chain. Work per call is bounded (see "Production fixes"). It emits intents through `_send`/`_dispatch` and never calls a chain. |
| `src/SpendWallet.sol` | One wallet per chain. It keeps balance-backed day buckets (today and tomorrow). `pay()` is the only outflow; there is no generic call and no approve. It also has per-call caps, a payee allowlist, id dedup, tombstones, a local freeze on press (re-announced while unacknowledged: on a refused payment, on any coordinator heartbeat or epoch message, or by anyone through `reannounce()`), the midnight sweep, and a `verify()` that re-reads stored facts. Returns to the vault are accounting first and best-effort transfers after. |
| `src/Vault.sol`, `src/SafeTransfer.sol` | Owner funds on the same chain. `release` moves the exact amount or nothing. Every transfer result is checked explicitly, and tokens that return nothing (USDT-style) are accepted. |
| `src/OwnerConsole.sol` | Home-chain config events: cap changes, and an unstop that names the epoch it lifts. |
| `src/reactive/*` | `PursestringsReactive` handles subscriptions (wallet events, console, Cron1000), `react(LogRecord)` routing and `requestCallbackV_1_0`. `CallbackFront` accepts only the proxy plus our RC id, forwards only five selectors, and refuses when no wallet is bound. `Payer` provides `pay`/`coverDebt`/`receive` for both. `TestnetConfig` holds the chain numbers. The interfaces are a local mirror of reactive-lib-omni; none of this has run against the real system contract. |
| `test/harness/NetworkHandler.sol` | The network model and the ghosts (details below). |
| `test/Directed.t.sol` | One deterministic scenario per rule, on the same model and ghosts. |
| `test/ReactiveGlue.t.sol`, `test/Gas.t.sol` | The adapter end to end with a mock system contract, and the gas measurements. |
| `test/mutants/Mutants.sol`, `script/patch_mutants.py`, `script/mutants.sh` | The 17 hook mutants, 19 source-patch mutants, and the runner (full suite, 2 seeds). |
| `test/ProductionTiming.t.sol` | The production timing values on the model with Cron every 17 min: lost STOP time-to-freeze, one test per timeout relation, revival after an outage, two short chains in one cycle. |

## The network model (ours, not Reactive's)

One queue holds messages in both directions: core→wallet callbacks, and wallet/console→core origin logs. The fuzzer can do any of the following, in any order:
- deliver messages in order (batches of 1–16) or one at random (reorder);
- drop, duplicate, or replay a message that was already delivered;
- hold a message back and release it much later;
- cut off a destination chain for 1–30 minutes. Callbacks created during the cut are held (up to 64) and come back later, out of order;
- kill a destination chain for 1–6 hours: every callback to it is lost (a front in debt, a proxy down);
- **reorg a callback transaction.** It runs on a competing branch. Its events reach the coordinator at once, and its state never becomes canonical. The branch stays readable for 0 to (wait − 1) seconds of that chain's confirmation wait, and a re-read (`verify`) sent to that chain while the branch is alive is served from it half the time. The message is then re-included later or lost (50/50);
- pass time normally (1–60 s) or have an outage (1–26 h, which crosses days);
- run a Cron tick, let the agent pay on any chain, STOP on any chain, unstop, change the cap (12/20/30 USD), or withdraw and refill a vault;
- **heal** now and then: release everything held, end partitions, dead chains and branches, and then for 40 rounds deliver everything, let 5 minutes pass, tick, and let every agent retry, **except the agent on the chain where the owner last pressed STOP, which stays idle**. Then invariant (s) is checked.

Model time is compressed: confirmation waits are 60/90/180 s on the three chains, reclaim timeout = wait + 4 min, want TTL 10 min, heartbeat 30 min, ticks every 1–5 min. The ratios match production (reorg window < wait < reclaim timeout ≤ want TTL), and so does heartbeat vs tick cadence (a beat is due long after every tick). Production values are in `TestnetConfig` (waits 16/30 min, heartbeat 40 min, below). `test/ProductionTiming.t.sol` and a separate liveness run use the production values with Cron every 17 min (see (d)).

## Invariants

| # | Statement | How it's measured |
|---|---|---|
| (a) | Per day, total outflow across all wallets ≤ the **owner's cap for that day**, and the coordinator's day cap equals it exactly. A cap decrease takes effect from a day not yet opened; a raise applies to open days. | Outflows are counted by the token (a test ERC-20 in Foundry that records every transfer out of a wallet except to its own vault, bucketed by day), not by the wallet's counter. The bound comes from the test's own record: what the owner set (by console nonce), which of those messages reached the coordinator, and when each day opened. It doesn't come from the coordinator and isn't "the highest cap ever". |
| (b) | Once STOP is in effect on a chain, nothing leaves it. After an epoch change nothing is paid from older-epoch allowance, and none stays spendable. | Ghost state built from the messages the network delivered, plus real outflows. |
| (s) | **The owner's STOP, end to end.** After the network heals for a bounded time (40 × 5 min = 3h20m of model time, above the longest retry backoff of 2h40m), every wallet is on the coordinator's epoch. If the owner's last action was STOP (pressed after the last unstop click), the coordinator and every chain are frozen and no payment succeeds anywhere, even with the pressing chain's agent idle. One-directional: it checks that a STOP holds, not that an unstop takes effect. | Ghost of the owner's actions (order of presses and unstop clicks), then real wallet state and real payment attempts. |
| (e) | Per-chain lemma: wallet allowance for today/tomorrow ≤ the coordinator's `held` for that chain. Summed over chains, this gives (a). | Wallet vs coordinator. It catches over-credit long before an agent has overspent. |
| — | Token conservation in every wallet: balance == unspent allowance + tokens owed back to the vault (`stranded`). | Wallet vs token, exact. Catches unbacked allowance and forgotten returns alike. |
| (c) | Books conserve: `pool + Σ held == cap`. | A sanity check, not evidence of safety: it follows from the code's own arithmetic, and no mutant has ever failed it. |
| (d) | Liveness-lite (separate fuzz). After a 60-step warm-up with reorder and duplicates, with in-order delivery and Cron ticks every minute and no drops, reorgs, STOP or cap changes, a retrying short chain is never refused for 6 straight 5-minute rounds while budget was available. This holds with the model's compressed waits (1–3 min). Two more variants: **with chain 2 dead** for the whole measured period (the others must not starve, and the dead chain may absorb at most one more grant), and **with production timing** (waits 30/30/16 min, reclaim/want TTL 40/40/26 min, Cron every 17 min, agents retrying every 5 min; bound 20 rounds). | Compressed: bound 6 = want TTL 2 + reclaim with confirmation 1 + retry 1 + boundary 1 + 1 spare. Production: bound 20 = want TTL 8 + reclaim on the next react 1 + wait 6 + re-read 1 + grant 1 + retry 1 + boundary 1 + 1 spare. The derivation assumes one confirmation cycle serves every short chain, which was false until round 4 (see Results). |

## Results

- **Default `forge test`:** 62 tests pass in about 30 s. The 6 invariants run 128 runs × depth 150 = 19,200 calls each.
- **Liveness, compressed timing:** passes 256 runs in `forge test` and 3,000 runs (`--fuzz-runs 3000`), both with all chains alive and with chain 2 dead.
  - Over 400 seeds (`LivenessStats`), 388 had a short chain. The longest refused streak with budget available was **2 rounds**: served after 1 round 100 times and after 2 rounds once.
  - 117 of 951 retries with budget available were still refused. That is the anti-ping-pong rule at work.
- **Liveness, production timing:** derived bound 20 rounds (100 min); the in-suite fuzz is pinned to 64 runs, the 120-seed stats in the suite show a worst of 7.
  - **The tail is longer than the small sample shows.** On the round-3 code, the judge measured a worst of 19 rounds (95 min) over 1,600 seeds (10,000–11,599). We then found **31 rounds (155 min), above the bound**, on seeds 0–1,599 (seeds 197 and 1,576). The cause: one open reclaim per donor, sized to the first short chain's want. The confirmed return could then be served to the *other* short chain, which waited another 30-min confirmation cycle.
  - **Fixed in round 4:** a donor is asked for everything the short chains are owed. Worst streak now **13 rounds (65 min) over 3,200 seeds** (0–1,599 and the judge's 10,000–11,599): 1,021 + 978 seeds never waited, and 2 + 1 seeds waited 13 rounds. `LIVENESS_SEEDS=1600 forge test --match-test test_livenessStatsProductionTiming -vv` reproduces the first half. `test_twoShortChainsServedInOneConfirmationCycle` pins it (60 min; the old sizing took 95).
  - As a product number: the donor path at production timing takes up to about an hour in this model. It is still our model, not a measurement on Reactive.
- **Production timing, `test/ProductionTiming.t.sol`:**
  - A **lost STOP press with the pressing chain's agent idle** reaches the coordinator and every chain within **55 min worst**, across every pressing chain × 6 start offsets × (other agents paying $1 every 5 min, or nobody active at all). Asserted ≤ 60 min. Meanwhile the other agents could spend what they already held or were granted: in the active case, **up to the day's remaining allowance ($20 of $20 here)**. Within the cap, but that is what a lost STOP costs.
  - A lost grant is cancelled and its chain served again after 15 min.
  - A chain back from a 4 h outage is served within 10 min (the backoff resets on any event from it).
  - A late reclaim isn't closed before its timeout, and an asking chain is no donor during its want TTL.
- **Coverage from a seeded 40,000-step walk** (all faults on, with a heal every 500 steps; every safety rule is checked at the end, and it passes):
  - 207 days crossed; 2,154 payments succeeded and 12,055 were refused (most refusals are deliberate: frozen, short, or retries during heals).
  - 108 reorgs, all on branches that lived; 57 re-reads were served from a live branch.
  - 1,072 messages lost (drops plus callbacks to dead chains), 2,971 duplicates, 364 replays, 350 hold-backs, 342 partitions.
  - 183 STOPs and 166 unstops. 80 heals, 28 of them with the owner's STOP in force (and the pressing chain's agent idle).
  - 330 cap changes, 90 vault withdrawals.
  - 2,188 grants, 194 reclaims, 361 cancels, 889 voided grants, 1,273 confirmed credits.
  - 51 stale-epoch grants were delivered, 20 to unfrozen wallets, and 2 of those were fresh (the rule-6-only path).
  - The queue peaked at 71.

## Mutants (`script/mutants.sh`: full `forge test`, default budget, seeds 0x5eed and 0x1234, fresh failure-persistence dir per run)

Three kinds of deliberate breaks:
- **M1–M17** are virtual hooks or overrides in `test/mutants/Mutants.sol`, selected with `MUTANT=<n>`. Only the tests built on the network model see them.
- **Y\*/Z\*/W\*** are source patches (`script/patch_mutants.py`) applied to a copy of the project, so every suite sees them:
  - Y\* are the round-2 judge's mutants that survived the old runner;
  - Z\* break the round-3 fixes;
  - W\* are the round-3 judge's survivors (W2, W9, W10, W12) plus the round-4 fixes (W14, W15).
- A patch that no longer matches its source exactly fails the run instead of silently becoming a no-op. This happened once in this round: Z1's patch was stale after the heartbeat rewrite. The full run reported NOT OK; Z1 was rerun with the corrected patch (`ONLY="0 Z1"`) and killed on both seeds. Every other row is from the full run.

The runner runs the **full suite** for each mutant. "Over cap?" is yes if any failing check was (a) "paid out more than the owner's cap", meaning the token counted a real over-cap payout. The "found by" column says which check showed it:
- "fuzz invariant": invariant (a) on its own;
- "seeded walk": the fixed-seed coverage walk with all faults on;
- "scenario": only a directed scenario written for that rule.

| id | Broken on purpose | seed 0x5eed / 0x1234 | Fuzz invariants that failed | Other checks that failed | Over cap? (found by) |
|---|---|---|---|---|---|
| M0 | real contracts | PASS / PASS | — | — | — |
| M1 | wallet: no dedup of coordinator messages (rule 4) | KILLED(5) / KILLED(5) | (a), (b), (e) | `coverageWalk`, `rule4_duplicateGrantAppliesOnce` | YES (fuzz invariant) |
| M2 | core: credit a reclaim when it is sent (rule 2) | KILLED(11) / KILLED(11) | (a), (e) | `coverageWalk`, `lostStopReachesEveryChainWithinAnHour`, `reclaimWithPendingReturnDoesNotTimeOut`, `rule2_noReReadBeforeTheWait`, `rule2_orphanedReclaimNotCredited`, `rule2_reReadOfAYoungFactIsNotCredited`, `rule2_reclaimNotCreditedWhenSent`, `rule2_slowChainUsesItsOwnWait`, `rule3_reclaimTakesOnlyUnspent` | YES (fuzz invariant) |
| M3 | wallet: reclaim counts spent allowance (rule 3) | KILLED(3) / KILLED(3) | (a) | `coverageWalk`, `rule3_reclaimTakesOnlyUnspent` | YES (fuzz invariant) |
| M4 | wallet: ignore the epoch on grants (rule 6) | KILLED(2) / KILLED(1) | (b) | `rule6_staleGrantAfterStopUnstop` | no |
| M5 | wallet: ignore the day number on grants | KILLED(3) / KILLED(3) | (a), (e) | `dayKeyedAllowance_pregrantNotSpendableToday` | YES (fuzz invariant) |
| M6 | core: refund a cancel when it is sent (rule 5) | KILLED(4) / KILLED(4) | (a), (e) | `coverageWalk`, `rule5_cancelRefundedOnlyAfterConfirmedUnapplied` | YES (fuzz invariant) |
| M7 | core: credit returns at head, no wait/re-read (rule 2) | KILLED(7) / KILLED(8) | (s) | `coverageWalk`, `reclaimWithPendingReturnDoesNotTimeOut`, `rule2_noReReadBeforeTheWait`, `rule2_orphanedReclaimNotCredited`, `rule2_reReadOfAYoungFactIsNotCredited`, `rule2_slowChainUsesItsOwnWait`, `stop_orphanedEpochAckIsNotTrusted` | YES (seeded walk) |
| M8 | core: no dedup of credits (rule 4) | KILLED(1) / KILLED(1) | — | `rule4_replayedReturnCreditedOnce` | YES (scenario) |
| M9 | wallet: pressing chain does not freeze locally (STOP) | KILLED(3) / KILLED(3) | (b) | `coverageWalk`, `stop_pressingChainFreezesAtOnce` | no |
| M10 | core: wait, then credit without re-reading the fact | KILLED(6) / KILLED(7) | (s) | `reclaimWithPendingReturnDoesNotTimeOut`, `rule2_noReReadBeforeTheWait`, `rule2_orphanedReclaimNotCredited`, `rule2_reReadOfAYoungFactIsNotCredited`, `rule2_slowChainUsesItsOwnWait`, `stop_orphanedEpochAckIsNotTrusted` | YES (scenario) |
| M11 | wallet: credit allowance although the vault transfer failed | KILLED(3) / KILLED(3) | backing | `coverageWalk`, `unfundedGrantDoesNotApply` | no |
| M12 | core: grant sent before the reserve is debited (rule 1) | KILLED(10) / KILLED(10) | (a), (e) | `coverageWalk`, `dayKeyedAllowance_pregrantNotSpendableToday`, `ownerCap_staleCapChangeIsIgnored`, `rule1_reserveDebitedBeforeGrantIsSent`, `rule3_reclaimTakesOnlyUnspent`, `rule4_replayedReturnCreditedOnce`, `rule5_cancelRefundedOnlyAfterConfirmedUnapplied`, `twoShortChainsServedInOneConfirmationCycle` | YES (fuzz invariant) |
| M13 | core: STOP never propagated to other chains (X1) | KILLED(10) / KILLED(10) | (s) | `coverageWalk`, `lostStopReachesEveryChainWithinAnHour`, `stop_delayedUnstopDoesNotLiftALaterStop`, `stop_lostPressIdleAgentOnPressingChain`, `stop_lostPressIsReannounced`, `stop_orphanedEpochAckIsNotTrusted`, `stop_pressOvertakingAnEarlierUnstopStays`, `stop_reachesEveryChain`, `stop_staleUnfreezeMessageIsIgnored` | no |
| M14 | core: unstop ignores the epoch it names (X2) | KILLED(2) / KILLED(2) | — | `stop_delayedUnstopDoesNotLiftALaterStop`, `stop_pressOvertakingAnEarlierUnstopStays` | no |
| M15 | core: re-read credited without the age check (X3) | KILLED(2) / KILLED(2) | — | `rule2_reReadOfAYoungFactIsNotCredited`, `rule2_slowChainUsesItsOwnWait` | YES (scenario) |
| M16 | core: re-read asked without the core-side wait (X11) | KILLED(3) / KILLED(3) | — | `rule2_noReReadBeforeTheWait`, `rule2_slowChainUsesItsOwnWait`, `twoShortChainsServedInOneConfirmationCycle` | no |
| M17 | core: stale cap message re-applied (X9) | KILLED(1) / KILLED(1) | — | `ownerCap_staleCapChangeIsIgnored` | YES (scenario) |
| Y3 | core: re-read cursor never advances (bounded work doesn't carry over) | KILLED(2) / KILLED(2) | — | `everyRouteEndToEnd`, `retryListsCarryOverAcrossTicks` | no |
| Y4 | core: cancel cursor never advances (bounded work doesn't carry over) | KILLED(1) / KILLED(1) | — | `retryListsCarryOverAcrossTicks` | no |
| Y5 | wallet: return to the vault reverts on failure (freeze tied to the transfer) | KILLED(1) / KILLED(1) | — | `freezeDoesNotDependOnTheTransfer` | no |
| Y6 | core: every chain uses chain 0's (shortest) confirmation wait | KILLED(2) / KILLED(2) | — | `everyRouteEndToEnd`, `rule2_slowChainUsesItsOwnWait` | YES (scenario) |
| Y8 | wallet: applies epoch messages older than its own epoch | KILLED(1) / KILLED(1) | — | `stop_staleUnfreezeMessageIsIgnored` | no |
| Y11 | wallet: forgets stranded tokens even when the return failed | KILLED(1) / KILLED(1) | — | `freezeDoesNotDependOnTheTransfer` | no |
| Y12 | wallet: accepts a short delivery from the vault (fee-on-transfer guard off) | KILLED(1) / KILLED(1) | — | `shortDeliveryCreatesNoAllowance` | no |
| Y13 | front: drops the reactive-contract id check | KILLED(1) / KILLED(1) | — | `frontRejectsWrongSenderWrongRcForeignSelectorsAndUnbound` | no |
| Y14 | core: epoch ack trusted at head, without the re-read | KILLED(2) / KILLED(3) | (s) | `everyRouteEndToEnd`, `stop_orphanedEpochAckIsNotTrusted` | no |
| Z1 | core: no heartbeat (a lost STOP waits for the pressing chain's agent) | KILLED(2) / KILLED(2) | — | `lostStopReachesEveryChainWithinAnHour`, `stop_lostPressIdleAgentOnPressingChain` | no |
| Z2 | wallet: a re-read doesn't re-announce an unacknowledged press | KILLED(3) / KILLED(3) | — | `lostStopReachesEveryChainWithinAnHour`, `stop_lostPressIdleAgentOnPressingChain`, `stop_lostPressIsReannounced` | no |
| Z3 | core: no limit of one unanswered grant per chain | KILLED(4) / KILLED(4) | — | `deadChainAbsorbsAtMostOneGrant`, `gas_reactWorstCaseIsBounded`, `liveness_othersServedWhileOneChainIsDead(uint256)`, `oneUnansweredGrantPerChain` | no |
| Z4 | core: a reclaim can time out while its return is pending | KILLED(1) / KILLED(1) | — | `reclaimWithPendingReturnDoesNotTimeOut` | no |
| W2 | core: heartbeat 3x slower than configured | KILLED(1) / KILLED(1) | — | `lostStopReachesEveryChainWithinAnHour` | no |
| W9 | config: production reclaim timeout = wait / 2 | KILLED(1) / KILLED(1) | — | `lateReclaimIsNotClosedBeforeItsTimeout` | no |
| W10 | config: production want TTL 10 min | KILLED(1) / KILLED(1) | — | `askingChainIsNoDonorDuringItsWantTtl` | no |
| W12 | config: production grant timeout 10 h | KILLED(3) / KILLED(3) | — | `everyRouteEndToEnd`, `lostGrantIsCancelledAndTheChainServedAgain`, `revivedChainIsServedPromptly` | no |
| W14 | core: no backoff reset when a chain shows it is alive | KILLED(1) / KILLED(1) | — | `revivedChainIsServedPromptly` | no |
| W15 | core: a reclaim is sized to the first short chain's want only (old sizing) | KILLED(1) / KILLED(1) | — | `twoShortChainsServedInOneConfirmationCycle` | no |

Reading the table:
- **All 36 deliberate rule breaks are caught at the default budget on 2 seeds.**
- **12 lead to a real over-cap payout:**
  - 6 shown by the fuzz invariant on its own: M1, M2, M3, M5, M6, M12;
  - 1 more by the seeded walk: M7;
  - 5 only by a targeted scenario: M8, M10, M15, M17, Y6.
- **The other 24 are caught by the checks for their own rule and don't overspend:**
  - STOP/epoch rules: M4, M9, M13, M14, Y8, Y14, Z1, Z2, W2;
  - token backing: M11, Y5, Y11, Y12 (the token itself refuses to overspend);
  - the adapter's sender check: Y13;
  - carry-over of bounded work: Y3, Y4;
  - availability and production timing: Z3, Z4, W9, W10, W12, W14, W15;
  - a cost rule: M16. The age check alone keeps credits safe.
- **Many kills come only from a directed or production-timing scenario** at the default fuzz budget. Fuzz kills near the budget edge vary between runs: the per-seed counts are from this run and are not bit-for-bit reproducible. Kill/survive and over-cap status were stable in the judges' reruns.
- **Every directed scenario was written knowing which mutant it targets.** A kill therefore shows the rule is needed; it is not independent discovery.
- Full run: 33 min here (36 variants plus the real contracts × 2 seeds × full suite). Expect 30–60 min depending on the machine. Kept in `cache/mutants/<stamp>/`, which is gitignored.

## Production fixes after review

| Finding | Fix | Evidence |
|---|---|---|
| STOP: an unstop clicked before a later STOP could lift it, if the STOP's log overtook the unstop. Found while adding (s); shown by `test_stop_pressOvertakingAnEarlierUnstopStays`, which fails on the old rule. (The fuzz invariant (s) alone does not reproduce it at the default budget.) | Every strictly newer press opens a new frozen epoch, even when the system is already frozen. An unstop lifts only the epoch it names. | `test_stop_pressOvertakingAnEarlierUnstopStays`; fails on the old code. |
| F6: a duplicate or replayed StopPressed re-froze after an unstop. | Only a strictly newer press mark acts. | `test_stop_replayedPressDoesNotRefreeze`; fails on the old code. |
| A lost StopPressed log was never resent, so other chains kept running. | The pressing wallet re-announces an unacknowledged press (at most every 300 s). **Round 3 (R2-1):** this no longer depends on the pressing chain's agent paying. It also happens on any coordinator epoch message or re-read, and anyone can call `reannounce()`. The coordinator sends each chain a heartbeat re-read once 40 min have passed since its last one, on the next react (model: 30 min). With Cron every ~17 min that is within 57 min, so a lost press comes back even if nothing happens on that chain. (In round 3 the beat was round-robin at heartbeat/3 intervals, which with Cron alone reached each chain only every ~100 min; fixed in round 4, W2 pins it.) | `test_stop_lostPressIsReannounced`; the judge's `test_stop_lostPressIdleAgentOnPressingChain` (fails with the heartbeat off, Z1, or without the re-read echo, Z2); `test_stop_anyoneCanReannounceAnUnacknowledgedPress`; (s) now runs with the pressing chain's agent idle; `test_lostStopReachesEveryChainWithinAnHour` at production timing (worst 55 min). |
| F2: no Cron. | The RC subscribes to Cron1000 on Lasna (`block.chainid`, `0x…fffFfF`), about every 17 min (~78 ticks a day). A tick measures up to 484k gas in our heaviest case, so roughly 1–5 lREACT a day by the documented fee formula, plus the heartbeats (about 3 callbacks and 3 reactive txs per ~51 min in an idle system). Unmeasured. A tick runs the same bounded loop: epoch resends, re-reads, cancels, reclaim timeouts, day opening, pre-grants, serving. | `test_cronTickDrivesPregrants`, `test_cronFromOtherTopicOrChainIgnored`. |
| F1: unbounded `react()`. | Per call: at most `MAX_SENDS` = 4 callback requests and `SCAN` = 4 entries of each retry list, with rotating cursors; the rest carries to the next tick. STOP/unstop messages go first, every chain gets its epoch message in the same call (at most 4 chains), and a call that sends epoch messages does nothing else. Re-reads, cancels and heartbeats leave one send for serving, and re-reads take at most 2 per call (R2-4). | `test_gas_reactWorstCaseIsBounded`: heaviest of the measured cases **510k gas** (a Short late in the day; the STOP call is 420k, Cron 484k), identical at 32 and 400 entries per list. In the stuffed state every chain has an unanswered grant, so a call with one grant plus reclaims plus re-reads up to 4 sends isn't measured; that would add roughly one more stand-in request (~50–60k). That is under Reactive's 900k cap with ~43% margin (our test asserts ≤ 600k), measured in Foundry with a guessed system-contract cost (~53k per callback request: the event plus two fresh storage writes), not in the ReactVM. `test_retryListsCarryOverAcrossTicks`: 12 due cancels and 12 due re-reads are all serviced within 19 Cron ticks (Y3, Y4). |
| F3: callback gas 300k fixed. | Gas limit per chain. Measured cold through the front with the test token, worst wallet entry: **221k** (applyGrant after sweeping 2 past buckets into a new epoch). Others: applyGrant with 2 buckets drained 205k, applyEpoch freeze 141k/137k, applyReclaim 104k, applyCancel 86k, verify 15k. Allowance for USDC: +15k per token call × 5 (unmeasured, deliberately generous), then ×1.5, giving 444k. Proxy overhead (DOCS_BRIEF): extraGas + maxChargeGas = 130k on the L2s and 200k on Sepolia. Limits: **700k on every chain** (needed: 574k L2, 644k Sepolia). Round 4 raised the L2s from 600k, which was only 4.5% headroom over an unmeasured USDC estimate. Headroom is now 22% (L2) and 8.7% (Sepolia) over the estimate; measure USDC on the live loop before trusting either. | `test_gas_callbackLimitCoversWorstWalletEntry`; `test_gas_worstEntriesRunWithinTheCallbackBudget` runs the freeze path (not the 221k grant path) within (700k − 130k). Per the docs, fees are billed on gas used, so the headroom should cost nothing unless used (to confirm on the live loop). |
| F5: the freeze depended on a token transfer. | `applyEpoch` writes epoch and frozen first. Every return to the vault is accounting first (`stranded`), followed by a best-effort transfer: gas-capped, never reverting, retried on the next message or by anyone via `flush()`. Sweeps work the same way, so a failing sweep no longer blocks inbound messages. | `test_freezeDoesNotDependOnTheTransfer`: with transfers to the vault blocked, the wallet still freezes, drops its allowance and refuses payment; a later flush returns the tokens. It is in the gated suite and kills Y5 and Y11. |
| F9: confirmation wait 60 s, below Sepolia finality, and untested. | Per-chain waits. **Sepolia 16 min** (finality is 2 epochs = 12.8 min). **Base Sepolia and Unichain Sepolia 30 min:** a typical time to L2 finality, not a guaranteed bound. A stalled batcher can leave L2 blocks unsafe for longer, so safety on the L2s assumes a healthy sequencer and batcher until Reactive says it delivers only finalized logs. Delayed reorgs are in the model, and both halves of the confirmation rule have mutants. | Invariants plus `test_rule2_reReadOfAYoungFactIsNotCredited`. **Round 3:** `test_rule2_slowChainUsesItsOwnWait` runs the same attack on chain 2 (the slowest chain) with a branch that outlives chain 0's wait but not chain 2's. Y6 (every chain on the shortest wait) overspends there. `test_everyRouteEndToEnd` shows a Sepolia ack credited after its wait while a Base ack is still waiting. |
| F4: no fee settlement. | `Payer` (the AbstractPayer pattern): `pay(amount)` callable only by the vendor (the system contract for the RC, the proxy for a front), `coverDebt()` callable by anyone, and `receive()`. The front also has an owner `withdrawFees`. Funding is described in the README. | `test_feesOnlyTheVendorCollects_andAnyoneCanCoverDebt`. |
| F10 (Low) | The front refuses when no wallet is bound. | `test_frontRejectsWrongSenderWrongRcForeignSelectorsAndUnbound`. |
| F11 (Low) | A reclaim records and reports exactly the allowance it gave up, which is what goes to the vault. M3 now breaks rule 3 directly (spent allowance counted as reclaimable). | M3 row above. |
| F12 (Low) | Explicit transfer-result checks (`SafeTransfer`; tokens returning nothing are accepted). A grant measures the wallet's own balance delta, so a token that delivers less creates no unbacked allowance. | `test_shortDeliveryCreatesNoAllowance` (fee-on-transfer mode in the test token), in the gated suite; kills Y12. |
| R2-2: a dead destination absorbed the whole day's budget (each new Short got a new grant that could never be cancelled). | At most one unanswered grant per chain. A chain whose grant the wallet hasn't answered (applied, not applied or cancel ack) is neither served nor pre-granted. The global 32-grant cap is gone. | The judge's scenario `test_deadChainAbsorbsAtMostOneGrant`: dead chain 2 now holds ≤ one grant, against $20 before, and chain 0 is served. `test_oneUnansweredGrantPerChain` on the real adapter. The liveness fuzz with chain 2 dead. Z3 removes the rule and dies. |
| Production timeouts were unset; with a 30-min wait, a 5-min reclaim timeout closed reclaims whose return was still pending. | Every timing parameter is per chain. `TestnetConfig.chainParams(wait)`: grant 10 min, re-read 5 min, reclaim timeout and want TTL = wait + 10 min (Sepolia 26, L2s 40 min). A reclaim whose return is pending never times out (in code). | `test_reclaimWithPendingReturnDoesNotTimeOut` (Z4 removes the guard and dies). **Round 4, one production-timing test per relation:** `test_lateReclaimIsNotClosedBeforeItsTimeout` (W9: reclaim timeout = wait/2 dies), `test_askingChainIsNoDonorDuringItsWantTtl` (W10: want TTL 10 min dies), `test_lostGrantIsCancelledAndTheChainServedAgain` (W12: grant timeout 10 h dies). |
| A chain back from a long outage waited for its next backed-off retry (up to 32 × 10 min, observed 85 min after a 4 h outage). | Any event from a chain resets its epoch-resend tries and its in-flight grant's cancel tries. Cost: during a callback-only outage with an active agent, that one grant's cancel is retried every 10 min instead of backing off. | `test_revivedChainIsServedPromptly`: served 10 min after a 4 h outage; W14 removes the reset and dies. |
| A donor's reclaim was sized to one short chain's want, so two short chains needed two 30-min cycles, and the tail reached 31 rounds (155 min). | A donor is asked for everything the short chains are owed (each at least one serving chunk). | `test_twoShortChainsServedInOneConfirmationCycle` (60 min vs 95 before); W15 restores the old sizing and dies; 3,200-seed tail 13 rounds. |

The production adapter's routing is covered by one scripted end-to-end run (`test_everyRouteEndToEnd`: all 12 event routes plus Cron, through react(), proxy → front → wallet). The fuzz itself still feeds the core through the test's own decoder.

## What turned out wrong or underspecified in the design

1. **"Credit after a time-based wait" alone isn't safe.**
   - If Reactive delivers a log whose block is later orphaned, the coordinator never hears about the reorg (M10).
   - **Fix:** after the wait, the core asks the origin wallet to re-read the stored fact (`verify`). It credits only if the fact still holds and has existed for the full wait at the moment of the re-read, using the amount from the re-read.
   - The age check on the re-read is the safety half (M15 overspends without it). The core-side wait before asking only saves billed callbacks: without it (M16), nothing overspends, and only a cost test fails.
   - If reactivedevs confirm that delivery happens only after finality, the re-read can be dropped. **This is still the most important question for them.**
2. **Origin-side nonces can't be dedup keys under reorgs.** Every request and its answer are keyed by an id the core assigns (Lasna doesn't reorg).
3. **"Short fires once per chain per day" deadlocks a chain.** Short is now rate-limited (re-armed after 300 s) and re-armed by grants, epochs and new days.
4. **The waiting list needs a TTL** (found by the liveness fuzz).
5. **The floor doesn't stop ping-pong when every chain is short.** A chain that asked within the TTL isn't a donor, and the serve order rotates.
6. **Retries need exponential backoff** (×2 per try, up to 32×).
7. **STOP races.**
   - Unstop must name the epoch it lifts.
   - An unfreeze carries the coordinator's view of the chain's last press.
   - Epoch acks go through the re-read.
   - New in round 2: every new press opens a new frozen epoch even when already frozen, duplicates of a press are ignored, and an unacknowledged press is re-announced.
   - New in round 3: re-announcing can't depend on the agent on the pressing chain, so there is a heartbeat and a permissionless `reannounce()`.
8. **A chain must not be granted again while its last grant is unanswered**, or a dead chain absorbs the budget (R2-2).
9. **Timeouts must follow the confirmation wait.** A reclaim timeout shorter than the wait closes reclaims whose return is still pending.
10. **A donor must be asked for everything that is owed**, not for one chain's want. Otherwise short chains are served one per confirmation cycle (found by the 1,600-seed production-timing run).
11. **A heartbeat must be scheduled per chain**, not round-robin at heartbeat/3, or Cron pacing stretches it to every ~100 min.

## Simplified or not covered (honest list)

- **One clock.** Wallets bucket by their own `block.timestamp` and the core by Lasna's, but the model shares one clock. Skew near midnight isn't modelled.
- **Reorgs** are modelled for callback transactions only. Not modelled: reorgs of agent `pay`, `pressStop` or console transactions. Reorgs deeper than the wait are outside the model. `AssumptionTest` shows on purpose that such a reorg makes the coordinator over-credit.
- **The STOP bound** is "within 3h20m after the network heals" in model time. That covers the longest retry backoff; usually it is one round. With a lost press and an idle pressing agent, production relies on the heartbeat: within 55 min in our production-timing model (asserted ≤ 60 min), not measured on Reactive. Until then the other chains can spend what they hold. **The "2–30 s window" in IDEA_V3 is not measured** and must not be claimed until the live loop measures it.
- **(s) is one-directional.** It checks only that a STOP holds; it does not check that an unstop takes effect. A press logged before an unstop but delivered after it re-freezes the system. That is fail-safe, but the owner sees an unstop that "didn't take" and must click again.
- **Liveness numbers are from our model.** With compressed waits the bound is 6 rounds. With production timing it is 20 rounds (100 min), and the worst seen was 7 (35 min) in 120 seeds. Neither is measured on Reactive.
- **The K_EPOCH re-read reports when the wallet entered its current epoch** (R2-5). If STOP and unstop alternate faster than the wait, an epoch ack never becomes old enough, and epoch messages keep being resent with backoff. That costs callbacks, not safety. Not fixed.
- **A failing flush** spends up to (gas − 40k) on each attempt (R2-6). Not fixed.
- **Two surviving judge mutants are harmless by design:** W4 (no re-announce on `applyEpoch`; redundant with the echo on every re-read) and W8 (a CancelAck doesn't free the in-flight slot; the void credit frees it later, so it only adds delay). Neither is in the gate.
- **react() can still be starved** if the RC is in debt or out of reserves. That is an operations risk (keep it funded); it is not modelled.
- **Gas numbers** are measured with the test token in Foundry. The USDC allowance and the system contract's cost per callback request are assumptions.
- **Not tested here at all:**
  - fees and debt as they really behave on Reactive, InsufficientGas, and callback-failure semantics;
  - several wallets per chain and per-agent sub-caps;
  - the real x402 / ERC-1271 path from v3.1;
  - the API fake-event and used-callId tests (W2);
  - the dashboard number "X ≥ true remaining";
  - a finer local expiry per allowance (the day bucket is the only expiry, at most about 48 h);
  - the per-chain block clock from the v3.1 gate.
- **Mutant coverage gaps:** several liveness rules (Short re-arm, want TTL, rotation, floor, backoff), the sweep, the per-call cap and the payee allowlist have no mutants. Every directed scenario was written knowing which mutant it targets, so a kill shows the rule is needed; it is not independent discovery.
- **Cap decrease** applies from the next unopened day (d+1, or d+2 if tomorrow is already pre-granted). The design text's "clears tomorrow's pre-grants" isn't implemented, and the UI must say "new cap from <date>".
- **The agent and owner keys are immutable** in the wallet (F13), and the agent can steer allowance within the cap (F14). Both are known and not addressed in this round.
- **Deploy order:** the RC takes wallet and front addresses in its constructor, so a live deploy needs precomputed addresses.

## What remains for the live loop (gate part 2: Lasna ↔ Base Sepolia ↔ Unichain Sepolia)

1. Ask t.me/reactivedevs first:
   - Is a log delivered at head, safe or finalized? This sets the waits and decides whether the re-read stays.
   - Can delivery duplicate logs? Are failed callbacks retried?
   - What happens to logs whose block is orphaned?
   - What does a callback request cost inside `react()`?
2. Swap the mirror for `reactive-lib-omni` and check the LogRecord field order. Fund the RC and the fronts (README), and check the Cron subscription with `rnk_getFilters`.
3. Deploy one wallet, vault and front on each L2 and the RC on Lasna. Run 20 loops and log origin tx → reactive tx → `getCallbacks` → destination tx, with latency and cost, separately for:
   - the reserve top-up path (target median ≤ 6 s, aiming for 3);
   - the donor path, which waits the full confirmation wait (16–30 min) plus the re-read. The "≤ 6 s" claim must not be applied to it;
   - STOP from each chain to $0.00 on the others: measured median/p95. Only then may a STOP window appear in the video.
4. Measure real callback gas with USDC and re-derive the limits in `TestnetConfig`.
