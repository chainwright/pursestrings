// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {
    IERC20Min,
    IWalletInbox,
    IWalletEvents,
    K_RECLAIM,
    K_VOID,
    K_ROLL,
    K_EPOCH
} from "./interfaces/IPursestrings.sol";
import {Vault} from "./Vault.sol";
import {SafeTransfer} from "./SafeTransfer.sol";

/// One agent's wallet on one chain. Its budget-token balance backs its allowance: a grant pulls
/// tokens from the local vault, a reclaim or sweep pushes them back. The only outflow to anyone
/// else is pay(): no generic call, no approve.
///
/// Allowance is kept per day bucket (today and, after a pre-grant, tomorrow). The wallet counts
/// allowance, never balanceOf, so stray tokens sent here are not spendable.
contract SpendWallet is IWalletInbox, IWalletEvents {
    using SafeTransfer for IERC20Min;

    uint256 public constant DAY = 1 days;
    /// Returns to the vault are best-effort: attempted only with at least this much gas left,
    /// and the attempt itself may use all but FLUSH_KEEP. A failed or skipped return never undoes
    /// the accounting (a freeze, a reclaim, a sweep): the tokens wait in `stranded`.
    uint256 internal constant FLUSH_MIN_GAS = 90_000;
    uint256 internal constant FLUSH_KEEP = 40_000;

    // pay() refusal reasons
    uint8 internal constant R_FROZEN = 1;
    uint8 internal constant R_PAYEE = 2;
    uint8 internal constant R_CAP = 3;
    uint8 internal constant R_SHORT = 4;
    // GrantNotApplied reasons
    uint8 internal constant NA_STALE_EPOCH = 1;
    uint8 internal constant NA_FROZEN = 2;
    uint8 internal constant NA_BAD_DAY = 3;
    uint8 internal constant NA_UNFUNDED = 4;

    IERC20Min public immutable token;
    Vault public immutable vault;
    /// The only sender of coordinator messages (in production: the fee-only callback front).
    address public immutable bridge;
    address public immutable owner;
    address public immutable agent;
    uint256 public immutable perCallCap;
    /// A reclaim never takes a wallet below this much unspent allowance (anti ping-pong).
    uint256 public immutable keepFloor;
    /// pay() emits LowWater once when unspent drops below this. Must sit below keepFloor,
    /// so a reclaim can never cause the donor's own low-water.
    uint256 public immutable lowWater;

    struct Bucket {
        uint128 allowance;
        uint128 spent;
    }

    mapping(uint64 => Bucket) public buckets;
    uint64[] internal _openDays;
    mapping(address => bool) public payeeAllowed;

    // Inbound dedup: every coordinator message id is applied at most once (gaps are fine).
    mapping(uint256 => bool) public seen;
    mapping(uint256 => bool) public grantApplied;
    /// grant id => time it was tombstoned as never applied (0 = not tombstoned)
    mapping(uint256 => uint64) public grantVoidAt;

    struct ReclaimRec {
        uint64 day;
        uint64 at;
        uint128 amount;
    }

    mapping(uint256 => ReclaimRec) public reclaimRec;

    struct RollRec {
        uint64 day;
        uint64 at;
        uint128 today;
        uint128 tomorrow;
    }

    mapping(uint64 => RollRec) public rollRec;

    uint64 public epoch;
    uint64 public epochSince;
    bool public frozen;
    /// Strictly increasing mark of the last local STOP press, and the newest press the
    /// coordinator has acknowledged in an unfreeze. A press stays in force until acknowledged.
    uint64 public lastPressAt;
    uint64 public pressAckedAt;
    uint64 public stopEchoAt;

    /// Short is emitted once, then again only after SHORT_REARM seconds or when re-armed by an
    /// applied/voided grant, a new epoch or a new day. "Once per day" alone deadlocks a chain for
    /// the rest of the day if that one Short is lost or arrives while the coordinator is frozen.
    uint64 public constant SHORT_REARM = 300;
    mapping(uint64 => uint64) public shortAt; // day => time of the last Short (0 = armed)
    mapping(uint64 => bool) public lowFired;
    /// Tokens owed back to the vault whose transfer hasn't happened yet. Never allowance.
    uint256 public stranded;

    modifier onlyBridge() {
        require(msg.sender == bridge, "bridge");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "owner");
        _;
    }

    constructor(
        IERC20Min token_,
        Vault vault_,
        address bridge_,
        address owner_,
        address agent_,
        uint256 perCallCap_,
        uint256 keepFloor_,
        uint256 lowWater_
    ) {
        require(lowWater_ < keepFloor_, "lowWater must be below floor");
        token = token_;
        vault = vault_;
        bridge = bridge_;
        owner = owner_;
        agent = agent_;
        perCallCap = perCallCap_;
        keepFloor = keepFloor_;
        lowWater = lowWater_;
    }

    // ------------------------------------------------------------------ owner

    function setPayee(address payee, bool allowed) external onlyOwner {
        payeeAllowed[payee] = allowed;
    }

    /// STOP from this chain: freezes here in the same transaction, then tells the coordinator.
    function pressStop() external onlyOwner {
        uint64 mark = uint64(block.timestamp);
        if (mark <= lastPressAt) mark = lastPressAt + 1;
        lastPressAt = mark;
        stopEchoAt = uint64(block.timestamp);
        if (_freezesOnPress()) frozen = true;
        emit StopPressed(mark);
    }

    /// Anything other than the budget token can leave only through the owner.
    function rescue(IERC20Min other, address to, uint256 amount) external onlyOwner {
        require(address(other) != address(token), "budget token leaves only via pay");
        other.safeTransfer(to, amount);
    }

    /// Anyone may retry returning stranded tokens to the vault.
    function flush() external {
        _flush();
    }

    // ------------------------------------------------------------------ agent

    /// Pays `amount` of the budget token to an allowlisted payee from today's allowance.
    /// Over allowance it refuses without reverting and emits Short (rate-limited, see
    /// SHORT_REARM). The caller must read the return value.
    function pay(address payee, uint256 amount, bytes32 callId) external returns (bool) {
        require(msg.sender == agent, "agent");
        _sweep();
        if (frozen) {
            // A local press the coordinator hasn't acknowledged yet is re-announced (rate-limited),
            // so a lost StopPressed log can't leave the other chains running.
            if (lastPressAt > pressAckedAt && block.timestamp >= uint256(stopEchoAt) + SHORT_REARM) {
                stopEchoAt = uint64(block.timestamp);
                emit StopPressed(lastPressAt);
            }
            return _refuse(callId, R_FROZEN);
        }
        if (!payeeAllowed[payee]) return _refuse(callId, R_PAYEE);
        if (amount == 0 || amount > perCallCap) return _refuse(callId, R_CAP);

        uint64 d = today();
        Bucket storage b = buckets[d];
        uint256 unspent = b.allowance - b.spent;
        if (amount > unspent) {
            uint64 last = shortAt[d];
            if (last == 0 || block.timestamp >= last + SHORT_REARM) {
                shortAt[d] = uint64(block.timestamp);
                emit Short(d, amount - unspent, uint64(block.timestamp));
            }
            return _refuse(callId, R_SHORT);
        }
        b.spent += uint128(amount);
        uint256 left = unspent - amount;
        if (left < lowWater && !lowFired[d]) {
            lowFired[d] = true;
            emit LowWater(d, left, uint64(block.timestamp));
        }
        emit Paid(callId, payee, amount, d, epoch);
        token.safeTransfer(payee, amount);
        _flush();
        return true;
    }

    // ------------------------------------------------------------ coordinator

    function applyGrant(uint256 id, uint64 day, uint256 amount, uint64 e) external onlyBridge {
        _sweep();
        if (!_fresh(id)) return;
        seen[id] = true;
        if (e > epoch) _roll(e);

        uint64 t = today();
        uint64 d = _bucketDay(day);
        uint8 why;
        if (!_epochAccepts(e)) why = NA_STALE_EPOCH;
        else if (frozen) why = NA_FROZEN;
        else if (d < t || d > t + 1) why = NA_BAD_DAY;
        else if (!_pull(amount)) why = NA_UNFUNDED;

        if (why != 0) {
            grantVoidAt[id] = uint64(block.timestamp);
            shortAt[t] = 0;
            emit GrantNotApplied(id, why, uint64(block.timestamp));
            _flush();
            return;
        }
        _openDay(d);
        buckets[d].allowance += uint128(amount);
        grantApplied[id] = true;
        shortAt[d] = 0;
        lowFired[d] = false;
        emit GrantApplied(id, d, amount, uint64(block.timestamp));
        _flush();
    }

    /// Rule 3: shrinks only unspent allowance, and never below keepFloor. Records and reports
    /// exactly the allowance it gave up, which is what goes back to the vault.
    function applyReclaim(uint256 id, uint64 day, uint256 amount) public virtual onlyBridge {
        _sweep();
        if (!_fresh(id)) return;
        seen[id] = true;
        Bucket storage b = buckets[day];
        uint256 unspent = b.allowance - b.spent;
        uint256 back = unspent > keepFloor ? _min(amount, unspent - keepFloor) : 0;
        b.allowance -= uint128(back);
        reclaimRec[id] = ReclaimRec(day, uint64(block.timestamp), uint128(back));
        if (back > 0) _toVault(back);
        emit Reclaimed(id, day, back, uint64(block.timestamp));
        _flush();
    }

    /// Tombstones the grant first if it never arrived, so it can never apply afterwards.
    function applyCancel(uint256 id, uint256 grantId) external onlyBridge {
        _sweep();
        if (!_fresh(id)) return;
        seen[id] = true;
        if (grantApplied[grantId]) {
            emit CancelAck(id, grantId, true, uint64(block.timestamp));
            return;
        }
        if (!seen[grantId]) {
            seen[grantId] = true;
            grantVoidAt[grantId] = uint64(block.timestamp);
            shortAt[today()] = 0;
        }
        emit CancelAck(id, grantId, false, uint64(block.timestamp));
        _flush();
    }

    /// Freeze (frozen=true) or unfreeze for a newer epoch. Entering a newer epoch takes away
    /// all allowance of older epochs. A local press stays in force until the coordinator
    /// acknowledges having seen it. The freeze is pure state and is written before any token
    /// moves; returning the tokens to the vault is best-effort and can't undo it.
    function applyEpoch(uint64 e, bool frozen_, uint64 pressSeenAt) external onlyBridge {
        if (e < epoch) return;
        if (pressSeenAt > pressAckedAt) pressAckedAt = pressSeenAt;
        if (e > epoch) _roll(e);
        frozen = frozen_ || lastPressAt > pressAckedAt;
        emit EpochAck(e, frozen, uint64(block.timestamp));
        _sweep();
        _flush();
    }

    /// Re-reads stored facts so the coordinator can credit only what is still true once the
    /// original event is older than the confirmation wait.
    function verify(uint8 kind, uint256 key) external onlyBridge {
        uint64 nowTs = uint64(block.timestamp);
        if (kind == K_RECLAIM) {
            ReclaimRec memory r = reclaimRec[key];
            emit Verified(kind, key, r.at != 0, r.day, r.amount, 0, r.at, nowTs);
        } else if (kind == K_VOID) {
            uint64 at = grantVoidAt[key];
            emit Verified(kind, key, at != 0 && !grantApplied[key], 0, 0, 0, at, nowTs);
        } else if (kind == K_ROLL) {
            RollRec memory r = rollRec[uint64(key)];
            emit Verified(kind, key, r.at != 0, r.day, r.today, r.tomorrow, r.at, nowTs);
        } else if (kind == K_EPOCH) {
            emit Verified(kind, key, epoch >= key, 0, 0, 0, epochSince, nowTs);
        }
    }

    // ------------------------------------------------------------------ views

    function today() public view returns (uint64) {
        return uint64(block.timestamp / DAY);
    }

    function unspentOf(uint64 day) external view returns (uint256) {
        Bucket memory b = buckets[day];
        return b.allowance - b.spent;
    }

    /// Unspent allowance across every live bucket. Must never exceed the token balance.
    function liveUnspent() external view returns (uint256 sum) {
        for (uint256 i; i < _openDays.length; i++) {
            Bucket memory b = buckets[_openDays[i]];
            sum += b.allowance - b.spent;
        }
    }

    // ------------------------------------------------------------- internals

    /// First touch after local midnight: leftovers of past days stop being allowance and are owed
    /// back to the vault.
    function _sweep() internal {
        uint64 t = today();
        uint256 i;
        while (i < _openDays.length) {
            uint64 d = _openDays[i];
            if (d < t) {
                Bucket memory b = buckets[d];
                uint256 left = b.allowance - b.spent;
                delete buckets[d];
                _openDays[i] = _openDays[_openDays.length - 1];
                _openDays.pop();
                if (left > 0) {
                    _toVault(left);
                    emit Swept(d, left);
                }
            } else {
                i++;
            }
        }
    }

    function _roll(uint64 e) internal {
        uint64 t = today();
        uint256 r0 = _drain(t);
        uint256 r1 = _drain(t + 1);
        epoch = e;
        epochSince = uint64(block.timestamp);
        rollRec[e] = RollRec(t, uint64(block.timestamp), uint128(r0), uint128(r1));
        frozen = lastPressAt > pressAckedAt;
        shortAt[t] = 0;
        emit Rolled(e, t, r0, r1, uint64(block.timestamp));
    }

    function _drain(uint64 d) internal returns (uint256 left) {
        Bucket storage b = buckets[d];
        left = b.allowance - b.spent;
        if (left > 0) {
            b.allowance = b.spent;
            _toVault(left);
        }
    }

    function _openDay(uint64 d) internal {
        for (uint256 i; i < _openDays.length; i++) {
            if (_openDays[i] == d) return;
        }
        _openDays.push(d);
    }

    /// Accounting only: the tokens are owed to the vault from now on (see _flush).
    function _toVault(uint256 amount) internal {
        stranded += amount;
    }

    /// Best-effort return of stranded tokens to the vault. Never reverts.
    function _flush() internal {
        uint256 amount = stranded;
        if (amount == 0 || gasleft() < FLUSH_MIN_GAS) return;
        if (token.tryTransfer(address(vault), amount, gasleft() - FLUSH_KEEP)) stranded = 0;
    }

    function _refuse(bytes32 callId, uint8 reason) internal returns (bool) {
        emit Refused(callId, reason);
        return false;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    // Policy steps, kept separate so each rule can be broken on purpose in the mutation suite.

    /// Rule 4 (wallet side): each coordinator message id applies at most once.
    function _fresh(uint256 id) internal view virtual returns (bool) {
        return !seen[id];
    }

    /// Rule 6: a grant from an older epoch is refused on arrival.
    function _epochAccepts(uint64 e) internal view virtual returns (bool) {
        return e >= epoch;
    }

    /// Allowances are tied to the day number the coordinator granted them for.
    function _bucketDay(uint64 day) internal view virtual returns (uint64) {
        return day;
    }

    /// The pressing chain freezes in the same transaction.
    function _freezesOnPress() internal view virtual returns (bool) {
        return true;
    }

    /// A grant applies only if its tokens actually arrive from the vault: the wallet measures its
    /// own balance, so a token that delivers less than asked (fee-on-transfer) can't create
    /// unbacked allowance. Whatever did arrive of a short delivery is owed back to the vault.
    function _pull(uint256 amount) internal virtual returns (bool) {
        uint256 before = token.balanceOf(address(this));
        if (!vault.release(amount)) return false;
        uint256 got = token.balanceOf(address(this)) - before;
        if (got >= amount) return true;
        stranded += got;
        return false;
    }
}
