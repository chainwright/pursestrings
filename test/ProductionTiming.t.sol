// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, console2} from "forge-std/Test.sol";
import {NetworkHandler} from "./harness/NetworkHandler.sol";
import {BudgetCoreHarness} from "./harness/BudgetCoreHarness.sol";
import {SpendWallet} from "../src/SpendWallet.sol";
import {IWalletEvents} from "../src/interfaces/IPursestrings.sol";

/// The production timing values (TestnetConfig: waits 30/30/16 min, grant timeout 10 min, re-read
/// 5 min, reclaim timeout = want TTL = wait + 10 min, heartbeat 40 min, origin events cap the
/// retry backoff at 40 min) on the network model with
/// Cron every 17.74 min by default (1000 blocks at the 1.064 s per block measured over 10,000
/// Lasna blocks on 06.11.2026;
/// NetworkHandler.settleProduction), swept where the Cron period matters. One test per relation the values exist
/// for, plus the time a lost STOP takes to reach every chain. MUTANT=<n> swaps in a broken
/// variant; the source-patch mutants W* change TestnetConfig itself.
contract ProductionTimingTest is Test {
    uint256 constant T0 = 1_800_000_000 - (1_800_000_000 % 1 days) + 6 hours; // 06:00

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
    /// coordinator and every chain within ceil(heartbeat / P) * P + 2 min, where P is the Cron
    /// period: the next heartbeat re-read of the pressing chain carries the press back at once.
    /// Swept over P = 17, 17.74 (the default: 1.064 s Lasna blocks, measured), 18.3, 18.5, 19 and
    /// 19.5 min, every
    /// pressing chain and 61 start offsets (1-min steps), with no agent activity anywhere (only Cron drives the
    /// core); and at the default P with the other agents paying $1 every 5 min. Measured at 1-min
    /// resolution. Logs the worst per period and what was spent meanwhile.
    function test_lostStopReachesEveryChainWithinOneBeatCycle() public {
        uint256[6] memory periods = [uint256(1020), 1064, 1100, 1110, 1140, 1170];
        uint256 worstSpent;
        for (uint256 k; k < periods.length; k++) {
            uint256 p = periods[k];
            // one beat cycle (the beat lands on the first Cron tick after 40 min) + 2 min delivery
            uint256 bound = ((40 minutes + p - 1) / p) * p + 2 minutes;
            uint256 worst;
            for (uint8 pc; pc < 3; pc++) {
                for (uint256 off; off < 61; off++) {
                    for (uint256 active; active < (p == 1064 ? 2 : 1); active++) {
                        uint256 snap = vm.snapshotState();
                        (uint256 secs, uint256 spent) = _lostPress(pc, off * 1 minutes, active == 1, p);
                        vm.revertToState(snap);
                        if (secs > worst) worst = secs;
                        if (spent > worstSpent) worstSpent = spent;
                        assertLe(secs, bound, "a lost STOP took longer than one heartbeat cycle to reach every chain");
                    }
                }
            }
            console2.log(
                "Cron period (s) / worst minutes until every chain froze / bound (min)", p, worst / 60, bound / 60
            );
        }
        console2.log("worst spent by the other agents meanwhile ($, 6 decimals)", worstSpent);
    }

    function _lostPress(uint8 pc, uint256 offset, bool agentsActive, uint256 period)
        internal
        returns (uint256 secs, uint256 spent)
    {
        _fresh();
        h.setCronEvery(period);
        for (uint8 c; c < 3; c++) {
            if (c != pc && agentsActive) assertFalse(h.payExact(c, 10e6));
        }
        h.settleProduction(30 minutes + offset);
        uint256 pressAt = block.timestamp;
        uint256 outAt = h.outflowOfDay(_today());
        h.ownerPressStop(pc);
        h.dropFirst(false, STOP_PRESSED, pc);
        for (uint256 m; m < 180; m++) {
            if (agentsActive && m % 5 == 0) {
                for (uint8 c; c < 3; c++) {
                    if (c != pc) h.payExact(c, 1e6);
                }
            }
            h.settleProduction(60);
            if (core.frozen() && h.wallets(0).frozen() && h.wallets(1).frozen() && h.wallets(2).frozen()) break;
        }
        secs = block.timestamp - pressAt;
        spent = h.outflowOfDay(_today()) - outAt;
        assertTrue(core.frozen(), "the coordinator never heard the STOP");
        _assertSafe();
    }

    // ----------------------------------------------------- timeout relations

    /// reclaimTimeout > the time a reclaim callback may take to land: a reclaim delivered 35 min
    /// late (destination congested) is still the open one, not closed and re-asked (W9: timeout
    /// = wait / 2 = 15 min). Timeouts are only checked on a react, so the 35-min hold always
    /// contains a Cron tick after 15 min (P <= 20 min) and stays under the real 40 min; run at
    /// three Cron phases so the check doesn't depend on one alignment.
    function test_lateReclaimIsNotClosedBeforeItsTimeout() public {
        for (uint256 phase; phase < 3; phase++) {
            uint256 snap = vm.snapshotState();
            _fresh();
            vm.warp(block.timestamp + phase * 6 minutes);
            assertFalse(h.payExact(0, 10e6));
            assertFalse(h.payExact(1, 10e6));
            h.settleProduction(41 minutes); // past the want TTL: chains 0 and 1 are donors again
            assertFalse(h.payExact(2, 8e6));
            h.deliverFirst(false, SHORT, 2);
            uint256 id = core.openReclaim(0, _today());
            assertGt(id, 0, "setup: reclaim to chain 0");
            h.holdFirst(true, RECLAIM, 0);
            h.settleProduction(35 minutes);
            assertEq(core.openReclaim(0, _today()), id, "a late reclaim was closed before its timeout");
            h.releaseHeld();
            h.settleProduction(60 minutes);
            _assertSafe();
            vm.revertToState(snap);
        }
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

    /// Two chains short at once with one donor: one reclaim, sized to everything both are owed,
    /// serves both within one confirmation cycle (wait 30 min + Cron + delivery), instead of one
    /// chain per 30-min cycle.
    function test_twoShortChainsServedInOneConfirmationCycle() public {
        _fresh();
        assertFalse(h.payExact(0, 10e6));
        assertFalse(h.payExact(1, 10e6));
        h.settleProduction(45 minutes); // pool empty; chain 0 is a donor again
        assertTrue(h.payExact(1, 10e6), "setup: chain 1 spends all");
        assertFalse(h.payExact(1, 3e6));
        assertFalse(h.payExact(2, 3e6));
        uint256 start = block.timestamp;
        bool paid1;
        bool paid2;
        for (uint256 r; r < 14 && !(paid1 && paid2); r++) {
            // <= 70 min: one cycle measures 60 min; the old per-chain sizing took 95 min
            h.settleProduction(300);
            if (!paid1) paid1 = h.payExact(1, 3e6);
            if (!paid2) paid2 = h.payExact(2, 3e6);
        }
        assertTrue(paid1 && paid2, "two short chains not both served within one confirmation cycle");
        console2.log("two short chains: minutes until both served", (block.timestamp - start) / 60);
        _assertSafe();
    }

    /// A shortfall larger than one donor's slack: chain 2 needs $8, chain 0 can give only $2 above
    /// its floor, chain 1 can give $8. Both are asked within the same confirmation cycle, so chain
    /// 2 is served within one cycle. (A reviewer's J5, "ask only the first eligible donor", does not
    /// break this: the first donor's own Reclaimed event triggers the next react, which asks the
    /// next donor a minute later. Measured identical, so J5 is not in the mutation gate.)
    function test_shortfallLargerThanOneDonorIsServedInOneCycle() public {
        _fresh();
        assertFalse(h.payExact(0, 10e6));
        assertFalse(h.payExact(1, 10e6));
        h.settleProduction(5 minutes);
        for (uint256 k; k < 6; k++) {
            assertTrue(h.payExact(0, 1e6), "setup: chain 0 spends $6 of $10");
        }
        h.settleProduction(45 minutes); // past the want TTLs: both are donors
        assertFalse(h.payExact(2, 8e6));
        uint256 start = block.timestamp;
        bool paid;
        for (uint256 r; r < 14 && !paid; r++) {
            h.settleProduction(300);
            paid = h.payExact(2, 8e6);
        }
        assertTrue(paid, "a shortfall larger than one donor's slack took more than one cycle");
        console2.log("shortfall from two donors: minutes until served", (block.timestamp - start) / 60);
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

    /// STOP reaches a chain that comes back from an 8 h callback outage within one capped retry:
    /// its agent's Shorts cap the epoch resend backoff at 4 x 10 min, so the resend after revival
    /// comes within 40 min plus a Cron period, not after up to 32 x 10 min (J2).
    function test_stopReachesAChainBackFromAnOutage() public {
        _fresh();
        assertFalse(h.payExact(2, 5e6));
        h.settleProduction(30 minutes);
        h.killChain(2, 8 hours);
        h.ownerPressStop(0);
        for (uint256 r; r < 96; r++) {
            h.payExact(2, 1e6); // the agent on chain 2 stays active
            h.settleProduction(300);
        }
        assertTrue(core.frozen(), "setup: STOP reached the coordinator");
        assertFalse(h.wallets(2).frozen(), "setup: chain 2 never heard the STOP while dead");
        h.killChain(2, 0); // callbacks land again
        uint256 back = block.timestamp;
        for (uint256 m; m < 120 && !h.wallets(2).frozen(); m++) {
            if (m % 5 == 0) h.payExact(2, 1e6);
            h.settleProduction(60);
        }
        uint256 mins = (block.timestamp - back) / 60;
        console2.log("STOP reached chain 2 after its 8 h outage, minutes after revival", mins);
        assertLe(mins, 60, "STOP took more than an hour to reach a revived chain");
        _assertSafe();
    }

    /// A front that stays dead while its agent keeps asking costs a bounded number of billed
    /// cancels: origin events (Shorts) only cap the backoff, they don't reset it (R4-3). Was 70
    /// per 12 h when every event reset it.
    function test_deadFrontWithActiveAgentCostsBoundedCancels() public {
        _fresh();
        h.killChain(2, 13 hours);
        h.payExact(2, 2e6);
        h.settleProduction(30 minutes);
        uint256 before = h.cancelsSent();
        for (uint256 r; r < 144; r++) {
            h.payExact(2, 2e6);
            h.settleProduction(300);
        }
        uint256 n = h.cancelsSent() - before;
        console2.log("cancels sent to a dead front in 12 h with its agent active", n);
        assertLe(n, 24, "a dead front with an active agent costs a cancel every few minutes");
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
