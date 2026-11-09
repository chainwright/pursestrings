# Live loop run book: Lasna ↔ Base Sepolia ↔ Unichain Sepolia

**Status (09.11.2026 UTC):** the staged smoke test (steps A–E) passed live on 07.11 UTC (`live/LIVE_RUN_2026-11-07.md`), and the compact series in §6 ran on 09.11 (`live/SERIES_2026-11-09.md`). The coordinator has been paused since 09.11 09:15 UTC, debt 0.0142 lREACT (a paused coordinator is not charged). Contract addresses and creation hashes: `deployments/README.md`.

Still open with the Reactive developers (t.me/reactivedevs):
- delivery depth (head, safe or finalized);
- duplicate delivery;
- retries of failed callbacks;
- the cost of a callback request;
- whether origin logs emitted while a coordinator is in debt are dropped or queued, and whether Cron resumes by itself after `depositTo`.

Their answers can change the waits in `src/reactive/TestnetConfig.sol`. Those are immutable in the deployed coordinator, so a change means a redeploy.

Everything below has been rehearsed end to end on three local anvil chains with the real chain ids: `script/dryrun.sh`, exit 0, no network.

## Measured

| Fact | Value | How |
|---|---|---|
| Lasna block time | **1.064 s per block** over 10,000 blocks (06.11) | block timestamps |
| Cron1000 period, **observed** | **1,059.5 s mean (17.66 min)** over 173 intervals, range 1,050–1,074 s; the model's 17.74 min (from block time) is 0.5 % off | timestamps of tick blocks n·1000+1, 7,716,001 → 7,889,001 |
| Ticks received while funded | **76 of 76**; our reactive tx lands in block n·1000+1 | tick blocks; `loop_logger.py cron-check --block N` reads one |
| Idle tick gas | 93–115k (median 115k) ≈ 0.019–0.022 lREACT at 100 gwei; a tick with a heartbeat callback 149–179k; the heaviest live react 507,771 (the pre-grant tick, block 7,790,001) | receipts |
| Short react with a grant / STOP react | 349,065 gas (0.045 lREACT at 100 gwei) / 272,350 (0.037) | `live/loops.jsonl` |
| USDC grant callback | **245,809 gas** for the whole destination tx (limit 700k); EpochAck callbacks 158,490 (Base) and 120,893 (Unichain) | `live/loops.jsonl` |
| Callback cost on the L2s | < 1e-6 ETH each (Base front reserve 0.002 → 0.0019739 ETH after ~35 callbacks) | proxy `reserves(front)` |
| Idle running cost | **≈ 2.9 lREACT a day at 100 gwei** (≈ 5 at 175): the 3-lREACT deposit lasted ≈ 22 h with the smoke test inside | ticks + reserves |
| Top-up and STOP latency | 2 s each (one loop each, 07.11) | `live/loops.jsonl` |
| Lasna gas price | 100 gwei (07.11 and 09.11 03:18 UTC; 175 on 06.11) | `cast gas-price` |
| USDC on Base Sepolia and Unichain Sepolia | 6 decimals, EIP-712 version "2", at the addresses in §1 | `decimals()`, `version()` |
| Deploy | coordinator CREATE 4,593,296 gas at 110 gwei = 0.505 lREACT; the L2 sides ≈ 0.00005 / 0.000005 ETH | receipts |
| Holdings (09.11 03:45 UTC) | deployer (0xeE7F…cbfc) **10.16 lREACT**, $16 USDC and ≈ 0.0045 ETH on each L2; agent 0.0005 ETH on each L2 | balances |
| Agent | address `0xf22aE6D4425cD74a4B1e04705ba71a4EAD6D2b14`; its key comes from your own secret store (§1) | — |

## 0. What is where

| Piece | File | Sends txs? |
|---|---|---|
| Deploy all three chains, with the coordinator's address predicted | `script/Deploy.s.sol` | only with `--broadcast` |
| Wiring checks on every chain | `script/Check.s.sol` (`run()`) | no |
| Origin txs (pay, stop, unstop), funding (reserves, vaults, agent gas), cap, faucet | `script/Loop.s.sol` | yes (`--broadcast`) |
| Trace origin → reactive tx → `getCallbacks` → the callback that answers it; summary; `cron-check` (is the coordinator getting ticks?) | `script/loop_logger.py` (offline tests: `script/test_loop_logger.py`) | no (read-only, no key) |
| The agent that keeps asking until served, then pays (donor path) | `script/agent_retry.py` (runs `Loop.s.sol pay`) | yes (agent pays) |
| Full rehearsal on local anvils | `script/dryrun.sh` (+ `script/dryrun_relay.py`) | local only |

The contracts are built on **reactive-lib-omni v0.1.0** (`lib/reactive-lib-omni`, commit 3ade0dc). Its `LogRecord` and `CallbackConfiguration_V_1_0` field order match what the spike assumed.

## 1. Environment (names only; nothing secret is ever printed or written)

Run the whole session in a subshell (`bash`, then `exit` at the end), so the keys don't outlive it. Or `unset DEPLOYER_PRIVATE_KEY AGENT_PRIVATE_KEY` when done.

```bash
cd pursestrings   # the repo root
export PATH=$HOME/.foundry/bin:$PATH
export LASNA_RPC_URL=https://lasna-rpc.rnk.dev/
export BASE_SEPOLIA_RPC_URL=<your Base Sepolia RPC>
export UNICHAIN_SEPOLIA_RPC_URL=<your Unichain Sepolia RPC>

# keys: read them from your own secret store or env var into the environment; never echo them
export DEPLOYER_PRIVATE_KEY="$(<your secret store's read command> deployer)"   # deployer = owner, 0xeE7F…cbfc
export AGENT_PRIVATE_KEY="$(<your secret store's read command> agent)"         # agent
export AGENT_ADDRESS=0xf22aE6D4425cD74a4B1e04705ba71a4EAD6D2b14
export PAYEE_ADDRESS=0xeE7F470E1C47431b033F8638E932a9ebfFB3cbfc   # the deployer: paid USDC can go back to the vaults

export USDC_BASE_SEPOLIA=0x036CbD53842c5426634e7929541eC2318f3dCF7e      # checked 06.11: 6 decimals, version "2"
export USDC_UNICHAIN_SEPOLIA=0x31d0220469e10c4E71834a79b1f276d740d3768F  # checked 06.11: 6 decimals, version "2"
export DEPLOYMENTS_FILE=deployments/latest.json
```

- Every script reads the keys with `vm.envUint` inside forge, so they never appear on a command line or in the process list. A `-vvvv` trace shows `<env var value>`, not the key. The logger needs no key.
- **Creating a key:** let your secret store generate it, or pass the value on stdin. A key given as a command-line argument to any tool is briefly visible in the process list (`ps`).

## 2. Rehearse (free, no network)

```bash
script/dryrun.sh
```

Expected output:
- `ONCHAIN EXECUTION COMPLETE & SUCCESSFUL`, with the predicted coordinator address equal to the deployed one;
- three "wiring ok" lines;
- `dry-run loop ok`;
- logger traces: two top-ups on Base back to back, `matched ['GrantApplied#1']` then `matched ['GrantApplied#2']` (the second loop must not take the first one's grant), linked by the origin tx hash; a STOP, `matched ['EpochAck(1, frozen) on base', 'EpochAck(1, frozen) on unichain']`, traced twice and counted once by `summary`;
- the agent retry: `steps ['ask', 'ask', 'served', 'paid']`, and an unservable ask exits 2;
- six `ok` lines from the loop driver.

## 3. How the deploy can and can't go wrong (read before step B)

- **The address checks in `Deploy.s.sol` run in forge's simulation only.** These are `require(nonce unchanged)` and `require(coordinator == predicted)`. In the simulation nothing else touches the Lasna nonce, so they can't fail there.
- **The real guard is the fixed nonce.** Forge broadcasts the coordinator's CREATE with the nonce fixed in the simulation. It either lands at the predicted address, or it is rejected ("nonce too low") and the already-deployed L2 sides are orphaned and must be redeployed. A coordinator at an address the fronts don't pin cannot happen.
- **Don't use the deployer key for anything else on Lasna during the deploy.**
- `deployments/latest.json` is written during the simulation, so after a failed broadcast it describes contracts that don't exist. **`script/Check.s.sol` after every deploy is the real verification.** Fund nothing before it passes.
- Failure cases: an orphaned L2 side holds no funds when FRONT_FUNDING_WEI = 0, and vaults are empty at deploy. If the coordinator lands and an L2 side fails, it is a live, subscribed contract with no working fronts, and whatever you put into it is gone: **it has no withdraw, no unsubscribe and no owner**. That is why it is deployed with 0 lREACT attached, and funded only after Check.

## 4. Timing

- **Never deploy or loop in the 2 h before 00:00 UTC: 22:00–24:00 UTC** (`TZ=UTC date` to check). In that window the coordinator pre-grants tomorrow's share. Before the vaults are funded, those come back as void grants, each with a 30-min confirmation wait. They also emit `GrantSent` events for the next day. The logger ignores those, but they muddy the first run.
- Start in a UTC morning (from 00:00 UTC), so a whole UTC day is available.
- **Fund both vaults before the first payment.** Otherwise the first grant isn't applied (NA_UNFUNDED), and the loop waits ~40 min for the void credit.

## 5. Staged smoke test (run on 07.11, kept as the record of how)

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
- CAP is $4 a day for the smoke test. A surprise then moves at most $4 of faucet USDC. Raise it later with `setCap`; a raise applies at once.
- `--gas-estimate-multiplier 200` gives headroom on Lasna. Gas that isn't used is not charged.
- **Learned live (07.11): the public Lasna RPC refuses any tx whose gasLimit × maxFee exceeds 1 lREACT** ("tx fee (1.84 ether) exceeds the configured cap"). With the ×2 multiplier the coordinator's CREATE was refused while both L2 sides landed. Nothing was spent on Lasna and the nonce stayed 0, so the same initcode (from `broadcast/multi/Deploy.s.sol-latest/run.json`) was sent with `cast send --create --legacy --gas-price 110gwei --gas-limit 7000000 --nonce 0` and landed at the predicted address. Next time: deploy the L2 sides with forge and the coordinator this way, or use a multiplier ≤ 130 with an explicit legacy price.
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
- Steps A–E passed on 07.11. The series in §6 replaces the old "setCap 40000000, vaults to $40 each" plan.

## Budget of the smoke test, as it went (07.11; replaces the 06.11 estimate)

| Item | Estimated 06.11 (175 gwei) | Measured |
|---|---|---|
| Deploy on Lasna | 1.04 lREACT | **0.505 lREACT** (4.59 M gas at 110 gwei, legacy) |
| Reserves deposit | 3 | 3, used up in ≈ 22 h |
| 1 top-up loop | ≈ 0.2 | the Short react 349k gas (0.045 at 100 gwei) + its GrantApplied react |
| 1 STOP + unstop | ≈ 0.5–1.0 | the STOP react 272k gas (0.037) + the EpochAck / unstop reacts |
| Idle Cron + heartbeat answers | ≈ 3–5 per ½ day, "6–10 a day at 175 gwei" | **≈ 2.9 lREACT a day at 100 gwei** (≈ 1.5 per ½ day; ≈ 5 a day at 175) |
| L2 callbacks | ≈ 0.003 ETH per L2 | < 1e-6 ETH each |

- **The faucet converts 1 ETH to 100 lREACT** (Reactive's docs): send ETH to the faucet contract on Base Sepolia (`0x2afaFD298b23b62760711756088F75B7409f5967`, `forge script script/Loop.s.sol --sig "faucet(uint256)" <wei> --broadcast`) or on Sepolia (`0x9b9BB25f1A81078C544C829c5EB7822d747Cf434`, `script/SepoliaFaucet.s.sol`). At most 5 ETH per tx; anything above that is lost. On 08.11 a 0.05 Sepolia ETH drip bought ≈ 5 lREACT, so the deployer holds 10.16.
- Never deposit much at once into the coordinator's reserves: it can't be recovered. A coordinator that runs out pauses (debt, no reacts) and costs nothing while paused.

## 6. The compact live series (run on 09.11.2026)

10 top-up loops, 3 donor loops, 5 STOP cycles, in that order, in one session. The order matters: every epoch roll drains both wallets into their vaults, so STOP goes last; the donor loops need the pool empty and Unichain holding slack, which the top-up phase leaves behind.

### Go / no-go

| Lasna gas (`cast gas-price`) | Plan |
|---|---|
| ≤ 120 gwei | **full**: 10 top-up / 3 donor / 5 STOP |
| 120–180 gwei | **trimmed**: 10 / 2 / 3 |
| > 180 gwei | **no-go**: wait a day |

Re-read the gas at every phase boundary. If it crosses 180, finish the loop in progress and stop the series there.

### When

- **Origin transactions only between 14:00 and 19:00 UTC** (any 5-h window early in a UTC day works; the 09.11 series started at 05:17 UTC), so the whole series stays inside one UTC day. Check with `TZ=UTC date` before starting.
- **Never 22:00–24:00 UTC**: the coordinator pre-grants tomorrow then. The read-only tail of Phase 4 and Phase 5 may run past 19:00, but end before 21:30 UTC.
- Timeline at the full plan (UTC): Phase 0–1 14:00–14:35, Phase 2 14:35–15:10 (T7 ≈ 14:55), Phase 3 from T7 + 41 min ≈ 15:40 to ≈ 17:30, Phase 4 ≈ 17:30–18:00 plus the 45-min tail, Phase 5 ≈ 18:50. If Phase 3 can't start by 16:00 UTC, run the trimmed donor count (2).

### Reserves (lREACT)

- Phase 1 deposits **3 lREACT** (the deposit settles the 0.0076 debt first).
- Read the reserves at every phase boundary. **Below 1.5 before Phase 3 or Phase 4: deposit 1.5 more**, once.
- **The deployer must keep ≥ 4.5 lREACT after the series** (the final deployment and its short hash set need ≈ 0.5 + 2.5). 10.16 − 3 − 1.5 ≈ 5.6, so there is room for one 1.5 top-up, not two. If a second one would be needed, run fewer STOP cycles instead (≈ 0.4 lREACT each at 100 gwei).
- Before each STOP cycle the reserves must be ≥ 0.5; otherwise stop the series there.
- **Don't deposit at the end.** What is left idles away at ≈ 3 a day, then the coordinator pauses again, at no cost.

### Environment

As in §1, in a subshell, plus:

```bash
export LOOPS_FILE=live/series_2026-11-09.jsonl        # fresh; live/loops.jsonl stays the 07.11 record, untouched
export AGENT_LOG=live/series_2026-11-09_agent.jsonl   # every agent ask of the donor phase
SYS=0x8888888888888888888888888888888888888888
RC=$(python3 -c "import json;print(json.load(open('deployments/latest.json'))['coordinator'])")
W0=$(python3 -c "import json;print(json.load(open('deployments/latest.json'))['base']['wallet'])")
W1=$(python3 -c "import json;print(json.load(open('deployments/latest.json'))['unichain']['wallet'])")
V0=$(python3 -c "import json;print(json.load(open('deployments/latest.json'))['base']['vault'])")
V1=$(python3 -c "import json;print(json.load(open('deployments/latest.json'))['unichain']['vault'])")
F0=$(python3 -c "import json;print(json.load(open('deployments/latest.json'))['base']['front'])")
F1=$(python3 -c "import json;print(json.load(open('deployments/latest.json'))['unichain']['front'])")
B=$BASE_SEPOLIA_RPC_URL; U=$UNICHAIN_SEPOLIA_RPC_URL; LA=$LASNA_RPC_URL

# read-only snapshot: gas, coordinator reserves/debt/cap/pool, deployer lREACT, per chain wallet unspent, vault and wallet USDC, front reserves
snap() {
  local d; d=$(( $(cast block latest --field timestamp --rpc-url $LA) / 86400 ))
  echo "$(TZ=UTC date +%H:%M:%SZ) gas $(cast gas-price --rpc-url $LA) day $d"
  echo " RC reserves $(cast call $SYS 'reserves(address)(uint256)' $RC --rpc-url $LA) debt $(cast call $SYS 'debt(address)(uint256)' $RC --rpc-url $LA)"
  echo " RC cap $(cast call $RC 'capOfDay(uint64)(uint256)' $d --rpc-url $LA) pool $(cast call $RC 'poolOf(uint64)(uint256)' $d --rpc-url $LA) epoch $(cast call $RC 'epoch()(uint64)' --rpc-url $LA) frozen $(cast call $RC 'frozen()(bool)' --rpc-url $LA)"
  echo " deployer $(cast balance 0xeE7F470E1C47431b033F8638E932a9ebfFB3cbfc --rpc-url $LA --ether) lREACT"
  for c in "B $B $W0 $V0 $F0 $USDC_BASE_SEPOLIA 0x476F44b11F5C942c58f4c8E3d0300E5710743585" "U $U $W1 $V1 $F1 $USDC_UNICHAIN_SEPOLIA 0x775c9B990ADe401060B78D0e98684eEf8d2466C1"; do
    set -- $c
    echo " $1 unspent $(cast call $3 'unspentOf(uint64)(uint256)' $(cast call $3 'today()(uint64)' --rpc-url $2 | cut -d' ' -f1) --rpc-url $2) vault $(cast call $6 'balanceOf(address)(uint256)' $4 --rpc-url $2) wallet $(cast call $6 'balanceOf(address)(uint256)' $3 --rpc-url $2) front reserves $(cast call $7 'reserves(address)(uint256)' $5 --rpc-url $2)"
  done
}

# one top-up loop: $1 chain (0 base, 1 unichain), $2 amount. Origin, then its trace; then 60 s
# before the next origin (belt and braces with the logger's floors)
topup() {
  local n; n=$([ "$1" = 0 ] && echo base || echo unichain)
  forge script script/Loop.s.sol --sig "pay(uint256,uint256)" $1 $2 --broadcast | grep -E "unspent before|paid|refused"
  local o; o=$(python3 script/loop_logger.py last-tx --fn pay --chain $n); echo "origin $o"
  python3 script/loop_logger.py trace --path topup --chain $n --tx "$o" --timeout-min 10
  sleep 60
}
```

### Phase 0: read-only (5 min)

```bash
TZ=UTC date; snap | tee live/series_2026-11-09_phase0.txt
echo "B0=$(cast block-number --rpc-url $B) U0=$(cast block-number --rpc-url $U)" | tee -a live/series_2026-11-09_phase0.txt   # for the checker in Phase 5
```
Apply the go rule to the gas line.

### Phase 1: resume (≤ 25 min)

```bash
forge script script/Loop.s.sol --sig "fundReserves(uint256,uint256)" 3000000000000000000 0 --broadcast   # 3 lREACT; settles the 0.0076 debt first
forge script script/Loop.s.sol --sig "fundVault(uint256,uint256)" 0 15000000 --broadcast   # Base vault: 2.67 + 1.33 (swept back) + 15 = $19 for $18 of grants
forge script script/Loop.s.sol --sig "fundVault(uint256,uint256)" 1 6000000 --broadcast    # Unichain vault: 2.67 + 1.33 + 6 = $10 for $8 of grants
python3 script/loop_logger.py cron-check --wait-min 20    # the next tick block must hold our reactive tx
```
- `cron-check` waits for the next tick block (n·1000 + 1), lists our reactive tx in it with its gas, and the reserves before and after (≈ 0.02–0.03 less).
- **No tick within 20 min after the deposit: stop.** Ask the Reactive developers and don't burn more.
- Base needs $18 of backing: 12 for the six Phase 2 grants and 6 for the three donor grants (a reclaim returns Unichain's tokens to the Unichain vault; the Base grant is pulled from the Base vault). 14 would leave exactly $18.000000; 15 leaves $1 of margin. The deployer holds $16 per chain, and paid USDC comes back to it (it is the payee).

```bash
forge script script/Loop.s.sol --sig "setCap(uint256)" 20000000 --broadcast
sleep 30; snap      # RC cap 20000000 and pool 20000000 for today; both wallets' unspent 0
```

At CAP $20: chunk $2 (`cap / 10`), floor $2, low water $1, per-call cap $10.

### Phase 2: 10 top-up loops (≈ 35 min)

Each line: `topup <chain> <amount>`. Chain 0 = Base (B), 1 = Unichain (U).

| # | Command | What happens | Wallet after |
|---|---|---|---|
| T1 | `topup 1 1000000` | U refused (Short) → grant $2 | U 2 |
| T2 | `topup 0 1000000` | B refused (Short) → grant $2 | B 2 |
| R2 | `forge script script/Loop.s.sol --sig "pay(uint256,uint256)" 0 1000000 --broadcast` | B **paid** $1: the "refused → served → paid" moment; record the hash, no trace | B 1 |
| T3 | `topup 1 3000000` | U refused, short by 1 → grant $2 | U 4 |
| T4 | `topup 0 1000000` | B **paid**, leaves 0 < $1: LowWater → top-up $2 | B 2 |
| T5 | `topup 1 5000000` | U refused → grant $2 | U 6 |
| T6 | `topup 0 2000000` | B paid, LowWater → top-up | B 2 |
| T7 | `topup 1 7000000` | U refused → grant $2. **U's last ask: note the time** | U 8 |
| T8 | `topup 0 2000000` | B paid, LowWater → top-up | B 2 |
| T9 | `topup 0 2000000` | same | B 2 |
| T10 | `topup 0 2000000` | same; the pool is now **0** | B 2 |

- Each loop triggers exactly one top-up: a $2 grant (6 to B, 4 to U = $20).
- Sub-paths, n = 5 each: refusal T1, T2, T3, T5, T7; LowWater top-up after a paid call T4, T6, T8, T9, T10. Report them separately and together (n = 10).
- **Unichain must end with $8 unspent** for the three donor loops (8 → 6 → 4 → 2, its floor). So no payment on U in this phase. (Paying $1 on U after T1, T3, T5 and T7 would leave U at $4–7, so the served-then-paid moment is R2 on Base instead, which keeps T4 a LowWater top-up.)
- Paid in Phase 2: $10 on B (R2 1 + T4 1 + 4 × 2).
- `snap` after T10: pool 0, U unspent 8000000, B unspent 2000000. Reserves ≥ 1.5, or deposit 1.5 now.

### Phase 3: 3 donor loops (≈ 1 h 50; trimmed plan: 2)

Start **D1 no earlier than T7 + 41 min**: a chain that asked within its 40-min want TTL is no donor. The donor phase needs the agent to keep asking: a single ask lapses 40 min after it, while the credit lands after the 30-min L2 wait plus up to one Cron period. `script/agent_retry.py` asks `pay $1` every 310 s (Short re-arms at 300 s) until the grant lands, then pays it.

```bash
donor() {  # $1 = origin amount on Base: 2000000 for D1, 1000000 for D2 and D3
  forge script script/Loop.s.sol --sig "pay(uint256,uint256)" 0 $1 --broadcast | grep -E "unspent before|paid|refused"
  local o; o=$(python3 script/loop_logger.py last-tx --fn pay --chain base)   # BEFORE the retries overwrite pay-latest.json
  echo "donor origin $o"
  python3 script/loop_logger.py trace --path donor --chain base --tx "$o" --timeout-min 80 > "live/series_2026-11-09_donor_${o:2:8}.json" &
  local t=$!
  python3 script/agent_retry.py --chain base --amount 1000000 --every-sec 310 --timeout-min 80
  local rc=$?
  wait $t; cat "live/series_2026-11-09_donor_${o:2:8}.json"
  return $rc
}
donor 2000000 && sleep 60 && donor 1000000 && sleep 60 && donor 1000000
```

- Each origin is a paid LowWater on B (B 2 → 0, then 1 → 0): the pool is empty, so the coordinator asks U for a reclaim of $2. U's unspent goes 8 → 6 → 4 → 2.
- `agent_retry.py` ends with `served` then `paid` (B left $1) and exit 0. **Exit 2** (not served within 80 min): stop the donor phase, `snap`, check the reserves and debt, and whether U is still above its floor; don't start the next donor loop. **Exit 3** (served, but the final pay refused): the same, plus read the wallet's Refused reason in that receipt.
- Expected latency **30–36 min with the agent retrying every 5 min** (model bound 1 h 40). Report it with that wording.
- Record for each loop (the trace JSON has them): the ReclaimSent reactive tx and its `applyReclaim` callback on U (Reclaimed), the `verify` callback's landing time, the Credited reactive tx, and GrantApplied on B. That splits the 30-min wait from the rest.
- `snap` after D3; reserves ≥ 1.5 before Phase 4, or deposit 1.5 now (if not used yet).

### Phase 4: 5 STOP cycles (≈ 30 min + 45 min tail; trimmed plan: 3)

Only after the donor loops.

```bash
# First block of the last $2 seconds on RPC $1, from the chain's measured block time. A fixed
# "head - 150" covered only ~30 s on Base Sepolia (~0.2 s/block) and missed every ack on 09.11.
since() {
  local h t0 t1; h=$(cast block-number --rpc-url $1)
  t1=$(cast block $h --field timestamp --rpc-url $1); t0=$(cast block $((h - 1000)) --field timestamp --rpc-url $1)
  echo $(( h - $2 * 1000 / (t1 - t0 > 0 ? t1 - t0 : 1) ))
}
stopcycle() {  # $1 = chain that presses: 1, 0, 1, 0, 1
  local n; n=$([ "$1" = 0 ] && echo base || echo unichain)
  forge script script/Loop.s.sol --sig "stop(uint256)" $1 --broadcast | grep -E "STOP"
  local o; o=$(python3 script/loop_logger.py last-tx --fn stop --chain $n); echo "press $o"
  python3 script/loop_logger.py trace --path stop --chain $n --tx "$o" --timeout-min 10 | tee /dev/stderr | grep -q '"complete": true' \
    || { echo "STOP trace incomplete: no unstop; check snap"; return 1; }
  forge script script/Loop.s.sol --sig "unstop()" --broadcast | grep -E "unstop sent"
  echo "unstop $(python3 script/loop_logger.py last-tx --fn unstop --chain base)"
  sleep 40   # then the EpochAck(e+1, false) on both chains, recorded by hand (the logger has no unstop path)
  cast logs --from-block $(since $B 180) --address $W0 'EpochAck(uint64,bool,uint64)' --rpc-url $B | grep -E "transactionHash|data"
  cast logs --from-block $(since $U 180) --address $W1 'EpochAck(uint64,bool,uint64)' --rpc-url $U | grep -E "transactionHash|data"
  sleep 80   # >= 2 min between presses
}
for c in 1 0 1 0 1; do stopcycle $c || break; done
```

- Latency = press → the last `EpochAck(e, frozen)` on every chain: the "$0.00 chain by chain" figure, n = 5.
- Before each cycle: reserves ≥ 0.5 (`snap`), or stop here.
- Then leave it running ≈ 45 min, read-only: the epoch resends stop once the 30-min K_EPOCH re-reads confirm, and the K_ROLL credits return the drained allowance to the pool. `snap` at the end.

### Phase 5: close (10 min, read-only)

```bash
python3 script/loop_logger.py summary          # one record per origin (re-traces dropped)
snap | tee live/series_2026-11-09_close.txt
python3 script/loop_logger.py paid-sum --chain base --from-block $B0
python3 script/loop_logger.py paid-sum --chain unichain --from-block $U0
```
- The checker: today's Paid sum over both chains must be ≤ $20 (expected: B $10 in Phase 2 + $7 in Phase 3 (origins 2 + 1 + 1, final pays 1 + 1 + 1) = $17; U $0). Base backing: $18 granted = $17 paid + $1 left.
- Conservation per chain: vault + wallet = funded − Σ paid.
- The real charged cost: reserves at Phase 0 / each boundary / close, against the formula fees the logger records.
- Write `live/LIVE_RUN_2026-11-09.md`, then commit `broadcast/`, the series files and the run note.

### Expected spend (measured gas where we have it; answer reacts assumed at 0.02–0.03 lREACT each at 100 gwei)

| Phase | Reacts (approx.) | lREACT at 100 gwei | at 175 gwei |
|---|---|---|---|
| Idle Cron + heartbeats over ~5 h (17 ticks, ~11 beats with their answers) | ~40 | 0.7 | 1.2 |
| Resume (debt, first ticks, sweeps) + setCap | ~6 | 0.15 | 0.25 |
| 10 top-ups (origin react 0.045 + GrantApplied 0.025) | 20 | 0.7 | 1.2 |
| 3 donors (LowWater + Reclaimed + ~6 agent Shorts + verify/Verified + GrantApplied) | ~33 | 0.9 | 1.5 |
| 5 STOP cycles = 10 epochs (press or unstop, 2 EpochAck, 2 Rolled each) + tail (20 K_ROLL and 2 K_EPOCH re-reads, ~4 resends) | ~90 | 2.1 | 3.7 |
| **Total** | | **≈ 4.5 (3 + 1.5 deposited)** | **≈ 7.9** |

- Trimmed plan (10 / 2 / 3): ≈ 3.3 at 100 gwei, ≈ 5.8 at 175.
- L2 ETH: about 40 agent pays at ~57k gas, < 0.00002 ETH per chain (the agent holds 0.0005); callbacks < 1e-6 ETH each.

### Sample size

This series gives **n = 10 top-ups**: state "median of 10". Ten more come from the final deployment (where the submission's hashes must come from anyway; report per deployment). Target: top-up median ≤ 6 s (both live loops so far: 2 s). Donor and STOP are reported separately.

## 7. What to record for the submission and the judges

- Every hash, from `broadcast/`, `deployments/README.md` and the series files: origin tx → reactive tx → `getCallbacks` → destination tx (the answering one).
- Median and p95 latency per path (`summary`).
- The Cron1000 period: observed 17.66 min; `cron-check` adds single ticks.
- The real charged cost: reserves/debt before and after a known number of loops, against the formula.
- USDC callback gas: 245,809 against the 700k limit (measured). Still open: whether the proxy bills on gas used or on the limit (compare the front reserves' drop per callback with both).
- The first successful agent payments on-chain (R2 and the donor loops' final pays) and the checker's sum.

## Unsure / to confirm live

- How a reactive tx links to its origin: **resolved.** The reactive tx's input holds the origin tx hash (its LogRecord), seen on both 07.11 loops; the logger now links on it and falls back to time and id floors only after a 90-s grace.
- `getCallbacks` is served at `0x…ffffff` on Lasna, not by the system contract (07.11). The logger parses `cast call --json` and falls back to raw output.
- `depositTo`, `reserves` and `debt` come from Reactive's docs, not the library (they worked live on 07.11).
- Whether Cron delivery restarts by itself after a paused coordinator is funded again: the first check of Phase 1.
- Whether origin logs emitted while the coordinator is in debt are dropped or queued.
