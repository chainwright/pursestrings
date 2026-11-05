// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {BudgetCoreHarness} from "../harness/BudgetCoreHarness.sol";
import {SpendWallet} from "../../src/SpendWallet.sol";
import {Vault} from "../../src/Vault.sol";
import {IERC20Min, IWalletInbox, K_RECLAIM, K_VOID, K_ROLL, K_EPOCH} from "../../src/interfaces/IPursestrings.sol";

/// Deliberately broken variants. Each breaks exactly one rule; the invariant suite must fail
/// on every one of them. Selected with MUTANT=<n> (0 = the real contracts).
///
///  1 wallet: no dedup of coordinator messages            (rule 4, wallet side)
///  2 core:   credit a reclaim when it is sent              (rule 2: before the event)
///  3 wallet: reclaim counts spent allowance as reclaimable (rule 3: takes what was spent)
///  4 wallet: ignore the epoch on grants                    (rule 6)
///  5 wallet: ignore the day number on grants               (day-keyed allowances)
///  6 core:   refund a cancel when it is sent               (rule 5)
///  7 core:   credit returns at head (no wait, no re-read)  (rule 2, reorgs)
///  8 core:   no dedup of credits                           (rule 4, core side)
///  9 wallet: the pressing chain does not freeze locally    (STOP)
/// 10 core:   wait, then credit WITHOUT re-reading the fact (v3.1 "time-based wait" alone)
/// 11 wallet: credit allowance even if the vault transfer failed (failed-grant path)
/// 12 core:   grant sent without debiting the reserve; debited when acknowledged (rule 1)
/// 13 core:   STOP never propagated: every epoch message says "not frozen"   (judge X1)
/// 14 core:   unstop lifts whatever epoch is frozen, ignoring the one it names (judge X2)
/// 15 core:   re-read credited without the age check on the fact            (judge X3)
/// 16 core:   re-read requested at once, without the core-side wait         (judge X11)
/// 17 core:   cap messages applied regardless of nonce order (stale re-applied) (judge X9)
library MutantIds {
    uint256 constant WALLET_NO_DEDUP = 1;
    uint256 constant CORE_CREDIT_RECLAIM_ON_SEND = 2;
    uint256 constant WALLET_SHRINK_SPENT = 3;
    uint256 constant WALLET_IGNORE_EPOCH = 4;
    uint256 constant WALLET_IGNORE_DAY = 5;
    uint256 constant CORE_REFUND_CANCEL_ON_SEND = 6;
    uint256 constant CORE_CREDIT_AT_HEAD = 7;
    uint256 constant CORE_NO_CREDIT_DEDUP = 8;
    uint256 constant WALLET_NO_LOCAL_FREEZE = 9;
    uint256 constant CORE_WAIT_WITHOUT_REREAD = 10;
    uint256 constant WALLET_CREDIT_UNFUNDED = 11;
    uint256 constant CORE_DEBIT_ON_ACK = 12;
    uint256 constant CORE_STOP_NOT_PROPAGATED = 13;
    uint256 constant CORE_UNSTOP_IGNORES_EPOCH = 14;
    uint256 constant CORE_NO_AGE_CHECK = 15;
    uint256 constant CORE_NO_CORE_WAIT = 16;
    uint256 constant CORE_CAP_IGNORES_NONCE = 17;
    uint256 constant COUNT = 17;
}

contract MutantCore is BudgetCoreHarness {
    uint256 public immutable m;

    constructor(Params memory p, address feeder_, uint256 m_) BudgetCoreHarness(p, feeder_) {
        m = m_;
    }

    function _sendReclaim(uint8 c, uint64 d, uint256 amount) internal override returns (uint256 id) {
        id = super._sendReclaim(c, d, amount);
        if (m == MutantIds.CORE_CREDIT_RECLAIM_ON_SEND) {
            credited[_key(K_RECLAIM, c, id)] = true;
            _credit(K_RECLAIM, c, d, amount);
        }
    }

    function _sendCancel(uint256 grantId) internal override {
        super._sendCancel(grantId);
        if (m == MutantIds.CORE_REFUND_CANCEL_ON_SEND) {
            Grant storage g = grants[grantId];
            bytes32 k = _key(K_VOID, g.chain, grantId);
            if (!credited[k]) {
                credited[k] = true;
                g.st = G_REFUNDED;
                _credit(K_VOID, g.chain, g.day, g.amount);
            }
        }
    }

    function _admit(uint8 kind, uint8 c, uint256 id, uint64 day, uint256 a0, uint256 a1, uint64 ts) internal override {
        if (m == MutantIds.CORE_CREDIT_AT_HEAD) {
            bytes32 k = _key(kind, c, id);
            if (credited[k]) return;
            credited[k] = true;
            _creditUnchecked(kind, c, id, day, a0, a1);
            return;
        }
        super._admit(kind, c, id, day, a0, a1, ts);
    }

    function _alreadyCredited(bytes32 k) internal view override returns (bool) {
        if (m == MutantIds.CORE_NO_CREDIT_DEDUP) return false;
        return super._alreadyCredited(k);
    }

    function _onMatured(bytes32 k) internal override {
        if (m == MutantIds.CORE_WAIT_WITHOUT_REREAD) {
            // Credit once the wait has passed, never re-reading. The entry stays in the list
            // (marked credited) because the core is scanning that list right now.
            if (credited[k]) return;
            Pending memory p = pending[k];
            credited[k] = true;
            _creditUnchecked(p.kind, p.chain, p.id, p.day, p.amount, p.amount2);
            return;
        }
        super._onMatured(k);
    }

    function _grant(uint8 c, uint64 d, uint256 amount) internal override {
        if (m != MutantIds.CORE_DEBIT_ON_ACK) return super._grant(c, d, amount);
        // the pool is NOT debited here
        DayBook storage b = _days[d];
        b.dry[c] = false;
        uint256 id = nextId++;
        grants[id] = Grant(c, G_SENT, 0, d, epoch, uint64(block.timestamp), uint128(amount));
        _liveGrants.push(id);
        emit GrantSent(id, c, d, amount, epoch);
        _send(c, abi.encodeCall(IWalletInbox.applyGrant, (id, d, amount, epoch)));
    }

    function _onGrantApplied(uint8 c, uint256 grantId) internal override {
        Grant storage g = grants[grantId];
        if (m == MutantIds.CORE_DEBIT_ON_ACK && g.st == G_SENT && g.chain == c) {
            DayBook storage b = _days[g.day];
            uint256 x = g.amount < b.pool ? g.amount : b.pool;
            b.pool -= uint120(x);
            b.held[c] += x;
        }
        super._onGrantApplied(c, grantId);
    }

    function _epochMessage(uint8 c) internal view override returns (bytes memory) {
        if (m == MutantIds.CORE_STOP_NOT_PROPAGATED) {
            return abi.encodeCall(IWalletInbox.applyEpoch, (epoch, false, pressSeenAt[c]));
        }
        return super._epochMessage(c);
    }

    function _unstopLifts(uint64 e) internal view override returns (bool) {
        if (m == MutantIds.CORE_UNSTOP_IGNORES_EPOCH) return true;
        return super._unstopLifts(e);
    }

    function _oldEnough(uint8 c, Echo memory v) internal view override returns (bool) {
        if (m == MutantIds.CORE_NO_AGE_CHECK) return true;
        return super._oldEnough(c, v);
    }

    function _waitPassed(bytes32 k, uint64 nowTs) internal view override returns (bool) {
        if (m == MutantIds.CORE_NO_CORE_WAIT) return true;
        return super._waitPassed(k, nowTs);
    }

    function _newerCap(uint64 nonce) internal view override returns (bool) {
        if (m == MutantIds.CORE_CAP_IGNORES_NONCE) return true;
        return super._newerCap(nonce);
    }

    function _creditUnchecked(uint8 kind, uint8 c, uint256 id, uint64 day, uint256 a0, uint256 a1) internal {
        if (kind == K_RECLAIM) {
            _closeReclaim(id);
            _credit(kind, c, day, a0);
        } else if (kind == K_VOID) {
            grants[id].st = G_REFUNDED;
            _credit(kind, c, day, a0);
        } else if (kind == K_ROLL) {
            _credit(kind, c, day, a0);
            _credit(kind, c, day + 1, a1);
        } else if (kind == K_EPOCH) {
            if (uint64(id) > epochAcked[c]) epochAcked[c] = uint64(id);
        }
    }
}

contract MutantWallet is SpendWallet {
    uint256 public immutable m;

    constructor(
        IERC20Min token_,
        Vault vault_,
        address bridge_,
        address owner_,
        address agent_,
        uint256 perCallCap_,
        uint256 keepFloor_,
        uint256 lowWater_,
        uint256 m_
    ) SpendWallet(token_, vault_, bridge_, owner_, agent_, perCallCap_, keepFloor_, lowWater_) {
        m = m_;
    }

    function _fresh(uint256 id) internal view override returns (bool) {
        if (m == MutantIds.WALLET_NO_DEDUP) return true;
        return super._fresh(id);
    }

    /// Rule 3 broken: the reclaim counts spent allowance as reclaimable. It gives up allowance
    /// it has already paid out (the excess comes out of `spent`), moves only what it really has,
    /// and reports the full amount, which the coordinator then credits.
    function applyReclaim(uint256 id, uint64 day, uint256 amount) public override {
        if (m != MutantIds.WALLET_SHRINK_SPENT) return super.applyReclaim(id, day, amount);
        require(msg.sender == bridge, "bridge");
        _sweep();
        if (!_fresh(id)) return;
        seen[id] = true;
        Bucket storage b = buckets[day];
        uint256 unspent = b.allowance - b.spent;
        uint256 z = b.allowance > keepFloor ? _min(amount, b.allowance - keepFloor) : 0;
        uint256 moved = z < unspent ? z : unspent;
        b.allowance -= uint128(z);
        b.spent -= uint128(z - moved);
        reclaimRec[id] = ReclaimRec(day, uint64(block.timestamp), uint128(z));
        if (moved > 0) _toVault(moved);
        emit Reclaimed(id, day, z, uint64(block.timestamp));
    }

    function _epochAccepts(uint64 e) internal view override returns (bool) {
        if (m == MutantIds.WALLET_IGNORE_EPOCH) return true;
        return super._epochAccepts(e);
    }

    function _bucketDay(uint64 day) internal view override returns (uint64) {
        if (m == MutantIds.WALLET_IGNORE_DAY) return today();
        return super._bucketDay(day);
    }

    function _freezesOnPress() internal view override returns (bool) {
        if (m == MutantIds.WALLET_NO_LOCAL_FREEZE) return false;
        return super._freezesOnPress();
    }

    function _pull(uint256 amount) internal override returns (bool) {
        if (m == MutantIds.WALLET_CREDIT_UNFUNDED) {
            vault.release(amount);
            return true;
        }
        return super._pull(amount);
    }
}
