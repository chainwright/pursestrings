// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, console2} from "forge-std/Test.sol";
import {NetworkHandler} from "./harness/NetworkHandler.sol";
import {BudgetCoreHarness} from "./harness/BudgetCoreHarness.sol";
import {SpendWallet} from "../src/SpendWallet.sol";
import {IWalletEvents} from "../src/interfaces/IPursestrings.sol";

/// The race on camera (IDEA_V3 beat 4): agents on both chains pay in the same second while a
/// reclaim is in flight, and the day ends "Over $0.00". We never promise exactly $20 spent: what
/// is spent depends on who held what when the race ran; what is asserted is that nothing went over.
///
/// Production timing (TestnetConfig, refill ahead on). Cap $20. Chains 0 and 1 hold $10 each
/// (the pool is empty), and chain 2 asks for $3, so the coordinator sends reclaims to chains 0 and
/// 1. Then, with no time passing, both agents pay $1 at a time until refused, in four orders of
/// the in-flight reclaim:
///   0. the reclaims land after both bursts (nothing above the floor is left to give);
///   1. the reclaims land between the bursts (chain 0 first, then chain 1);
///   2. the reclaims land first, and their "reclaimed" events reach the coordinator only after
///      both bursts;
///   3. the reclaim to chain 1 is lost; the one to chain 0 lands after both agents have paid a
///      few dollars, and both then pay on.
/// After that every agent keeps paying $1 every minute for the rest of the day (the reclaims are
/// confirmed after the 30-min wait, chain 2 is served, the timeouts run), and the day's outflow,
/// counted by the token, must be at most the cap: Over $0.00.
contract RaceTest is Test {
    uint256 constant T0 = 1_800_000_000 - (1_800_000_000 % 1 days) + 12 hours; // noon
    bytes32 immutable RECLAIM = bytes32(SpendWallet.applyReclaim.selector);
    bytes32 immutable RECLAIMED = IWalletEvents.Reclaimed.selector;

    NetworkHandler h;
    BudgetCoreHarness core;

    /// The agent on chain c pays $1 up to n times, stopping at the first refusal.
    function _burst(uint8 c, uint256 n) internal returns (uint256 paid) {
        for (uint256 k; k < n && h.payExact(c, 1e6); k++) {
            paid += 1e6;
        }
    }

    function _race(uint256 order) internal returns (uint256 spent, uint256 inRace, uint256 over) {
        vm.warp(T0);
        h = new NetworkHandler(vm.envOr("MUTANT", uint256(0)), false, true, true);
        core = h.core();
        uint64 t = uint64(block.timestamp / 1 days);
        assertFalse(h.payExact(0, 10e6));
        assertFalse(h.payExact(1, 10e6));
        h.settleProduction(60);
        assertEq(core.poolOf(t), 0, "setup: pool empty");
        h.settleProduction(45 minutes); // past the want TTL: chains 0 and 1 are donors again
        assertFalse(h.payExact(2, 3e6));
        h.deliverFirst(false, IWalletEvents.Short.selector, 2);
        assertEq(h.count(true, RECLAIM, 0), 1, "setup: a reclaim in flight to chain 0");
        assertEq(h.count(true, RECLAIM, 1), 1, "setup: a reclaim in flight to chain 1");
        uint256 at = block.timestamp;

        if (order == 0) {
            inRace += _burst(0, 20) + _burst(1, 20);
            h.deliverFirst(true, RECLAIM, 0);
            h.deliverFirst(true, RECLAIM, 1);
        } else if (order == 1) {
            inRace += _burst(0, 20);
            h.deliverFirst(true, RECLAIM, 0);
            h.deliverFirst(true, RECLAIM, 1);
            inRace += _burst(1, 20);
        } else if (order == 2) {
            h.deliverFirst(true, RECLAIM, 0);
            h.deliverFirst(true, RECLAIM, 1);
            h.holdFirst(false, RECLAIMED, 0);
            h.holdFirst(false, RECLAIMED, 1);
            inRace += _burst(0, 20) + _burst(1, 20);
            h.releaseHeld();
        } else {
            h.dropFirst(true, RECLAIM, 1);
            inRace += _burst(0, 5) + _burst(1, 3);
            h.deliverFirst(true, RECLAIM, 0);
            inRace += _burst(1, 20) + _burst(0, 20);
        }
        assertEq(block.timestamp, at, "the race took more than one second");
        h.deliverAll();

        // the rest of the day: everyone keeps asking for $1 a minute
        while (block.timestamp / 1 days == t && block.timestamp < (uint256(t) + 1) * 1 days - 60) {
            for (uint8 c; c < 3; c++) {
                h.payExact(c, 1e6);
            }
            h.settleProduction(60);
        }
        spent = h.outflowOfDay(t);
        over = spent > h.gDayCap(t) ? spent - h.gDayCap(t) : 0;
        assertEq(over, 0, "Over > $0.00: paid out more than the cap");
        string memory why = h.safetyFailure();
        require(bytes(why).length == 0, why);
    }

    /// The same race while a reclaim sent AHEAD by refill ahead is in flight: chain 0 is busy
    /// ($4.50/h on $10, pool empty), chain 1 idle on $10; the moment the coordinator's reclaim to
    /// chain 1 is queued (not yet applied), both agents pay $1 at a time until refused, in the
    /// same second. Then the rest of the day as above.
    function test_race_whileARefillAheadReclaimIsInFlight() public {
        vm.warp(T0 - 6 hours); // 06:00
        h = new NetworkHandler(vm.envOr("MUTANT", uint256(0)), false, true, true);
        core = h.core();
        uint64 t = uint64(block.timestamp / 1 days);
        assertFalse(h.payExact(0, 10e6));
        assertFalse(h.payExact(1, 10e6));
        h.settleProduction(60);
        bool raced;
        uint256 inRace;
        for (uint256 m; m < 180 && !raced; m++) {
            if (m % 5 == 0) h.payExact(0, 375e3);
            uint256 before = block.timestamp / h.cronEvery();
            vm.warp(block.timestamp + 60);
            if (block.timestamp / h.cronEvery() != before) h.tick();
            for (uint256 g; g < 1000 && h.queueLength() > 0 && !raced; g++) {
                if (h.count(true, RECLAIM, 1) > 0) {
                    raced = true;
                    break;
                }
                h.deliverNext();
            }
            if (!raced && h.count(true, RECLAIM, 1) > 0) raced = true;
            if (raced) {
                assertGt(h.aheadReclaims(), 0, "setup: the reclaim in flight was sent ahead");
                uint256 at = block.timestamp;
                inRace = _burst(0, 20) + _burst(1, 20);
                assertEq(block.timestamp, at, "the race took more than one second");
            }
        }
        assertTrue(raced, "setup: no reclaim was sent ahead within 3 h");
        h.deliverAll();
        while (block.timestamp < (uint256(t) + 1) * 1 days - 60) {
            for (uint8 c; c < 3; c++) {
                h.payExact(c, 1e6);
            }
            h.settleProduction(60);
        }
        uint256 spent = h.outflowOfDay(t);
        uint256 over = spent > h.gDayCap(t) ? spent - h.gDayCap(t) : 0;
        console2.log("refill-ahead reclaim in flight");
        console2.log("  paid in the racing second / spent today / over ($, 6 dp)", inRace, spent, over);
        assertEq(over, 0, "Over > $0.00: paid out more than the cap");
        string memory why = h.safetyFailure();
        require(bytes(why).length == 0, why);
    }

    function test_race_bothChainsPayInTheSameSecondWhileAReclaimIsInFlight() public {
        string[4] memory names = [
            "reclaims land after both bursts",
            "reclaims land between the bursts",
            "reclaims land first, their events late",
            "one reclaim lost, the other mid-race"
        ];
        for (uint256 order; order < 4; order++) {
            uint256 snap = vm.snapshotState();
            (uint256 spent, uint256 inRace, uint256 over) = _race(order);
            console2.log(names[order]);
            console2.log("  paid in the racing second / spent today / over ($, 6 dp)", inRace, spent, over);
            vm.revertToState(snap);
        }
    }
}
