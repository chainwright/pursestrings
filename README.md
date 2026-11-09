# Pursestrings

One daily allowance for your agents, on every chain. Money moves only locally
(vault to wallet on the same chain); only the permission moves across chains,
coordinated by a reactive contract on Reactive Network (Lasna).

Status: week 1. Deployed on testnets on 07.11.2026 (coordinator on Lasna, wallet + vault + front
on Base Sepolia and on Unichain Sepolia; the console on Base Sepolia). Addresses, creation
hashes and source verification (all eight are an exact match on Sourcify): `deployments/README.md`. The live smoke test passed: one top-up loop and one STOP, each
answered on-chain 2 s after its origin (`live/LIVE_RUN_2026-11-07.md`). On 09.11 UTC the compact
live series ran in full (`live/SERIES_2026-11-09.md`):
- 10 top-up loops: all complete, median 2 s, p95 3 s;
- 3 donor loops: all complete, 30.4 min median (31.2 max) with the agent retrying every 5 min;
- 5 STOP presses: both chains frozen, median 2 s, p95 3 s;
- 12 successful agent payments, $17 in all, under the $20 daily cap.

**Branch `w3-final`** holds the code for the final redeploy (W3, `live/W3_2026-11-09.md`): refill
ahead by burn rate, the idle heartbeat and the `flush()` sweep below. The 07.11 deployment runs
`main` (`272db8f` for `src/`), which is what Sourcify verifies; none of the W3 changes is live yet.

The coordinator then used up its reserve and is paused again until funded (a paused coordinator
is not charged; Cron resumes by itself after `depositTo`, seen live; see "If the coordinator
looks inactive" below). `SPIKE_RESULT.md` covers the protocol spike: what passed, the mutants, what is
still not covered, and what the spike changed in the design.

```
forge build
forge test             # invariants, directed scenarios, liveness, production timing, gas, Reactive glue (~30-45 s)
script/mutants.sh      # full suite x 2 seeds per mutant: each must fail, the real contracts must pass (30-60 min, machine-dependent)
script/dryrun.sh       # the whole testnet deployment + the loops + the pay-per-call demo, on three local anvils (no network)
python3 script/test_loop_logger.py   # offline tests of the live-loop logger's matching
python3 demo/test_api.py             # offline tests of the demo API's acceptance rules and the agent's 402 loop
python3 script/test_checker.py       # offline tests of the checker's arithmetic, log chunking and day ranges
python3 script/checker.py            # read-only: today's spending on every chain vs the cap, "Over: $0.00"
```

## Pay-per-call demo (our own 402 flow, not x402)

`demo/api.py` is a tiny HTTP service (Python standard library only). It sells rows of demo data at
$1 a row. It uses its own minimal 402 flow with no outside facilitator. It is **not x402-compatible**:
no x402 headers, no facilitator, no signed authorization. Real x402 is future work (`IDEA_V3.md` v3.1).

1. `GET /v1/snapshot?n=3` without payment answers **402** with a quote: the price, the payee, a fresh
   `callId`, the accepted chains, an expiry, and a private `claim`.
2. The agent pays through its own wallet: `SpendWallet.pay(payee, price, callId)`.
3. The agent repeats the request with `X-Payment: <chainId>:<txHash>:<callId>` and
   `X-Payment-Claim: <claim>`. The API reads that transaction's receipt from the chain itself. It
   serves data only if all of these hold:
   - a wallet registered in the deployment file emitted `Paid` with this callId, payee and amount;
   - the token contract's own `Transfer` from that wallet to the payee, for exactly that amount,
     follows the `Paid` log in the same successful tx;
   - the callId was issued here, is unexpired and unused, and the claim matches.

   The callId is then recorded as used, on disk. A `Paid` emitted by any other contract is refused,
   even with real tokens moved alongside it. So are a transfer from an unregistered address, a wrong
   amount or payee, a replay, and someone who saw the agent's tx on-chain but doesn't hold its claim.
4. If the wallet refused the pay, the agent gets one of two states:
   - **amber, "budget on its way, retry in ~N s"**: the wallet emitted `Short` and the day still has
     budget for the call. N is ~5 s when the coordinator's pool covers it (top-up, measured median
     2 s live). When the budget must come back from another chain it is 310 s between retries,
     ~30 min in all (donor, measured median 30.4 min).
   - **red**: the cap is reached (what can still leave today is below the price), or STOP is in
     force, or the payee or per-call cap isn't allowed, or the coordinator is paused (unfunded).
   This hint reads the coordinator and the wallets' buckets. The spending check that counts is the
   checker below.

```
export PAYEE_ADDRESS=<the payee allowlisted on the wallets>   # plus the RPC/key environment of LIVE_LOOP.md §1
python3 demo/api.py --port 8402 &                             # read-only on chain: no key
python3 demo/agent.py --chain base --resource "/v1/snapshot?n=1"                  # 402 -> pay -> data
python3 demo/agent.py --chain base --resource "/v1/snapshot?n=9" --wait-min 40    # waits through amber
```

The agent pays through `forge script script/Loop.s.sol --sig "payCall(...)"`, with the agent key
read inside forge. It refuses a quote above `--max-usd` (default $10) or, when `PAYEE_ADDRESS` is set,
to any other payee. Exit codes: 0 data, 10 amber with no time left, 11 red, 12 rejected, 4 forge
failed (it never pays twice blind).

Limits:
- The demo accepts a payment at 0 confirmations (`--min-confirmations` raises that), so an L2
  reorg after serving would cost the seller, not the budget.
- Quotes live in a local JSON file (`cache/demo/api_state.json`).

`script/dryrun.sh` step 4c runs the whole flow on local chains:
- 402 → pay → data;
- a replay (409), a fake `Paid` from a contract that also moves $2 of real tokens to the payee, and
  an onlooker without the claim, all refused;
- an over-allowance call that gets amber, then is served after the grant lands;
- a $10 call with $8 left that gets red;
- the checker reporting Over $0.00.

The API's acceptance rules are mutation-checked: each rule switched off makes `demo/test_api.py`
fail (`live/W2_DEMO_2026-11-09.md`).

## Refill ahead by burn rate (branch `w3-final`, final redeploy)

The coordinator tops a busy chain up before its agent is refused, and starts the slow donor path
(30 min) before the chain runs out:
- **A meter per chain.** Every heartbeat re-read now answers with that wallet's spent for today,
  and a LowWater counts as a reading when the books are exact for that chain. The rate is the spend
  over the last window (at least 10 min). Readings apply only in origin-time order. The meter
  steers refills only and never enters the books, so a wrong reading can cost a wait or park
  budget on the wrong chain, never exceed the cap.
- **Only for fast chains** (burning a chunk, cap/10, within 90 min), and only on a fresh reading
  (asked for first if needed; the answer arrives seconds later):
  - with < 20 min of spending left (one Cron period plus margin), a top-up of 1 h of its rate from
    the pool;
  - with < 90 min left and a pool that can't give that top-up, one reclaim per react from the chain
    with the most slack beyond its floor, one chunk and its own projected need.
- Slower chains, and chains that are projected dry but don't ask, are left to the W2 path
  (LowWater or a refusal, then a top-up in seconds or the donor path). Every grant and reclaim
  goes through the same code as before, after the frozen check: rules 1-6, the cap and STOP are
  unchanged.

**Share of payments that had to wait**, in a simulated day at production timing
(`test/RefillAhead.t.sol`, 30 days per demand profile, the same days with refill ahead off and on):

| Demand | Off (W2) | On (W3) | Calls waiting >= 20 min | Total minutes waited |
|---|---|---|---|---|
| burst: $7/h on one chain for 90 min | 4.8 % | **1.6 %** | 4 → 1 | 441 → 102 |
| night batch: $2.5/h for 4 h | 0.6 % | 0.9 % | 0 → 3 | 23 → 119 |
| steady: $0.7/h all day | 1.8 % | 1.9 % | 1 → 3 | 88 → 147 |

It helps where the W2 coordinator is weak: a burst outruns the $1 low-water cushion, and the
donor path started too late. On gentler days the W2 path already rarely waits, and refill ahead
is a wash: in the last two rows some calls that would have waited until midnight (the budget left
sits on other chains' floors) are paid after a wait instead, so counting those, it is 6.1 % → 6.1 %
and 13.2 % → 13.0 %. It is a model, not a measurement.

**The race** (`test/Race.t.sol`): agents on both chains pay $1 at a time in the same second while a
reclaim (or a refill-ahead reclaim) is in flight, in five orders. Every day ends **Over $0.00**;
what is spent varies ($19.38-$20.00), and we never promise exactly $20.

## The checker

`script/checker.py` answers one question: did the wallets, all chains together, send out more than
the day's cap? It is read-only, needs no key, and works without our tools: Python's standard library
plus the public RPCs.
- **What it counts.** It sums the budget token's own ERC-20 `Transfer` logs whose `from` is a
  deployment wallet, within the UTC day by each chain's block time. It never uses the wallet's own
  counter. A transfer to the wallet's own vault is a return and is listed apart; anything else that
  leaves a wallet is spent.
- **How it finds the day.** The day's blocks are found from timestamps by bisection. Base Sepolia
  makes a block every 0.2 s, so block counts would be wrong. Log queries are chunked to what each
  public RPC accepts (Base Sepolia 200 blocks at ≤ 25 requests/s, Unichain Sepolia 1000). A Base
  Sepolia day takes ~1.5–2 min.
- **The cap.** It is the coordinator's `capOfDay(d)` on Lasna, or `--cap-usd`.
- **Output and exit code.** It prints "Over: $0.00" (or the overspend) and "can still leave" per day.
  It exits 1 if any day is over.

Live, read-only, 09.11 at ~10:03 UTC (`live/checker_2026-11-09.log`):
- Base Sepolia: $17.00 out in 12 transfers. These are the series' 12 payments, counted here from the
  token's logs, not from `Paid`.
- Unichain Sepolia: $0.00.
- Cap $20: **Over: $0.00**.
- 07.11 and 08.11: $0.00 against a $4 cap.

Built on reactive-lib-omni v0.1.0. `LIVE_LOOP.md` has the exact commands: the smoke test and the
compact series (10 top-up, 3 donor, 5 STOP loops, with an agent that keeps asking on the donor
path), both as they were run, with measured costs.

Tested by fuzz + mutation (not proven), against our own model of the network. MIT licensed.

What the tests do and don't show:
- The fuzz drives the coordinator through the test's own log decoder, not through the Reactive
  adapter. The adapter (`react()`, every route plus Cron, proxy -> front -> wallet) is covered by
  one scripted end-to-end test with a mock system contract.
- The owner-level STOP check (s) is one-directional: it checks that a STOP holds everywhere after
  the network heals, not that an unstop takes effect (a late press can re-freeze; fail-safe).
- Confirmation waits are 16 min on Sepolia (above its 12.8 min finality) and 30 min on Base and
  Unichain Sepolia. The 30 min is a typical time to L2 finality, not a guaranteed bound: a stalled
  batcher can leave L2 blocks unsafe longer, so L2 safety assumes a healthy sequencer and batcher
  until Reactive confirms it delivers only finalized logs.
- STOP latency after a lost STOP log depends on the Cron period (1000 Lasna blocks): one
  heartbeat cycle plus delivery, 51-59 min in our model for a Cron of 17-19.5 min (53 at the
  17.74 min derived from Lasna's block time). On `w3-final` the heartbeat is 40 min only while an
  agent has spent or asked in the last 2 h: then the worst is 46 min. With nobody spending it is
  120 min (worst 123 min at 17.74), and nothing is spent meanwhile; the first spend brings the
  40-min beat back (STOP everywhere within 42 min of it in the model). The observed Cron1000 period is 17.66 min (mean of
  173 live intervals, 1,050-1,074 s), so the 17.74-min model figure stands within 0.5 %. A STOP
  whose log is delivered (the normal case) took 2 s live.
- Live so far:
  - 07.11: 76 of 76 Cron ticks received while funded; one top-up loop and one STOP, 2 s each; the
    USDC grant callback used 245,809 gas of its 700k limit.
  - 09.11, the series: top-up median 2 s (n = 10); donor 30.4 min median (n = 3, agent retrying
    every 5 min); STOP to both chains frozen, median 2 s (n = 5).
  - Not yet live: the lost-STOP heartbeat path, and the demo API (dry run only so far). Every other
    latency figure is from Foundry and our network model.

## If the coordinator looks inactive

Reactscan may show the coordinator on Lasna as inactive. That means it ran out of lREACT and is
paused, not broken. A paused coordinator is not charged and gets no `react()` calls. Nothing can
overspend while it is paused: a wallet can spend only today's bucket, and no new bucket is
granted. Each vault stays withdrawable by its owner on its own chain.

One `depositTo` wakes it, and Cron resumes by itself. We saw this live on 09.11:
- deposit of 3 lREACT at 05:18:06 UTC, which settled the 0.0076 debt first:
  [`0xc006f5af…6c98`](https://lasna.reactscan.net/tx/0xc006f5afc4254d1563ed18bee2da2ff1d4451d24e87bf8452d1d8ab9f6d96c98);
- the next Cron1000 tick, block 7,897,001 at 05:33:35 UTC, already carried our reactive tx
  [`0x3a5712a8…a2a7`](https://lasna.reactscan.net/tx/0x3a5712a8242d77a7ebda2383e007e7c5e654e8ba26e5ed67df67cf9944d4a2a7)
  (193,268 gas). No other step was needed.

On `w3-final`, anyone can also call `flush()` on a wallet while the coordinator is paused: it
sweeps yesterday's leftover allowance and returns it to the vault, with no agent payment and no
coordinator message (W1 gate P1-8; the deployed wallets don't sweep in `flush()`).

A STOP pressed during a pause still holds. The pressing chain freezes in the same transaction,
and on the first Cron tick after the deposit the coordinator carries the STOP to every chain
(`test_debtPause48h_*` in `test/Directed.t.sol`: a 48 h pause with every event in it lost).

The current deployment has been paused since the end of the 09.11 series (debt 0.0142 lREACT) and
stays that way until the final deployment. Plan for the judging window: the judged coordinator is
the final deployment, kept funded from submission until results. At the measured ≈ 2.9 lREACT a
day (100 gwei), two weeks is ≈ 40 lREACT, about 0.4 Sepolia ETH through the faucet. We deposit
≈ 6 lREACT every two days, never far ahead, because reserves can't be withdrawn, and check after
each deposit that the next tick carries our tx (`loop_logger.py cron-check`). If it lapses anyway,
it pauses in the safe state above, and one deposit brings it back.

## Fees and funding (for the live loop)

- **Reactive contract on Lasna:** fund its reserves with
  `cast send 0x8888888888888888888888888888888888888888 "depositTo(address)" $RC --value <lREACT>`.
  It also keeps a balance of its own (send lREACT to it); the system contract collects fees from
  that balance with `pay()`, and anyone can clear a debt with `coverDebt()`. A contract in debt
  gets no `react()` calls, so STOP would stop propagating: keep it funded.
  Cost drivers: Cron1000 (~75-85 ticks a day), the heartbeat (a re-read to each chain every
  ~51-56 min when idle, plus the `react()` for its answer), and one `react()` per wallet event.
  **Measured: ≈ 2.9 lREACT a day idle at 100 gwei** (≈ 5 at 175): the 3-lREACT deposit lasted
  ≈ 22 h with the smoke test inside. An idle tick uses 93-115k gas (≈ 0.02 lREACT); the heaviest
  live react was 507,771 gas.
  On `w3-final`, the heartbeat slows to 120 min while no agent spends: an idle day goes from
  ≈ 54 to ≈ 23 heartbeats on two chains, ≈ 2.9 → ≈ 2.3 lREACT a day at 100 gwei (estimate from the
  measured gas, `live/W3_2026-11-09.md`; not measured live).
  The series (09.11, 100 gwei) cost **4.51 lREACT in ≈ 4 h**. Per loop, from the reserve deltas:
  - top-up ≈ 0.057, ticks included;
  - donor ≈ 0.33;
  - STOP press + unstop ≈ 0.30, plus ≈ 1.3 for the 30-min re-reads after five epoch rolls.
  A front that stays dead while its agent keeps asking costs about one cancel per 40 min.
- **Callback front on each destination chain:** fund with
  `cast send $CALLBACK_PROXY "depositTo(address)" $FRONT --value <ETH>` and/or send ETH to the
  front; the proxy collects with `pay()`, `coverDebt()` works the same way, and the owner can
  take the float back with `withdrawFees()`. Callback fees are billed on gas used (per the docs;
  to confirm on the live loop), so the generous gas limits in `src/reactive/TestnetConfig.sol`
  should cost nothing unless used. **Measured:** < 1e-6 ETH per callback on Base Sepolia (the
  front's 0.002 ETH reserve was 0.0019739 after ~35 callbacks).
- Fees never come out of the budget token.

Licences: this repo is MIT. `forge-std` (MIT/Apache-2.0) and `reactive-lib-omni` are git
submodules, not vendored; `reactive-lib-omni` carries `SPDX: UNLICENSED` and has no LICENSE file.
