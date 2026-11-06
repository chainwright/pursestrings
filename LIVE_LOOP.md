# Live loop run book (gate part 2): Lasna ↔ Base Sepolia ↔ Unichain Sepolia

**Status: prepared, not run.** No network transaction has been sent. Wait for reactivedevs' answers first, on:
- delivery depth (head, safe or finalized);
- duplicate delivery;
- retries of failed callbacks;
- the cost of a callback request.

Their answers can change the waits in `src/reactive/TestnetConfig.sol` (and so the deployed coordinator).

Everything below has been run end to end on three local anvil chains with the real chain ids: `script/dryrun.sh`, exit 0, no network.

## 0. What is where

| Piece | File | Sends txs? |
|---|---|---|
| Deploy all three chains, with the coordinator's address predicted | `script/Deploy.s.sol` | yes (`--broadcast`) |
| Wiring checks on every chain | `script/Check.s.sol` (`run()`) | no |
| Origin txs for the loops, funding, cap, STOP/unstop, faucet | `script/Loop.s.sol` | yes (`--broadcast`) |
| Trace origin → reactive tx → `getCallbacks` → destination tx; summary | `script/loop_logger.py` | no (read-only, no key) |
| Full rehearsal on local anvils | `script/dryrun.sh` (+ `script/dryrun_relay.py`) | local only |

The contracts are built on **reactive-lib-omni v0.1.0** (`lib/reactive-lib-omni`, commit 3ade0dc). Its `IReactive.LogRecord` field order (chainId, contractAddress, topic0–3, data, blockNumber, opCode, blockHash, txHash, logIndex) and `ISystemContract.CallbackConfiguration_V_1_0` (chainId, recipient, gasLimit, payload) match what the spike's mirror assumed. The mirror is gone.

## 1. Environment (names only; nothing secret is ever printed or written)

```bash
cd /Users/mini/agents/sora/hackathons/reactive_2026/pursestrings
export LASNA_RPC_URL=https://lasna-rpc.rnk.dev/
export BASE_SEPOLIA_RPC_URL=<your Base Sepolia RPC>
export UNICHAIN_SEPOLIA_RPC_URL=<your Unichain Sepolia RPC>

# keys: taken from the secret store into the environment at run time; never echo them
export DEPLOYER_PRIVATE_KEY="$(python3 /Users/mini/agents/sora/scripts/secret.py S76)"   # deployer = owner, 0xeE7F…cbfc
export AGENT_PRIVATE_KEY="$(python3 /Users/mini/agents/sora/scripts/secret.py <agent label>)"
export AGENT_ADDRESS=<the agent key's address>
export PAYEE_ADDRESS=<the demo API's address; for the loop run the deployer's own address, so paid USDC can be moved back to the vaults>

# budget token: Circle testnet USDC. Check both addresses on developers.circle.com
# ("USDC contract addresses", testnet) before use: I have not verified them on-chain.
export USDC_BASE_SEPOLIA=0x036CbD53842c5426634e7929541eC2318f3dCF7e
export USDC_UNICHAIN_SEPOLIA=0x31d0220469e10c4E71834a79b1f276d740d3768F
export DEPLOYMENTS_FILE=deployments/latest.json
```

- **There is no agent key in the store yet.** Create one without it ever being shown:
  ```bash
  /Users/mini/.foundry/bin/cast wallet new --json | python3 -c 'import json,subprocess,sys; w=json.load(sys.stdin)[0]; subprocess.run(["python3","/Users/mini/agents/sora/scripts/secret.py","--add",w["private_key"],"testnet_private_key","Pursestrings agent (TEST ONLY)"],check=True); print("agent address", w["address"])'
  ```
  It prints only the address and the new label. Alternatively, use S76 for the agent too. That is simpler, but the deployer then also holds the agent role.
- Every script reads the keys with `vm.envUint` inside forge, so they never appear on a command line or in the process list. The logger needs no key at all.

## 2. Rehearse (free, no network)

```bash
script/dryrun.sh
```

Expected output:
- `ONCHAIN EXECUTION COMPLETE & SUCCESSFUL`;
- `coordinator predicted … = coordinator …`;
- three "wiring ok" lines;
- `dry-run loop ok`;
- a logger trace with `"complete": true`;
- five `ok` lines from the loop driver.

## 3. Get testnet tokens

| What | Command | Cost |
|---|---|---|
| Base Sepolia ETH and Unichain Sepolia ETH for the deployer | faucets of your choice (by hand) | free |
| lREACT on Lasna | `forge script script/Loop.s.sol --sig "faucet(uint256)" 300000000000000000 --broadcast` | 0.3 Base Sepolia ETH → 30 lREACT (DOCS_BRIEF: 1 ETH → 100 lREACT; above 5 ETH per tx is lost; the script refuses > 5) |
| USDC on both L2s | Circle's testnet faucet (by hand), to the deployer | free; at least 40 per chain for the loop run below |

## 4. Deploy

```bash
CAP=40000000 FRONT_FUNDING_WEI=0 RC_FUNDING_WEI=1000000000000000000 \
  forge script script/Deploy.s.sol --broadcast --slow
forge script script/Check.s.sol            # read-only wiring checks, must print three "wiring ok"
```

How it works:
- It predicts the coordinator's Lasna address from the deployer's Lasna nonce.
- It deploys, on Base Sepolia, the console, then the front (pinned to that address), vault and wallet, and binds them. It does the same on Unichain Sepolia.
- It deploys the coordinator on Lasna last, and stops if the coordinator doesn't land at the predicted address.
- **Don't use the deployer key for anything else on Lasna during the run.**
- Addresses go to `deployments/latest.json`, and broadcast logs with every tx hash go to `broadcast/`. Keep both: the submission needs the hashes.
- `CAP` is $40 a day, so 20 top-up loops fit in a day (each serves a $2 chunk).

Measured gas in the dry run (the same bytecode and calls):

| Chain | Txs | Gas | Cost |
|---|---|---|---|
| Lasna | 1 (coordinator, 18.1 kB runtime) | 4.53 M | ≈ 0.45 lREACT at the 100 gwei DOCS_BRIEF read on 04.11 (check `cast gas-price --rpc-url $LASNA_RPC_URL`), plus the 1 lREACT `RC_FUNDING_WEI` sent along |
| Base Sepolia | 9 (console, front, vault, wallet, binds, payee) | 4.17 M | at 0.01 gwei ≈ 0.00004 ETH; at 1 gwei ≈ 0.004 ETH |
| Unichain Sepolia | 8 | 3.92 M | same order as Base Sepolia |

Whether the system contract charges for the constructor's 23 subscriptions is unknown. The 1 lREACT sent along covers the first `pay()` requests.

## 5. Fund fees and budget

```bash
forge script script/Loop.s.sol --sig "fundReserves(uint256,uint256)" 20000000000000000000 10000000000000000 --broadcast
forge script script/Loop.s.sol --sig "fundVault(uint256,uint256)" 0 40000000 --broadcast   # 40 USDC, Base Sepolia vault
forge script script/Loop.s.sol --sig "fundVault(uint256,uint256)" 1 40000000 --broadcast   # 40 USDC, Unichain Sepolia vault
```

- **20 lREACT** goes into the coordinator's reserves (`depositTo` on the system contract) and **0.01 ETH** into each front's reserves (`depositTo` on its callback proxy). The `depositTo` signature is from DOCS_BRIEF; the library doesn't declare it.
- The script refuses if there is no code at the system or proxy address, because a deposit to an address without code would silently vanish.
- Check the reserves with `cast call 0x8888888888888888888888888888888888888888 "reserves(address)(uint256)" <coordinator> --rpc-url $LASNA_RPC_URL` and `… "debt(address)(uint256)" …`. Check the subscriptions with `cast rpc rnk_getFilters --rpc-url $LASNA_RPC_URL` (DOCS_BRIEF: it answers; its parameters are to be confirmed).
- **First measurement:** time a few Cron ticks on Lasna (the coordinator's reactive txs while idle). The real Cron1000 period sets every STOP-latency figure.

## 6. The loops (20 per path)

After each origin command, trace it. The logger polls for up to `--timeout-min` (120 by default) and appends one JSON line to `live/loops.jsonl`.

**Top-up path** (reserve → chain; target median ≤ 6 s, aim 3):
```bash
forge script script/Loop.s.sol --sig "pay(uint256,uint256)" 0 1000000 --broadcast    # refused on Base Sepolia: Short
python3 script/loop_logger.py trace --path topup --chain base --tx "$(python3 script/loop_logger.py last-tx --fn pay --chain base)"
forge script script/Loop.s.sol --sig "pay(uint256,uint256)" 0 2000000 --broadcast    # spend the $2 grant, so the next loop is short again
```
Alternate chain 0 and chain 1. Each loop serves one $2 chunk, so 20 loops use $40 of the day's cap.

**Donor path** (reclaim from the other chain; expect the 30-min L2 wait plus a Cron tick, roughly 45–80 min, model bound 1h40):
1. Make both chains hold allowance and the pool empty: `pay` 10000000 refused on chain 0 and on chain 1, then wait about 2 min.
2. Wait at least 41 minutes, past the want TTL, so chain 1 is a donor again.
3. On chain 0, spend down to the floor and be short again: `pay 0 8000000`, then `pay 0 4000000` (refused).
4. Trace it: `python3 script/loop_logger.py trace --path donor --chain base --tx "$(python3 script/loop_logger.py last-tx --fn pay --chain base)" --timeout-min 150`.

Each donor loop takes about an hour, so plan 5–10, not 20, unless the waits change.

**STOP path:**
```bash
forge script script/Loop.s.sol --sig "stop(uint256)" 1 --broadcast                    # press on Unichain Sepolia
python3 script/loop_logger.py trace --path stop --chain unichain --tx "$(python3 script/loop_logger.py last-tx --fn stop --chain unichain)"
forge script script/Loop.s.sol --sig "unstop()" --broadcast                           # after the trace completes
```
The trace's latency is press → last epoch callback landed on every chain, which is the "$0.00 chain by chain" figure. Wait for the unfreeze to land (another trace or a few minutes) before the next press.

**Summary:**
```bash
python3 script/loop_logger.py summary     # per path: runs, completed, latency median / p95, formula fees
```

## 7. What a loop costs (estimates; the live run replaces them)

Fees by the documented formula, using our Foundry gas figures:
- Lasna: max(price, basefee) × (gas + 100k) at ~100 gwei.
- Callbacks: price × 1.1 × (gas + 80k) on the L2s.

| Path, per loop | Reactive txs (lREACT) | Callbacks (L2 ETH) | Origin tx |
|---|---|---|---|
| top-up | 2 (Short, GrantApplied): ≈ 0.04–0.08 each, so ≈ 0.1 | 1–2 (grant ≈ 205k gas, sometimes a heartbeat): ≈ 0.000003 each at 0.01 gwei | 1 `pay` ≈ 60–100k gas |
| donor | 4–5 (Short, Reclaimed, Verified, GrantApplied, Cron) ≈ 0.3 | 3–4 (reclaim, re-read, grant) | 1–3 `pay` |
| STOP | ~8–10 (press, acks, rolls, re-reads, unstop) ≈ 0.6 | ~6 (epoch to each chain twice, re-reads) | `stop` + `unstop` |
| idle (per day) | Cron1000 ~75–85 ticks plus heartbeat answers: a few lREACT a day (up to ~4.6 if every tick were the heaviest measured) | ~3 heartbeats per ~51–56 min | — |

A 2-day run with 20 top-up, 10 donor and 20 STOP loops comes to roughly:
- **0.45** (deploy) + **2 + 3 + 12** (loops) + **~8** (idle) ≈ **25 lREACT**, which is why the run book funds 20 + 1 and keeps the faucet's 30;
- **≈ 0.02 ETH per L2** with generous gas prices;
- **≤ 80 USDC** of faucet USDC, which keeps moving between vault, wallet and payee and is not consumed if the payee is the deployer.

## 8. What to record for the submission and the judges

- Every hash from `broadcast/` and `live/loops.jsonl`: origin tx → reactive tx → `getCallbacks` → destination tx.
- Median and p95 latency per path, from `summary`.
- The Cron1000 period measured on Lasna.
- The real charged cost: reserves/debt before and after a known number of loops, compared with the formula above.
- USDC callback gas: the grant callback's `gasUsed` against the 700k limit, and whether the proxy accepted a 700k limit and billed on gas used.

## Unsure / to confirm live

- How a reactive tx links to its origin tx. The logger matches the first coordinator event of the right kind after the origin block's time. Fine for one loop at a time; don't overlap loops of the same path.
- `getCallbacks`' exact return encoding. The logger parses `cast call --json`, and falls back to printing the raw output.
- `depositTo` on the system contract and proxies, and `reserves`/`debt`: from DOCS_BRIEF, not from the library.
- The USDC addresses above, and whether the Circle faucet gives enough per request.
- Whether the constructor's subscriptions are charged, and whether a contract that hasn't paid yet already receives Cron ticks.
