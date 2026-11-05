# Week-1 gate, part 1: protocol spike result (05.11.2026, revised after two judge reviews)

**Verdict: gate part 1 passes, with gaps.** The production Solidity for the coordinator and wallets passed 6 invariants under our own fault model of the network: reorder, drop, duplicate, delay, partitions, and reorgs, both instant and on branches that stay readable for up to just under the chain's confirmation wait. It also passed 19 deterministic scenarios, one or more per rule (`test/Directed.t.sol`). All 17 deliberate rule breaks are caught at the default `forge test` budget on 2 seeds, each one also by a deterministic scenario; 11 of them produced an actual over-cap payout. The gaps:
- There is no per-chain block clock (the model has one clock).
- There is no API fake-event test.
- The Reactive adapter runs end to end with a mock system contract, but it is not fuzzed.
- Nothing has run on a live network.
- Safety rests on every chain's reorgs being shallower than its confirmation wait.

What this spike is not: a deployment. There are no keys, no network transactions, and no measured latency or cost. The fuzz is our model of Reactive, not Reactive itself.

How to rerun: `forge build && forge test` (default profile, about 25 s), then `script/mutants.sh` (about 30 minutes). For the larger coverage walk: `WALK_STEPS=40000 forge test --match-contract PursestringsCoverageWalk -vv`.

## What was built

| File | Role |
|---|---|
| `src/BudgetCore.sol` | The rule as it runs on Lasna. It keeps per-day books, `pool[d] + Σ held[d][chain] == capOfDay[d]`, plus the waiting list (with a TTL), reclaims with timeouts, a per-chain floor, STOP epochs, pending credits that wait for confirmation, and a per-chain confirmation wait. Work per call is bounded (see "Production fixes"). It emits intents through `_send`/`_dispatch` and never calls a chain. |
| `src/SpendWallet.sol` | One wallet per chain. It keeps balance-backed day buckets (today and tomorrow). `pay()` is the only outflow; there is no generic call and no approve. It also has per-call caps, a payee allowlist, id dedup, tombstones, a local freeze on press (re-announced while unacknowledged), the midnight sweep, and a `verify()` that re-reads stored facts. Returns to the vault are accounting first and best-effort transfers after. |
| `src/Vault.sol`, `src/SafeTransfer.sol` | Owner funds on the same chain. `release` moves the exact amount or nothing. Every transfer result is checked explicitly, and tokens that return nothing (USDT-style) are accepted. |
| `src/OwnerConsole.sol` | Home-chain config events: cap changes, and an unstop that names the epoch it lifts. |
| `src/reactive/*` | `PursestringsReactive` handles subscriptions (wallet events, console, Cron1000), `react(LogRecord)` routing and `requestCallbackV_1_0`. `CallbackFront` accepts only the proxy plus our RC id, forwards only five selectors, and refuses when no wallet is bound. `Payer` provides `pay`/`coverDebt`/`receive` for both. `TestnetConfig` holds the chain numbers. The interfaces are a local mirror of reactive-lib-omni; none of this has run against the real system contract. |
| `test/harness/NetworkHandler.sol` | The network model and the ghosts (details below). |
| `test/Directed.t.sol` | One deterministic scenario per rule, on the same model and ghosts. |
| `test/ReactiveGlue.t.sol`, `test/Gas.t.sol` | The adapter end to end with a mock system contract, and the gas measurements. |
| `test/mutants/Mutants.sol`, `script/mutants.sh` | The 17 mutants and the runner. |

## The network model (ours, not Reactive's)

One queue holds messages in both directions: core→wallet callbacks, and wallet/console→core origin logs. The fuzzer can do any of the following, in any order:
- deliver messages in order (batches of 1–16) or one at random (reorder);
- drop, duplicate, or replay a message that was already delivered;
- hold a message back and release it much later;
- cut off a destination chain for 1–30 minutes. Callbacks created during the cut are held (up to 64) and come back later, out of order;
- **reorg a callback transaction.** It runs on a competing branch. Its events reach the coordinator at once, and its state never becomes canonical. The branch stays readable for 0 to (wait − 1) seconds of that chain's confirmation wait, and a re-read (`verify`) sent to that chain while the branch is alive is served from it half the time. The message is then re-included later or lost (50/50);
- pass time normally (1–60 s) or have an outage (1–26 h, which crosses days);
- run a Cron tick, let the agent pay on any chain, STOP on any chain, unstop, change the cap (12/20/30 USD), or withdraw and refill a vault;
- **heal** now and then: release everything held, end partitions and branches, and then for 40 rounds deliver everything, let 5 minutes pass, tick, and let every agent retry. Then invariant (s) is checked.

Model time is compressed: confirmation waits are 60/90/180 s on the three chains (production: 16–30 min, below). What the model keeps is the relation the design rests on: every reorg is shallower than its chain's wait.

## Invariants

| # | Statement | How it's measured |
|---|---|---|
| (a) | Per day, total outflow across all wallets ≤ the **owner's cap for that day**, and the coordinator's day cap equals it exactly. A cap decrease takes effect from a day not yet opened; a raise applies to open days. | Outflows are counted by the token (a test ERC-20 in Foundry that records every transfer out of a wallet except to its own vault, bucketed by day), not by the wallet's counter. The bound comes from the test's own record: what the owner set (by console nonce), which of those messages reached the coordinator, and when each day opened. It doesn't come from the coordinator and isn't "the highest cap ever". |
| (b) | Once STOP is in effect on a chain, nothing leaves it. After an epoch change nothing is paid from older-epoch allowance, and none stays spendable. | Ghost state built from the messages the network delivered, plus real outflows. |
| (s) | **The owner's STOP, end to end.** After the network heals for a bounded time (40 × 5 min = 3h20m, above the longest retry backoff of 2h40m), every wallet is on the coordinator's epoch. If the owner's last action was STOP (pressed after the last unstop click), the coordinator and every chain are frozen and no payment succeeds anywhere. | Ghost of the owner's actions (order of presses and unstop clicks), then real wallet state and real payment attempts. |
| (e) | Per-chain lemma: wallet allowance for today/tomorrow ≤ the coordinator's `held` for that chain. Summed over chains, this gives (a). | Wallet vs coordinator. It catches over-credit long before an agent has overspent. |
| — | Allowance ≤ token balance in every wallet. | Wallet vs token. |
| (c) | Books conserve: `pool + Σ held == cap`. | A sanity check, not evidence of safety: it follows from the code's own arithmetic, and no mutant has ever failed it. |
| (d) | Liveness-lite (separate fuzz). After a 60-step warm-up with reorder and duplicates, with in-order delivery and Cron ticks every minute and no drops, reorgs, STOP or cap changes, a retrying short chain is never refused for 6 straight 5-minute rounds while budget was available. | The bound of 6 is derived from the protocol: want TTL 2 + reclaim with confirmation 1 + retry 1 + boundary 1, with 1 spare. |

## Results

- **Default `forge test`:** 44 tests pass in about 25 s. The 6 invariants run 128 runs × depth 150 = 19,200 calls each.
- **Liveness:** passes 256 runs in `forge test`, and passed 3,000 runs (`forge test --match-test testFuzz_liveness --fuzz-runs 3000`) on this code.
  - Over 400 seeds (`LivenessStats`), 386 seeds had a short chain.
  - The longest refused streak with budget available was **3 rounds**: 158 short chains were served after 1 round, 9 after 2, and 1 after 3.
  - 208 of 889 retries with budget available were still refused. That is the anti-ping-pong rule at work.
- **Coverage from a seeded 40,000-step walk** (all faults on, with a heal every 500 steps; every safety rule is checked at the end, and it passes):
  - 192 days crossed; 2,614 payments succeeded and 12,691 were refused (most refusals are deliberate: frozen, short, or retries during heals).
  - 115 reorgs, all on branches that lived 1–179 s. 41 re-reads were served from a live branch.
  - 159 drops, 2,864 duplicates, 359 replays, 367 hold-backs, 404 partitions.
  - 163 STOPs and 159 unstops. 80 heals, 20 of them with the owner's STOP in force.
  - 369 cap changes, 100 vault withdrawals.
  - 2,589 grants, 273 reclaims, 324 cancels, 1,098 voided grants, 1,526 confirmed credits.
  - 79 stale-epoch grants were delivered, 45 to unfrozen wallets, and 2 of those were fresh (the rule-6-only path).
  - The queue peaked at 66, not counting up to 64 more held back.

## Mutants (`script/mutants.sh`: default budget, seeds 0x5eed and 0x1234, fresh failure-persistence dir per run)

Each mutant breaks one rule in the real code (a virtual hook or override in `test/mutants/Mutants.sol`). The runner runs the invariant suite and the directed scenarios together. "Over cap?" is yes if any failing check was (a) "paid out more than the owner's cap", meaning the token counted a real over-cap payout.

| id | Broken on purpose | seed 0x5eed / 0x1234 | Fuzz invariants that failed | Directed scenarios that failed | Over cap? |
|---|---|---|---|---|---|
| M0 | real contracts | PASS / PASS | — | — | — |
| M1 | wallet: no dedup of coordinator messages (rule 4) | KILLED(4) / KILLED(4) | (a), (b), (e) | `rule4_duplicateGrantAppliesOnce` | YES |
| M2 | core: credit a reclaim when it is sent (rule 2) | KILLED(7) / KILLED(7) | (a), (e) | `rule2_noReReadBeforeTheWait`, `rule2_orphanedReclaimNotCredited`, `rule2_reclaimNotCreditedWhenSent`, `rule2_reReadOfAYoungFactIsNotCredited`, `rule3_reclaimTakesOnlyUnspent` | YES |
| M3 | wallet: reclaim counts spent allowance (rule 3) | KILLED(2) / KILLED(2) | (a) | `rule3_reclaimTakesOnlyUnspent` | YES |
| M4 | wallet: ignore the epoch on grants (rule 6) | KILLED(1) / KILLED(1) | — | `rule6_staleGrantAfterStopUnstop` | no |
| M5 | wallet: ignore the day number on grants | KILLED(3) / KILLED(3) | (a), (e) | `dayKeyedAllowance_pregrantNotSpendableToday` | YES |
| M6 | core: refund a cancel when it is sent (rule 5) | KILLED(3) / KILLED(3) | (a), (e) | `rule5_cancelRefundedOnlyAfterConfirmedUnapplied` | YES |
| M7 | core: credit returns at head, no wait/re-read (rule 2) | KILLED(4) / KILLED(3) | (s) | `rule2_noReReadBeforeTheWait`, `rule2_orphanedReclaimNotCredited`, `rule2_reReadOfAYoungFactIsNotCredited` | YES |
| M8 | core: no dedup of credits (rule 4) | KILLED(1) / KILLED(1) | — | `rule4_replayedReturnCreditedOnce` | YES |
| M9 | wallet: pressing chain does not freeze locally (STOP) | KILLED(4) / KILLED(3) | (b), (s) | `stop_lostPressIsReannounced`, `stop_pressingChainFreezesAtOnce` | no |
| M10 | core: wait, then credit without re-reading the fact | KILLED(4) / KILLED(3) | (e) | `rule2_noReReadBeforeTheWait`, `rule2_orphanedReclaimNotCredited`, `rule2_reReadOfAYoungFactIsNotCredited` | YES |
| M11 | wallet: credit allowance although the vault transfer failed | KILLED(2) / KILLED(2) | backing | `unfundedGrantDoesNotApply` | no |
| M12 | core: grant sent before the reserve is debited (rule 1) | KILLED(8) / KILLED(8) | (a), (e) | `dayKeyedAllowance_pregrantNotSpendableToday`, `ownerCap_staleCapChangeIsIgnored`, `rule1_reserveDebitedBeforeGrantIsSent`, `rule3_reclaimTakesOnlyUnspent`, `rule4_replayedReturnCreditedOnce`, `rule5_cancelRefundedOnlyAfterConfirmedUnapplied` | YES |
| M13 | core: STOP never propagated to other chains (X1) | KILLED(5) / KILLED(5) | (s) | `stop_delayedUnstopDoesNotLiftALaterStop`, `stop_lostPressIsReannounced`, `stop_pressOvertakingAnEarlierUnstopStays`, `stop_reachesEveryChain` | no |
| M14 | core: unstop ignores the epoch it names (X2) | KILLED(2) / KILLED(2) | — | `stop_delayedUnstopDoesNotLiftALaterStop`, `stop_pressOvertakingAnEarlierUnstopStays` | no |
| M15 | core: re-read credited without the age check (X3) | KILLED(1) / KILLED(1) | — | `rule2_reReadOfAYoungFactIsNotCredited` | YES |
| M16 | core: re-read asked without the core-side wait (X11) | KILLED(1) / KILLED(1) | — | `rule2_noReReadBeforeTheWait` | no |
| M17 | core: stale cap message re-applied (X9) | KILLED(1) / KILLED(2) | (a) | `ownerCap_staleCapChangeIsIgnored` | YES |

Reading the table:
- **11 of 17 mutants produced a real over-cap payout:** M1, M2, M3, M5, M6, M7, M8, M10, M12, M15, M17.
- **The other 6 are caught by the checks for their own rule and don't overspend:**
  - M4 and M9 break STOP/epoch rules (b);
  - M11 breaks token backing (the token refuses to overspend);
  - M13 and M14 break the owner-level STOP property (s): payments continue, or resume, after the owner's STOP, but within the cap;
  - M16 is a cost rule. Without the core-side wait the coordinator asks for re-reads it can't use yet, but the age check alone keeps credits safe.
- **5 mutants are caught only by their directed scenario at the default fuzz budget:** M4, M8, M14, M15, M16. The fuzz alone doesn't reach their timing in 128 × 150 calls. This is why every rule has a deterministic scenario.
- **M7's fuzz kill is through (s), not (a).** Its over-cap kill comes from the directed scenario.
- The six mutants added in this round correspond to the judges' findings: M12 is rule 1, and M13–M17 are X1, X2, X3, X11 and X9.
- M10 was fixed during this run. It used to remove entries from the pending list while the (now bounded) coordinator loop was scanning that list, which made every tick revert instead of crediting without a re-read. The M10 row is from a rerun after that fix (`ONLY="0 10" script/mutants.sh`); the other rows are from the full run.
- Full run: 31.5 min. Kept in `cache/mutants/<stamp>/`, which is gitignored; rerun with `script/mutants.sh`.


## Production fixes after review

| Finding | Fix | Evidence |
|---|---|---|
| STOP: an unstop clicked before a later STOP could lift it, if the STOP's log overtook the unstop. Found by the new invariant (s) on the old code at the default budget. | Every strictly newer press opens a new frozen epoch, even when the system is already frozen. An unstop lifts only the epoch it names. | `test_stop_pressOvertakingAnEarlierUnstopStays`; fails on the old code. |
| F6: a duplicate or replayed StopPressed re-froze after an unstop. | Only a strictly newer press mark acts. | `test_stop_replayedPressDoesNotRefreeze`; fails on the old code. |
| A lost StopPressed log was never resent, so other chains kept running. | The pressing wallet re-announces an unacknowledged press when its agent is refused (at most every 300 s). | `test_stop_lostPressIsReannounced`; fails without it. |
| F2: no Cron. | The RC subscribes to Cron1000 on Lasna (`block.chainid`, `0x…fffFfF`), about every 18 min, roughly 78 ticks and 1–2.3 lREACT a day (DOCS_BRIEF §5). A tick runs the same bounded loop: epoch resends, re-reads, cancels, reclaim timeouts, day opening, pre-grants, serving. | `test_cronTickDrivesPregrants`, `test_cronFromOtherTopicOrChainIgnored`. |
| F1: unbounded `react()`. | Per call: at most `MAX_SENDS` = 4 callback requests and `SCAN` = 4 entries of each retry list, with rotating cursors; the rest carries to the next tick. STOP/unstop messages go first, and every chain gets its epoch message in the same call (at most 4 chains). New grants are refused while 32 are unacknowledged. | `test_gas_reactWorstCaseIsBounded`: worst **583k gas** (STOP with full lists), identical at 32 and 400 entries per list, under the 600k asserted limit and the 900k Reactive cap. This uses a deliberately heavy stand-in for the system contract (~53k per callback request: the event plus two fresh storage writes); the real cost per request is unknown. `test_liveGrantsCapped`. |
| F3: callback gas 300k fixed. | Gas limit per chain. Measured cold through the front with the test token, worst wallet entry: **216k** (applyGrant after sweeping 2 past buckets into a new epoch). Others: applyGrant with 2 buckets drained 200k, applyEpoch freeze 138k/134k, applyReclaim 102k, applyCancel 86k, verify 11k. Allowance for USDC: +15k per token call × 5 (unmeasured, deliberately generous), then ×1.5, giving 437k. Proxy overhead (DOCS_BRIEF): extraGas + maxChargeGas = 130k on the L2s and 200k on Sepolia. Limits: **600k L2, 700k Sepolia** (needed: 567k and 637k). | `test_gas_callbackLimitCoversWorstWalletEntry`; `test_gas_worstEntriesRunWithinTheCallbackBudget` runs the worst freeze within (600k − 130k). Callback fees are billed on gas used, so the headroom costs nothing unless used. |
| F5: the freeze depended on a token transfer. | `applyEpoch` writes epoch and frozen first. Every return to the vault is accounting first (`stranded`), followed by a best-effort transfer: gas-capped, never reverting, retried on the next message or by anyone via `flush()`. Sweeps work the same way, so a failing sweep no longer blocks inbound messages. | `test_freezeDoesNotDependOnTheTransfer`: with transfers to the vault blocked, the wallet still freezes, drops its allowance and refuses payment; a later flush returns the tokens. |
| F9: confirmation wait 60 s, below Sepolia finality, and untested. | Per-chain waits. **Sepolia 16 min** (finality is 2 epochs = 12.8 min). **Base Sepolia and Unichain Sepolia 30 min** (OP Stack: batch posting plus L1 finality; not measured by us). These are conservative until Reactive says whether it delivers head, safe or finalized logs. Delayed reorgs are now in the model, and both halves of the confirmation rule have mutants. | Invariants plus `test_rule2_reReadOfAYoungFactIsNotCredited`. `test_everyRouteEndToEnd` shows a Sepolia ack credited after 16 min while a Base ack is still waiting at 21 min. |
| F4: no fee settlement. | `Payer` (the AbstractPayer pattern): `pay(amount)` callable only by the vendor (the system contract for the RC, the proxy for a front), `coverDebt()` callable by anyone, and `receive()`. The front also has an owner `withdrawFees`. Funding is described in the README. | `test_feesOnlyTheVendorCollects_andAnyoneCanCoverDebt`. |
| F10 (Low) | The front refuses when no wallet is bound. | `test_frontRejectsWrongSenderWrongRcForeignSelectorsAndUnbound`. |
| F11 (Low) | A reclaim records and reports exactly the allowance it gave up, which is what goes to the vault. M3 now breaks rule 3 directly (spent allowance counted as reclaimable). | M3 row above. |
| F12 (Low) | Explicit transfer-result checks (`SafeTransfer`; tokens returning nothing are accepted). A grant measures the wallet's own balance delta, so a token that delivers less creates no unbacked allowance. | — |

The fuzz now also passes through the production adapter's routing in one place: `test_everyRouteEndToEnd` sends real wallet and console logs through `react()` for all 12 event routes plus Cron, and real callback payloads through proxy → front → wallet. It is one scripted run, not a fuzz.

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
   - New in this round: every new press opens a new frozen epoch even when already frozen, duplicates of a press are ignored, and an unacknowledged press is re-announced.

## Simplified or not covered (honest list)

- **One clock.** Wallets bucket by their own `block.timestamp` and the core by Lasna's, but the model shares one clock. Skew near midnight isn't modelled.
- **Reorgs** are modelled for callback transactions only. Not modelled: reorgs of agent `pay`, `pressStop` or console transactions. Reorgs deeper than the wait are outside the model. `AssumptionTest` shows on purpose that such a reorg makes the coordinator over-credit.
- **The STOP bound** is "within 3h20m after the network heals" in model time. That covers the longest retry backoff; usually it is one round. **The "2–30 s window" in IDEA_V3 is not measured** and must not be claimed until the live loop measures it.
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
- **Mutant coverage gaps:** the liveness rules (Short re-arm, want TTL, rotation, floor, backoff), the sweep, the per-call cap and the payee allowlist have no mutants.
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
