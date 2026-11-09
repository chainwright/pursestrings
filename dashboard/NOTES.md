# Pursestrings dashboard ("Drawstring")

One page, two modes. Both are read-only: no key, no transaction, and nothing in the page or the server can sign.

- **Replay** (default, and the only mode of the static build). It replays the recorded series of 09.11.2026 from
  `web/data.js`: real testnet transactions, every hash linked to its explorer. The top bar says
  `replay · recorded 09.11 · real txs`. Hold STOP (0.6 s) to replay the recorded press S1, or use the
  `replay: STOP` / `replay: top-up` buttons. `dashboard/test_dashboard.py` checks every hash, time and latency in
  `data.js` against the committed records in `live/` and `broadcast/`.
- **Live** (only when served by `server.py`). Every number comes from the chains through `/api/state`. The top bar
  says `● live` and the time of the read.

## Run

Replay, no server of ours (any static file server):
```
python3 -m http.server 8000 --directory dashboard/web    # then open http://127.0.0.1:8000/
```

Live, from the repo root (Python 3.9+, standard library only):
```
python3 dashboard/server.py --port 8917                  # then open http://127.0.0.1:8917/
```

URL options: `?mode=replay` (replay on the live server), `?replay=stop|topup`, `?theme=dark|light`, `?debug=1` (a
developer bar with the recorded states open / amber / red / frozen / paused).

## Static deploy

`dashboard/web/` is the whole site: `index.html`, `style.css`, `app.js`, `data.js`, `mode.js`. There is no build
step. Any static host works (GitHub Pages through an Actions upload of `dashboard/web`, Netlify with base directory
`dashboard` and `netlify.toml`, or any web server). The only outside requests are Google Fonts and, when someone clicks
a hash, the block explorers.

## Live mode: the server

- Cold start reads today's logs from 00:00 UTC. A Base Sepolia day is about 230k blocks at 200 blocks per `getLogs`,
  so this takes about 3–4 minutes. Until it finishes, the page shows `READING TODAY'S CHAIN LOGS` and the catch-up
  percentages, and draws nothing chain-derived. A half-read day is not a fact.
- The settled cursor is saved to `dashboard/cache/cursor.json` (not committed), so a restart resumes where it
  stopped. After the catch-up the server polls every 3 s and the page every 2 s.
- Addresses come from `deployments/latest.json`, or from `--deployments FILE`.
- The RPC URLs are the public ones, or `BASE_SEPOLIA_RPC_URL` / `UNICHAIN_SEPOLIA_RPC_URL` / `LASNA_RPC_URL`. The
  client is the repo's own `script/evm_rpc.py` (chunking, pacing, 429/range retry).

**Why a server and not the browser.** All three RPCs answer CORS. The blocker is volume: about 2,300 `getLogs` per
Base day, against a limit of 25/s. With one poller and a cursor the page loads instantly, and the rate limit is
respected however many tabs are open. The server calls only `eth_blockNumber`, `eth_getBlockByNumber`, `eth_getLogs`,
`eth_getTransactionByHash`, `eth_getTransactionReceipt`, `eth_call` and `eth_chainId`, and it answers `POST` with 405.

Checked live on 09.11 (read at head ≈13:00 UTC): all 18 loops of the series (T1–T10, D1–D3, S1–S5) were rebuilt from
chain logs alone, with the same hashes and actual latencies as `live/SERIES_2026-11-09.md`, and all 18 got ✓ after the
server's own receipt re-read. Over $0.00, Base $17.00 in 12 payments, the same as `script/checker.py`.

## Data source per element (live mode)
| Element | Source |
|---|---|
| Spool coil (reserve) | `poolOf(today)` on the Lasna coordinator, at the Lasna head block |
| Epoch, frozen, paused | coordinator `epoch()`, `frozen()`. Paused = system contract `debt(rc) > 0` or `reserves(rc) == 0` (0x8888…) |
| Loop per mouth (unspent) | wallet `unspentOf(today)` at that chain's head (today is the wallet's own clock) |
| Knot per mouth | `heldOf(today, c)` − unspent − spent − in flight: allowance returned to the vault and not yet credited back (a STOP drain or a reclaim) |
| Outlined cord in flight | `GrantSent(day = today)` on Lasna with no `GrantApplied`/`GrantNotApplied` for that id yet |
| Spent pieces | the token's `Transfer` logs out of each wallet, one piece per log, length = amount × K. Returns to the wallet's own vault are excluded (the checker rule) |
| Money well | token `balanceOf(vault)` + `balanceOf(wallet)` at head |
| Plate | `frozen` = wallet `frozen()`. `amber` = a `Short` in the last 6 min with no later `GrantApplied` on that chain. `red` = the same, but cap − spent < the refused price. `held` = the same while the coordinator is paused. Otherwise `open` |
| Headline | frozen anywhere: `MOST STILL POSSIBLE DURING FREEZE` = Σ unspent on unfrozen chains. Paused: `AFTER RESUME` = cap − spent. Otherwise cap − spent |
| Tape | reserve + loops + knots + in flight + pieces, at one K. If Σ ≠ cap the label says `(books catching up)` |
| Over badge | `script/checker.py`'s rule on the same Transfer logs, cap = `capOfDay(today)` |
| Receipts strip | loops rebuilt as in `script/loop_logger.py`: the Lasna react tx whose input carries the origin tx hash (Short / LowWater / StopPressed), then its answer on the destination chain, matched by grant id or epoch |
| Path stats | median and max of the actual times (n is small, so no percentiles) |
| ✓ | only after the server re-reads every hash of the row with `eth_getTransactionReceipt`: status 1 and the expected event inside. Replay never shows ✓ |

## The STOP button
In replay, hold plays the recorded press S1 (08:16:57 UTC on Unichain; both chains frozen 2 s later). In live mode it
is dimmed and does nothing on purpose: the page holds no keys and sends nothing. A real STOP is the owner's own
transaction (`SpendWallet.pressStop` on any chain, e.g. `script/Loop.s.sol stop`); the page then draws it from the
`StopPressed` → `Frozen` → `EpochAck` logs.

## Known gaps
- Live motion (grant flight, coin drop, cinch) has been checked with synthetic events only: no transaction happened
  while the server was being tested. The first real loop after a deposit is the true test.
- When a chain has both unspent allowance and a pending return (mid donor loop), the pending amount appears only in
  the caption and on the tape, not as cord.
- Loops that a Cron tick served without carrying the origin hash are not listed. Unstop loops are not listed either.
- Reorgs: the last 64 blocks are re-read every poll. A deeper reorg would need a restart. The cache is per UTC day.
- The red state (`?debug=1`, "red") is an illustration on recorded numbers: no $5.00 call was refused on 09.11, and
  the page says so.
