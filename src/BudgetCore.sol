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
        uint64 confirmWait;
        uint64 grantTimeout;
        uint64 reclaimTimeout;
        uint64 verifyTimeout;
        uint64 pregrantWindow;
        uint64 wantTtl;
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

    struct DayBook {
        bool open;
        uint256 cap;
        uint256 pool;
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

    uint8 public immutable nChains;
    uint256 public immutable keepFloor;
    uint64 public immutable confirmWait;
    uint64 public immutable grantTimeout;
    uint64 public immutable reclaimTimeout;
    uint64 public immutable verifyTimeout;
    uint64 public immutable pregrantWindow;
    uint64 public immutable wantTtl;

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

    event DayOpened(uint64 day, uint256 cap);
    event GrantSent(uint256 id, uint8 chain, uint64 day, uint256 amount, uint64 epoch);
    event ReclaimSent(uint256 id, uint8 chain, uint64 day, uint256 amount);
    event CancelSent(uint256 id, uint256 grantId);
    event Credited(uint8 kind, uint8 chain, uint64 day, uint256 amount);
    event Frozen(uint64 epoch);
    event Unfrozen(uint64 epoch);

    constructor(Params memory p) {
        require(p.nChains > 0 && p.nChains <= 16, "chains");
        nChains = p.nChains;
        cap = p.cap;
        keepFloor = p.keepFloor;
        confirmWait = p.confirmWait;
        grantTimeout = p.grantTimeout;
        reclaimTimeout = p.reclaimTimeout;
        verifyTimeout = p.verifyTimeout;
        pregrantWindow = p.pregrantWindow;
        wantTtl = p.wantTtl;
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

    function _onGrantApplied(uint8 c, uint256 grantId) internal {
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

    function _onStopPressed(uint8 c, uint64 mark) internal {
        if (mark > pressSeenAt[c]) pressSeenAt[c] = mark;
        if (!frozen) {
            frozen = true;
            epoch++;
            for (uint8 i; i < nChains; i++) {
                delete want[i];
            }
            emit Frozen(epoch);
            for (uint8 i; i < nChains; i++) {
                _sendEpoch(i);
            }
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
            } else if (v.ts >= v.appliedAt + confirmWait) {
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
        if (nonce > capNonce) {
            capNonce = nonce;
            uint64 t = _today();
            for (uint64 d = t; d <= t + 1; d++) {
                DayBook storage b = _days[d];
                if (b.open && newCap > b.cap) {
                    b.pool += newCap - b.cap;
                    b.cap = newCap;
                }
            }
            cap = newCap;
        }
        _poke();
    }

    function _onUnstop(uint64 nonce, uint64 e) internal {
        if (nonce > unstopNonce) {
            unstopNonce = nonce;
            if (frozen && e == epoch) {
                epoch++;
                frozen = false;
                emit Unfrozen(epoch);
                for (uint8 i; i < nChains; i++) {
                    _sendEpoch(i);
                }
            }
        }
        _poke();
    }

    function _onTick() internal {
        _poke();
    }

    // ============================================================== the loop

    function _poke() internal {
        uint64 nowTs = uint64(block.timestamp);

        // 1. returns old enough to confirm: ask the origin chain to re-read the fact
        for (uint256 i = _pendingKeys.length; i > 0; i--) {
            bytes32 k = _pendingKeys[i - 1];
            if (nowTs >= pending[k].originTs + confirmWait) _onMatured(k);
        }

        // 2. grants never acknowledged: cancel (refund only on a confirmed tombstone)
        for (uint256 i = _liveGrants.length; i > 0; i--) {
            uint256 id = _liveGrants[i - 1];
            Grant storage g = grants[id];
            if (g.st == G_APPLIED || g.st == G_REFUNDED) {
                _removeAt(_liveGrants, i - 1);
            } else if (
                nowTs >= g.sentAt + _backoff(grantTimeout, g.tries) && pending[_key(K_VOID, g.chain, id)].kind == 0
            ) {
                _sendCancel(id);
            }
        }

        // 3. reclaims never answered: close, so the donor can be asked again with a new id
        for (uint256 i = _liveReclaims.length; i > 0; i--) {
            uint256 id = _liveReclaims[i - 1];
            Reclaim storage r = reclaims[id];
            if (r.open && nowTs >= r.sentAt + reclaimTimeout) _closeReclaim(id);
            if (!r.open) _removeAt(_liveReclaims, i - 1);
        }

        // 4. epoch (freeze/unfreeze) not yet confirmed on a chain: re-send
        for (uint8 c; c < nChains; c++) {
            if (epochAcked[c] < epoch && nowTs >= epochSentAt[c] + _backoff(grantTimeout, epochTries[c])) {
                _sendEpoch(c);
            }
        }

        if (frozen) return;

        // 5. open today; pre-grant tomorrow late in the day
        uint64 t = _today();
        _open(t);
        if (block.timestamp % DAY >= DAY - pregrantWindow && !_days[t + 1].open) {
            _open(t + 1);
            uint256 share = _days[t + 1].cap / (uint256(nChains) + 1);
            if (share > 0) {
                for (uint8 c; c < nChains; c++) {
                    _grant(c, t + 1, share);
                }
            }
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
                _sendReclaim(j, t, w.amount);
            }
        }
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

    function _grant(uint8 c, uint64 d, uint256 amount) internal {
        DayBook storage b = _days[d];
        b.pool -= amount; // rule 1: debit before sending
        b.held[c] += amount;
        b.dry[c] = false;
        uint256 id = nextId++;
        grants[id] = Grant(c, G_SENT, 0, d, epoch, uint64(block.timestamp), uint128(amount));
        _liveGrants.push(id);
        emit GrantSent(id, c, d, amount, epoch);
        _dispatch(c, abi.encodeCall(IWalletInbox.applyGrant, (id, d, amount, epoch)));
    }

    function _sendReclaim(uint8 c, uint64 d, uint256 amount) internal virtual returns (uint256 id) {
        id = nextId++;
        reclaims[id] = Reclaim(c, true, d, uint64(block.timestamp), uint128(amount));
        openReclaim[c][d] = id;
        _liveReclaims.push(id);
        emit ReclaimSent(id, c, d, amount);
        _dispatch(c, abi.encodeCall(IWalletInbox.applyReclaim, (id, d, amount)));
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
        _dispatch(g.chain, abi.encodeCall(IWalletInbox.applyCancel, (id, grantId)));
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
        _dispatch(c, abi.encodeCall(IWalletInbox.applyEpoch, (epoch, frozen, pressSeenAt[c])));
    }

    /// A claimed return enters the books only as pending (rule 2).
    function _admit(uint8 kind, uint8 c, uint256 id, uint64 day, uint256 a0, uint256 a1, uint64 ts)
        internal
        virtual
    {
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
            _dispatch(p.chain, abi.encodeCall(IWalletInbox.verify, (p.kind, p.id)));
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

    /// Moves a confirmed return from a chain's holding back to the day's pool. Clamped, so the
    /// conservation identity holds even against a misbehaving wallet.
    function _credit(uint8 kind, uint8 c, uint64 d, uint256 amount) internal {
        DayBook storage b = _days[d];
        uint256 x = amount < b.held[c] ? amount : b.held[c];
        if (x == 0) return;
        b.held[c] -= x;
        b.pool += x;
        emit Credited(kind, c, d, x);
    }

    function _open(uint64 d) internal {
        DayBook storage b = _days[d];
        if (!b.open) {
            b.open = true;
            b.cap = cap;
            b.pool = cap;
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

    /// Emit a message to chain `c`. Production: a Reactive callback request.
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
