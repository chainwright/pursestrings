// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, console2} from "forge-std/Test.sol";
import {NetworkHandler} from "./harness/NetworkHandler.sol";
import {BudgetCoreHarness} from "./harness/BudgetCoreHarness.sol";
import {SpendWallet} from "../src/SpendWallet.sol";
import {IWalletEvents} from "../src/interfaces/IPursestrings.sol";

/// The production timing values (TestnetConfig: waits 30/30/16 min, grant timeout 10 min, re-read
/// 5 min, reclaim timeout = want TTL = wait + 10 min, heartbeat 40 min) on the network model with
/// Cron every 17 min (NetworkHandler.settleProduction). One test per relation the values exist
/// for, plus the time a lost STOP takes to reach every chain. MUTANT=<n> swaps in a broken
/// variant; the source-patch mutants W* change TestnetConfig itself.
contract ProductionTimingTest is Test {
    uint256 constant T0 = 1_800_000_000 - (1_800_000_000 % 1 days) + 6 hours; // 06:00
    uint256 constant LOST_STOP_BOUND = 60 minutes; // heartbeat 40 min + one Cron period 17 min + delivery

    NetworkHandler h;
    BudgetCoreHarness core;
    bytes32 immutable GRANT = bytes32(SpendWallet.applyGrant.selector);
    bytes32 immutable RECLAIM = bytes32(SpendWallet.applyReclaim.selector);
    bytes32 immutable SHORT = IWalletEvents.Short.selector;
    bytes32 immutable STOP_PRESSED = IWalletEvents.StopPressed.selector;

    function _fresh() internal {
        vm.warp(T0);
        h = new NetworkHandler(vm.envOr("MUTANT", uint256(0)), false, true);
        core = h.core();
    }

    function _today() internal view returns (uint64) {
        return uint64(block.timestamp / 1 days);
    }

    function _assertSafe() internal view {
        string memory why = h.safetyFailure();
        require(bytes(why).length == 0, why);
    }

    // ------------------------------------------------------------ lost STOP

    /// A STOP press whose log is lost, with the pressing chain's agent idle, reaches the
    /// coordinator and every chain within LOST_STOP_BOUND, for every pressing chain and six start
    /// offsets, with the other agents paying $1 every 5 min, and with no agent activity at all
    /// (only Cron drives the core). Logs the worst time and what was spent meanwhile.
    function test_lostStopReachesEveryChainWithinAnHour() public {
        uint256 worstMin;
        uint256 worstSpent;
        for (uint8 pc; pc < 3; pc++) {
            for (uint256 off; off < 6; off++) {
                for (uint256 active; active < 2; active++) {
                    uint256 snap = vm.snapshotState();
                    (uint256 mins, uint256 spent) = _lostPress(pc, off * 10 minutes, active == 1);
                    vm.revertToState(snap);
                    if (mins > worstMin) worstMin = mins;
                    if (spent > worstSpent) worstSpent = spent;
                    assertLe(mins * 60, LOST_STOP_BOUND, "a lost STOP took longer than an hour to reach every chain");
                }
            }
        }
        console2.log("lost STOP, pressing agent idle: worst minutes until every chain froze", worstMin);
        console2.log("worst spent by the other agents meanwhile ($, 6 decimals)", worstSpent);
    }

    function _lostPress(uint8 pc, uint256 offset, bool agentsActive) internal returns (uint256 mins, uint256 spent) {
        _fresh();
        for (uint8 c; c < 3; c++) {
            if (c != pc) assertFalse(h.payExact(c, 10e6));
        }
        h.settleProduction(30 minutes + offset);
        uint256 pressAt = block.timestamp;
        uint256 outAt = h.outflowOfDay(_today());
        h.ownerPressStop(pc);
        h.dropFirst(false, STOP_PRESSED, pc);
        for (uint256 r; r < 36; r++) {
            if (agentsActive) {
                for (uint8 c; c < 3; c++) {
                    if (c != pc) h.payExact(c, 1e6);
                }
            }
            h.settleProduction(300);
            if (core.frozen() && h.wallets(0).frozen() && h.wallets(1).frozen() && h.wallets(2).frozen()) break;
        }
        mins = (block.timestamp - pressAt) / 60;
        spent = h.outflowOfDay(_today()) - outAt;
        assertTrue(core.frozen(), "the coordinator never heard the STOP");
        _assertSafe();
    }

    // ----------------------------------------------------- timeout relations

    /// reclaimTimeout > the time a reclaim callback may take to land: a reclaim delivered 30 min
    /// late (destination congested) is still the open one, not closed and re-asked (W9).
    function test_lateReclaimIsNotClosedBeforeItsTimeout() public {
        _fresh();
        assertFalse(h.payExact(0, 10e6));
        assertFalse(h.payExact(1, 10e6));
        h.settleProduction(41 minutes); // past the want TTL: chains 0 and 1 are donors again
        assertFalse(h.payExact(2, 8e6));
        h.deliverFirst(false, SHORT, 2);
        uint256 id = core.openReclaim(0, _today());
        assertGt(id, 0, "setup: reclaim to chain 0");
        h.holdFirst(true, RECLAIM, 0);
        h.settleProduction(30 minutes);
        assertEq(core.openReclaim(0, _today()), id, "a late reclaim was closed before its timeout");
        h.releaseHeld();
        h.settleProduction(60 minutes);
        _assertSafe();
    }

    /// wantTtl: a chain that asked stays no donor for its want TTL. Chain 0 asks again; 15 min
    /// later chain 2 is short; chain 0 must not be reclaimed from (W10).
    function test_askingChainIsNoDonorDuringItsWantTtl() public {
        _fresh();
        assertFalse(h.payExact(0, 10e6));
        assertFalse(h.payExact(1, 10e6));
        h.settleProduction(45 minutes);
        assertTrue(h.payExact(0, 6e6), "setup: chain 0 spends");
        assertFalse(h.payExact(0, 6e6), "setup: chain 0 asks again (short by $2, $4 still unspent)");
        h.settleProduction(15 minutes);
        assertFalse(h.payExact(2, 3e6));
        h.deliverFirst(false, SHORT, 2);
        assertEq(h.count(true, RECLAIM, 0), 0, "a chain that asked 15 min ago was reclaimed from");
        assertEq(core.openReclaim(0, _today()), 0, "a chain that asked 15 min ago was reclaimed from");
        h.settleProduction(60 minutes);
        _assertSafe();
    }

    /// grantTimeout: a grant whose callback is lost is cancelled after ~10 min (plus a Cron
    /// period), the chain's in-flight slot frees, and its retrying agent is served (W12).
    function test_lostGrantIsCancelledAndTheChainServedAgain() public {
        _fresh();
        assertFalse(h.payExact(0, 5e6));
        h.deliverFirst(false, SHORT, 0);
        h.dropFirst(true, GRANT, 0);
        uint256 start = block.timestamp;
        bool paid;
        for (uint256 r; r < 12 && !paid; r++) {
            h.settleProduction(300);
            paid = h.payExact(0, 5e6);
        }
        assertTrue(paid, "chain 0 not served within an hour after its grant was lost");
        console2.log("lost grant: minutes until the chain was served again", (block.timestamp - start) / 60);
        _assertSafe();
    }

    /// Backoff reset: chain 2's callbacks are lost for 4 h while its agent keeps asking (its
    /// cancels back off up to 32 x 10 min). Once callbacks land again, any event from the chain
    /// resets the backoff, and it is served within 30 min, not after the next backed-off cancel.
    function test_revivedChainIsServedPromptly() public {
        _fresh();
        h.killChain(2, 4 hours);
        for (uint256 r; r < 48; r++) {
            h.payExact(2, 2e6);
            h.settleProduction(300);
        }
        h.killChain(2, 0); // callbacks land again
        uint256 back = block.timestamp;
        bool paid;
        for (uint256 r; r < 6 && !paid; r++) {
            paid = h.payExact(2, 2e6);
            h.settleProduction(300);
        }
        assertTrue(paid, "a revived chain waited more than 30 min for its backed-off retry");
        console2.log("revived chain: minutes until served", (block.timestamp - back) / 60);
        _assertSafe();
    }
}
