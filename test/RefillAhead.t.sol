// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, console2} from "forge-std/Test.sol";
import {NetworkHandler} from "./harness/NetworkHandler.sol";
import {BudgetCoreHarness} from "./harness/BudgetCoreHarness.sol";
import {SpendWallet} from "../src/SpendWallet.sol";
import {IWalletEvents} from "../src/interfaces/IPursestrings.sol";

/// A simulated day of three agents paying per call, at production timing (waits 30/30/16 min,
/// heartbeat 40 min, Cron every 17.74 min, everything queued delivered each minute), run twice on
/// the same demand: refill ahead by burn rate off (the W2 coordinator) and on (W3). Reports the
/// share of payments that had to wait. A day of warm-up with the same profile (another seed) runs
/// first, so the measured day starts as a live system would: tomorrow's pre-grants made at 22:00,
/// and meters with yesterday's rates.
///
/// Demand (Poisson per minute, seeded), the story's day: a busy agent runs a night batch on chain 0
/// ("its share runs out at 3 a.m."), the others are light:
///   chain 0: 7 calls/h from 01:00 to 05:00 at $0.10 / 0.25 / 0.50 / 1 (weights 30/30/30/10,
///            mean $0.355), about $10; then 0.5 calls/h from 08:00 to 20:00 at the day prices;
///   chain 1: 0.75 calls/h from 09:00 to 18:00;
///   chain 2: 0.1 calls/h all day.
/// Day prices $0.10 / 0.25 / 0.50 / 1 / 2 (weights 30/30/20/13/7, mean $0.475).
/// About $17 a day against the $20 cap, so what is measured is waiting, not the cap.
/// The agent keeps its calls in order: a refused call is retried every minute, and the calls behind
/// it wait too. A call "had to wait" if it was not paid in the minute it arrived. In the model a
/// top-up lands within that minute's delivery, so a top-up wait shows as 1 minute (2 s live).
contract RefillAheadTest is Test {
    uint256 constant D0 = 1_800_000_000 - (1_800_000_000 % 1 days); // a midnight
    uint256 constant CAP_CALLS = 160;

    struct Stats {
        uint256 calls;
        uint256 waited;
        uint256 longWaits; // >= 20 min: the budget had to come from another chain
        uint256 unserved; // still waiting at the end of the day
        uint256 sumWait; // minutes, over the calls that waited
        uint256 maxWait;
        uint256 spent;
        uint256 grants;
        uint256 reclaims;
        uint256 reacts; // origin logs to the coordinator + Cron ticks
        uint256 callbacks;
    }

    struct Queue {
        uint64[CAP_CALLS] at;
        uint64[CAP_CALLS] amount;
        uint256 len;
        uint256 head;
    }

    function _price(uint256 r) internal pure returns (uint64) {
        r %= 100;
        if (r < 30) return 1e5;
        if (r < 60) return 25e4;
        if (r < 80) return 5e5;
        if (r < 93) return 1e6;
        return 2e6;
    }

    function _batchPrice(uint256 r) internal pure returns (uint64) {
        r %= 100;
        if (r < 30) return 1e5;
        if (r < 60) return 25e4;
        if (r < 90) return 5e5;
        return 1e6;
    }

    /// The call (amount, 0 = none) chain c's agent makes in minute m of a day, for a profile and a
    /// seed. Chance per minute in 1/10,000.
    function _arrival(uint256 profile, uint256 seed, uint8 c, uint256 m) internal pure returns (uint64) {
        uint256 r = uint256(keccak256(abi.encode(seed, c, m)));
        bool batch;
        uint256 per10k;
        if (c == 0) {
            if (profile == 1) {
                per10k = (m >= 7 * 60 && m < 23 * 60) ? 250 : 0; // steady: 1.5 per hour all day
            } else if (profile == 2 && m >= 60 && m < 300) {
                (batch, per10k) = (true, 1167); // night batch: 7 per hour, 01:00-05:00
            } else if (profile == 3 && m >= 60 && m < 150) {
                (batch, per10k) = (true, 3333); // burst: 20 per hour, 01:00-02:30
            } else {
                per10k = (m >= 8 * 60 && m < 20 * 60) ? 83 : 0; // 0.5 per hour by day
            }
        } else if (c == 1) {
            per10k = (m >= 9 * 60 && m < 18 * 60) ? 125 : 0; // 0.75 per hour
        } else {
            per10k = profile == 1 ? 42 : 17; // 0.25 / 0.1 per hour
        }
        if (r % 10_000 >= per10k) return 0;
        return batch ? _batchPrice(r >> 32) : _price(r >> 32);
    }

    /// SIM_DEBUG=true: the state at every refusal of the measured day.
    function _debug(NetworkHandler h, uint8 c, uint256 m, uint256 amt) internal view {
        if (!vm.envOr("SIM_DEBUG", false)) return;
        uint64 day = uint64(block.timestamp / 1 days);
        uint256 u = h.wallets(c).unspentOf(day);
        if (u >= amt) return;
        BudgetCoreHarness k = h.core();
        console2.log("refusal: chain, minute, amount", c, m, amt);
        console2.log("   unspent, pool, held", u, k.poolOf(day), k.heldOf(day, c));
        console2.log("   held0/1/2", k.heldOf(day, 0), k.heldOf(day, 1), k.heldOf(day, 2));
        console2.log("   unspent0/1/2", h.wallets(0).unspentOf(day), h.wallets(1).unspentOf(day), h.wallets(2).unspentOf(day));
    }

    /// One day of agents: arrivals, in-order retries every minute, the network running between.
    function _runDay(NetworkHandler h, uint256 profile, uint256 seed, bool measure) internal returns (Stats memory st) {
        Queue[3] memory q;
        uint256 g0 = h.grantsSent();
        uint256 r0 = h.reclaimsSent();
        uint256 a0 = h.toCore() + h.ticks();
        uint256 b0 = h.toWallet();
        uint64 day = uint64(block.timestamp / 1 days);
        for (uint256 m; m < 1440; m++) {
            for (uint8 c; c < 3; c++) {
                uint64 amt = _arrival(profile, seed, c, m);
                if (amt != 0 && q[c].len < CAP_CALLS) {
                    q[c].at[q[c].len] = uint64(m);
                    q[c].amount[q[c].len] = amt;
                    q[c].len++;
                }
                if (measure && q[c].head < q[c].len) _debug(h, c, m, q[c].amount[q[c].head]);
                while (q[c].head < q[c].len && h.payExact(c, q[c].amount[q[c].head])) {
                    uint256 w = m - q[c].at[q[c].head];
                    st.calls++;
                    st.spent += q[c].amount[q[c].head];
                    if (w > 0) {
                        st.waited++;
                        st.sumWait += w;
                        if (w >= 20) st.longWaits++;
                        if (w > st.maxWait) st.maxWait = w;
                    }
                    q[c].head++;
                }
            }
            h.settleProduction(60);
        }
        for (uint8 c; c < 3; c++) {
            st.unserved += q[c].len - q[c].head;
        }
        st.grants = h.grantsSent() - g0;
        st.reclaims = h.reclaimsSent() - r0;
        st.reacts = h.toCore() + h.ticks() - a0;
        st.callbacks = h.toWallet() - b0;
        if (measure) {
            assertLe(h.outflowOfDay(day), h.gDayCap(day), "(a) paid out more than the owner's cap");
        }
    }

    function _simulate(uint256 profile, uint256 seed, bool refill) internal returns (Stats memory st) {
        uint256 snap = vm.snapshotState();
        vm.warp(D0);
        // after = the deployed W3 (1), or SIM_W3=2: refill ahead without the idle heartbeat
        NetworkHandler h = new NetworkHandler(0, false, true, refill ? uint8(vm.envOr("SIM_W3", uint256(1))) : 0);
        if (vm.envOr("SIM_DEBUG", false)) console2.log("=== simulate seed / refill", seed, refill ? 1 : 0);
        _runDay(h, profile, seed + 1_000_000, false); // warm-up day
        st = _runDay(h, profile, seed, true);
        string memory why = h.safetyFailure();
        require(bytes(why).length == 0, why);
        vm.revertToState(snap);
    }

    function _log(string memory label, Stats memory s) internal pure {
        console2.log(label);
        console2.log("  calls paid / had to wait / waited >= 20 min", s.calls, s.waited, s.longWaits);
        console2.log("  still waiting at midnight / max wait (min) / total wait (min)", s.unserved, s.maxWait, s.sumWait);
        console2.log("  spent ($, 6 dp) / grants / reclaims", s.spent, s.grants, s.reclaims);
        console2.log("  reacts / callbacks", s.reacts, s.callbacks);
    }

    function _add(Stats memory a, Stats memory b) internal pure {
        a.calls += b.calls;
        a.waited += b.waited;
        a.longWaits += b.longWaits;
        a.unserved += b.unserved;
        a.sumWait += b.sumWait;
        if (b.maxWait > a.maxWait) a.maxWait = b.maxWait;
        a.spent += b.spent;
        a.grants += b.grants;
        a.reclaims += b.reclaims;
        a.reacts += b.reacts;
        a.callbacks += b.callbacks;
    }

    /// The share of payments that had to wait, before (W2) and after (W3), on the same days, for
    /// each demand profile (1 steady, 2 night batch, 3 burst). SIM_SEEDS=<n> runs n days per
    /// profile (default 4); SIM_PROFILE=<p> runs one profile; SIM_VERBOSE=true logs every day.
    /// live/W3_2026-11-09.md reports SIM_SEEDS=30.
    ///  - burst (where the W2 coordinator is weak: the donor path starts too late), refill ahead
    ///    must at least halve the calls that wait;
    ///  - steady and night batch (W2 already rarely waits), it must not be worse beyond one call in
    ///    two days, counting the calls still waiting at midnight with those that waited.
    function test_simulatedDay_shareOfPaymentsThatWaited() public {
        uint256 seeds = vm.envOr("SIM_SEEDS", uint256(4));
        uint256 only = vm.envOr("SIM_PROFILE", uint256(0));
        for (uint256 profile = 1; profile <= 3; profile++) {
            if (only != 0 && profile != only) continue;
            Stats memory before;
            Stats memory after_;
            for (uint256 seed; seed < seeds; seed++) {
                Stats memory b = _simulate(profile, seed, false);
                Stats memory a = _simulate(profile, seed, true);
                if (vm.envOr("SIM_VERBOSE", false)) {
                    console2.log("profile / seed", profile, seed);
                    _log(" refill ahead off (W2)", b);
                    _log(" refill ahead on (W3)", a);
                }
                _add(before, b);
                _add(after_, a);
            }
            console2.log("PROFILE / days", profile, seeds);
            _log(" refill ahead off (W2)", before);
            _log(" refill ahead on (W3)", after_);
            console2.log(
                "  share of paid calls that had to wait, per 10,000: off / on",
                before.waited * 10_000 / before.calls,
                after_.waited * 10_000 / after_.calls
            );
            console2.log(
                "  share that waited, the calls still waiting at midnight included, per 10,000: off / on",
                (before.waited + before.unserved) * 10_000 / (before.calls + before.unserved),
                (after_.waited + after_.unserved) * 10_000 / (after_.calls + after_.unserved)
            );
            if (profile == 3) {
                assertLe(after_.waited * 2, before.waited, "burst: refill ahead did not halve the waits");
                assertLe(after_.sumWait * 2, before.sumWait, "burst: refill ahead did not halve the wait time");
                assertLe(after_.longWaits, before.longWaits, "burst: refill ahead added long waits");
            } else {
                // A call stuck until midnight (the budget left sits on other chains' floors) and a
                // call that waited are two ends of the same shortage, so they are counted together.
                assertLe(
                    after_.waited + after_.unserved,
                    before.waited + before.unserved + seeds / 2,
                    "refill ahead made more calls wait"
                );
            }
        }
    }
}

/// Directed scenarios for refill ahead by burn rate, at production timing (TestnetConfig: refill
/// horizon 1 h, top-up lead 20 min, reclaim lead 90 min; waits 30/30/16 min; heartbeat 40 min;
/// Cron every 17.74 min). Each one also checks every safety rule at the end. MUTANT=<n> and the
/// V* source patches (script/patch_mutants.py) break one rule of the new logic each.
contract RefillAheadDirectedTest is Test {
    uint256 constant T0 = 1_800_000_000 - (1_800_000_000 % 1 days) + 6 hours; // 06:00
    bytes32 immutable GRANT = bytes32(SpendWallet.applyGrant.selector);
    bytes32 immutable VERIFY = bytes32(SpendWallet.verify.selector);
    bytes32 immutable VERIFIED = IWalletEvents.Verified.selector;
    bytes32 immutable LOWWATER = IWalletEvents.LowWater.selector;

    NetworkHandler h;
    BudgetCoreHarness core;

    /// An agent that pays `amt` every `every` minutes; a refused call is retried every minute
    /// (the next period's call is skipped while it waits).
    struct Agent {
        uint8 c;
        uint256 amt;
        uint256 every;
        bool owing;
        uint256 since;
        uint256 waits;
        uint256 longest;
        uint256 paid;
    }

    function _fresh(bool refill) internal {
        vm.warp(T0);
        h = new NetworkHandler(vm.envOr("MUTANT", uint256(0)), false, true, refill ? 1 : 0);
        core = h.core();
    }

    function _today() internal view returns (uint64) {
        return uint64(block.timestamp / 1 days);
    }

    function _agent(uint8 c, uint256 amt, uint256 every) internal pure returns (Agent memory a) {
        a.c = c;
        a.amt = amt;
        a.every = every;
    }

    function _act(Agent memory a, uint256 m) internal {
        if (!a.owing && m % a.every == 0) {
            a.owing = true;
            a.since = m;
        }
        if (a.owing && h.payExact(a.c, a.amt)) {
            uint256 w = m - a.since;
            if (w > 0) a.waits++;
            if (w > a.longest) a.longest = w;
            a.owing = false;
            a.paid += a.amt;
        }
    }

    function _assertSafe() internal view {
        string memory why = h.safetyFailure();
        require(bytes(why).length == 0, why);
    }

    /// Short on each chain for the given amounts (the pool serves them), then a minute passes.
    function _fund(uint256 a0, uint256 a1, uint256 a2) internal {
        if (a0 > 0) assertFalse(h.payExact(0, a0));
        if (a1 > 0) assertFalse(h.payExact(1, a1));
        if (a2 > 0) assertFalse(h.payExact(2, a2));
        h.settleProduction(60);
        uint64 t = _today();
        assertEq(core.heldOf(t, 0) + core.heldOf(t, 1) + core.heldOf(t, 2), a0 + a1 + a2, "setup: funding");
    }

    // ------------------------------------------------------------------ top-up path

    /// A busy agent ($1.50 every 15 min = $6/h) on $10, with $10 in the pool. Refill ahead tops it
    /// up from the pool while it still holds at least the low-water mark, so no call waits. The
    /// W2 coordinator refills only on LowWater (< $1 left) or a refusal: with $1.00 left a $1.50
    /// call is refused and waits.
    function _topUp(bool refill) internal returns (Agent memory a, uint256 unspentAtFirstAhead) {
        _fresh(refill);
        _fund(10e6, 0, 0);
        a = _agent(0, 15e5, 15);
        bool seen;
        for (uint256 m; m < 180; m++) {
            uint256 before = h.aheadGrants();
            _act(a, m);
            uint256 u = h.wallets(0).unspentOf(_today());
            h.settleProduction(60);
            if (!seen && h.aheadGrants() > before) {
                seen = true;
                unspentAtFirstAhead = u;
            }
        }
        _assertSafe();
    }

    function test_refill_topsUpBeforeTheAgentIsRefused() public {
        (Agent memory off,) = _topUp(false);
        assertGt(off.waits, 0, "setup: without refill ahead a call waits (else the test shows nothing)");
        (Agent memory on, uint256 u) = _topUp(true);
        console2.log("calls that waited: refill ahead off / on", off.waits, on.waits);
        assertGt(h.aheadGrants(), 0, "no top-up was granted ahead");
        assertEq(on.waits, 0, "a call waited although the pool had budget");
        assertGe(u, 1e6, "the top-up came only once the chain was below its low-water mark");
        assertEq(on.paid, 18e6, "not every call was paid");
    }

    // ------------------------------------------------------------------ donor path

    /// The pool is empty; the busy agent ($0.375 every 5 min = $4.50/h) holds $10, an idle chain $10.
    /// Refill ahead starts the 30-min donor path while the busy chain still has more than an hour
    /// left, so it is never refused in 200 min. Without it, the donor path starts on LowWater
    /// (< $1 left) and the agent waits about half an hour.
    function _donor(bool refill) internal returns (Agent memory a, uint256 leftAtFirstReclaim) {
        _fresh(refill);
        _fund(10e6, 10e6, 0);
        assertEq(core.poolOf(_today()), 0, "setup: pool empty");
        a = _agent(0, 375e3, 5);
        bool seen;
        for (uint256 m; m < 200; m++) {
            uint256 before = h.aheadReclaims();
            _act(a, m);
            uint256 u = h.wallets(0).unspentOf(_today());
            h.settleProduction(60);
            if (!seen && h.aheadReclaims() > before) {
                seen = true;
                leftAtFirstReclaim = u;
            }
        }
        _assertSafe();
    }

    function test_refill_startsTheDonorPathBeforeTheChainRunsOut() public {
        (Agent memory off,) = _donor(false);
        assertGe(off.longest, 20, "setup: without refill ahead the agent waits for the donor path");
        (Agent memory on, uint256 left) = _donor(true);
        console2.log("longest wait (min): refill ahead off / on", off.longest, on.longest);
        console2.log("busy chain's unspent when the reclaim went out ahead ($, 6 dp)", left);
        assertGt(h.aheadReclaims(), 0, "no reclaim was sent ahead");
        assertEq(on.waits, 0, "the busy agent waited for the donor path");
        assertGe(left, 3e6, "the reclaim went out with less than 30 min of spending left");
    }

    // --------------------------------------------------------------- when not to act

    /// A slow chain ($1 an hour) is left to the reactive path: nothing ahead, even with the pool
    /// empty and a donor holding plenty.
    function test_refill_nothingAheadForASlowChain() public {
        _fresh(true);
        _fund(5e6, 10e6, 5e6);
        Agent memory a = _agent(0, 1e6, 60);
        for (uint256 m; m < 300; m++) {
            _act(a, m);
            h.settleProduction(60);
        }
        assertEq(h.aheadGrants() + h.aheadReclaims(), 0, "refill ahead acted for a chain spending $1/h");
        _assertSafe();
    }

    /// A burst ends ($6/h for 90 min, then nothing): at most one top-up goes out ahead after it
    /// ends (the read before refilling sees it stopped), not one per hour of its old rate.
    function test_refill_aBurstThatEndsGetsAtMostOneMoreTopUp() public {
        _fresh(true);
        _fund(6e6, 6e6, 0);
        Agent memory a = _agent(0, 5e5, 5);
        for (uint256 m; m < 90; m++) {
            _act(a, m);
            h.settleProduction(60);
        }
        uint256 atStop = h.aheadGrants();
        h.settleProduction(5 hours);
        console2.log("top-ups ahead during the burst / after it ended", atStop, h.aheadGrants() - atStop);
        assertGt(atStop, 0, "setup: refill ahead acted during the burst");
        assertLe(h.aheadGrants() - atStop, 1, "an idle chain kept being refilled ahead");
        _assertSafe();
    }

    /// A chain that spent everything and then went quiet, its LowWater lost: the fresh reading
    /// shows it dry. A chain that is really out asks; one that doesn't is idle. Nothing ahead.
    function test_refill_aDryChainThatDoesNotAskGetsNothing() public {
        _fresh(true);
        _fund(4e6, 6e6, 0);
        Agent memory a = _agent(0, 5e5, 5);
        for (uint256 m; m < 40; m++) {
            _act(a, m);
            h.dropAll(false, LOWWATER, 0);
            h.settleProduction(60);
        }
        assertEq(h.wallets(0).unspentOf(_today()), 0, "setup: chain 0 spent its $4");
        uint256 before = h.aheadGrants();
        h.settleProduction(3 hours);
        assertEq(h.aheadGrants(), before, "a dry chain that isn't asking was refilled ahead");
        _assertSafe();
    }

    /// Two busy chains ($3/h each, $7 each) and an idle one ($6), pool empty. Reclaims ahead go to
    /// the idle chain only, and leave it its floor plus one chunk ($4): never to a busy chain.
    function test_refill_aDonorKeepsItsFloorAChunkAndItsOwnNeed() public {
        _fresh(true);
        _fund(7e6, 7e6, 6e6);
        Agent memory a0 = _agent(0, 25e4, 5);
        Agent memory a1 = _agent(1, 25e4, 5);
        uint64 t = _today();
        for (uint256 m; m < 75; m++) {
            _act(a0, m);
            _act(a1, m);
            h.settleProduction(60);
            assertEq(core.openReclaim(0, t), 0, "a busy chain was asked to give");
            assertEq(core.openReclaim(1, t), 0, "a busy chain was asked to give");
            assertGe(h.wallets(2).unspentOf(t), 4e6, "the idle donor was taken below floor + one chunk");
        }
        h.settleProduction(60 minutes);
        assertGt(h.aheadReclaims(), 0, "setup: a reclaim went out ahead");
        assertGe(h.wallets(2).unspentOf(t), 4e6, "the idle donor was taken below floor + one chunk");
        _assertSafe();
    }

    // ----------------------------------------------------------------- STOP stays intact

    /// While frozen, nothing is granted, ahead or otherwise. The busy chain ($12/h) is pressed
    /// with $1.50 left, just before its first rate is known; while frozen its meter then shows it
    /// nearly dry by the books (the drained $1.50 is still held until its K_ROLL credit), the
    /// reading is fresh and the pool has $10.50: exactly when refill ahead would act if it ran
    /// while frozen. After the unstop, the busy chain is served again in the new epoch.
    function test_refill_nothingIsGrantedWhileFrozen() public {
        _fresh(true);
        _fund(95e5, 0, 0);
        Agent memory a = _agent(0, 1e6, 5);
        for (uint256 m; m < 36; m++) {
            _act(a, m);
            h.settleProduction(60);
        }
        assertEq(h.wallets(0).unspentOf(_today()), 15e5, "setup: $1.50 left on the busy chain");
        assertEq(h.aheadGrants(), 0, "setup: nothing ahead yet (no rate before the second reading)");
        h.ownerPressStop(1);
        h.settleProduction(60);
        assertTrue(core.frozen() && h.wallets(0).frozen(), "setup: frozen everywhere");
        uint256 grantsAtStop = h.grantsSent();
        uint256 rateSeen;
        for (uint256 m; m < 120; m++) {
            h.payExact(0, 1e6); // the agent keeps trying
            h.settleProduction(60);
            (,,,,, uint128 r) = core.meter(0);
            if (r > rateSeen) rateSeen = r;
        }
        assertGt(rateSeen, 0, "setup: the busy chain's rate became known while frozen");
        assertEq(h.grantsSent(), grantsAtStop, "a grant went out while frozen");
        h.ownerUnstop(core.epoch());
        uint256 paidAfter;
        for (uint256 m; m < 60; m++) {
            if (h.payExact(0, 1e6)) paidAfter++;
            h.settleProduction(60);
        }
        assertGt(paidAfter, 0, "the busy chain was not served again after the unstop");
        assertEq(h.wallets(0).epoch(), core.epoch(), "served from an older epoch");
        _assertSafe();
    }

    // ------------------------------------------------------------------ the meter

    /// Readings apply in origin-time order: an older reading delivered again (replayed or late)
    /// changes nothing, and neither does a duplicate of the newest.
    function test_refill_meterIgnoresOlderAndDuplicateReadings() public {
        _fresh(true);
        _fund(10e6, 0, 0);
        Agent memory a = _agent(0, 5e5, 5);
        for (uint256 m; m < 120; m++) {
            _act(a, m);
            h.settleProduction(60);
        }
        (uint64 d1, uint64 ts1, uint128 sp1,,, uint128 r1) = core.meter(0);
        assertGt(ts1, 0, "setup: chain 0 has a reading");
        assertGt(r1, 0, "setup: chain 0 has a rate");
        h.replay(false, VERIFIED, 0, 0); // the newest again
        h.replay(false, VERIFIED, 0, 1); // an older one, late
        h.deliverAll();
        (uint64 d2, uint64 ts2, uint128 sp2,,, uint128 r2) = core.meter(0);
        assertEq(ts2, ts1, "an older or duplicate reading moved the meter");
        assertEq(sp2, sp1, "an older or duplicate reading changed spent");
        assertEq(r2, r1, "an older or duplicate reading changed the rate");
        assertEq(d2, d1);
    }

    /// A LowWater counts as a reading only while the books are exact for that chain (no unanswered
    /// grant, no open reclaim, no unconfirmed return). Right after a STOP and unstop, the allowance
    /// the roll drained is still in `held` until its K_ROLL credit: a reading taken then would
    /// count it as spent and invent a burst. The meter must never show more spent than the wallet.
    function test_refill_lowWaterIsAReadingOnlyWhenTheBooksAreExact() public {
        _fresh(true);
        _fund(10e6, 0, 0);
        Agent memory a = _agent(0, 5e5, 5);
        for (uint256 m; m < 30; m++) {
            _act(a, m);
            h.settleProduction(60);
        }
        h.ownerPressStop(1);
        h.settleProduction(60);
        h.ownerUnstop(core.epoch());
        h.settleProduction(60); // the roll drained chain 0's $7; its credit waits 30 min
        uint64 t = _today();
        assertGt(core.heldOf(t, 0), h.wallets(0).unspentOf(t) + 5e6, "setup: held still counts the drained allowance");
        bool low;
        for (uint256 m; m < 25; m++) {
            uint256 lowBefore = h.count(false, LOWWATER, 0);
            _act(a, m);
            if (h.count(false, LOWWATER, 0) > lowBefore) low = true;
            h.settleProduction(60);
            (uint64 d, , uint128 spent,,,) = core.meter(0);
            (, uint128 walletSpent) = h.wallets(0).buckets(t);
            if (d == t) assertLe(spent, walletSpent, "the meter counted drained allowance as spent");
        }
        assertTrue(low, "setup: a LowWater was emitted while the drained allowance was uncredited");
        _assertSafe();
    }

    /// Read before refilling: whenever a top-up or reclaim goes out ahead, the busy chain's reading
    /// is younger than refillLead / 4 (here it is asked for first, and the grant follows on the
    /// answer's react, seconds later).
    function test_refill_actsOnlyOnAFreshReading() public {
        _fresh(true);
        _fund(10e6, 0, 0);
        Agent memory a = _agent(0, 15e5, 15);
        uint256 asked;
        for (uint256 m; m < 240; m++) {
            _act(a, m);
            uint256 g = h.aheadGrants() + h.aheadReclaims();
            // one minute by hand: deliver, time passes, Cron on its boundary, look, deliver
            h.deliverAll();
            uint256 before = block.timestamp / h.cronEvery();
            vm.warp(block.timestamp + 60);
            if (block.timestamp / h.cronEvery() != before) {
                h.tick();
                if (h.count(true, VERIFY, 0) > 0 && h.count(true, GRANT, 0) == 0) asked++;
            }
            h.deliverAll();
            if (h.aheadGrants() + h.aheadReclaims() > g) {
                (, uint64 ts,,,,) = core.meter(0);
                assertLe(block.timestamp, uint256(ts) + core.refillLead() / 4, "acted ahead on a stale reading");
            }
        }
        assertGt(h.aheadGrants(), 0, "setup: refill ahead acted");
        assertGt(asked, 0, "the coordinator never asked for a reading first");
        assertEq(a.waits, 0, "a call waited");
        _assertSafe();
    }
}
