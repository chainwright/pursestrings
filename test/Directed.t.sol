// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, Vm} from "forge-std/Test.sol";
import {NetworkHandler} from "./harness/NetworkHandler.sol";
import {BudgetCoreHarness} from "./harness/BudgetCoreHarness.sol";
import {SpendWallet} from "../src/SpendWallet.sol";
import {IWalletEvents, IConsoleEvents} from "../src/interfaces/IPursestrings.sol";

/// One deterministic scenario per rule, on the same network model and ghosts as the fuzz.
/// Each one sets up the exact message timing its rule exists for, then lets greedy agents spend
/// and checks every safety rule (NetworkHandler.safetyFailure: (a) first, so a failure message
/// starting with "(a) paid out" is a real overspend). MUTANT=<n> swaps in a broken variant, and
/// script/mutants.sh expects each mutant to fail at least its own scenario here.
contract DirectedTest is Test {
    uint8 constant HOME = 255; // the home-chain console
    bytes32 immutable GRANT = bytes32(SpendWallet.applyGrant.selector);
    bytes32 immutable RECLAIM = bytes32(SpendWallet.applyReclaim.selector);
    bytes32 immutable CANCEL = bytes32(SpendWallet.applyCancel.selector);
    bytes32 immutable VERIFY = bytes32(SpendWallet.verify.selector);
    bytes32 immutable EPOCH = bytes32(SpendWallet.applyEpoch.selector);
    bytes32 immutable RECLAIMED = IWalletEvents.Reclaimed.selector;
    bytes32 immutable STOP_PRESSED = IWalletEvents.StopPressed.selector;
    bytes32 immutable UNSTOP = IConsoleEvents.Unstop.selector;
    bytes32 immutable CAPSET = IConsoleEvents.CapSet.selector;
    bytes32 immutable SHORT = IWalletEvents.Short.selector;

    uint256 constant T0 = 1_800_000_000 - (1_800_000_000 % 1 days) + 6 hours; // 06:00

    NetworkHandler h;
    BudgetCoreHarness core;

    function setUp() public {
        vm.warp(T0);
        h = new NetworkHandler(vm.envOr("MUTANT", uint256(0)), false, false, 1);
        core = h.core();
    }

    // ------------------------------------------------------------- helpers

    function _w(uint8 c) internal view returns (SpendWallet) {
        return h.wallets(c);
    }

    function _today() internal view returns (uint64) {
        return uint64(block.timestamp / 1 days);
    }

    /// The agent on chain c asks for `amt` with no allowance: refused, emits Short.
    function _short(uint8 c, uint256 amt) internal {
        assertFalse(h.payExact(c, amt), "expected a refusal");
    }

    /// The agent on chain c is refused, and only its Short reaches the core: the core's answer
    /// (a grant or reclaims) is left queued for the scenario to delay, drop or reorder.
    function _shortDelivered(uint8 c, uint256 amt) internal {
        _short(c, amt);
        h.deliverFirst(false, SHORT, c);
    }

    /// Chains 0 and 1 each get and apply a $10 grant; the day's pool is then empty.
    function _fundTwo() internal {
        _short(0, 10e6);
        _short(1, 10e6);
        h.settleFor(2);
        assertEq(_w(0).unspentOf(_today()), 10e6, "setup: chain 0 funded");
        assertEq(_w(1).unspentOf(_today()), 10e6, "setup: chain 1 funded");
        assertEq(core.poolOf(_today()), 0, "setup: pool empty");
    }

    /// Past the want TTL, so chains 0 and 1 are donors again; chain 2 asks for $8, which the core
    /// can only serve by reclaiming. Leaves the two reclaim callbacks queued.
    function _reclaimsForChain2() internal {
        vm.warp(block.timestamp + 700);
        h.tick();
        _shortDelivered(2, 8e6);
        assertEq(h.count(true, RECLAIM, 0), 1, "setup: reclaim to chain 0");
        assertEq(h.count(true, RECLAIM, 1), 1, "setup: reclaim to chain 1");
    }

    /// Greedy agents: every chain pays $1 at a time until refused, the network settles, repeat.
    function _spendAll() internal {
        for (uint256 r; r < 10; r++) {
            for (uint8 c; c < 3; c++) {
                for (uint256 k; k < 30 && h.payExact(c, 1e6); k++) {}
            }
            h.settleFor(3);
        }
    }

    function _assertSafe() internal view {
        string memory why = h.safetyFailure();
        require(bytes(why).length == 0, why);
    }

    // ------------------------------------------------------ one per rule

    /// Rule 1: the reserve is debited before a grant is sent. Three chains ask at once; only the
    /// $20 in the pool may go out.
    function test_rule1_reserveDebitedBeforeGrantIsSent() public {
        _short(0, 10e6);
        _short(1, 10e6);
        _short(2, 10e6);
        h.settleFor(2);
        _spendAll();
        _assertSafe();
    }

    /// Rule 2: a reclaim is credited only after the donor's event. Both reclaim callbacks are lost.
    function test_rule2_reclaimNotCreditedWhenSent() public {
        _fundTwo();
        _reclaimsForChain2();
        h.dropAll(true, RECLAIM, 0);
        h.dropAll(true, RECLAIM, 1);
        _spendAll();
        _assertSafe();
    }

    /// Rule 2, reorgs: both reclaims run on an instantly orphaned block, so their "reclaimed"
    /// events reach the core but the reclaims never happened.
    function test_rule2_orphanedReclaimNotCredited() public {
        _fundTwo();
        _reclaimsForChain2();
        h.reorgFirst(RECLAIM, 0, 0, true);
        h.reorgFirst(RECLAIM, 1, 0, true);
        _spendAll();
        _assertSafe();
    }

    /// Rule 2, confirmation: a reclaim that lived on a branch, was re-included on a second branch
    /// just before the core's re-read, and was served that re-read from the second branch, which
    /// is then abandoned. The fact the re-read saw is younger than the wait: no credit.
    function test_rule2_reReadOfAYoungFactIsNotCredited() public {
        _fundTwo();
        _reclaimsForChain2();
        h.dropFirst(true, RECLAIM, 1);
        h.reorgFirst(RECLAIM, 0, 30, false); // branch 1, the message stays queued
        h.deliverFirst(false, RECLAIMED, 0); // the core admits the return as pending
        vm.warp(block.timestamp + 61);
        h.tick(); // the wait has passed: the core asks chain 0 to re-read
        assertEq(h.count(true, VERIFY, 0), 1, "setup: re-read requested");
        h.reorgFirst(RECLAIM, 0, 30, true); // branch 2, then the message is lost for good
        h.deliverOnBranch(0); // the re-read is served from branch 2
        h.deliverAll();
        _spendAll();
        _assertSafe();
    }

    /// Rule 2 on the slowest chain: each chain's wait is its own. Chain 2 waits 180 s (chain 0
    /// only 60). A reclaim on chain 2 is re-included on a branch that lives 120 s (shallower than
    /// chain 2's wait, deeper than chain 0's) and the re-read 61 s later is served from it. That
    /// fact is 61 s old: old enough by chain 0's wait, not by chain 2's. No credit.
    function test_rule2_slowChainUsesItsOwnWait() public {
        _short(1, 10e6);
        _short(2, 10e6);
        h.settleFor(2);
        vm.warp(block.timestamp + 700);
        h.tick();
        _shortDelivered(0, 8e6); // reclaims to chains 1 and 2
        h.dropFirst(true, RECLAIM, 1);
        h.reorgFirst(RECLAIM, 2, 30, false); // branch 1, the message stays queued
        h.deliverFirst(false, RECLAIMED, 2); // the core admits the return as pending
        vm.warp(block.timestamp + 181);
        h.tick(); // chain 2's wait has passed: re-read requested
        assertEq(h.count(true, VERIFY, 2), 1, "setup: re-read requested");
        h.reorgFirst(RECLAIM, 2, 120, true); // branch 2: lives 120 s, then the reclaim is lost
        vm.warp(block.timestamp + 61);
        h.deliverOnBranch(2); // the re-read sees a 61-second-old fact
        h.deliverAll();
        _spendAll();
        _assertSafe();
    }

    /// The core asks for a re-read only after the confirmation wait has passed since the event.
    /// (Cost, not safety: the age check on the re-read alone keeps credits safe. An early re-read
    /// is a billed callback that can only come back "too young".)
    function test_rule2_noReReadBeforeTheWait() public {
        _fundTwo();
        _reclaimsForChain2();
        h.deliverFirst(true, RECLAIM, 0);
        h.deliverFirst(false, RECLAIMED, 0);
        assertEq(h.count(true, VERIFY, 0), 0, "(cost) re-read requested before the confirmation wait");
        vm.warp(block.timestamp + 61);
        h.tick();
        assertEq(h.count(true, VERIFY, 0), 1, "re-read requested once the wait has passed");
    }

    /// A reclaim whose return is pending never times out, even if confirming it takes longer
    /// than reclaimTimeout (here the re-read is delayed): the donor isn't asked again meanwhile.
    function test_reclaimWithPendingReturnDoesNotTimeOut() public {
        _fundTwo();
        _reclaimsForChain2();
        h.dropFirst(true, RECLAIM, 1);
        h.deliverFirst(true, RECLAIM, 0);
        h.deliverFirst(false, RECLAIMED, 0); // pending; donor 0 has answered
        uint256 id = core.openReclaim(0, _today());
        assertGt(id, 0, "setup: reclaim open");
        vm.warp(block.timestamp + core.chainParams(0).confirmWait + 1);
        h.tick();
        h.holdFirst(true, VERIFY, 0); // the re-read is slow
        vm.warp(block.timestamp + core.chainParams(0).reclaimTimeout + 1);
        h.tick();
        assertEq(core.openReclaim(0, _today()), id, "a reclaim with a pending return timed out");
        assertEq(h.count(true, RECLAIM, 0), 0, "donor 0 asked again while its return was pending");
        h.releaseHeld();
        h.settleFor(4);
        _assertSafe();
    }

    /// Rule 3: a reclaim shrinks only unspent allowance. Chain 0 has spent $6 of $10.
    function test_rule3_reclaimTakesOnlyUnspent() public {
        _fundTwo();
        for (uint256 k; k < 6; k++) {
            assertTrue(h.payExact(0, 1e6));
        }
        _reclaimsForChain2();
        h.settleFor(4);
        _spendAll();
        _assertSafe();
    }

    /// Rule 4, wallet side: a duplicated grant applies once.
    function test_rule4_duplicateGrantAppliesOnce() public {
        _shortDelivered(0, 10e6);
        _shortDelivered(1, 10e6);
        h.duplicateFirst(true, GRANT, 0);
        h.settleFor(2);
        _spendAll();
        _assertSafe();
    }

    /// Rule 4, core side: a "reclaimed" event replayed after it was credited is not credited again.
    function test_rule4_replayedReturnCreditedOnce() public {
        _fundTwo();
        _reclaimsForChain2();
        h.settleFor(4);
        h.replay(false, RECLAIMED, 0, 0);
        h.replay(false, RECLAIMED, 1, 0);
        _spendAll();
        _assertSafe();
    }

    /// Rule 5: a cancelled grant is refunded only once the wallet confirms it never applied it.
    /// The grant is late, the cancel is sent, and the grant then lands before the cancel.
    function test_rule5_cancelRefundedOnlyAfterConfirmedUnapplied() public {
        _shortDelivered(0, 10e6);
        h.holdFirst(true, GRANT, 0);
        _short(1, 10e6);
        h.deliverAll();
        vm.warp(block.timestamp + 310);
        h.tick(); // grant to chain 0 unacknowledged: cancel
        h.holdFirst(true, CANCEL, 0);
        _short(2, 10e6);
        h.deliverAll();
        h.releaseHeld(); // the late grant, then the cancel
        h.deliverAll();
        _spendAll();
        _assertSafe();
    }

    /// Rule 6: a grant held back across STOP and unstop arrives, unseen and uncancelled, at a
    /// wallet already in the newer epoch. It must not become spendable.
    function test_rule6_staleGrantAfterStopUnstop() public {
        _shortDelivered(0, 5e6);
        h.holdFirst(true, GRANT, 0); // epoch-0 grant, held
        h.ownerPressStop(1);
        h.deliverAll(); // epoch 1, frozen, reaches every chain
        h.ownerUnstop(core.epoch());
        h.deliverAll(); // epoch 2, running
        assertEq(_w(0).epoch(), core.epoch(), "setup: chain 0 in the new epoch");
        h.releaseHeld();
        h.deliverAll();
        _assertSafe();
    }

    /// Allowances are tied to the day they were granted for: tomorrow's pre-grants can't be
    /// spent today.
    function test_dayKeyedAllowance_pregrantNotSpendableToday() public {
        vm.warp(block.timestamp + 17 hours); // 23:00, inside the pre-grant window
        h.tick();
        h.settleFor(2);
        assertGt(core.heldOf(_today() + 1, 0), 0, "setup: tomorrow pre-granted");
        _spendAll();
        assertEq(_today(), uint64(T0 / 1 days), "setup: still the same day");
        _assertSafe();
    }

    /// STOP: the pressing chain freezes in the same transaction.
    function test_stop_pressingChainFreezesAtOnce() public {
        _fundTwo();
        h.ownerPressStop(0);
        assertFalse(h.payExact(0, 1e6), "paid on the pressing chain right after STOP");
        _assertSafe();
    }

    /// STOP from chain 1 reaches the other chains: after the network delivers, nothing is paid
    /// anywhere.
    function test_stop_reachesEveryChain() public {
        _fundTwo();
        h.ownerPressStop(1);
        h.healAndSettle();
        assertTrue(_w(0).frozen() && _w(2).frozen(), "STOP did not reach every chain");
        _assertSafe();
    }

    /// STOP whose log is lost on the way to the coordinator: the pressing wallet re-announces it
    /// when its agent is refused, and it still reaches every chain.
    function test_stop_lostPressIsReannounced() public {
        _fundTwo();
        h.ownerPressStop(1);
        h.dropFirst(false, STOP_PRESSED, 1);
        h.healAndSettle();
        assertTrue(core.frozen(), "coordinator never heard the STOP");
        _assertSafe();
    }

    /// A reviewer's R2-1 scenario: the press log is lost and the agent on the pressing chain stays
    /// idle; only the agents on chains 0 and 2 act, on a healthy network. The coordinator's
    /// heartbeat (a re-read, driven by Cron) reaches chain 1, which re-announces its press.
    function test_stop_lostPressIdleAgentOnPressingChain() public {
        _short(0, 10e6);
        _short(2, 10e6);
        h.settleFor(2);
        h.ownerPressStop(1);
        h.dropFirst(false, STOP_PRESSED, 1);
        uint256 outAtPress = h.outflowOfDay(_today());
        for (uint256 r; r < 40; r++) {
            h.deliverAll();
            vm.warp(block.timestamp + 300);
            h.tick();
            h.payExact(0, 5e5);
            h.payExact(2, 5e5);
        }
        assertTrue(core.frozen(), "the coordinator never heard the STOP");
        assertTrue(_w(0).frozen() && _w(2).frozen(), "STOP did not reach chains 0 and 2");
        assertFalse(h.payExact(0, 5e5), "paid on chain 0 after STOP");
        assertLe(h.outflowOfDay(_today()) - outAtPress, 20e6, "spent more than the cap after STOP");
        _assertSafe();
    }

    /// Anyone can re-announce an unacknowledged press (e.g. the owner's UI), at most every 5 min,
    /// and only until the coordinator acknowledges it.
    function test_stop_anyoneCanReannounceAnUnacknowledgedPress() public {
        h.ownerPressStop(1);
        h.dropFirst(false, STOP_PRESSED, 1);
        vm.recordLogs();
        vm.prank(address(0x5714));
        _w(1).reannounce(); // right after the press: rate-limited
        assertEq(vm.getRecordedLogs().length, 0, "re-announced inside the rate limit");
        vm.warp(block.timestamp + 301);
        vm.prank(address(0x5714));
        _w(1).reannounce();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "not re-announced");
        assertEq(logs[0].topics[0], STOP_PRESSED);
        assertEq(abi.decode(logs[0].data, (uint64)), _w(1).lastPressAt(), "same press mark");
    }

    /// An unstop names the epoch it lifts. Two unstop clicks; the second is delayed past a new
    /// STOP pressed after both clicks. It must not lift that STOP.
    function test_stop_delayedUnstopDoesNotLiftALaterStop() public {
        h.ownerPressStop(0);
        h.deliverAll();
        h.ownerUnstop(core.epoch());
        h.ownerUnstop(core.epoch()); // impatient second click, same epoch
        h.deliverFirst(false, UNSTOP, HOME);
        h.holdFirst(false, UNSTOP, HOME);
        h.deliverAll();
        assertFalse(core.frozen(), "setup: first unstop lifted the STOP");
        h.ownerPressStop(2); // pressed after both unstop clicks
        h.deliverAll();
        h.releaseHeld();
        h.deliverAll();
        h.healAndSettle();
        _assertSafe();
    }

    /// A STOP pressed after the owner clicked unstop, whose log overtakes that unstop, is not
    /// lifted by it (every new press opens a new frozen epoch).
    function test_stop_pressOvertakingAnEarlierUnstopStays() public {
        h.ownerPressStop(0);
        h.deliverAll();
        h.ownerUnstop(core.epoch());
        h.holdFirst(false, UNSTOP, HOME);
        h.ownerPressStop(1);
        h.deliverAll(); // the new press arrives first
        h.releaseHeld();
        h.deliverAll();
        h.healAndSettle();
        _assertSafe();
    }

    /// A wallet ignores an epoch message older than its own epoch: a delayed "unfrozen" from
    /// before a later STOP must not unfreeze it.
    function test_stop_staleUnfreezeMessageIsIgnored() public {
        h.ownerPressStop(0);
        h.deliverAll(); // epoch 1, frozen everywhere
        h.ownerUnstop(core.epoch());
        h.deliverFirst(false, UNSTOP, HOME); // epoch 2, unfrozen: messages to every chain queued
        h.holdFirst(true, EPOCH, 0); // chain 0's "epoch 2, unfrozen" is delayed
        h.deliverAll();
        h.ownerPressStop(1);
        h.deliverAll(); // epoch 3, frozen, reaches chain 0
        assertTrue(_w(0).frozen(), "setup: chain 0 frozen in epoch 3");
        h.releaseHeld(); // the stale unfreeze arrives
        h.deliverAll();
        assertTrue(_w(0).frozen(), "a stale epoch message unfroze the wallet");
        h.healAndSettle();
        _assertSafe();
    }

    /// An epoch acknowledgement from an orphaned block is not trusted: the coordinator re-reads
    /// it, finds the wallet still on the old epoch, and resends until the freeze really lands.
    function test_stop_orphanedEpochAckIsNotTrusted() public {
        _fundTwo();
        h.ownerPressStop(1);
        h.deliverFirst(false, STOP_PRESSED, 1); // epoch 1: freeze messages queued
        h.reorgFirst(EPOCH, 0, 0, true); // chain 0's freeze runs on an orphaned block, then is lost
        h.healAndSettle();
        assertTrue(_w(0).frozen(), "chain 0 never froze: an orphaned ack was trusted");
        _assertSafe();
    }

    /// A duplicated or replayed StopPressed log does not re-freeze after the owner's unstop.
    function test_stop_replayedPressDoesNotRefreeze() public {
        h.ownerPressStop(1);
        h.deliverAll();
        h.ownerUnstop(core.epoch());
        h.deliverAll();
        assertFalse(core.frozen(), "setup: unstopped");
        h.replay(false, STOP_PRESSED, 1, 0);
        h.deliverAll();
        assertFalse(core.frozen(), "a replayed press re-froze the budget");
    }

    /// (a)'s bound is the owner's cap: a decrease applies from the next day; a cap message the
    /// owner has since replaced, delivered again, changes nothing.
    function test_ownerCap_staleCapChangeIsIgnored() public {
        h.ownerSetCap(30e6);
        h.ownerSetCap(12e6);
        h.deliverAll();
        h.replay(false, CAPSET, HOME, 1); // the older message (cap 30), again
        h.deliverAll();
        vm.warp(block.timestamp + 1 days);
        h.tick(); // tomorrow opens
        _spendAll();
        assertLe(h.outflowOfDay(_today()), 12e6, "(a) paid out more than the owner's cap for the day");
        _assertSafe();
    }

    /// A reviewer's R2-2 scenario: every callback to chain 2 is lost (its front is in debt) while
    /// its agent keeps asking. Chain 2 absorbs at most one grant; healthy chain 0 is still served.
    function test_deadChainAbsorbsAtMostOneGrant() public {
        h.killChain(2, 1 days);
        for (uint256 r; r < 40; r++) {
            h.payExact(2, 1e6);
            h.deliverAll();
            vm.warp(block.timestamp + 301);
            h.tick();
            h.deliverAll();
        }
        uint64 t = _today();
        assertLe(core.heldOf(t, 2), 2e6, "dead chain 2 absorbed more than one grant");
        assertGe(core.poolOf(t), 18e6, "the pool drained into the dead chain");
        bool paid;
        for (uint256 r; r < 3 && !paid; r++) {
            paid = h.payExact(0, 1e6);
            h.settleFor(1);
        }
        assertTrue(paid, "healthy chain 0 starved by dead chain 2");
        _assertSafe();
    }

    /// A grant from a vault that can't cover it doesn't apply.
    function test_unfundedGrantDoesNotApply() public {
        h.ownerWithdrawVault(0);
        _short(0, 10e6);
        h.settleFor(2);
        _assertSafe();
    }

    /// The owner (or anyone) recovers yesterday's leftover while the coordinator is
    /// down, with no agent pay and no coordinator callback: flush() sweeps past days first, then
    /// returns the tokens to the vault. Nothing reaches the coordinator and nothing is spendable.
    function test_flushSweepsYesterdaysLeftoverWithoutPayOrCallback() public {
        _short(0, 10e6);
        h.settleFor(2);
        uint64 d0 = _today();
        assertTrue(h.payExact(0, 3e6), "setup: spend $3 of $10");
        h.deliverAll();
        assertEq(h.queueLength(), 0, "setup: nothing in flight");
        uint256 nextIdBefore = core.nextId();
        vm.warp(block.timestamp + 1 days); // the coordinator is paused: no tick, no react
        assertEq(_w(0).unspentOf(d0), 7e6, "setup: yesterday's $7 still a bucket");
        assertEq(h.tokens(0).balanceOf(address(_w(0))), 7e6, "setup: the $7 sits in the wallet");
        vm.recordLogs();
        vm.prank(address(0x5714)); // not the agent, not the bridge
        _w(0).flush();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint128 allowance,) = _w(0).buckets(d0);
        assertEq(allowance, 0, "yesterday's bucket was not swept");
        assertEq(_w(0).liveUnspent(), 0, "allowance left after the sweep");
        assertEq(_w(0).stranded(), 0, "the leftover is still owed to the vault");
        assertEq(h.tokens(0).balanceOf(address(_w(0))), 0, "the leftover is still in the wallet");
        assertEq(
            h.tokens(0).balanceOf(address(h.vaults(0))) + h.tokens(0).outflowTotal(address(_w(0))),
            100 * h.CAP(),
            "vault + paid != funded"
        );
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(_w(0))) continue;
            assertEq(logs[i].topics[0], IWalletEvents.Swept.selector, "flush emitted a coordinator event");
        }
        assertEq(core.nextId(), nextIdBefore, "the coordinator was involved");
        assertEq(h.queueLength(), 0, "a message was queued");
        assertFalse(h.payExact(0, 1e6), "the swept leftover is still spendable");
    }

    // ------------------------------------------- coordinator paused in debt

    /// Drop every origin log queued for the coordinator: while it is in debt it gets no react(),
    /// so (worst case) nothing emitted in the window is ever delivered. A paused coordinator also
    /// sends nothing, so no callback may be queued.
    function _dropEveryOriginLog() internal {
        while (true) {
            uint256 n = h.queueLength();
            if (n == 0) return;
            (bool toWallet, uint8 c, bytes32 tag) = h.queueAt(0);
            assertFalse(toWallet, "a paused coordinator sent a callback");
            h.dropAll(false, tag, c);
        }
    }

    /// The coordinator runs out of reserves and is paused for 48 h (no Cron, no react). Every
    /// origin event in that window is lost: chain 1's agent keeps paying (and, once dry, emitting
    /// Short and LowWater), and the owner presses STOP on chain 0, whose agent then stays idle.
    /// After `depositTo` the first react is a Cron tick. Checks:
    ///  - STOP reaches the coordinator and every chain on that one tick and the callbacks and
    ///    events it sets off, with no second tick (both heartbeats are overdue, and the pressing
    ///    wallet re-announces the press on its re-read);
    ///  - the leftovers of the day the pause began, stuck in the wallets while the coordinator was
    ///    down, are swept to the vaults by the epoch messages;
    ///  - nothing was paid beyond what each wallet held, nothing on the days the coordinator never
    ///    opened, and nothing after STOP; the books conserve on every open day; tokens conserve.
    /// Production timing (waits 30/30/16 min, heartbeat 40 min, Cron every 17.74 min).
    function test_debtPause48h_stopOnChain0_agentOnChain1() public {
        _debtPause48h(0);
    }

    /// The same with the press on chain 2. The first tick sends at most two heartbeats (chains 0
    /// and 1); chain 2's goes out on the next react, which is the answer to the first heartbeat a
    /// few seconds later, not the next Cron tick.
    function test_debtPause48h_stopOnChain2_agentOnChain1() public {
        _debtPause48h(2);
    }

    function _debtPause48h(uint8 pc) internal {
        h = new NetworkHandler(vm.envOr("MUTANT", uint256(0)), false, true, 1);
        core = h.core();
        uint64 d0 = _today();

        // Day d0, 06:00: $8 to chains 0 and 1, $4 to chain 2 (the pool is then empty); each spends
        // some of it.
        _short(0, 8e6);
        _short(1, 8e6);
        _short(2, 4e6);
        h.settleProduction(10 minutes);
        assertEq(core.poolOf(d0), 0, "setup: pool empty");
        assertTrue(h.payExact(0, 2e6) && h.payExact(1, 3e6) && h.payExact(2, 1e6), "setup: spends");
        h.settleProduction(30 minutes);
        uint256[3] memory left = [uint256(6e6), 5e6, 3e6];
        for (uint8 c; c < 3; c++) {
            assertEq(_w(c).unspentOf(d0), left[c], "setup: unspent before the pause");
        }
        assertEq(h.queueLength(), 0, "setup: nothing in flight when the pause begins");

        // The pause: 48 h in 5-min steps; no tick, every origin log lost.
        uint256 pauseAt = block.timestamp;
        uint256 paid1;
        for (uint256 s; s < 576; s++) {
            vm.warp(block.timestamp + 5 minutes);
            if (s == 24) {
                h.ownerPressStop(pc); // 2 h into the pause
                assertTrue(_w(pc).frozen(), "the pressing chain did not freeze at once");
            }
            // chain 1's agent pays $0.25 every hour: 18 times on day d0 (06:45-23:45, $4.50 of its
            // $5), refused from d0 + 1 on (its LowWater and Shorts are lost too)
            if (s % 12 == 0 && h.payExact(1, 25e4)) paid1 += 25e4;
            _dropEveryOriginLog();
        }
        assertEq(block.timestamp - pauseAt, 48 hours);
        uint64 t = _today();
        assertEq(t, d0 + 2, "setup: two days later");
        assertEq(paid1, 45e5, "chain 1 paid other than $4.50 of the $5 it held on day d0");
        // Chain 1's first (refused) pay on d0 + 1 swept its $0.50 leftover: no longer allowance,
        // owed to the vault. A refusal doesn't flush, so the tokens wait in `stranded` (anyone's
        // flush() or the next coordinator message returns them).
        (uint128 a1,) = _w(1).buckets(d0);
        assertEq(a1, 0, "chain 1's own pay on d0 + 1 did not sweep its $0.50 leftover");
        assertEq(_w(1).liveUnspent(), 0, "chain 1 still holds spendable allowance");
        assertEq(_w(1).stranded(), 5e5, "chain 1's swept leftover is not owed to the vault");
        assertFalse(core.frozen(), "setup: the coordinator never heard the STOP");
        assertFalse(_w(1).frozen(), "setup: chain 1 still running");
        assertFalse(core.isOpen(d0 + 1) || core.isOpen(t), "setup: no day opened during the pause");
        uint8 other = pc == 0 ? 2 : 0; // the idle chain that isn't pressing
        assertEq(_w(pc).unspentOf(d0), left[pc], "setup: the pressing chain's leftover is stuck");
        assertEq(_w(other).unspentOf(d0), left[other], "setup: the idle chain's leftover is stuck");

        // Resume: one Cron tick, then whatever it sets off is delivered, with no second tick.
        h.tick();
        h.deliverAll();
        assertTrue(core.frozen(), "STOP did not reach the coordinator within one react of the resume");
        for (uint8 c; c < 3; c++) {
            assertTrue(_w(c).frozen(), "STOP did not reach every chain within one react of the resume");
            assertEq(_w(c).epoch(), core.epoch(), "a wallet is not on the coordinator's epoch");
        }

        // Leftovers swept: no allowance left anywhere, every token back in its vault.
        for (uint8 c; c < 3; c++) {
            (uint128 allowance,) = _w(c).buckets(d0);
            assertEq(allowance, 0, "a past day's leftover is still a bucket");
            assertEq(_w(c).liveUnspent(), 0, "allowance left after STOP");
            assertEq(_w(c).stranded(), 0, "a leftover is still owed to the vault");
            assertEq(h.tokens(c).balanceOf(address(_w(c))), 0, "a leftover is still in the wallet");
            assertEq(
                h.tokens(c).balanceOf(address(h.vaults(c))) + h.tokens(c).outflowTotal(address(_w(c))),
                100 * h.CAP(),
                "tokens do not conserve: vault + paid != funded"
            );
        }

        // No overspend: nothing on the unopened day, nothing today, nothing after STOP.
        assertFalse(h.payExact(1, 1e6), "chain 1 paid after STOP");
        assertEq(h.outflowOfDay(d0), 2e6 + 3e6 + 1e6 + paid1, "day d0 outflow");
        assertEq(h.outflowOfDay(d0 + 1), 0, "paid on a day the coordinator never opened");
        assertEq(h.outflowOfDay(t), 0, "paid on the resume day");

        // Books conserve on every open day; the unopened day stays empty.
        for (uint64 d = d0; d <= t; d++) {
            uint256 sum = core.poolOf(d);
            for (uint8 c; c < 3; c++) {
                sum += core.heldOf(d, c);
            }
            assertEq(sum, core.capOfDay(d), "books: pool + held != cap");
        }
        assertEq(core.capOfDay(d0 + 1), 0, "the unopened day has a cap");

        // The owner's STOP holds after the network runs on (invariant (s)), and every rule holds.
        h.settleProduction(2 hours);
        h.healAndSettle();
        _assertSafe();
    }
}

/// What the confirmation wait protects against, shown on purpose: a reorg DEEPER than the wait.
/// The re-read is served from a branch that has lived longer than the wait, so it passes the age
/// check, and the coordinator credits a reclaim that is then rolled back. The design is safe only
/// while the wait exceeds the chain's reorg window; this test documents that, it does not test a
/// rule. (Not part of the mutation run.)
contract AssumptionTest is Test {
    function test_outsideTheModel_reorgDeeperThanTheWaitOvercredits() public {
        vm.warp(1_800_000_000 - (1_800_000_000 % 1 days) + 6 hours);
        NetworkHandler h = new NetworkHandler(0, false, false, 1);
        bytes32 reclaim = bytes32(SpendWallet.applyReclaim.selector);
        uint64 t = uint64(block.timestamp / 1 days);
        assertFalse(h.payExact(0, 10e6));
        assertFalse(h.payExact(1, 10e6));
        h.settleFor(2);
        vm.warp(block.timestamp + 700);
        h.tick();
        assertFalse(h.payExact(2, 8e6));
        h.deliverFirst(false, IWalletEvents.Short.selector, 2);
        h.dropFirst(true, reclaim, 1);
        h.reorgFirst(reclaim, 0, 120, true); // the branch lives 120 s; the wait is 60 s
        h.deliverAll(); // the core admits the reclaim as pending
        vm.warp(block.timestamp + 61);
        h.tick();
        h.deliverOnBranch(0); // re-read at 61 s on a branch that is still alive: "old enough"
        h.deliverAll();
        assertLt(h.core().heldOf(t, 0), h.wallets(0).unspentOf(t), "expected: a phantom credit");
    }
}
