# Live loop run book (gate part 2): Lasna ↔ Base Sepolia ↔ Unichain Sepolia

**Status: prepared, not run.** No network transaction has been sent. Wait for reactivedevs' answers first, on:
- delivery depth (head, safe or finalized);
- duplicate delivery;
- retries of failed callbacks;
- the cost of a callback request.

Their answers can change the waits in `src/reactive/TestnetConfig.sol`. Those are immutable in the deployed coordinator, so a change means a redeploy.

Everything below has been rehearsed end to end on three local anvil chains with the real chain ids: `script/dryrun.sh`, exit 0, no network.

## Measured so far (06.11.2026, read-only; no transaction)

| Fact | Value | How |
|---|---|---|
| Lasna block time | **1.064 s per block** over 10,000 blocks, so **Cron1000 ≈ 17.74 min** (1,064 s) | block timestamps; the model's default now (was 18.5 min from one 100-block sample) |
| Lasna gas price | **175 gwei** (DOCS_BRIEF read 100 on 04.11) | `cast gas-price` |
| USDC on Base Sepolia and Unichain Sepolia | 6 decimals, EIP-712 version "2", at the addresses in §1 | `decimals()`, `version()` |
| Deploy simulated on forks of all three real chains (no `--broadcast`; CAP=4000000, FRONT_FUNDING_WEI=0, RC_FUNDING_WEI=0) | **succeeded**: the real system contract ran the 23 `subscribe` calls, and the coordinator landed at the predicted address | `forge script script/Deploy.s.sol` |
| Estimated deploy cost | Lasna **5.97 M gas ≈ 1.04 lREACT** at 175 gwei; Base Sepolia ≈ 0.00005 ETH; Unichain Sepolia ≈ 0.000005 ETH | the simulation |
| Deployer (S76, 0xeE7F…cbfc) holds | **3.15 lREACT**; **0.007 ETH** on Base Sepolia; **0.007 ETH** on Unichain Sepolia | balances |
| Agent | key in the secret store as **S77**, address `0xf22aE6D4425cD74a4B1e04705ba71a4EAD6D2b14` | — |

## 0. What is where

| Piece | File | Sends txs? |
|---|---|---|
| Deploy all three chains, with the coordinator's address predicted | `script/Deploy.s.sol` | only with `--broadcast` |
| Wiring checks on every chain | `script/Check.s.sol` (`run()`) | no |
| Origin txs (pay, stop, unstop), funding (reserves, vaults, agent gas), cap, faucet | `script/Loop.s.sol` | yes (`--broadcast`) |
| Trace origin → reactive tx → `getCallbacks` → the callback that answers it; summary | `script/loop_logger.py` | no (read-only, no key) |
| Full rehearsal on local anvils | `script/dryrun.sh` (+ `script/dryrun_relay.py`) | local only |

The contracts are built on **reactive-lib-omni v0.1.0** (`lib/reactive-lib-omni`, commit 3ade0dc). Its `LogRecord` and `CallbackConfiguration_V_1_0` field order match what the spike assumed.

## 1. Environment (names only; nothing secret is ever printed or written)

Run the whole session in a subshell (`bash`, then `exit` at the end), so the keys don't outlive it. Or `unset DEPLOYER_PRIVATE_KEY AGENT_PRIVATE_KEY` when done.

```bash
cd /Users/mini/agents/sora/hackathons/reactive_2026/pursestrings
export LASNA_RPC_URL=https://lasna-rpc.rnk.dev/
export BASE_SEPOLIA_RPC_URL=<your Base Sepolia RPC>
export UNICHAIN_SEPOLIA_RPC_URL=<your Unichain Sepolia RPC>

# keys: from the secret store into the environment; never echo them
export DEPLOYER_PRIVATE_KEY="$(python3 /Users/mini/agents/sora/scripts/secret.py S76)"   # deployer = owner, 0xeE7F…cbfc
export AGENT_PRIVATE_KEY="$(python3 /Users/mini/agents/sora/scripts/secret.py S77)"      # agent
export AGENT_ADDRESS=0xf22aE6D4425cD74a4B1e04705ba71a4EAD6D2b14
export PAYEE_ADDRESS=0xeE7F470E1C47431b033F8638E932a9ebfFB3cbfc   # the deployer: paid USDC can go back to the vaults

export USDC_BASE_SEPOLIA=0x036CbD53842c5426634e7929541eC2318f3dCF7e      # checked 06.11: 6 decimals, version "2"
export USDC_UNICHAIN_SEPOLIA=0x31d0220469e10c4E71834a79b1f276d740d3768F  # checked 06.11: 6 decimals, version "2"
export DEPLOYMENTS_FILE=deployments/latest.json
```

- Every script reads the keys with `vm.envUint` inside forge, so they never appear on a command line or in the process list. A `-vvvv` trace shows `<env var value>`, not the key (judge's test, round 6). The logger needs no key.
- **About the agent key:** it already exists as S77, so nothing needs creating.
  - The round-6 one-liner that created a key piped it into `scripts/secret.py --add "<value>" …`. That puts the value on `secret.py`'s command line, briefly visible in the process list (`ps`).
  - `secret.py` (outside this project) only takes the value as an argument. To create another key without that exposure, `secret.py` would first need to read the value from stdin.
  - For a TEST-ONLY key the exposure is small, but don't use that pattern for anything else.

## 2. Rehearse (free, no network)

```bash
script/dryrun.sh
```

Expected output:
- `ONCHAIN EXECUTION COMPLETE & SUCCESSFUL`, with the predicted coordinator address equal to the deployed one;
- three "wiring ok" lines;
- `dry-run loop ok`;
- two logger traces (top-up and STOP) with `matched ['GrantApplied#…']` and `matched ['EpochAck(…) on base', 'EpochAck(…) on unichain']`;
- six `ok` lines from the loop driver.

## 3. How the deploy can and can't go wrong (read before step B)

- **The address checks in `Deploy.s.sol` run in forge's simulation only.** These are `require(nonce unchanged)` and `require(coordinator == predicted)`. In the simulation nothing else touches the Lasna nonce, so they can't fail there.
- **The real guard is the fixed nonce.** Forge broadcasts the coordinator's CREATE with the nonce fixed in the simulation. It either lands at the predicted address, or it is rejected ("nonce too low") and the already-deployed L2 sides are orphaned and must be redeployed. A coordinator at an address the fronts don't pin cannot happen.
- **Don't use S76 for anything else on Lasna during the deploy.**
- `deployments/latest.json` is written during the simulation, so after a failed broadcast it describes contracts that don't exist. **`script/Check.s.sol` after every deploy is the real verification.** Fund nothing before it passes.
- Failure cases (judge round 6): an orphaned L2 side holds no funds when FRONT_FUNDING_WEI = 0, and vaults are empty at deploy. If the coordinator lands and an L2 side fails, it is a live, subscribed contract with no working fronts, and whatever you put into it is gone: **it has no withdraw, no unsubscribe and no owner**. That is why it is deployed with 0 lREACT attached, and funded only after Check.

## 4. Timing

- **Never deploy or loop in the 2 h before 00:00 UTC: 22:00–24:00 UTC = 16:00–18:00 CST** (`TZ=UTC date` to check). In that window the coordinator pre-grants tomorrow's share. Before the vaults are funded, those come back as void grants, each with a 30-min confirmation wait. They also emit `GrantSent` events for the next day. The logger ignores those, but they muddy the first run.
- Start in a UTC morning (from 00:00 UTC, i.e. after 18:00 CST), so a whole UTC day is available.
- **Fund both vaults before the first payment.** Otherwise the first grant isn't applied (NA_UNFUNDED), and the loop waits ~40 min for the void credit.

## 5. Staged smoke test (engineer_r6 §6, adjusted)

**Step A, free, read-only.** Already done on 06.11 (table above). Repeat on the day of the run:
```bash
for u in "$LASNA_RPC_URL" "$BASE_SEPOLIA_RPC_URL" "$UNICHAIN_SEPOLIA_RPC_URL"; do cast chain-id --rpc-url "$u"; done   # 5318007 / 84532 / 1301
cast gas-price --rpc-url "$LASNA_RPC_URL"
cast nonce 0xeE7F470E1C47431b033F8638E932a9ebfFB3cbfc --rpc-url "$LASNA_RPC_URL"
cast balance 0xeE7F470E1C47431b033F8638E932a9ebfFB3cbfc --rpc-url "$LASNA_RPC_URL" --ether
```

**Step B, free: simulate against the live chains (no `--broadcast`). Done once on 06.11; repeat just before deploying:**
```bash
CAP=4000000 FRONT_FUNDING_WEI=0 RC_FUNDING_WEI=0 forge script script/Deploy.s.sol
```
It must print the predicted coordinator, and simulate all three chains without a revert.

**Step C, ≈1.04 lREACT + a little L2 ETH: deploy with nothing attached, then verify:**
```bash
CAP=4000000 FRONT_FUNDING_WEI=0 RC_FUNDING_WEI=0 \
  forge script script/Deploy.s.sol --broadcast --slow --gas-estimate-multiplier 200
forge script script/Check.s.sol      # must print "base wiring ok", "unichain wiring ok", "coordinator wiring ok"
```
- CAP is $4 a day for the smoke test (judge D-4). A surprise then moves at most $4 of faucet USDC. Raise it later with `setCap`; a raise applies at once.
- `--gas-estimate-multiplier 200` gives headroom on Lasna. Gas that isn't used is not charged.
- Keep `broadcast/`: it holds every tx hash for the submission.

**Step D, only after Check passes: small funding, then watch idle Cron:**
```bash
forge script script/Loop.s.sol --sig "fundReserves(uint256,uint256)" 3000000000000000000 2000000000000000 --broadcast   # 3 lREACT; 0.002 ETH per front
forge script script/Loop.s.sol --sig "fundVault(uint256,uint256)" 0 4000000 --broadcast       # $4, Base Sepolia vault
forge script script/Loop.s.sol --sig "fundVault(uint256,uint256)" 1 4000000 --broadcast       # $4, Unichain Sepolia vault
forge script script/Loop.s.sol --sig "fundAgent(uint256,uint256)" 0 500000000000000 --broadcast   # 0.0005 ETH gas for the agent, Base
forge script script/Loop.s.sol --sig "fundAgent(uint256,uint256)" 1 500000000000000 --broadcast   # same, Unichain
RC=$(python3 -c "import json;print(json.load(open('deployments/latest.json'))['coordinator'])")
cast call 0x8888888888888888888888888888888888888888 "reserves(address)(uint256)" $RC --rpc-url "$LASNA_RPC_URL"
cast call 0x8888888888888888888888888888888888888888 "debt(address)(uint256)" $RC --rpc-url "$LASNA_RPC_URL"
```
- `fundReserves` refuses if there is no code at the system or proxy address.
- **Wait for 2–3 Cron ticks**, about 18 min each. Record when the coordinator's reactive txs arrive (the real Cron period), and how much each tick takes from the reserves. That is the first live measurement.
- Top up the reserves in 2–3 lREACT steps as they run down. Never deposit much at once: it can't be recovered.

**Step E, one top-up loop, then one STOP:**
```bash
forge script script/Loop.s.sol --sig "pay(uint256,uint256)" 0 1000000 --broadcast     # refused on Base Sepolia: Short
python3 script/loop_logger.py trace --path topup --chain base --tx "$(python3 script/loop_logger.py last-tx --fn pay --chain base)" --timeout-min 30
forge script script/Loop.s.sol --sig "stop(uint256)" 1 --broadcast
python3 script/loop_logger.py trace --path stop --chain unichain --tx "$(python3 script/loop_logger.py last-tx --fn stop --chain unichain)" --timeout-min 30
forge script script/Loop.s.sol --sig "unstop()" --broadcast
```
- The logger reports a loop as complete only when the wallet's own event is in a destination receipt: `GrantApplied` for this grant's id, or `EpochAck(e, frozen)` from every wallet. Latency is measured to that event. Heartbeats and other callbacks of the same reactive tx are listed as "other" and don't count.
- Only after steps A–E pass: `setCap 40000000`, top up the reserves, fund the vaults to $40 each, and run the series in §6.

## Budget for the staged smoke test (B–E plus about half a day of idle Cron) vs. what we hold

Fees by the documented formula (Lasna: price × (gas + 100k); callbacks: price × 1.1 × (gas + 80k)) at **175 gwei on Lasna**, with our Foundry gas. Estimates, except where marked measured.

| Item | lREACT | Base Sepolia ETH | Unichain Sepolia ETH |
|---|---|---|---|
| Deploy (simulated 06.11: 5.97 M gas on Lasna) | **1.04** | 0.00005 | 0.000005 |
| Reserves deposit (spent by the coordinator's reactive txs; front reserves pay callbacks) | **3** | 0.002 | 0.002 |
| Agent gas | — | 0.0005 | 0.0005 |
| 1 top-up loop (2 reactive txs ≈ 0.07–0.13 each) | ≈ 0.2, from reserves | callbacks ≈ 0 | — |
| 1 STOP + unstop (~8–10 reactive txs ≈ 0.05–0.1 each) | ≈ 0.5–1.0, from reserves | ≈ 0 | ≈ 0 |
| Idle Cron + heartbeat answers, ½ day (~40 ticks + ~40 answers, 0.04–0.1 each) | ≈ 3–5, from reserves | ≈ 0 | ≈ 0 |
| **Needed** | **≈ 4 to start (1.04 + 3), ≈ 6–8 to finish without going into debt** | **≈ 0.003** + faucet ETH | **≈ 0.003** |
| **We hold** (06.11) | **3.15** | **0.007** | **0.007** |

Reading it:
- **lREACT is short.** 3.15 covers the deploy (1.04) but not the 3-lREACT deposit after it, nor half a day of Cron. Get **≈ 5–10 lREACT more** before step C.
- **The faucet converts 1 ETH to 100 lREACT** (DOCS_BRIEF §4): send ETH to the faucet contract on Base Sepolia (`0x2afaFD298b23b62760711756088F75B7409f5967`) or Sepolia (`0x9b9BB25f1A81078C544C829c5EB7822d747Cf434`). At most 5 ETH per tx; anything above that is lost. So **0.05–0.1 Base Sepolia ETH buys 5–10 lREACT**: `forge script script/Loop.s.sol --sig "faucet(uint256)" 100000000000000000 --broadcast` (0.1 ETH, which the script caps at 5 ETH).
- **Base Sepolia ETH is short for that.** We hold 0.007. The smoke test itself needs ≈ 0.003 on each L2 (Unichain is covered), but buying lREACT through the Base Sepolia faucet needs **≈ 0.05–0.1 more Base Sepolia ETH**. Alternatively, use Sepolia ETH through the Sepolia faucet contract (not scripted; same `request(address)` call).
- At 175 gwei, idle running costs roughly **6–10 lREACT a day** (Cron plus heartbeat answers). It was "a few" at the 100 gwei read on 04.11; it scales with the Lasna gas price, and the idle-tick gas is unmeasured (a busy tick measures up to 484k). The live smoke test measures it from the reserves.

## 6. The 20-loop series (after the smoke test)

After each origin command, trace it. The logger polls for up to `--timeout-min` (default 120), appends one JSON line to `live/loops.jsonl`, and prints the matched answers. One loop at a time; not between 16:00 and 18:00 CST.

**Top-up path** (reserve → chain; target median ≤ 6 s, aim 3). Each loop serves one $2 chunk, so 20 loops need a $40 cap and vaults funded to $40 each:
```bash
forge script script/Loop.s.sol --sig "pay(uint256,uint256)" 0 1000000 --broadcast    # refused on Base Sepolia: Short
python3 script/loop_logger.py trace --path topup --chain base --tx "$(python3 script/loop_logger.py last-tx --fn pay --chain base)"
forge script script/Loop.s.sol --sig "pay(uint256,uint256)" 0 2000000 --broadcast    # spend the $2, so the next loop is short again
```
Alternate chain 0 and chain 1.

**Donor path** (reclaim from the other chain; expect the 30-min L2 wait plus a Cron tick, ~45–80 min; model bound 1h40):
1. Both chains hold allowance and the pool is empty: `pay` 10000000 refused on chain 0 and on chain 1, then about 2 min.
2. Wait at least 41 min, past the want TTL, so chain 1 is a donor again.
3. On chain 0, spend down to the floor and be short again: `pay 0 8000000`, then `pay 0 4000000` (refused).
4. Trace: `python3 script/loop_logger.py trace --path donor --chain base --tx "$(python3 script/loop_logger.py last-tx --fn pay --chain base)" --timeout-min 150`.

Each donor loop takes about an hour, so plan 5–10.

**STOP path:**
```bash
forge script script/Loop.s.sol --sig "stop(uint256)" 1 --broadcast
python3 script/loop_logger.py trace --path stop --chain unichain --tx "$(python3 script/loop_logger.py last-tx --fn stop --chain unichain)"
forge script script/Loop.s.sol --sig "unstop()" --broadcast       # after the trace completes
```
Latency is press → the last `EpochAck(e, frozen)` landed on every chain, which is the "$0.00 chain by chain" figure. Wait for the unfreeze to land before the next press.

**Summary:** `python3 script/loop_logger.py summary` prints per path: runs, completed, median/p95 latency, and formula fees.

Cost of the full series (estimates at 175 gwei; the smoke test replaces them):

| Path, per loop | Reactive txs (lREACT) | Callbacks (L2 ETH) |
|---|---|---|
| top-up | 2 ≈ 0.2 | 1–2, each ≈ 0.000003 at 0.01 gwei |
| donor | 4–5 ≈ 0.5 | 3–4 |
| STOP + unstop | ~8–10 ≈ 0.5–1.0 | ~6 |
| idle, per day | 6–10 | ~80 heartbeats |

20 top-up + 5–10 donor + 20 STOP over 2 days ≈ 4 + 5 + 15 + 15 ≈ **40 lREACT ≈ 0.4 ETH through the faucet**, plus ≈ 0.02 ETH per L2. The USDC keeps circulating if the payee is the deployer.

## 7. What to record for the submission and the judges

- Every hash, from `broadcast/` and `live/loops.jsonl`: origin tx → reactive tx → `getCallbacks` → destination tx (the answering one).
- Median and p95 latency per path.
- The observed Cron1000 period (reactive-tx times of idle ticks).
- The real charged cost: reserves/debt before and after a known number of loops, against the formula.
- USDC callback gas: the grant callback's `gasUsed` against the 700k limit, and whether the proxy accepted 700k and billed on gas used.

## Unsure / to confirm live

- How a reactive tx links to its origin tx. The logger matches the first coordinator event of the right kind, for the origin's UTC day, after the origin block's time. Fine for one loop at a time.
- `getCallbacks`' exact return encoding. The logger parses `cast call --json`, and falls back to raw output.
- `depositTo`, `reserves` and `debt` come from DOCS_BRIEF, not the library.
- Whether the 23 constructor subscriptions are charged (the fork simulation ran them; the live node may meter them natively), and whether an unfunded coordinator already receives Cron ticks.
- The idle-tick gas, so the real idle cost per day.
