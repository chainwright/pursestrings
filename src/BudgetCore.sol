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

    struct Params {
        uint8 nChains;
        uint256 cap;
        uint256 keepFloor;
        /// Per chain: how long a return must have existed on its origin chain before it is
        /// credited. Must exceed that chain's reorg window (see TestnetConfig).
        uint64[] confirmWaits;
        uint64 grantTimeout;
        uint64 reclaimTimeout;
        uint64 verifyTimeout;
        uint64 pregrantWindow;
        uint64 wantTtl;
        /// Every chain gets a heartbeat (a cheap re-read) at least this often, driven by Cron.
        /// It carries a lost STOP press back even if nothing else is sent to that chain.
        /// 0 = off.
        uint64 heartbeat;
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

    /// Work bounds per call (one react()): at most MAX_SENDS callback requests, and at most SCAN
    /// entries of each retry list looked at; the rest is carried to the next call (Cron tick or
    /// event). STOP/unstop messages go first. Gas measured in test/Gas.t.sol.
    uint256 public constant MAX_SENDS = 4;
    uint256 public constant SCAN = 4;
    /// Caps above this are treated as this (it is ~1.3e36 base units; it only bounds packing).
    uint256 public constant MAX_CAP = type(uint120).max;
    /// New grants are refused while this many are unacknowledged (e.g. a destination chain is
    /// dead), so the retry lists can't grow without bound.
    uint256 public constant MAX_LIVE_GRANTS = 32;

    uint8 public immutable nChains;
    uint256 public immutable keepFloor;
    uint64 public immutable grantTimeout;
    uint64 public immutable reclaimTimeout;
    uint64 public immutable verifyTimeout;
    uint64 public immutable pregrantWindow;
    uint64 public immutable wantTtl;
    uint64 public immutable heartbeat;

    uint256 public cap;
    uint64 public capNonce;
    uint64 public unstopNonce;
    uint64 public epoch;
    bool public frozen;

    mapping(uint8 => uint64) public pressSeenAt;
    mapping(uint8 => uint64) public epochAcked;
    mapping(uint8 => uint64) public epochSentAt;
    mapping(uint8 => uint8) public epochTries;
    mapping(uint8 => uint64) internal _lastEpochSent;
    mapping(uint8 => uint64) public confirmWaitOf;

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
    uint8 internal _rr;

    /// Callback requests still allowed in this call, plus one (never stored as zero, so resetting
    /// it each call is a cheap non-zero write).
    uint256 internal _sendsLeft = 1;
    uint256 internal _pCur;
    uint256 internal _gCur;
    uint256 internal _rCur;
    /// day => bit per chain already pre-granted for that day
    mapping(uint64 => uint256) internal _pregranted;
    uint64 internal _nextBeat;
    uint8 internal _beatChain;

    event DayOpened(uint64 day, uint256 cap);
    event GrantSent(uint256 id, uint8 chain, uint64 day, uint256 amount, uint64 epoch);
    event ReclaimSent(uint256 id, uint8 chain, uint64 day, uint256 amount);
    event CancelSent(uint256 id, uint256 grantId);
    event Credited(uint8 kind, uint8 chain, uint64 day, uint256 amount);
    event Frozen(uint64 epoch);
    event Unfrozen(uint64 epoch);

    constructor(Params memory p) {
        // STOP reaches every chain in the same call: one epoch message per chain fits the budget.
        require(p.nChains > 0 && p.nChains <= MAX_SENDS, "chains");
        require(p.confirmWaits.length == p.nChains, "waits");
        nChains = p.nChains;
        cap = p.cap < MAX_CAP ? p.cap : MAX_CAP;
        keepFloor = p.keepFloor;
        for (uint8 c; c < p.nChains; c++) {
            confirmWaitOf[c] = p.confirmWaits[c];
        }
        grantTimeout = p.grantTimeout;
        reclaimTimeout = p.reclaimTimeout;
        verifyTimeout = p.verifyTimeout;
        pregrantWindow = p.pregrantWindow;
        wantTtl = p.wantTtl;
        heartbeat = p.heartbeat;
    }

    // ================================================================ inputs
    // Each is one decoded origin event. All end in _poke(): retries run lazily on every
    // react() as well as on Cron ticks.

    function _onShort(uint8 c, uint64 day, uint256 shortBy) internal {
        if (!frozen && day == _today()) {
            Want storage w = want[c];
            if (!_wanting(c, day) || w.amount < shortBy) w.amount = uint128(shortBy);
            w.day = day;
            w.at = uint64(block.timestamp);
        }
        _poke();
    }

    function _onLowWater(uint8 c, uint64 day) internal {
        if (!frozen && day == _today()) {
            if (!_wanting(c, day)) want[c] = Want(day, uint64(block.timestamp), uint128(cap / 10));
        }
        _poke();
    }

    function _onGrantApplied(uint8 c, uint256 grantId) internal virtual {
        Grant storage g = grants[grantId];
        if (g.st != 0 && g.chain == c && (g.st == G_SENT || g.st == G_CANCELLING)) g.st = G_APPLIED;
        _poke();
    }

    function _onGrantNotApplied(uint8 c, uint256 grantId, uint64 ts) internal {
        Grant storage g = grants[grantId];
        if (g.st != 0 && g.chain == c) _admit(K_VOID, c, grantId, g.day, g.amount, 0, ts);
        _poke();
    }

    function _onCancelAck(uint8 c, uint256 grantId, bool applied, uint64 ts) internal {
        Grant storage g = grants[grantId];
        if (g.st != 0 && g.chain == c) {
            if (applied) {
                if (g.st != G_REFUNDED) g.st = G_APPLIED;
            } else {
                _admit(K_VOID, c, grantId, g.day, g.amount, 0, ts);
            }
        }
        _poke();
    }

    function _onReclaimed(uint8 c, uint256 reqId, uint256 amount, uint64 ts) internal {
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
        _admit(K_ROLL, c, e, day, r0, r1, ts);
        _poke();
    }

    function _onEpochAck(uint8 c, uint64 e, uint64 ts) internal {
        if (e > epochAcked[c]) _admit(K_EPOCH, c, e, 0, 0, 0, ts);
        _poke();
    }

    /// Only a strictly newer press acts, so a duplicated, replayed or re-announced log can't
    /// re-freeze after an unstop. Every new press opens a new frozen epoch, even when already
    /// frozen: an unstop issued before this press names an older epoch and can never lift it.
    function _onStopPressed(uint8 c, uint64 mark) internal {
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
            if (fresh || nowTs >= epochSentAt[c] + _backoff(grantTimeout, epochTries[c])) {
                if (!_canSend()) break;
                _sendEpoch(c);
            }
        }

        // 1b. heartbeat: one chain per beat, round robin, so each chain hears from the core at
        //     least every `heartbeat` even when nothing else is due (Cron drives this).
        if (heartbeat != 0 && nowTs >= _nextBeat && _canSend()) _beat(nowTs);

        // 2. returns old enough to confirm: ask the origin chain to re-read the fact
        uint256 n = _pendingKeys.length;
        if (n > 0) {
            uint256 i = _pCur % n;
            for (uint256 s; s < SCAN && s < n; s++) {
                bytes32 k = _pendingKeys[i];
                if (_waitPassed(k, nowTs)) {
                    if (!_canSend()) break;
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
                if (nowTs >= g.sentAt + _backoff(grantTimeout, g.tries) && pending[_key(K_VOID, g.chain, id)].kind == 0)
                {
                    if (!_canSend()) break;
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
                if (r.open && nowTs >= r.sentAt + reclaimTimeout) _closeReclaim(_liveReclaims[i]);
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
                if (mask & (1 << c) != 0) continue;
                if (!_canGrant()) break;
                mask |= 1 << c;
                _grant(c, d, share < _days[d].pool ? share : _days[d].pool);
            }
            _pregranted[d] = mask;
        }

        // 6. serve the waiting list
        _serve(t);
    }

    function _serve(uint64 t) internal {
        DayBook storage b = _days[t];
        uint256 chunk = b.cap / 10;
        uint8 start = _rr;
        _rr = uint8((uint256(_rr) + 1) % nChains); // rotate, so no chain is always served first
        for (uint8 k; k < nChains; k++) {
            uint8 c = uint8((uint256(start) + k) % nChains);
            if (!_wanting(c, t)) continue;
            Want storage w = want[c];
            uint256 need = w.amount;
            if (b.pool > 0) {
                if (!_canGrant()) return;
                uint256 give = need > chunk ? need : chunk;
                if (give > b.pool) give = b.pool;
                _grant(c, t, give);
                w.amount = give >= need ? 0 : uint128(need - give);
            }
            if (w.amount == 0) continue;
            for (uint8 j; j < nChains; j++) {
                if (j == c) continue;
                // A chain that asked recently is no donor, even once served: otherwise a grant is
                // reclaimed before its agent can spend it, and allowance circulates (ping-pong).
                if (_askedRecently(j, t)) continue;
                if (openReclaim[j][t] != 0 || b.dry[j] || b.held[j] <= keepFloor) continue;
                if (!_canSend()) return;
                _sendReclaim(j, t, w.amount);
            }
        }
    }

    function _beat(uint64 nowTs) internal virtual {
        uint8 c = _beatChain;
        _send(c, abi.encodeCall(IWalletInbox.verify, (K_EPOCH, epoch)));
        _beatChain = uint8((uint256(c) + 1) % nChains);
        _nextBeat = nowTs + heartbeat / nChains;
    }

    function _canSend() internal view returns (bool) {
        return _sendsLeft > 1;
    }

    function _canGrant() internal view returns (bool) {
        return _sendsLeft > 1 && _liveGrants.length < MAX_LIVE_GRANTS;
    }

    /// Every outgoing message goes through here, so the per-call budget always holds.
    function _send(uint8 c, bytes memory payload) internal {
        if (_sendsLeft > 1) _sendsLeft--;
        _dispatch(c, payload);
    }

    function _askedRecently(uint8 c, uint64 t) internal view returns (bool) {
        Want storage w = want[c];
        return w.day == t && w.at != 0 && block.timestamp <= uint256(w.at) + wantTtl;
    }

    function _wanting(uint8 c, uint64 t) internal view returns (bool) {
        Want storage w = want[c];
        return w.day == t && w.amount > 0 && block.timestamp <= uint256(w.at) + wantTtl;
    }

    // ============================================================ actions

    function _grant(uint8 c, uint64 d, uint256 amount) internal virtual {
        DayBook storage b = _days[d];
        b.pool -= uint120(amount); // rule 1: debit before sending
        b.held[c] += amount;
        b.dry[c] = false;
        uint256 id = nextId++;
        grants[id] = Grant(c, G_SENT, 0, d, epoch, uint64(block.timestamp), uint128(amount));
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
    }

    /// The confirmation wait has passed: re-read the fact on the origin chain.
    function _onMatured(bytes32 k) internal virtual {
        Pending storage p = pending[k];
        if (p.verifySentAt == 0 || block.timestamp >= p.verifySentAt + _backoff(verifyTimeout, p.tries)) {
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
        return v.ts >= v.appliedAt + confirmWaitOf[c];
    }

    /// Rule 2, cost: don't ask for a re-read before the fact can be old enough. Not needed for
    /// safety (_oldEnough is), but an early re-read is a billed callback that can only fail.
    function _waitPassed(bytes32 k, uint64 nowTs) internal view virtual returns (bool) {
        Pending storage p = pending[k];
        return nowTs >= p.originTs + confirmWaitOf[p.chain];
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
