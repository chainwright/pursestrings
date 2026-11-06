# Pursestrings

One daily allowance for your agents, on every chain. Money moves only locally
(vault to wallet on the same chain); only the permission moves across chains,
coordinated by a reactive contract on Reactive Network (Lasna).

Status: week-1 protocol spike. No deployment yet. See `SPIKE_RESULT.md` for what passed,
the mutants, what is still not covered, and what the spike changed in the design.

```
forge build
forge test             # invariants, directed scenarios, liveness, production timing, gas, Reactive glue (~30-45 s)
script/mutants.sh      # full suite x 2 seeds per mutant: each must fail, the real contracts must pass (30-60 min, machine-dependent)
script/dryrun.sh       # the whole testnet deployment + one loop, rehearsed on three local anvils (no network)
```

Built on reactive-lib-omni v0.1.0. The live testnet loop (deploy, fund, 20 loops per path, logger) is prepared but not
run: see `LIVE_LOOP.md` for the exact commands and their costs.

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
  heartbeat cycle plus delivery, 51-59 min in our model for a Cron of 17-19.5 min (56 at the
  default 18.5 min, from DOCS_BRIEF's single 1.11 s block-time sample). Lasna's real Cron period
  is unmeasured.
- Nothing has run on Reactive yet: all latency, gas and fee figures are Foundry measurements or
  estimates.

## Fees and funding (for the live loop)

- **Reactive contract on Lasna:** fund its reserves with
  `cast send 0x8888888888888888888888888888888888888888 "depositTo(address)" $RC --value <lREACT>`.
  It also keeps a balance of its own (send lREACT to it); the system contract collects fees from
  that balance with `pay()`, and anyone can clear a debt with `coverDebt()`. A contract in debt
  gets no `react()` calls, so STOP would stop propagating: keep it funded.
  Cost drivers: Cron1000 (~75-85 ticks a day), the heartbeat (a re-read to each chain every
  ~51-56 min when idle, plus the `react()` for its answer), and one `react()` per wallet event.
  A few lREACT a day (Cron alone up to ~4.6 if every tick were the heaviest measured, heartbeat
  answers on top), from the documented fee formula and our Foundry gas figures; **unmeasured**.
  A front that stays dead while its agent keeps asking costs about one cancel per 40 min.
- **Callback front on each destination chain:** fund with
  `cast send $CALLBACK_PROXY "depositTo(address)" $FRONT --value <ETH>` and/or send ETH to the
  front; the proxy collects with `pay()`, `coverDebt()` works the same way, and the owner can
  take the float back with `withdrawFees()`. Callback fees are billed on gas used (per the docs;
  to confirm on the live loop), so the generous gas limits in `src/reactive/TestnetConfig.sol`
  should cost nothing unless used. Per-callback costs on each chain are **unmeasured**.
- Fees never come out of the budget token.
