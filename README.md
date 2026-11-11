# Pursestrings

**One daily allowance shared by your agents' wallets across chains:** one agent wallet per chain, deployed on Base Sepolia and Unichain Sepolia, coordinated from Reactive Lasna (whether the coordinator is funded right now: see Status). Money stays on its own chain (vault to wallet, same chain); only the permission moves. One STOP freezes the chain you press at once and every other chain within seconds (after the next deposit if the coordinator is paused).

For people who let AI agents pay for APIs and services on more than one chain and want one hard daily cap and one STOP that contracts enforce, with no server or custodian of ours in between.

**See it:** [pursestrings-dashboard.netlify.app](https://pursestrings-dashboard.netlify.app) replays the real transactions recorded on 9 Nov 2026 (labelled as a replay; hold STOP to watch both chains freeze).

**Video (2:28):** [youtu.be/ZyAuvW-op7w](https://youtu.be/ZyAuvW-op7w): every on-chain step shown is a real testnet transaction from 10 Nov 2026, and the terminal panes are re-typeset from that session's logs; the hashes are in [live/VIDEO_2026-11-10.md](live/VIDEO_2026-11-10.md).

| Live loop (testnet, 09.11.2026) | Origin | Reactive tx on Lasna | Answer on the destination chain | Took |
|---|---|---|---|---|
| Top-up: agent refused on Base, budget granted | [Base `0xe762…b163`](https://base-sepolia.blockscout.com/tx/0xe7629c982f59b7f4e7401b7ede1391e2c6f244d181d8911bf95f7ade7deeb163) | [`0x0c12…fe7a`](https://lasna.reactscan.net/tx/0x0c12f2abf867f4f12519ebdfeace2c2357e0ed2f6df093956ac51541cf42fe7a) | [GrantApplied, Base `0x923a…f62c`](https://base-sepolia.blockscout.com/tx/0x923a57c6b9edc7df74c9144e6698dc6fd6535d029c875d383a937b9f2360f62c) | 1 s |
| STOP pressed on Base, both chains frozen | [Base `0x9a41…cbda`](https://base-sepolia.blockscout.com/tx/0x9a41353d38e611b3ea6e4739e784844088304162ac6c6d0e4e9d5e4fa8e7cbda) | [`0x23ba…44fc`](https://lasna.reactscan.net/tx/0x23bab0c180052f0133313842320b5d6d23d86c547b812a921c3d3aab269c44fc) | [Base `0x54e8…5026`](https://base-sepolia.blockscout.com/tx/0x54e8194c99f1f7589004c2c4eaf5176bce43c60bce12009604fbc5c768205026), [Unichain `0x821d…3eea`](https://sepolia.uniscan.xyz/tx/0x821d90dc68b6143b8581202205bf2c55fbb3de66fc9704249278d36b69b93eea) | 3 s |
| Donor: budget moved from Unichain to Base | [Base `0x6a8f…2b62`](https://base-sepolia.blockscout.com/tx/0x6a8f115cb141ef68124717b9af493a3e333578a23a0f0b502c271a72ffcd2b62) | [`0x4549…14bb`](https://lasna.reactscan.net/tx/0x4549903286455dda6be4ec54e7b9e9465534b5859ef5089004f1ff313fd314bb), [`0xfa5c…1a8f`](https://lasna.reactscan.net/tx/0xfa5c7b2d46f83f90fcd59926b194475eadd2f314fa0ad1045e718e8fedac1a8f) | [reclaim, Unichain `0xe3dd…1d39`](https://sepolia.uniscan.xyz/tx/0xe3ddec4724171323ee70f7e7662b6ddba34e5e85e3e4626a9a00df174f081d39), [GrantApplied, Base `0xfb1d…eca5`](https://base-sepolia.blockscout.com/tx/0xfb1d78dbc1da727b6b5c44d20fa277b8bbff4412c828015e04b6fcd690eeeca5) | 31 min (30 of them our deliberate L2 confirmation wait) |

**Verify in 5 minutes** (no key, no transaction):
1. Open the links above. The top-up and STOP answers sit in blocks seconds after their origin; the donor's comes after the 30-min wait. Each answer is a `deliverCallback` transaction sent by Reactive's relayer (`0xF7E8…1DDb`, the explorer's From field) to Reactive Network's callback proxy (`0x476F…3585` on Base Sepolia, `0x775c…66C1` on Unichain Sepolia, the To field). The proxy then calls our contracts: our callback front, then the wallet (the tx's internal calls).
2. `deployments/README.md` links each of the 8 contracts to its Sourcify exact match.
3. Run:
```
git clone --recurse-submodules https://github.com/chainwright/pursestrings && cd pursestrings
python3 script/checker.py --day 2026-11-09   # read-only, public RPCs, ~2 min: $17.00 out on Base, cap $20, "Over: $0.00"
forge test                                   # offline, ~40–90 s, 67 tests
script/dryrun.sh                             # offline: the deployment and the loops on three local anvils
```

## Status

Deployed on testnets on 07.11.2026 from this branch (`main`; `src/` unchanged since the deploy commit `0a2e273`): the coordinator on Lasna; a wallet, a vault and a callback front on Base Sepolia and on Unichain Sepolia; the owner console on Base Sepolia. Addresses, creation hashes and source verification: `deployments/README.md`. The smoke test on 07.11 answered one top-up and one STOP on-chain 2 s after each origin (`live/LIVE_RUN_2026-11-07.md`). On 09.11 UTC the compact live series ran in full (`live/SERIES_2026-11-09.md`, every hash):
- 10 top-up loops: all complete, median 2 s, p95 3 s;
- 3 donor loops: all complete, 30.4 min median (31.2 max) with the agent retrying every 5 min, almost all of it a fixed 30-min wait, a safety margin we chose;
- 5 STOP presses: both chains frozen, median 2 s, p95 3 s;
- 12 successful agent payments, $17 in all, under the $20 daily cap (paid to our own deployer address).
- Video recording, 10.11.2026 UTC: payee `0x3e5F9f00258633dB9DBFbB62132708e01875b1ae` (team-held, standing in for an API seller): 10 top-ups (median 2 s), 1 donor loop (31 min), 2 STOP presses (2 s) and one STOP pressed while the coordinator was paused (frozen everywhere 2 min 9 s after one deposit); $13 paid, Over $0.00. Every hash: `live/VIDEO_2026-11-10.md`.

After the 09.11 series the coordinator used up its reserve and was paused from 09.11 09:15 UTC. It was funded again for the demo-video session on 10.11.2026 (3.5 lREACT in two deposits; `live/VIDEO_2026-11-10.md`). At 02:30 UTC on 10.11 its reserve was 0.135 lREACT; when that ran out it paused again, in the safe state described under "If the coordinator looks inactive" below, until the next deposit. Read-only on 11.11.2026 at 10:25 UTC: paused, reserves 0, debt 0.0065 lREACT (`cast call` on the system contract `0x8888…8888`, `reserves(address)` and `debt(address)` of the coordinator). Later readings go into `live/DAILY_<date>.md`. This deployment of 07.11.2026 (`main`) is the judged one: there is no redeploy for judging. We plan to keep it funded from submission until results; the lREACT for that is being collected through the faucet.

## Run it

```
forge build
forge test             # invariants, directed scenarios, liveness, production timing, gas, Reactive glue (~40–90 s; 67 tests)
script/mutants.sh      # full suite x 2 seeds per mutant: each must fail, the real contracts must pass (≈ 45 min on our machine)
script/dryrun.sh       # the whole testnet deployment + the loops + the pay-per-call demo, on three local anvils (no network)
python3 script/test_loop_logger.py   # offline tests of the live-loop logger's matching
python3 script/test_agent_retry.py   # offline tests of the donor-path agent
python3 demo/test_api.py             # offline tests of the demo API's acceptance rules and the agent's 402 loop
python3 script/test_checker.py       # offline tests of the checker's arithmetic, log chunking and day ranges
python3 script/checker.py            # read-only: today's spending on every chain vs the cap, "Over: $0.00"
```

`LIVE_LOOP.md` has the exact live commands: the smoke test and the compact series (10 top-up, 3 donor, 5 STOP loops, with an agent that keeps asking on the donor path), both as they were run, with measured costs.

## Dashboard

`dashboard/` is a read-only page of what the owner sees: one daily cap as a cord on a spool, the money on each chain, and every loop with its explorer links. It has two modes, and it never holds a key or sends a transaction.

- **Replay** (the default, and the whole static build). It replays the real testnet transactions of 09.11.2026 from `dashboard/web/data.js` and is labelled `replay · recorded 09.11 · real txs`. Hold STOP for 0.6 s to replay the recorded press S1 (both chains frozen 2 s later), or press `replay: top-up` for loop T2. `dashboard/test_dashboard.py` checks every hash and time in `data.js` against `live/` and `broadcast/`.
- **Live**. `dashboard/server.py` reads Base Sepolia, Unichain Sepolia and Lasna through their public RPCs (standard library only) and the page draws today's state from it. A cold start reads the UTC day's logs first (~3–4 min).

```
python3 -m http.server 8000 --directory dashboard/web   # replay: open http://127.0.0.1:8000/
python3 dashboard/server.py --port 8917                 # live: open http://127.0.0.1:8917/ (?mode=replay for the replay)
python3 dashboard/test_dashboard.py                     # offline tests of the replay data and the copy
```

Deploying it: `dashboard/web/` is a plain static site with no build step. Serve that folder from GitHub Pages (an Actions upload of `dashboard/web`), from Netlify (base directory `dashboard`, `dashboard/netlify.toml`), or from any web server. Add `?debug=1` to see the developer bar with the recorded states. More: `dashboard/NOTES.md`.

## Pay-per-call demo (our own 402 flow, not x402)

`demo/api.py` is a tiny HTTP service (Python standard library only). It sells rows of demo data at
$1 a row. It uses its own minimal 402 flow with no outside facilitator. It is **not x402-compatible**:
no x402 headers, no facilitator, no signed authorization. Real x402 is future work.

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
- The demo API has run on local chains only, not against the live deployment yet.

`script/dryrun.sh` step 4c runs the whole flow on local chains:
- 402 → pay → data;
- a replay (409), a fake `Paid` from a contract that also moves $2 of real tokens to the payee, and
  an onlooker without the claim, all refused;
- an over-allowance call that gets amber, then is served after the grant lands;
- a $10 call with $8 left that gets red;
- the checker reporting Over $0.00.

The API's acceptance rules are mutation-checked: each rule switched off makes `demo/test_api.py`
fail. The patches and their output are in `live/mutants_api_2026-11-09.log`.

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

## If the coordinator looks inactive

Reactscan may show the coordinator on Lasna as inactive. That means it ran out of lREACT and is
paused, not broken. A paused coordinator is not charged and gets no `react()` calls. While paused,
no new budget is granted. Each wallet can spend at most what it already holds (today's bucket, and
after midnight a tomorrow bucket that had already landed), so spending stays within the cap in
force before the pause. A STOP pressed during a pause reaches the other chains after the next deposit,
because the wallet re-announces it. A cap change or unstop sent during a pause is lost (in our run, a
log emitted while the coordinator was paused got no `react()` and was not replayed later,
`live/VIDEO_2026-11-10.md` §1): send it again after the deposit.
Each vault stays withdrawable by its owner on its own chain.

One `depositTo` wakes it, and Cron resumes by itself. We saw this live on 09.11:
- deposit of 3 lREACT at 05:18:06 UTC, which settled the 0.0076 debt first:
  [`0xc006f5af…6c98`](https://lasna.reactscan.net/tx/0xc006f5afc4254d1563ed18bee2da2ff1d4451d24e87bf8452d1d8ab9f6d96c98);
- the next Cron1000 tick, block 7,897,001 at 05:33:35 UTC, already carried our reactive tx
  [`0x3a5712a8…a2a7`](https://lasna.reactscan.net/tx/0x3a5712a8242d77a7ebda2383e007e7c5e654e8ba26e5ed67df67cf9944d4a2a7)
  (193,268 gas). No other step was needed.

A STOP pressed during a pause still holds. The pressing chain freezes in the same transaction,
and on the first Cron tick after the deposit the coordinator carries the STOP to every chain
(`test_debtPause48h_*` in `test/Directed.t.sol`: a 48 h pause with every event in it lost). Other
chains keep spending only what they already hold until the deposit.

The current deployment is the judged one (07.11.2026, `main`), with no redeploy for judging. It was
paused from 09.11 09:15 UTC, funded again for the demo-video session on 10.11.2026 (3.5 lREACT), and
was left to run its reserve down (0.135 lREACT at 02:30 UTC on 10.11) and pause again at no cost. Plan
for the judging window: keep it funded from submission until results. At ≈ 2.9 lREACT a day as we
measured it (100 gwei, `docs/COSTS_AND_LIMITS.md`), 05.12 to late December is ≈ 26 days ≈ 75 lREACT idle, plus ≈ 0.6 per STOP cycle
(≈ 0.75 Sepolia ETH through the faucet). We deposit ≈ 6 lREACT every two days, never far ahead,
because reserves can't be withdrawn, and check after each deposit that the next tick carries our
tx (`loop_logger.py cron-check`). If it lapses anyway, it pauses in the safe state above, and one
deposit brings it back.

## More

- `CLAIMS.md`: every public claim in this README, the video and its description, with its level of
  proof (transaction, code, our own record, or only a plan) and where to check it.
- `docs/DESIGN_AND_TESTS.md`: the protocol design, the network model, the invariants, the 39
  mutants, what turned out wrong in the design, and the honest list of what is not covered.
- `docs/COSTS_AND_LIMITS.md`: what the tests do and don't show, fees and funding, measured costs.
- `LIVE_LOOP.md`: the live run book. `live/`: the raw records of every live run (traces, snapshots,
  logs, reports of 07.11 and 09.11).

Tested by fuzz + mutation (not proven), against our own model of the network. Built on
reactive-lib-omni v0.1.0 (commit `3ade0dc`).

**How this was built.** During the event, from 05.11.2026 (submissions opened at 06:00 UTC−6). The
design notes were written that morning, before any code. The scaffold was committed at 12:41 UTC−6
(`4642d66`) and the protocol spike 19 minutes later (`96167b1`, 13:00: BudgetCore, SpendWallet, Vault,
OwnerConsole and the network-model fuzz, about 2,000 lines), generated from those notes with AI coding
tools, which the rules welcome for this track; the tests, mutants, reviews and live runs that followed
are the later commits. The git history is kept as it was, unrewritten. Commit
messages mention our internal review rounds ("round N", "judge", "hound", "W1–W3", "P1-8"): those are
our own reviewers and work items, not the event's.

Licences: this repo is MIT. `forge-std` (MIT/Apache-2.0) and `reactive-lib-omni` are git
submodules, not vendored; `reactive-lib-omni` carries `SPDX: UNLICENSED` and has no LICENSE file.
