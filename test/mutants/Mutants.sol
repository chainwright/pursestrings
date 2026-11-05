// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {BudgetCoreHarness} from "../harness/BudgetCoreHarness.sol";
import {SpendWallet} from "../../src/SpendWallet.sol";
import {Vault} from "../../src/Vault.sol";
import {IERC20Min, K_RECLAIM, K_VOID, K_ROLL, K_EPOCH} from "../../src/interfaces/IPursestrings.sol";

/// Deliberately broken variants. Each breaks exactly one rule; the invariant suite must fail
/// on every one of them. Selected with MUTANT=<n> (0 = the real contracts).
///
///  1 wallet: no dedup of coordinator messages            (rule 4, wallet side)
///  2 core:   credit a reclaim when it is sent              (rule 2: before the event)
///  3 wallet: reclaim shrinks spent, not only unspent       (rule 3)
///  4 wallet: ignore the epoch on grants                    (rule 6)
///  5 wallet: ignore the day number on grants               (day-keyed allowances)
///  6 core:   refund a cancel when it is sent               (rule 5)
///  7 core:   credit returns at head (no wait, no re-read)  (rule 2, reorgs)
///  8 core:   no dedup of credits                           (rule 4, core side)
///  9 wallet: the pressing chain does not freeze locally    (STOP)
/// 10 core:   wait, then credit WITHOUT re-reading the fact (v3.1 "time-based wait" alone)
/// 11 wallet: credit allowance even if the vault transfer failed (failed-grant path)
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
    uint256 constant COUNT = 11;
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

    function _admit(uint8 kind, uint8 c, uint256 id, uint64 day, uint256 a0, uint256 a1, uint64 ts)
        internal
        override
    {
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
            Pending memory p = pending[k];
            credited[k] = true;
            _dropPending(k);
            _creditUnchecked(p.kind, p.chain, p.id, p.day, p.amount, p.amount2);
            return;
        }
        super._onMatured(k);
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

    function _reclaimable(Bucket storage b) internal view override returns (uint256) {
        if (m == MutantIds.WALLET_SHRINK_SPENT) return b.allowance;
        return super._reclaimable(b);
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
