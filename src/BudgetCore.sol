// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IWalletInbox, K_RECLAIM, K_VOID, K_ROLL, K_EPOCH} from "./interfaces/IPursestrings.sol";

/// The rule, as it runs inside the reactive contract on Lasna. It holds the books, decides,
/// and emits intents for chains through `_dispatch`. It never calls a chain directly and has
/// no dependency on the Reactive libraries: an adapter feeds decoded origin events into the
/// `_on*` functions and implements `_dispatch` with a callback request.
///
/// Books, per day d (the day is Lasna's clock):
///   pool[d] + sum_i held[d][i] == capOfDay[d]
/// where held[d][i] is what chain i may have been granted for d and not yet confirmed returned.
/// Safety argument: chain i can spend at most held[d][i] for day d, so total spend <= capOfDay[d].
///   1. the pool is debited before a grant is sent;
///   2. a return (reclaim, void grant, epoch roll) is credited only after a confirmation wait
///      AND a re-read on the origin chain (verify) that the fact is still true;
///   3. a reclaim shrinks only unspent allowance (wallet side);
///   4. every message is applied at most once on each side, gaps tolerated;
///   5. a cancelled grant is refunded only after the wallet tombstoned it unapplied;
///   6. STOP is a frozen state with an epoch; grants carry the epoch.
abstract contract BudgetCore {
    uint256 public constant DAY = 1 days;

    uint8 internal constant G_SENT = 1;
    uint8 internal constant G_APPLIED = 2;
    uint8 internal constant G_CANCELLING = 3;
    uint8 internal constant G_REFUNDED = 4;

    /// Timing per chain (TestnetConfig.chainParams derives the production values from the wait).
    /// Seconds, packed into one storage slot (uint32: up to 136 years).
    struct ChainParams {
        /// How long a return must have existed on its origin chain before it is credited. Must
        /// exceed that chain's reorg window.
        uint32 confirmWait;
        /// An unanswered grant is cancelled after this (doubling per retry, up to 32x); epoch
        /// messages are resent on the same schedule.
        uint32 grantTimeout;
        /// An unanswered reclaim is closed after this. Never while its return is pending.
        uint32 reclaimTimeout;
        /// A re-read is resent after this (doubling per retry, up to 32x).
        uint32 verifyTimeout;
        /// A chain's want expires after this; while it lives, that chain is no donor.
        uint32 wantTtl;
    }

    struct Params {
        uint8 nChains;
        uint256 cap;
        uint256 keepFloor;
        ChainParams[] chains;
        uint64 pregrantWindow;
        /// Every chain gets a heartbeat (a cheap re-read) at least this often, driven by Cron.
        /// It carries a lost STOP press back even if nothing else is sent to that chain.
        /// 0 = off.
        uint64 heartbeat;
        /// Refill ahead by burn rate (see _refillAhead). A top-up covers this many seconds of the
        /// chain's measured spend rate (at least one chunk). 0 = refill ahead off.
        uint32 refillHorizon;
        /// Top up from the pool once the chain's projected unspent covers less than this (must
        /// exceed the Cron period: the top-up goes out on the last react before the chain runs dry).
        uint32 refillLead;
        /// Start the donor path once the projected unspent covers less than this and the pool
        /// can't give the next top-up (must exceed refillLead + the confirmation wait + 2 Cron periods).
        uint32 reclaimLead;
        /// The heartbeat while no agent has spent or asked for `idleAfter`: a lost STOP
        /// press then costs nothing while it waits, so the beat can be slower. 0 = always
        /// `heartbeat`. Activity (a Short, a LowWater, a meter reading that shows spending) brings
        /// every chain's next beat back within `heartbeat`.
        uint64 idleHeartbeat;
        uint64 idleAfter;
    }

    /// A wallet's Verified event, decoded.
    struct Echo {
        uint8 kind;
        uint256 key;
        bool ok;
        uint64 day;
        uint256 a0;
        uint256 a1;
        uint64 appliedAt;
        uint64 ts;
    }

    /// cap, pool and open share one storage slot (opening a day is one write, not three).
    struct DayBook {
        uint128 cap;
        uint120 pool;
        bool open;
        mapping(uint8 => uint256) held;
        mapping(uint8 => bool) dry;
    }

    struct Grant {
        uint8 chain;
        uint8 st;
        uint8 tries;
        uint64 day;
        uint64 epoch;
        uint64 sentAt;
        uint128 amount;
        /// The wallet has answered (applied / not applied / cancel ack). Until then the grant is
        /// "in flight" and its chain gets no other grant.
        bool answered;
    }

    struct Reclaim {
        uint8 chain;
        bool open;
        uint64 day;
        uint64 sentAt;
        uint128 amount;
    }

    struct Pending {
        uint8 kind;
        uint8 chain;
        uint8 tries;
        uint64 day;
        uint64 originTs;
        uint64 verifySentAt;
        uint256 id;
        uint128 amount;
        uint128 amount2;
    }

    /// A chain's unmet need. It expires after wantTtl: a wallet that is still short re-emits
    /// Short (rate-limited), and a stale want would otherwise bar the chain as a donor forever.
    struct Want {
        uint64 day;
        uint64 at;
        uint128 amount;
    }

    /// A chain's spend meter. Every K_EPOCH re-read (the heartbeat is one) answers with that
    /// wallet's spent for today at an origin time, and a LowWater is a reading when held is exact
    /// (see _readAtLowWater); the rate is the spend over the last window of at least heartbeat / 4.
    /// Readings are applied only in origin-time order, so a duplicated, replayed or reordered
    /// answer changes nothing. It steers refills only: it never enters the books, so a wrong
    /// reading can cost a wait or park budget on the wrong chain, never exceed the cap.
    struct Meter {
        uint64 day;
        uint64 ts;
        uint128 spent;
        uint64 fromTs;
        uint128 fromSpent;
        /// budget-token units per hour
        uint128 rateH;
    }

    /// Work bounds per call (one react()): at most MAX_SENDS callback requests, and at most SCAN
    /// entries of each retry list looked at; the rest is carried to the next call (Cron tick or
    /// event). STOP/unstop messages go first. Gas measured in test/Gas.t.sol.
    uint256 public constant MAX_SENDS = 4;
    uint256 public constant SCAN = 4;
    /// See _alive: retry backoff kept at most 2^ALIVE_CAP while a chain shows only origin events.
    uint8 public constant ALIVE_CAP = 2;
    /// Caps above this are treated as this (it is ~1.3e36 base units; it only bounds packing).
    uint256 public constant MAX_CAP = type(uint120).max;

    uint8 public immutable nChains;
    uint256 public immutable keepFloor;
    uint64 public immutable pregrantWindow;
    uint64 public immutable heartbeat;
    uint32 public immutable refillHorizon;
    uint32 public immutable refillLead;
    uint32 public immutable reclaimLead;
    uint64 public immutable idleHeartbeat;
    uint64 public immutable idleAfter;

    uint256 public cap;
    uint64 public capNonce;
    uint64 public unstopNonce;
    uint64 public epoch;
    bool public frozen;
    /// When an agent last showed it was spending (a Short, a LowWater, a reading with more spent).
    uint64 public lastActiveAt;

    mapping(uint8 => uint64) public pressSeenAt;
    mapping(uint8 => uint64) public epochAcked;
    mapping(uint8 => uint64) public epochSentAt;
    mapping(uint8 => uint8) public epochTries;
    mapping(uint8 => uint64) internal _lastEpochSent;
    mapping(uint8 => ChainParams) internal _cp;

    mapping(uint64 => DayBook) internal _days;

    uint256 public nextId = 1;
    mapping(uint256 => Grant) public grants;
    uint256[] internal _liveGrants;
    mapping(uint256 => Reclaim) public reclaims;
    uint256[] internal _liveReclaims;
    mapping(uint8 => mapping(uint64 => uint256)) public openReclaim;

    mapping(bytes32 => Pending) public pending;
    mapping(bytes32 => uint256) internal _pendingPos; // index + 1
    bytes32[] internal _pendingKeys;
    mapping(bytes32 => bool) public credited;

    mapping(uint8 => Want) public want;
    /// Grants per chain the wallet hasn't answered yet: at most one. A chain whose callbacks are
    /// lost (front in debt, proxy down) can then absorb at most one grant, not the day's budget.
    mapping(uint8 => uint256) public inflight;
    uint8 internal _rr;

    /// Callback requests still allowed in this call, plus one (never stored as zero, so resetting
    /// it each call is a cheap non-zero write).
    uint256 internal _sendsLeft = 1;
    uint256 internal _pCur;
    uint256 internal _gCur;
    uint256 internal _rCur;
    /// day => bit per chain already pre-granted for that day
    mapping(uint64 => uint256) internal _pregranted;
    /// chain => when its next heartbeat is due
    mapping(uint8 => uint64) internal _beatDue;
    /// chain => its unanswered grant (at most one), 0 if none
    mapping(uint8 => uint256) internal _inflightId;
    mapping(uint8 => Meter) public meter;
    /// chain => when refill ahead last asked it for a reading
    mapping(uint8 => uint64) internal _readAskedAt;
    /// chain => entries in the pending list (returns not yet confirmed)
    mapping(uint8 => uint256) internal _pendingOf;

    event DayOpened(uint64 day, uint256 cap);
    event GrantSent(uint256 id, uint8 chain, uint64 day, uint256 amount, uint64 epoch);
    event ReclaimSent(uint256 id, uint8 chain, uint64 day, uint256 amount);
    event CancelSent(uint256 id, uint256 grantId);
    event Credited(uint8 kind, uint8 chain, uint64 day, uint256 amount);
    event Frozen(uint64 epoch);
    event Unfrozen(uint64 epoch);
    /// Refill ahead acted: kind 1 = a top-up granted ahead, 2 = a reclaim sent ahead (for the
    /// dashboard and the tests; the grant or reclaim itself is the usual GrantSent / ReclaimSent).
    event Ahead(uint8 kind, uint8 chain, uint256 amount, uint256 rateH);

    constructor(Params memory p) {
        // STOP reaches every chain in the same call: one epoch message per chain fits the budget.
        require(p.nChains > 0 && p.nChains <= MAX_SENDS, "chains");
        require(p.chains.length == p.nChains, "chain params");
        nChains = p.nChains;
        cap = p.cap < MAX_CAP ? p.cap : MAX_CAP;
        keepFloor = p.keepFloor;
        for (uint8 c; c < p.nChains; c++) {
            _cp[c] = p.chains[c];
        }
        pregrantWindow = p.pregrantWindow;
        heartbeat = p.heartbeat;
        refillHorizon = p.refillHorizon;
        refillLead = p.refillLead;
        reclaimLead = p.reclaimLead;
        require(p.refillHorizon == 0 || p.reclaimLead > p.refillLead, "reclaimLead must exceed refillLead");
        require(p.idleHeartbeat == 0 || (p.idleHeartbeat >= p.heartbeat && p.idleAfter > 0), "idle heartbeat");
        idleHeartbeat = p.idleHeartbeat;
        idleAfter = p.idleAfter;
        for (uint8 c; c < p.nChains; c++) {
            _beatDue[c] = uint64(block.timestamp) + uint64(c) * p.heartbeat / p.nChains; // staggered
        }
    }

    // ================================================================ inputs
    // Each is one decoded origin event. All end in _poke(): retries run lazily on every
    // react() as well as on Cron ticks.

    function _onShort(uint8 c, uint64 day, uint256 shortBy) internal {
        _alive(c, false);
        _markActive();
        if (!frozen && day == _today()) {
            Want storage w = want[c];
            if (!_wanting(c, day) || w.amount < shortBy) w.amount = uint128(shortBy);
            w.day = day;
            w.at = uint64(block.timestamp);
        }
        _poke();
    }

    function _onLowWater(uint8 c, uint64 day, uint256 unspent, uint64 ts) internal {
        _alive(c, false);
        _markActive();
        if (!frozen && day == _today()) {
            if (!_wanting(c, day)) want[c] = Want(day, uint64(block.timestamp), uint128(cap / 10));
            _readAtLowWater(c, day, unspent, ts);
        }
        _poke();
    }

    function _onGrantApplied(uint8 c, uint256 grantId) internal virtual {
        _alive(c, true);
        Grant storage g = grants[grantId];
        if (g.st != 0 && g.chain == c) {
            _answered(g);
            if (g.st == G_SENT || g.st == G_CANCELLING) g.st = G_APPLIED;
        }
        _poke();
    }

    function _onGrantNotApplied(uint8 c, uint256 grantId, uint64 ts) internal {
        _alive(c, true);
        Grant storage g = grants[grantId];
        if (g.st != 0 && g.chain == c) {
            _answered(g);
            _admit(K_VOID, c, grantId, g.day, g.amount, 0, ts);
        }
        _poke();
    }

    function _onCancelAck(uint8 c, uint256 grantId, bool applied, uint64 ts) internal {
        _alive(c, true);
        Grant storage g = grants[grantId];
        if (g.st != 0 && g.chain == c) {
            _answered(g);
            if (applied) {
                if (g.st != G_REFUNDED) g.st = G_APPLIED;
            } else {
                _admit(K_VOID, c, grantId, g.day, g.amount, 0, ts);
            }
        }
        _poke();
    }

    function _onReclaimed(uint8 c, uint256 reqId, uint256 amount, uint64 ts) internal {
        _alive(c, true);
        Reclaim storage r = reclaims[reqId];
        if (r.sentAt != 0 && r.chain == c) {
            // The donor's slot stays taken until this return is credited or dropped, so the
            // donor isn't asked again while the confirmation wait runs.
            if (r.open && amount < r.amount) _days[r.day].dry[c] = true;
            _admit(K_RECLAIM, c, reqId, r.day, amount, 0, ts);
        }
        _poke();
    }

    function _onRolled(uint8 c, uint64 e, uint64 day, uint256 r0, uint256 r1, uint64 ts) internal {
        _alive(c, true);
        _admit(K_ROLL, c, e, day, r0, r1, ts);
        _poke();
    }

    function _onEpochAck(uint8 c, uint64 e, uint64 ts) internal {
        _alive(c, true);
        if (e > epochAcked[c]) _admit(K_EPOCH, c, e, 0, 0, 0, ts);
        _poke();
    }

    /// Only a strictly newer press acts, so a duplicated, replayed or re-announced log can't
    /// re-freeze after an unstop. Every new press opens a new frozen epoch, even when already
    /// frozen: an unstop issued before this press names an older epoch and can never lift it.
    function _onStopPressed(uint8 c, uint64 mark) internal {
        _alive(c, false);
        if (mark > pressSeenAt[c]) {
            pressSeenAt[c] = mark;
            frozen = true;
            epoch++;
            for (uint8 i; i < nChains; i++) {
                delete want[i];
            }
            emit Frozen(epoch); // the epoch messages go out first thing in _poke()
        }
        _poke();
    }

    function _onVerified(uint8 c, Echo memory v) internal {
        _alive(c, true);
        if (v.kind == K_EPOCH && (refillHorizon != 0 || idleHeartbeat != 0)) _read(c, v.day, v.a1, v.ts);
        bytes32 k = _key(v.kind, c, v.key);
        Pending storage p = pending[k];
        if (p.kind != 0) {
            if (!v.ok) {
                if (v.kind == K_RECLAIM) _closeReclaim(v.key);
                _dropPending(k); // the fact is gone (reorged out); a real re-occurrence is re-admitted
            } else if (_oldEnough(c, v)) {
                if (v.kind == K_RECLAIM) {
                    _closeReclaim(v.key);
                    _credit(K_RECLAIM, c, p.day, v.a0);
                } else if (v.kind == K_VOID) {
                    Grant storage g = grants[v.key];
                    _answered(g);
                    g.st = G_REFUNDED;
                    _credit(K_VOID, c, g.day, g.amount);
                } else if (v.kind == K_ROLL) {
                    _credit(K_ROLL, c, v.day, v.a0);
                    _credit(K_ROLL, c, v.day + 1, v.a1);
                } else if (v.kind == K_EPOCH) {
                    if (uint64(v.key) > epochAcked[c]) epochAcked[c] = uint64(v.key);
                }
                credited[k] = true;
                _dropPending(k);
            }
            // else: fact not yet older than the wait; verify is re-sent after verifyTimeout
        }
        _poke();
    }

    /// Owner config, from the home-chain console. A raise applies at once, also to open days;
    /// a decrease applies to days not yet opened (at the latest d+2, since d+1 may be pre-granted).
    function _onCapSet(uint64 nonce, uint256 newCap) internal {
        if (newCap > MAX_CAP) newCap = MAX_CAP;
        if (_newerCap(nonce)) {
            capNonce = nonce;
            uint64 t = _today();
            for (uint64 d = t; d <= t + 1; d++) {
                DayBook storage b = _days[d];
                if (b.open && newCap > b.cap) {
                    b.pool += uint120(newCap - b.cap);
                    b.cap = uint128(newCap);
                }
            }
            cap = newCap;
        }
        _poke();
    }

    function _onUnstop(uint64 nonce, uint64 e) internal {
        if (nonce > unstopNonce) {
            unstopNonce = nonce;
            if (frozen && _unstopLifts(e)) {
                epoch++;
                frozen = false;
                emit Unfrozen(epoch);
            }
        }
        _poke();
    }

    function _onTick() internal {
        _poke();
    }

    // ============================================================== the loop

    function _poke() internal {
        _sendsLeft = MAX_SENDS + 1;
        uint64 nowTs = uint64(block.timestamp);

        // 1. epoch (freeze/unfreeze) not yet confirmed on a chain: a new epoch goes out at once,
        //    a resend after its backoff. First, so STOP never waits behind other work.
        for (uint8 c; c < nChains; c++) {
            if (epochAcked[c] >= epoch) continue;
            bool fresh = _lastEpochSent[c] != epoch;
            if (fresh || nowTs >= epochSentAt[c] + _backoff(_cp[c].grantTimeout, epochTries[c])) {
                if (!_canSend()) break;
                _sendEpoch(c);
            }
        }

        // A call that sent epoch (STOP/unstop) messages does nothing else: the most important
        // call stays the lightest. The rest waits for the next event or Cron tick.
        if (_sendsLeft <= MAX_SENDS) return;

        // 1b. heartbeat: every chain whose beat is due gets one, so each chain hears from the core
        //     at least every `heartbeat` plus one Cron period, even when nothing else is due.
        //     At most 2 per call (steady demand is 3 per `heartbeat`, one call per Cron period).
        if (heartbeat != 0) {
            uint256 beats;
            for (uint8 c; c < nChains && beats < 2; c++) {
                if (nowTs < _beatDue[c]) continue;
                if (!_canSendBackground()) break;
                _beat(c, nowTs);
                beats++;
            }
        }

        // 2. returns old enough to confirm: ask the origin chain to re-read the fact
        //    (at most 2 per call, so cancels always get a share of the budget)
        uint256 n = _pendingKeys.length;
        if (n > 0) {
            uint256 i = _pCur % n;
            uint256 stopAt = _sendsLeft > 3 ? _sendsLeft - 2 : 1;
            for (uint256 s; s < SCAN && s < n; s++) {
                bytes32 k = _pendingKeys[i];
                if (_waitPassed(k, nowTs)) {
                    if (_sendsLeft <= stopAt || !_canSendBackground()) break;
                    _onMatured(k);
                }
                i = (i + 1) % n;
            }
            _pCur = i;
        }

        // 3. grants never acknowledged: cancel (refund only on a confirmed tombstone)
        n = _liveGrants.length;
        {
            uint256 i = _gCur;
            for (uint256 s; s < SCAN && n > 0; s++) {
                if (i >= n) i = 0;
                uint256 id = _liveGrants[i];
                Grant storage g = grants[id];
                if (g.st == G_APPLIED || g.st == G_REFUNDED) {
                    _removeAt(_liveGrants, i);
                    n--;
                    continue;
                }
                if (
                    nowTs >= g.sentAt + _backoff(_cp[g.chain].grantTimeout, g.tries)
                        && pending[_key(K_VOID, g.chain, id)].kind == 0
                ) {
                    if (!_canSendBackground()) break;
                    _sendCancel(id);
                }
                i++;
            }
            _gCur = i;
        }

        // 4. reclaims never answered: close, so the donor can be asked again with a new id
        n = _liveReclaims.length;
        {
            uint256 i = _rCur;
            for (uint256 s; s < SCAN && n > 0; s++) {
                if (i >= n) i = 0;
                Reclaim storage r = reclaims[_liveReclaims[i]];
                // a reclaim whose return is pending is answered: it never times out
                if (
                    r.open && nowTs >= r.sentAt + _cp[r.chain].reclaimTimeout
                        && pending[_key(K_RECLAIM, r.chain, _liveReclaims[i])].kind == 0
                ) _closeReclaim(_liveReclaims[i]);
                if (!r.open) {
                    _removeAt(_liveReclaims, i);
                    n--;
                    continue;
                }
                i++;
            }
            _rCur = i;
        }

        if (frozen) return;

        // 5. open today; pre-grant tomorrow late in the day (one share per chain, once)
        uint64 t = _today();
        _open(t);
        if (block.timestamp % DAY >= DAY - pregrantWindow) {
            uint64 d = t + 1;
            _open(d);
            uint256 share = _days[d].cap / (uint256(nChains) + 1);
            uint256 mask = _pregranted[d];
            for (uint8 c; c < nChains && share > 0; c++) {
                if (mask & (1 << c) != 0 || !_inflightFree(c)) continue;
                if (!_canSend()) break;
                mask |= 1 << c;
                _grant(c, d, share < _days[d].pool ? share : _days[d].pool);
            }
            _pregranted[d] = mask;
        }

        // 6. serve the waiting list
        _serve(t);

        // 7. refill ahead by burn rate, with whatever sends are left
        _refillAhead(t);
    }

    /// Refill ahead by burn rate. For each chain whose meter shows it burning at least a chunk
    /// within reclaimLead, project when its allowance for today runs out (held minus spent at the
    /// last reading minus rate x elapsed). Acting only on a fresh reading (asked for if needed):
    ///  - within `refillLead` of that: top it up from the pool by `refillHorizon` of its rate (at
    ///    least one chunk), on this react, before its agent is refused;
    ///  - within `reclaimLead` of that, if the pool can't give that top-up: start the donor path
    ///    now (it takes the confirmation wait plus up to two Cron periods), one reclaim per react
    ///    from the chain with the most slack beyond its floor, one chunk and its own projected need
    ///    (read fresh first as well: an agent that just got busy may not have a rate yet).
    /// Slower chains are left to the reactive path, as in W2. A chain projected dry that isn't
    /// asking gets nothing here: its agent has slowed or stopped, and a real shortfall arrives as
    /// a Short that _serve answers. A chain that is asking (its want is live) is served by _serve.
    /// Every grant and reclaim goes through _grant / _sendReclaim, after the frozen return: the
    /// books, rules 1-6, the one-unanswered-grant rule and the STOP epochs hold as before.
    function _refillAhead(uint64 t) internal virtual {
        if (refillHorizon == 0) return;
        DayBook storage b = _days[t];
        uint256 chunk = b.cap / 10;
        uint256 owed; // the top-ups due within reclaimLead that the pool can't give
        uint256 needy; // bit per chain inside its reclaimLead (no donor)
        for (uint8 c; c < nChains; c++) {
            uint256 r = _rate(c);
            // Only a chain fast enough to burn a chunk within reclaimLead. A slower one is served
            // in time by the reactive path (LowWater -> top-up in seconds; the donor path starts
            // while its cushion lasts), and a chunk-sized top-up would park budget on it for hours.
            if (!_fastEnough(r, chunk) || _wanting(c, t)) continue;
            uint256 left = _leftAt(c, t, r);
            // Projected dry but not asking: the agent slowed or stopped (a chain that is really
            // out asks, and _serve answers it). Refilling it would park budget on an idle chain.
            if (left == 0 || left >= r * reclaimLead / 1 hours) continue;
            // Read before refilling: act only on a reading younger than refillLead / 4, so a
            // burst that has ended doesn't get another hour of its rate. The answer is a react of
            // its own a few seconds later, which comes back here.
            if (!_freshReading(c)) {
                if (!_canSend()) return;
                _askReading(c);
                continue;
            }
            needy |= 1 << c;
            uint256 size = r * refillHorizon / 1 hours;
            if (size < chunk) size = chunk;
            if (_refillDue(left, r) && b.pool > 0 && _inflightFree(c)) {
                if (!_canSend()) return;
                uint256 give = size < b.pool ? size : b.pool;
                emit Ahead(1, c, give, r);
                _grant(c, t, give);
                size -= give;
            }
            owed += size;
        }
        if (owed <= b.pool) return;
        owed -= b.pool;
        // The donor path, ahead: one reclaim per react, from the chain with the most slack. Being
        // speculative, it is gentler than a reclaim for a chain that is asking (which may take a
        // donor down to its floor): a donor keeps its floor, one chunk for its own next calls, and
        // its own projected need until the donor path could refill it.
        uint8 best = type(uint8).max;
        uint256 bestSlack;
        for (uint8 j; j < nChains; j++) {
            if (needy & (1 << j) != 0 || _askedRecently(j, t)) continue;
            if (openReclaim[j][t] != 0 || b.dry[j]) continue;
            uint256 r = _rate(j);
            uint256 keep = keepFloor + chunk + _donorNeed(r);
            uint256 left = _leftAt(j, t, r);
            if (left > keep && left - keep > bestSlack) {
                best = j;
                bestSlack = left - keep;
            }
        }
        if (best == type(uint8).max || !_canSend()) return;
        // Read before taking, too: a donor whose agent just got busy may not have a rate yet.
        if (!_freshReading(best)) return _askReading(best);
        uint256 amt = bestSlack < owed ? bestSlack : owed;
        emit Ahead(2, best, amt, _rate(best));
        _sendReclaim(best, t, amt);
    }

    /// A reading of chain c recent enough to refill on (younger than refillLead / 4, origin time).
    function _freshReading(uint8 c) internal view returns (bool) {
        return block.timestamp <= uint256(meter[c].ts) + refillLead / 4;
    }

    /// Ask chain c for a meter reading now (a heartbeat re-read, so it also carries a lost STOP
    /// press back), at most once per re-read timeout.
    function _askReading(uint8 c) internal {
        uint64 nowTs = uint64(block.timestamp);
        if (nowTs < _readAskedAt[c] + _cp[c].verifyTimeout) return;
        _readAskedAt[c] = nowTs;
        _beat(c, nowTs);
    }

    function _fastEnough(uint256 rateH, uint256 chunk) internal view virtual returns (bool) {
        return rateH != 0 && rateH * reclaimLead / 1 hours >= chunk;
    }

    /// The top-up goes out once the projected unspent covers less than refillLead of spending.
    function _refillDue(uint256 left, uint256 rateH) internal view virtual returns (bool) {
        return left < rateH * refillLead / 1 hours;
    }

    /// What an active donor keeps beyond the floor: its own projected spending until the donor
    /// path could bring budget back, so feeding one chain doesn't starve another (anti ping-pong
    /// for chains that never ask because they are refilled ahead).
    function _donorNeed(uint256 rateH) internal view virtual returns (uint256) {
        return rateH * (uint256(reclaimLead) + refillHorizon) / 1 hours;
    }

    /// A chain's spend rate (units per hour), or 0 if it has no reading younger than 3 heartbeats.
    function _rate(uint8 c) internal view returns (uint256) {
        Meter storage m = meter[c];
        if (block.timestamp > uint256(m.ts) + 3 * uint256(heartbeat)) return 0;
        return m.rateH;
    }

    /// Projected unspent allowance of chain c for day t: held, minus spent at the last reading of
    /// day t (or 0 at its midnight), minus the rate over the time since.
    function _leftAt(uint8 c, uint64 t, uint256 rateH) internal view returns (uint256) {
        Meter storage m = meter[c];
        uint256 spent;
        uint256 since = uint256(t) * DAY;
        if (m.day == t) {
            spent = m.spent;
            if (m.ts > since) since = m.ts;
        }
        if (block.timestamp > since) spent += rateH * (block.timestamp - since) / 1 hours;
        uint256 h = _days[t].held[c];
        return h > spent ? h - spent : 0;
    }

    /// A LowWater is a reading too, the moment it matters most: spent = held - unspent, exact when
    /// the chain has no unanswered grant, no open reclaim and no unconfirmed return (then held is
    /// exactly the wallet's allowance for the day). Otherwise it only asks.
    function _readAtLowWater(uint8 c, uint64 day, uint256 unspent, uint64 ts) internal {
        if (refillHorizon == 0 || inflight[c] != 0 || _pendingOf[c] != 0 || openReclaim[c][day] != 0) return;
        uint256 h = _days[day].held[c];
        if (h >= unspent) _read(c, day, h - unspent, ts);
    }

    /// A meter reading, applied only if newer (origin time) than the last one.
    function _read(uint8 c, uint64 day, uint256 spent, uint64 ts) internal virtual {
        Meter storage m = meter[c];
        if (!_newerReading(m, day, ts) || spent > type(uint128).max) return;
        if (spent > (day == m.day ? m.spent : 0)) _markActive();
        if (m.ts == 0) {
            // the very first reading: a basis, no rate yet
            m.fromTs = ts;
            m.fromSpent = uint128(spent);
        } else if (day != m.day) {
            // the first reading of a new day: its window starts at that day's midnight, spent 0
            m.fromTs = uint64(uint256(day) * DAY);
            m.fromSpent = 0;
        }
        m.day = day;
        m.ts = ts;
        m.spent = uint128(spent);
        if (spent < m.fromSpent) {
            // below the window's start (an earlier reading was high): restart the window here
            m.fromTs = ts;
            m.fromSpent = uint128(spent);
            return;
        }
        uint256 window = heartbeat / 4 > 60 ? heartbeat / 4 : 60;
        if (ts >= uint256(m.fromTs) + window) {
            uint256 rate = (spent - m.fromSpent) * 1 hours / (ts - m.fromTs);
            m.rateH = uint128(rate < MAX_CAP ? rate : MAX_CAP);
            m.fromTs = ts;
            m.fromSpent = uint128(spent);
        }
    }

    function _newerReading(Meter storage m, uint64 day, uint64 ts) internal view virtual returns (bool) {
        return day != 0 && day >= m.day && ts > m.ts;
    }

    function _serve(uint64 t) internal {
        DayBook storage b = _days[t];
        uint256 chunk = b.cap / 10;
        uint8 start = _rr;
        _rr = uint8((uint256(_rr) + 1) % nChains); // rotate, so no chain is always served first
        // 1. serve from the pool; add up what the chains still short are owed (each at least one
        //    chunk, which is what serving will give them)
        uint256 owed;
        for (uint8 k; k < nChains; k++) {
            uint8 c = uint8((uint256(start) + k) % nChains);
            if (!_wanting(c, t) || !_inflightFree(c)) continue;
            Want storage w = want[c];
            uint256 need = w.amount;
            if (b.pool > 0) {
                if (!_canSend()) return;
                uint256 give = need > chunk ? need : chunk;
                if (give > b.pool) give = b.pool;
                _grant(c, t, give);
                w.amount = give >= need ? 0 : uint128(need - give);
            }
            if (w.amount != 0) owed += w.amount > chunk ? w.amount : chunk;
        }
        if (owed == 0) return;
        // 2. one reclaim per eligible donor for everything owed, so a single confirmation cycle
        //    covers every short chain (sizing it to one chain's want made two short chains wait
        //    for two 30-min cycles, and the first return could go to the other chain)
        for (uint8 j; j < nChains; j++) {
            // A chain that asked recently is no donor, even once served: otherwise a grant is
            // reclaimed before its agent can spend it, and allowance circulates (ping-pong).
            if (_askedRecently(j, t)) continue;
            if (openReclaim[j][t] != 0 || b.dry[j] || b.held[j] <= keepFloor) continue;
            if (!_canSend()) return;
            _sendReclaim(j, t, owed);
        }
    }

    function _beat(uint8 c, uint64 nowTs) internal virtual {
        _send(c, abi.encodeCall(IWalletInbox.verify, (K_EPOCH, epoch)));
        _beatDue[c] = nowTs + (_isActive() ? heartbeat : idleHeartbeat);
    }

    /// Active: an agent showed it was spending within `idleAfter` (or the idle beat is off).
    function _isActive() internal view returns (bool) {
        return idleHeartbeat == 0 || (lastActiveAt != 0 && block.timestamp < uint256(lastActiveAt) + idleAfter);
    }

    /// An agent is spending. Coming out of idle, every chain's next beat is brought back within
    /// `heartbeat`, so a lost STOP press reaches every chain within one active beat cycle of the
    /// first sign of spending, as before W3.
    function _markActive() internal virtual {
        uint64 nowTs = uint64(block.timestamp);
        if (!_isActive()) {
            for (uint8 c; c < nChains; c++) {
                if (_beatDue[c] > nowTs + heartbeat) _beatDue[c] = nowTs + heartbeat;
            }
        }
        lastActiveAt = nowTs;
    }

    /// Retries to chain c (its in-flight grant's cancels, its epoch resends) back off up to 32x.
    /// An event that answers a callback (`answer`: applied/not applied, cancel ack, reclaimed,
    /// rolled, epoch ack, verified) proves callbacks land again: the backoff starts over. An
    /// origin-only event (Short, LowWater, StopPressed) proves only that the chain itself is up,
    /// not that its front gets callbacks: the backoff is capped at ALIVE_CAP doublings (4 x the
    /// timeout, 40 min in production) instead. So a chain back from an outage is retried within
    /// one capped backoff, and a front that stays dead while its agent is active costs one cancel
    /// per 40 min, not one per 10 min.
    function _alive(uint8 c, bool answer) internal virtual {
        uint8 limit = answer ? 0 : ALIVE_CAP;
        if (epochTries[c] > limit) epochTries[c] = limit;
        uint256 id = _inflightId[c];
        if (id != 0) {
            Grant storage g = grants[id];
            if (!g.answered && g.tries > limit) g.tries = limit;
        }
    }

    /// Heartbeats, re-reads and cancels leave one send per call for serving (grants and
    /// reclaims) while not frozen, so a backlog of re-reads can't starve the user-visible path.
    function _canSendBackground() internal view returns (bool) {
        return _sendsLeft > (frozen ? 1 : 2);
    }

    function _canSend() internal view returns (bool) {
        return _sendsLeft > 1;
    }

    /// At most one unanswered grant per chain.
    function _inflightFree(uint8 c) internal view virtual returns (bool) {
        return inflight[c] == 0;
    }

    function _answered(Grant storage g) internal {
        if (!g.answered) {
            g.answered = true;
            inflight[g.chain]--;
        }
    }

    /// Every outgoing message goes through here, so the per-call budget always holds.
    function _send(uint8 c, bytes memory payload) internal {
        if (_sendsLeft > 1) _sendsLeft--;
        _dispatch(c, payload);
    }

    function _askedRecently(uint8 c, uint64 t) internal view returns (bool) {
        Want storage w = want[c];
        return w.day == t && w.at != 0 && block.timestamp <= uint256(w.at) + _cp[c].wantTtl;
    }

    function _wanting(uint8 c, uint64 t) internal view returns (bool) {
        Want storage w = want[c];
        return w.day == t && w.amount > 0 && block.timestamp <= uint256(w.at) + _cp[c].wantTtl;
    }

    // ============================================================ actions

    function _grant(uint8 c, uint64 d, uint256 amount) internal virtual {
        DayBook storage b = _days[d];
        b.pool -= uint120(amount); // rule 1: debit before sending
        b.held[c] += amount;
        b.dry[c] = false;
        uint256 id = nextId++;
        grants[id] = Grant(c, G_SENT, 0, d, epoch, uint64(block.timestamp), uint128(amount), false);
        inflight[c]++;
        _inflightId[c] = id;
        _liveGrants.push(id);
        emit GrantSent(id, c, d, amount, epoch);
        _send(c, abi.encodeCall(IWalletInbox.applyGrant, (id, d, amount, epoch)));
    }

    function _sendReclaim(uint8 c, uint64 d, uint256 amount) internal virtual returns (uint256 id) {
        id = nextId++;
        reclaims[id] = Reclaim(c, true, d, uint64(block.timestamp), uint128(amount));
        openReclaim[c][d] = id;
        _liveReclaims.push(id);
        emit ReclaimSent(id, c, d, amount);
        _send(c, abi.encodeCall(IWalletInbox.applyReclaim, (id, d, amount)));
    }

    function _closeReclaim(uint256 id) internal {
        Reclaim storage r = reclaims[id];
        if (!r.open) return;
        r.open = false;
        if (openReclaim[r.chain][r.day] == id) openReclaim[r.chain][r.day] = 0;
    }

    function _sendCancel(uint256 grantId) internal virtual {
        Grant storage g = grants[grantId];
        if (g.st == G_CANCELLING && g.tries < 255) g.tries++;
        g.st = G_CANCELLING;
        g.sentAt = uint64(block.timestamp);
        uint256 id = nextId++;
        emit CancelSent(id, grantId);
        _send(g.chain, abi.encodeCall(IWalletInbox.applyCancel, (id, grantId)));
    }

    function _sendEpoch(uint8 c) internal {
        // a resend of the same epoch backs off; a new epoch starts fresh
        if (epochSentAt[c] != 0 && _lastEpochSent[c] == epoch) {
            if (epochTries[c] < 255) epochTries[c]++;
        } else {
            epochTries[c] = 0;
        }
        _lastEpochSent[c] = epoch;
        epochSentAt[c] = uint64(block.timestamp);
        _send(c, _epochMessage(c));
    }

    /// A claimed return enters the books only as pending (rule 2).
    function _admit(uint8 kind, uint8 c, uint256 id, uint64 day, uint256 a0, uint256 a1, uint64 ts) internal virtual {
        bytes32 k = _key(kind, c, id);
        if (_alreadyCredited(k) || pending[k].kind != 0) return;
        pending[k] = Pending(kind, c, 0, day, ts, 0, id, uint128(a0), uint128(a1));
        _pendingKeys.push(k);
        _pendingPos[k] = _pendingKeys.length;
        _pendingOf[c]++;
    }

    /// The confirmation wait has passed: re-read the fact on the origin chain.
    function _onMatured(bytes32 k) internal virtual {
        Pending storage p = pending[k];
        if (p.verifySentAt == 0 || block.timestamp >= p.verifySentAt + _backoff(_cp[p.chain].verifyTimeout, p.tries)) {
            if (p.verifySentAt != 0 && p.tries < 255) p.tries++;
            p.verifySentAt = uint64(block.timestamp);
            _send(p.chain, abi.encodeCall(IWalletInbox.verify, (p.kind, p.id)));
        }
    }

    /// Retries back off exponentially (x2 per try, up to x32): every callback is billed, and a
    /// slow network must not be answered with a retry storm.
    function _backoff(uint64 base, uint8 tries) internal pure returns (uint256) {
        return uint256(base) << (tries < 5 ? tries : 5);
    }

    function _alreadyCredited(bytes32 k) internal view virtual returns (bool) {
        return credited[k];
    }

    // Policy steps, kept separate so each rule can be broken on purpose in the mutation suite.

    /// Rule 2: a re-read counts only if the fact had existed for the whole confirmation wait when
    /// it was read (both times from the origin chain's clock). This is the safety check.
    function _oldEnough(uint8 c, Echo memory v) internal view virtual returns (bool) {
        return v.ts >= v.appliedAt + _cp[c].confirmWait;
    }

    /// Rule 2, cost: don't ask for a re-read before the fact can be old enough. Not needed for
    /// safety (_oldEnough is), but an early re-read is a billed callback that can only fail.
    function _waitPassed(bytes32 k, uint64 nowTs) internal view virtual returns (bool) {
        Pending storage p = pending[k];
        return nowTs >= p.originTs + _cp[p.chain].confirmWait;
    }

    /// An unstop lifts only the frozen epoch it names.
    function _unstopLifts(uint64 e) internal view virtual returns (bool) {
        return e == epoch;
    }

    /// Owner cap messages apply in nonce order; an older one delivered late is ignored.
    function _newerCap(uint64 nonce) internal view virtual returns (bool) {
        return nonce > capNonce;
    }

    /// The freeze/unfreeze message: the epoch, whether it is frozen, and the newest local press
    /// on that chain the coordinator has seen.
    function _epochMessage(uint8 c) internal view virtual returns (bytes memory) {
        return abi.encodeCall(IWalletInbox.applyEpoch, (epoch, frozen, pressSeenAt[c]));
    }

    /// Moves a confirmed return from a chain's holding back to the day's pool. Clamped, so the
    /// conservation identity holds even against a misbehaving wallet.
    function _credit(uint8 kind, uint8 c, uint64 d, uint256 amount) internal {
        DayBook storage b = _days[d];
        uint256 x = amount < b.held[c] ? amount : b.held[c];
        if (x == 0) return;
        b.held[c] -= x;
        b.pool += uint120(x);
        emit Credited(kind, c, d, x);
    }

    function _open(uint64 d) internal {
        DayBook storage b = _days[d];
        if (!b.open) {
            b.open = true;
            b.cap = uint128(cap);
            b.pool = uint120(cap);
            emit DayOpened(d, cap);
        }
    }

    function _dropPending(bytes32 k) internal {
        uint256 pos = _pendingPos[k];
        if (pos == 0) return;
        uint256 last = _pendingKeys.length;
        if (pos != last) {
            bytes32 moved = _pendingKeys[last - 1];
            _pendingKeys[pos - 1] = moved;
            _pendingPos[moved] = pos;
        }
        _pendingKeys.pop();
        delete _pendingPos[k];
        uint8 pc = pending[k].chain;
        if (_pendingOf[pc] > 0) _pendingOf[pc]--;
        delete pending[k];
    }

    function _removeAt(uint256[] storage arr, uint256 i) internal {
        arr[i] = arr[arr.length - 1];
        arr.pop();
    }

    function _key(uint8 kind, uint8 c, uint256 id) internal pure returns (bytes32) {
        return keccak256(abi.encode(kind, c, id));
    }

    function _today() internal view returns (uint64) {
        return uint64(block.timestamp / DAY);
    }

    /// Emit a message to chain `c`. Production: a Reactive callback request. Call _send, not this.
    function _dispatch(uint8 c, bytes memory payload) internal virtual;

    // ================================================================ views

    function chainParams(uint8 c) external view returns (ChainParams memory) {
        return _cp[c];
    }

    function confirmWaitOf(uint8 c) external view returns (uint64) {
        return _cp[c].confirmWait;
    }

    function today() external view returns (uint64) {
        return _today();
    }

    function capOfDay(uint64 d) external view returns (uint256) {
        return _days[d].cap;
    }

    function poolOf(uint64 d) external view returns (uint256) {
        return _days[d].pool;
    }

    function heldOf(uint64 d, uint8 c) external view returns (uint256) {
        return _days[d].held[c];
    }

    function isOpen(uint64 d) external view returns (bool) {
        return _days[d].open;
    }

    function pendingCount() external view returns (uint256) {
        return _pendingKeys.length;
    }

    function liveGrantCount() external view returns (uint256) {
        return _liveGrants.length;
    }
}
