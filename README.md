# Pursestrings

One daily allowance for your agents, on every chain. Money moves only locally
(vault to wallet on the same chain); only the permission moves across chains,
coordinated by a reactive contract on Reactive Network (Lasna).

Status: week-1 protocol spike. No deployment yet. See `SPIKE_RESULT.md` for what passed,
the 11 mutants and what the spike changed in the design.

```
forge build
forge test
script/mutants.sh      # each deliberately broken variant must fail the invariant suite
```

Tested by fuzz + mutation (not proven). MIT licensed.
