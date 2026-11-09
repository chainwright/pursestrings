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

The coordinator then used up its reserve and is paused again until funded (a paused coordinator
is not charged; Cron resumes by itself after `depositTo`, seen live; see "If the coordinator
looks inactive" below). `SPIKE_RESULT.md` covers the protocol spike: what passed, the mutants, what is
still not covered, and what the spike changed in the design.

```
forge build
forge test             # invariants, directed scenarios, liveness, production timing, gas, Reactive glue (~30-45 s)
script/mutants.sh      # full suite x 2 seeds per mutant: each must fail, the real contracts must pass (30-60 min, machine-dependent)
script/dryrun.sh       # the whole testnet deployment + the loops, rehearsed on three local anvils (no network)
python3 script/test_loop_logger.py   # offline tests of the live-loop logger's matching
```

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
  17.74 min derived from Lasna's block time). The observed Cron1000 period is 17.66 min (mean of
  173 live intervals, 1,050-1,074 s), so the 17.74-min model figure stands within 0.5 %. A STOP
  whose log is delivered (the normal case) took 2 s live.
- Live so far:
  - 07.11: 76 of 76 Cron ticks received while funded; one top-up loop and one STOP, 2 s each; the
    USDC grant callback used 245,809 gas of its 700k limit.
  - 09.11, the series: top-up median 2 s (n = 10); donor 30.4 min median (n = 3, agent retrying
    every 5 min); STOP to both chains frozen, median 2 s (n = 5).
  - Not yet live: the lost-STOP heartbeat path. Every other latency figure is from Foundry and
    our network model.

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
