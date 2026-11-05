# Week-1 gate, part 1: protocol spike result (05.11.2026)

**Verdict: passes.** The real contracts hold every safety invariant under the full network model, the liveness check holds, and all 11 deliberately broken variants fail. Getting there exposed seven places where IDEA_V3 v3.1 was wrong or underspecified. They're listed below and already fixed in the code.

What this spike is not: a live deployment. There are no keys, no network transactions, and no measured latency or cost. The fuzz is our own model of Reactive. It is not Reactive itself.

How to rerun: `forge build && forge test` (default profile), then `script/mutants.sh` (about 8 minutes).

## What was built

| File | Role |
|---|---|
| `src/BudgetCore.sol` | The rule as it runs on Lasna. It keeps per-day books, `pool[d] + Σ held[d][chain] == capOfDay[d]`, plus the waiting list (with a TTL), reclaims with timeouts, a per-chain floor, STOP epochs, and pending credits that wait for confirmation. It emits intents through `_dispatch` and never calls a chain. |
| `src/SpendWallet.sol` | One wallet per chain. It keeps balance-backed day buckets (today and tomorrow). `pay()` is the only outflow: there is no generic call and no approve. It also has per-call caps, a payee allowlist, id dedup, tombstones, a local freeze on press, the midnight sweep, and a `verify()` that re-reads stored facts. |
| `src/Vault.sol` | Owner funds on the same chain. `release` moves the exact amount or nothing. |
| `src/OwnerConsole.sol` | Home-chain config events: cap changes, and an unstop that names the epoch it lifts. |
| `src/reactive/*` | `PursestringsReactive` (subscriptions, `react(LogRecord)` routing, `requestCallbackV_1_0`) and `CallbackFront` (accepts only the proxy plus our RC id, and forwards only five selectors). The interfaces are a local mirror of reactive-lib-omni. Unit-tested here, never run against the real system contract. |
| `test/harness/NetworkHandler.sol` | The network model (details below). |
| `test/mutants/Mutants.sol`, `script/mutants.sh` | The 11 mutants and the runner. |

## The network model

One queue holds messages in both directions: core→wallet callbacks, and wallet/console→core origin logs. The fuzzer can do any of the following, in any order:
- deliver messages in order (batches of 1–16) or one at random (reorder);
- drop, duplicate, or replay a message that was already delivered;
- hold a message back and release it much later;
- cut off a destination chain for 1–30 minutes, so all callbacks to it are held and then released out of order;
- orphan a callback transaction (reorg). The wallet's state rolls back, its events have already escaped to the core, and the message is re-included 50% of the time;
- pass time normally (1–60 s) or have an outage (1–26 h, which crosses days);
- run a Cron tick, let the agent pay on any chain, STOP on any chain, unstop, change the cap (12/20/30 USD), or withdraw and refill a vault.

All three chains are subject to drops, reorder and reorgs.

## Invariants (real contracts)

| # | Statement | How it's measured |
|---|---|---|
| (a) | Paid out per day, summed over all wallets, ≤ that day's cap, and that cap ≤ any cap the owner ever set | **Real token transfers**, counted inside the token (wallet → anyone except its own vault) and bucketed by day. Never the wallet's counter. |
| (b) | Once STOP is in effect on a chain, nothing leaves it. After an epoch change, nothing is paid from older-epoch allowance, and none stays spendable. | Ghost state in the handler, built from the messages it delivered, plus real outflows |
| (c) | The coordinator's books conserve, and Σ held ≤ cap for every open day | Coordinator state |
| (e) | Per-chain lemma: wallet allowance for today/tomorrow ≤ the coordinator's `held` for that chain | Wallet vs coordinator. Summed over chains, this gives (a). |
| — | Allowance ≤ token balance in every wallet | Wallet vs token |
| (d) | Liveness-lite: no drops, reorgs or STOP (reorder, duplicates and delay stay on). A retrying short chain is never refused for 6 consecutive 5-minute rounds while, at each retry, the reserve plus its own allowance plus the floor-slack of peers that aren't short covered its need | Separate fuzz test. The bound of 6 is derived from the protocol (want TTL of 2 rounds + reclaim with confirmation 1 + retry 1 + boundary 1, with 1 round spare). |

Results:
- **Default `forge test`:** 5 invariants × 128 runs × depth 150 = 19,200 calls each, all PASS. Liveness passes 256 runs here, and passed 3,000 runs separately.
- **Mutation-script budget:** 512 runs × depth 300 = 153,600 calls per invariant. The real contracts PASS.
- **Coverage, from a seeded 40,000-step walk (`WALK_STEPS=40000`; (a) and (b) are checked along the way, and it passes):**
  - 189 days crossed, 896 payments succeeded and 4,749 were refused.
  - 147 reorgs, 179 drops, 3,345 duplicates, 359 replays, 409 hold-backs, 404 partitions.
  - 163 STOPs, 162 unstops, 369 cap changes, 100 vault withdrawals.
  - 1,727 grants, 131 reclaims, 542 cancels, 415 voided grants, 879 confirmed credits. The queue never exceeded 67 messages.
  - 206 stale-epoch grants were delivered, 137 of them to unfrozen wallets. Only 2 of those were fresh, meaning not already tombstoned.
- **Coverage, from the 4,000-step walk in `forge test`:**
  - 21 days crossed, 15 reorgs, 25 drops, 311 duplicates, 36 replays, 44 hold-backs, 32 partitions.
  - 16 STOPs and 16 unstops.
  - 168 grants, 13 reclaims, 31 cancels, 41 voided grants, 76 confirmed credits.
  - The queue never exceeded 33 messages.
- **Liveness stats (400 seeds):**
  - 386 seeds had a short chain, and 344 involved reclaims.
  - After 1 refused round with budget available, 150 short chains were served; after 2 rounds, 5. Nothing waited longer.
  - The fuzzer separately found one case that waited 4 rounds (seed 1809); its trace is in the git history.

## Mutants (script/mutants.sh; 512 × 300, seed 0x5eed, fresh failure-persistence dir per run)

| id | Broken on purpose | Result | Invariant that caught it | Shrunk calls |
|---|---|---|---|---|
| M0 | none: the real contracts | **PASS** | — | — |
| M1 | wallet doesn't dedup messages (rule 4) | KILLED | (a) 20.64 > 20.00 | 17 |
| M2 | core credits a reclaim when it sends it (rule 2) | KILLED | (a) 30.60 > 30.00 | 40 |
| M3 | reclaim shrinks spent, not only unspent (rule 3) | KILLED | (a) 23.68 > 20.00 | 68 |
| M4 | wallet ignores the epoch on grants (rule 6) | KILLED | (b) older-epoch allowance spendable | 16 |
| M5 | wallet ignores the day number | KILLED | (a) 24.36 > 20.00 | 11 |
| M6 | core refunds a cancel when it sends it (rule 5) | KILLED | (a) 20.26 > 20.00 | 27 |
| M7 | core credits at head (reorgs) | KILLED | (a) 20.70 > 20.00 | 27 |
| M8 | core doesn't dedup credits (rule 4) | KILLED | (a) 30.02 > 30.00 | 86 |
| M9 | pressing chain doesn't freeze locally | KILLED | (b) paid while STOP in effect | 4 |
| M10 | core waits, then credits **without re-reading** | KILLED | (e) 6.75 > 5.08 held | 11 |
| M11 | allowance credited although the vault transfer failed | KILLED | allowance > balance | 3 |

The "caught by" column is the first failing invariant in forge's output order. Several mutants trip more than one invariant. Each run takes 26–67 s, about 8 minutes for the whole script.

Two caveats on these results:
- **At the default budget (128 × 150) the kill rate is lower.** Before (e), the replay fault, and the partition fault were added, M3, M4, M7, M8 and M10 survived. With them, M4 is still only caught at the larger budget. M4 was confirmed on 5 of 5 seeds with fresh persistence directories.
- **Forge persists invariant failures and replays them.** Early in this spike that made a mutant look caught when it was really a replay. The script now gives every run its own persistence directory.

## What turned out wrong or underspecified in the design

1. **"Credit after a time-based wait" alone isn't safe.**
   - If Reactive delivers a log whose block is later orphaned, the coordinator never hears about the reorg, so waiting and then crediting still credits a phantom. M10 shows this.
   - **Fix:** after the wait, the core asks the origin wallet to re-read the stored fact (`verify`). It credits only if the fact still holds, is at least the wait old, and uses the amount from the re-read, not from the original event.
   - **Cost:** one extra callback and one extra `react` per credit, plus the wait. This applies to the donor path only; the reserve top-up path doesn't wait.
   - If reactivedevs confirm that delivery happens only after finality, the re-read can be dropped. **This is now the most important question for them.**
2. **Origin-side nonces can't be dedup keys under reorgs.** A rolled-back counter reuses the nonce with different content. Instead, every request and its answer are keyed by an id the core assigns (Lasna doesn't reorg). Short and LowWater are idempotent. The STOP press uses a strictly increasing mark.
3. **"Short fires once per chain per day" deadlocks the chain for the rest of the day** if that one Short is lost or lands while the core is frozen. Now Short is rate-limited (re-armed after 300 s) and also re-armed by an applied or voided grant, a new epoch, or a new day.
4. **The waiting list needs a TTL.** A satisfied chain's leftover partial want otherwise bars it as a donor indefinitely (found by the liveness fuzz).
5. **The floor doesn't stop ping-pong when every chain is short.** A chain that was just served became a donor in the same pass and was drained before its agent could spend. **Fix:** a chain that asked within the TTL isn't a donor, and the serve order rotates.
6. **Retries need exponential backoff.** With fixed intervals, any latency above the timeouts became a retry storm, and every callback is billed. Backoff now doubles per try, up to 32×.
7. **STOP races the text didn't cover.**
   - Unstop must name the epoch it lifts, or a delayed unstop lifts a later STOP.
   - An unfreeze must carry the coordinator's view of that chain's last press, or an in-flight unfreeze cancels a fresh local press.
   - Epoch acks go through the same re-read, or an orphaned ack stops the freeze from being re-sent.

Smaller points:
- **A LogRecord has no timestamp,** so every event carries `ts`.
- **Rule 5 (cancel/tombstone) covers most of rule 6 (epoch).** A late old-epoch grant is usually tombstoned by its cancel first. Rule 6 alone matters when a destination chain is cut off and its backlog arrives out of order, so the fuzzer needed a partition fault to reach that path.
- **Testing only real outflows is weak at small budgets.** The per-chain lemma (e) catches over-credit mutants long before an agent overspends. (a) stays the headline check.

## Simplified or not covered (honest list)

- **Cap decrease** applies to days not yet opened, so at the latest d+2. Clearing tomorrow's pre-grants on a decrease (the design text) isn't implemented. A raise applies at once.
- **One clock.** Wallets bucket by their own `block.timestamp` and the core by Lasna's, but the model shares one clock. Skew near midnight isn't modelled; per-bucket safety doesn't depend on it, but liveness near midnight might.
- **Reorgs are modelled as instant orphans of callback transactions.** Not modelled: delayed reorgs (state that lives a while, then rolls back) and reorgs of agent `pay` transactions or console config.
- **Not tested here at all:**
  - fees, debt, InsufficientGas, callback failure semantics;
  - several wallets per chain and per-agent sub-caps;
  - the real x402 / ERC-1271 path from v3.1;
  - the API fake-event and used-callId tests (W2);
  - the dashboard number X ≥ true remaining;
  - a finer local expiry per allowance (the day bucket is the only expiry, at most about 48 h).
- **The RC takes wallet and front addresses in its constructor.** A live deploy needs precomputed addresses or setters.

## What remains for the live loop (gate part 2: Lasna ↔ Base Sepolia ↔ Unichain Sepolia)

1. Ask t.me/reactivedevs first:
   - Is a log delivered before or after finality? This decides whether the re-read stays.
   - Can delivery duplicate logs? Do failed callbacks get retried?
   - What happens to logs whose block is orphaned?
2. Swap the mirror for `reactive-lib-omni`, check the LogRecord field order, add `AbstractCallback`-style fee payment to the front, fix the deploy order, and fund both sides.
3. Deploy one wallet, vault and front on each L2 and the RC on Lasna. Run 20 loops. Log origin tx → reactive tx → `getCallbacks` → destination tx, with latency and cost, separately for:
   - the reserve top-up path (target median ≤ 6 s, aiming for 3);
   - the donor path, which with the re-read is wait + about 4 hops. The "≤ 6 s" claim must not be applied to it.
4. Measure the cost per rebalance including the re-read round trip, and the Cron1000 cost.
