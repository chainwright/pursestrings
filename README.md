# Pursestrings

One daily allowance for your agents, on every chain. Money moves only locally
(vault to wallet on the same chain); only the permission moves across chains,
coordinated by a reactive contract on Reactive Network (Lasna).

Status: week-1 protocol spike. No deployment yet. See `SPIKE_RESULT.md` for what passed,
the 17 mutants, what is still not covered, and what the spike changed in the design.

```
forge build
forge test             # invariants, directed scenarios, liveness, gas, Reactive glue (~25 s)
script/mutants.sh      # every deliberately broken variant must fail; the real contracts must pass (~30 min)
```

Tested by fuzz + mutation (not proven), against our own model of the network. MIT licensed.

## Fees and funding (for the live loop)

- **Reactive contract on Lasna:** fund its reserves with
  `cast send 0x8888888888888888888888888888888888888888 "depositTo(address)" $RC --value <lREACT>`.
  It also keeps a balance of its own (send lREACT to it); the system contract collects fees from
  that balance with `pay()`, and anyone can clear a debt with `coverDebt()`. A contract in debt
  gets no `react()` calls, so STOP would stop propagating: keep it funded.
  Cost drivers: Cron1000 (~78 ticks a day) plus one `react()` per wallet event.
- **Callback front on each destination chain:** fund with
  `cast send $CALLBACK_PROXY "depositTo(address)" $FRONT --value <ETH>` and/or send ETH to the
  front; the proxy collects with `pay()`, `coverDebt()` works the same way, and the owner can
  take the float back with `withdrawFees()`. Callback fees are billed on gas used, so the
  generous gas limits in `src/reactive/TestnetConfig.sol` cost nothing unless used.
- Fees never come out of the budget token.
