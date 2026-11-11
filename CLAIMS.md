# Claims and their proof

Every public claim we make about Pursestrings — in `README.md`, in the demo video and in its YouTube
description — with the strongest proof we have for it, and where to find it. Where the proof is weaker
than the sentence, the row says so. State of 11.11.2026.

Proof levels, strongest first:

| Level | Means | How to check it yourself |
|---|---|---|
| **chain** | A transaction or a read-only call anyone can re-run | Open the hash on the explorer, or `cast receipt` / `cast call` against a public RPC |
| **code** | The deployed source (Sourcify exact match) or a test | Read the file and line; `forge test` |
| **record** | Our own log of a live run, with every hash in it | The file in `live/`; any hash in it opens on the explorer |
| **external** | Someone else's publication | The link |
| **plan** | A promise about the future, not a proof | Watch for `live/DAILY_<date>.md` |

Explorers: Base Sepolia `https://base-sepolia.blockscout.com/tx/<hash>`, Unichain Sepolia
`https://sepolia.uniscan.xyz/tx/<hash>`, Lasna `https://lasna.reactscan.net/tx/<hash>`.
Coordinator `0x7B8111CDF7001721469c584Fa9613369F0E7aC1E` (Lasna). Other addresses: `deployments/README.md`.

## README

| # | Claim (README section) | Level | Proof |
|---|---|---|---|
| 1 | One agent wallet per chain, deployed on Base Sepolia and Unichain Sepolia, coordinated from Lasna (top) | chain + code | `deployments/README.md`: 8 creation hashes, Sourcify exact match for all 8 |
| 2 | Money stays on its own chain; only the permission moves (top) | code + chain | `Vault.release` pays only its bound wallet (`src/Vault.sol:34`); `applyGrant` pulls from the same chain's vault (`src/SpendWallet.sol:211`). Every USDC transfer in the loop table's answers is vault ↔ wallet on one chain, e.g. Base `0x923a57c6…f62c` |
| 3 | One STOP freezes the pressing chain at once and every other chain within seconds (top, table row 2) | chain + code | Same-transaction freeze: `pressStop` (`src/SpendWallet.sol:144`). Fan-out: press `0x9a41353d…cbda` (Base, 08:19:29 UTC 09.11) → acks Base `0x54e8194c…5026` (08:19:31) and Unichain `0x821d90dc…3eea` (08:19:32) |
| 4 | …after the next deposit if the coordinator is paused (top, "If the coordinator looks inactive") | chain + code + test | Video session 10.11: press `0xa6d8…1082` 00:02:26 (in debt) → deposit 00:03:43 → Cron tick 00:05:46 → Unichain ack `0xd8a42219…86c3` 00:05:52 (`live/VIDEO_2026-11-10.md` §1). Re-announce path: `_echoStop` / `_echoStopForCoordinator` (`src/SpendWallet.sol:385,395`). Tests: `test_debtPause48h_*` (`test/Directed.t.sol:509,516`) |
| 5 | One hard daily cap and one STOP that contracts enforce, with no server or custodian of ours in between (top) | chain + code | Every answer is `deliverCallback` from Reactive's relayer `0xF7E8…1DDb` to Reactive's proxy (`0x476F…3585` Base, `0x775c…66C1` Unichain); the front accepts only the proxy with our RC injected (`src/reactive/CallbackFront.sol:37`); the wallet accepts only its front (`src/SpendWallet.sol:106`, `test_walletAcceptsCoordinatorMessagesOnlyFromItsFront`). Vault withdraw is owner-only (`src/Vault.sol:42`). Reactive's relayer is a service Reactive runs; "of ours" is the precise claim |
| 6 | The dashboard replays real transactions of 09.11, labelled as a replay (top) | code | `dashboard/web/data.js`; `dashboard/test_dashboard.py` checks every hash and time in it against `live/` and `broadcast/`; the page header reads `replay · recorded 09.11 · real txs` |
| 7 | Video: every on-chain step shown is a real testnet transaction from 10.11.2026; terminal panes re-typeset from the session's logs (top) | record + chain | `live/VIDEO_2026-11-10.md` (every hash, UTC times); `live/video_2026-11-10.jsonl` |
| 8 | Loop table: top-up 1 s, STOP 3 s, donor 31 min (30 of them our wait) | chain + code | The table's hashes; block times 05:36:40 → 05:36:41, 08:19:29 → 08:19:32, 06:30:43 → 07:01:56 UTC 09.11. The 30 min: `WAIT_OP_STACK = 30 minutes` (`src/reactive/TestnetConfig.sol:50`) |
| 9 | 8 contracts, Sourcify exact match (Verify in 5 minutes) | chain | `curl -s https://sourcify.dev/server/v2/contract/<chainId>/<address>`; links in `deployments/README.md` |
| 10 | `checker.py --day 2026-11-09`: $17.00 out on Base, cap $20, Over $0.00, ~2 min | record (re-runnable) | `live/checker_2026-11-09.log` (3 days in 5 min 20 s). Re-run it: read-only, public RPCs. An outside run for 10.11 gave $13.00, Over $0.00 |
| 11 | `forge test`: 67 tests, ~40–90 s | code | Run it. A clean clone took 43 s; our machine 75–90 s |
| 12 | Deployed 07.11.2026 from `main`; `src/` unchanged since `0a2e273` (Status) | chain + code | `git diff 0a2e273 HEAD -- src lib foundry.toml remappings.txt` is empty; coordinator creation `0x2798f598…c0ad` (07.11 00:04:48 UTC); Sourcify exact match |
| 13 | Smoke test 07.11: one top-up and one STOP answered 2 s after each origin (Status) | chain (re-read 11.11) | Top-up `0xf1af94ab…f63b` (Base 00:39:14) → GrantApplied `0xe5535550…682c` (00:39:16). STOP `0x2422cae8…7d35` (Unichain 01:19:48) → acks Base `0x324710ed…ef1c` (01:19:49), Unichain `0x10ada01f…2a6e` (01:19:50). All status 0x1. `live/LIVE_RUN_2026-11-07.md` |
| 14 | 09.11 series: 10 top-ups median 2 s (p95 3 s); 3 donors 30.4 min median (31.2 max); 5 STOPs median 2 s (p95 3 s); 12 payments, $17 (Status) | record + chain | `live/SERIES_2026-11-09.md`, `live/series_2026-11-09.jsonl` (every hash); the $17 / 12 transfers also come from the token's own logs in `live/checker_2026-11-09.log` |
| 15 | Video session 10.11: 10 top-ups, 1 donor (31 min), 2 STOPs (2 s), one STOP while paused frozen everywhere 2 min 9 s after one deposit; $13 paid, Over $0.00 (Status) | record + chain | `live/VIDEO_2026-11-10.md` §1–§5. Deposit 00:03:43 → Unichain ack 00:05:52 = 2 min 9 s |
| 16 | Paused from 09.11 09:15 UTC; 3.5 lREACT in two deposits on 10.11; 0.135 lREACT at 02:30 UTC on 10.11 (Status) | record | `live/SERIES_2026-11-09.md`; `live/VIDEO_2026-11-10.md` §6 (2 + 1.5 lREACT; reading 02:30:05) |
| 17 | Paused on 11.11 at 10:25 UTC: reserves 0, debt 0.0065 lREACT (Status) | chain | `cast call --rpc-url https://lasna-rpc.rnk.dev/ 0x8888888888888888888888888888888888888888 "reserves(address)(uint256)" 0x7B8111CDF7001721469c584Fa9613369F0E7aC1E` (and `debt(address)(uint256)`) |
| 18 | We plan to keep it funded from submission until results (Status, "If the coordinator looks inactive") | **plan** | Not proven yet. The proof will be `live/DAILY_<date>.md`, one per day |
| 19 | ≈ 2.9 lREACT a day idle at 100 gwei; ≈ 75 lREACT for ≈ 26 days; ≈ 0.75 Sepolia ETH | record + arithmetic | `docs/COSTS_AND_LIMITS.md` (measured by us: how long a 3-lREACT deposit lasted). 26 × 2.9 = 75.4. Faucet rate 1 SepETH → 100 lREACT is Reactive's |
| 20 | A paused coordinator is not charged and gets no `react()` calls | record | `live/VIDEO_2026-11-10.md` §1: the STOP press emitted in debt got no react of its own. One observation |
| 21 | While paused, each wallet spends at most what it already holds, so spending stays within the cap in force before the pause | code + test | `pay` spends only from the day bucket (`src/SpendWallet.sol:176`); `test_debtPause48h_*`; invariant (a) in `test/Pursestrings.invariant.t.sol`. Holds within the L2 reorg bound (`test_outsideTheModel_reorgDeeperThanTheWaitOvercredits`, `test/Directed.t.sol:624`; `docs/COSTS_AND_LIMITS.md`) |
| 22 | A cap change or unstop sent during a pause is lost; send it again after the deposit | code + record | `setCap` / `unstop` emit once and nothing re-emits them (`src/OwnerConsole.sol:17,24`); logs emitted in debt were not replayed (`live/VIDEO_2026-11-10.md` §1) |
| 23 | One `depositTo` wakes it and Cron resumes by itself (09.11: deposit `0xc006f5af…6c98` 05:18:06, tick block 7,897,001 at 05:33:35 carried `0x3a5712a8…a2a7`, 193,268 gas) | chain | The hashes; again on 10.11: deposit `0x443c…ff77` 00:03:43 → tick react `0xa55e…248c` 00:05:46 (`live/VIDEO_2026-11-10.md` §1) |
| 24 | Our 402 demo is not x402 and has run on local chains only | code | `demo/api.py`; `script/dryrun.sh` step 4c; `demo/test_api.py`; `live/mutants_api_2026-11-09.log` |
| 25 | Tested by fuzz + mutation: 39 mutants, each caught | code + record | `script/mutants.sh`; `docs/DESIGN_AND_TESTS.md`; `live/mutants_2026-11-08.log` |
| 26 | The checker uses block timestamps, not block counts (Base Sepolia's 0.2 s blocks); no `block.number` in `src/` | code | `script/checker.py` (bisection by timestamp); `grep -rn block.number src` returns nothing |
| 27 | Built during the event from 05.11.2026; scaffold 12:41 UTC−6, protocol spike 19 min later, written from design notes with AI coding tools; history unrewritten (How this was built) | code (git) | `git log --reverse`: `4642d66` 12:41:02, `96167b1` 13:00:14 (the spike's commit carries a co-author trailer naming the assistant). Submissions opened 05.11 06:00 UTC−6. The design notes themselves are not in this repo |
| 28 | MIT; `reactive-lib-omni` is `SPDX: UNLICENSED` with no LICENSE file | code | `LICENSE`; `lib/reactive-lib-omni` headers |

## Video narration and the YouTube description

| # | Claim | Level | Proof or correction |
|---|---|---|---|
| V1 | "In February, an AI agent was asked for 4 SOL and sent its whole token holding." | external | The Block, 22.02.2026: https://www.theblock.co/post/390722/ai-agent-created-by-openai-dev-accidentally-sends-entire-memecoin-holdings-to-reply-guy. That was one chain; a per-chain cap would have caught it too |
| V2 | "Run agents on two chains and you get two limits and no single off switch" (narration; description line 1) | **overstated** | True for plain on-chain wallets (a Safe allowance or a spend permission is per chain). Hosted agent-wallet services already pool a budget across EVM chains and offer an org-wide freeze, on their own servers. The precise claim: none of them enforces it on-chain without a server |
| V3 | "One shared daily cap"; "$20 a day, both chains together" | chain + record | `capOfDay` for day 20767 is $20 on the coordinator; `live/VIDEO_2026-11-10.md` §2 |
| V4 | "The money never crosses a chain. Only permission moves, and Reactive moves it." | code + chain | README row 2 and 5 |
| V5 | Top-up: refused on Base, Reactive grants $2, the callback proxy delivers it seconds later, the payment goes through | chain + record | Origin `0xfeaf…3d69` 00:10:02 → Lasna react `0x93d0…bfb4` → callback `0xd379…baec` 00:10:03 (Vault → wallet 2 USDC); paid `0x0502…f074` 00:11:29 (`live/VIDEO_2026-11-10.md` §2) |
| V6 | "One transaction from a terminal on Unichain. In about two seconds, Base is frozen too." | chain | Press `0x34dc…` Unichain 01:37:21 → Base ack `0x70e0…` 01:37:23 (`live/VIDEO_2026-11-10.md` §4) |
| V7 | Donor: "half an hour, and that's on purpose… a safety margin we chose"; ×150 badge, real 31:30 | chain + code | D1 origin `0x26a19f48…b570` 01:00:00 → reclaim on Unichain `0xcbae5b7a…aa9c` 01:00:02 → GrantApplied on Base `0xaf93b120…0890` 01:31:18 (`live/VIDEO_2026-11-10.md` §3); `src/reactive/TestnetConfig.sol:50` |
| V8 | "STOP still freezes the chain you press. After one deposit, it reaches every chain." | chain + code | README row 4 |
| V9 | Checker: "adds up every chain. Over zero dollars." | record (re-runnable) | `live/VIDEO_2026-11-10.md` §5; `python3 script/checker.py --day 2026-11-10` |
| V10 | On screen "forge test @ df0e02a: 67 tests passed" | code | `src/` is identical at `df0e02a` and at `main` |
| V11 | "With it, there's no server." | **overstated** | Precise: no server of ours. Reactive's relayer is a service Reactive runs |
| V12 | "You only keep the Reactive contract topped up." | **overstated** | Each chain's callback front also needs a little ETH for callback fees (≈ 1e-6 ETH per callback; `docs/COSTS_AND_LIMITS.md`) |
| V13 | End card: 8 contracts verified on Sourcify; deployment of 07.11.2026; every hash in `live/VIDEO_2026-11-10.md`; first commit 05.11.2026 | chain + code | README rows 9, 12, 27 |
| Y1 | "Everything in this video ran on testnets … on 10.11.2026 UTC, on the deployment of 07.11.2026"; "Every transaction shown has its hash in the repo" | record + chain | `live/VIDEO_2026-11-10.md` |
| Y2 | "Reactscan's Lasna clock reads about 1 s behind Base's" | chain | T2: Lasna react 00:10:01 vs Base origin 00:10:02 (the react is caused by the origin) |
| Y3 | "The dashboard is in live mode, reading the chains." | record, **incomplete** | True for the recording (`dashboard/server.py`). Not said in the description: the stats column is blurred and the receipt rows are cropped, because live mode counted 9 top-ups instead of 10, showed T10's hashes on a row labelled T9, and listed the lost STOP's callback as the press (`live/VIDEO_2026-11-10.md`, "Dashboard numbering") |
| Y4 | "Sped-up parts say how fast and how long they really took." | record | ×150 / 31:30, ×40 / 3:45, ×4 / 0:23 badges in the video |
| Y5 | "The payee is a team-held test address standing in for an API seller." | chain | `0x3e5F9f00258633dB9DBFbB62132708e01875b1ae`; the USDC went back afterwards (`live/VIDEO_2026-11-10.md` §5) |
| Y6 | "Narration: synthetic voice (ElevenLabs). Music: generated by the team with ElevenLabs Music (paid plan)." | team statement | No receipt in this repo |
| Y7 | "Code written during the event; first commit 05.11.2026" | code (git) | `4642d66` |
