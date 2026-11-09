# Costs, funding and the limits of the tests

Moved out of the README so that its first screen stays short. Numbers are from the 07.11 smoke
test and the 09.11 series (`live/`), unless a line says "model" (Foundry, our network model).
The full test design, the mutants and the honest list are in `docs/DESIGN_AND_TESTS.md`.

## What the tests do and don't show

Tested by fuzz + mutation (not proven), against our own model of the network.

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
  - Not yet live: the lost-STOP heartbeat path, and the demo API (dry run only so far). Every other
    latency figure is from Foundry and our network model.

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
  should cost nothing unless used. **Measured:** about 1e-6 ETH per callback on Base Sepolia
  (0.75–1.3e-6 by path, 09.11 series; the front's 0.002 ETH reserve was 0.0019739 after ~35
  callbacks on 07.11).
- Fees never come out of the budget token.

## Source comments left out of date on the judged deployment

The live contracts (07.11) are source-verified on Sourcify with an exact match, so `src/` on
`main` stays byte-identical to what was deployed, comments included: editing a comment changes the
metadata hash and the match would drop to partial. These comments on `main` are therefore left
out of date on purpose:
- `src/reactive/PursestringsReactive.sol:16-17` says "Not yet run against the real system
  contract"; it has run on Lasna since 07.11.2026.
- `src/reactive/TestnetConfig.sol:8` says "Nothing here has been deployed yet"; it has, on
  07.11.2026.
- `PursestringsReactive.sol:19` and `TestnetConfig.sol:7` cite "DOCS_BRIEF", our notes on
  Reactive's docs, which are not in this repo.

The judged deployment is this one (07.11.2026, `main`), with no redeploy for judging, so these
comments stay as they are and the Sourcify matches stay exact. Branch `w3-final` (the next version,
not the judged deployment) already has the fixed wording; if it is ever deployed, the date in them is
set to that deploy and the new addresses are verified on Sourcify again.
