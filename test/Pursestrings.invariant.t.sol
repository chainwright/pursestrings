// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, console2} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {NetworkHandler} from "./harness/NetworkHandler.sol";
import {SpendWallet} from "../src/SpendWallet.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {BudgetCoreHarness} from "./harness/BudgetCoreHarness.sol";

/// Safety under our own fault model of the network: reorder, drop, duplicate, delay, partitions,
/// reorgs (instant, or a branch that lives up to just under the chain's confirmation wait), STOP,
/// unstop, cap changes, vault withdrawals, day boundaries, and now and then a healed network.
/// MUTANT=<n> swaps in a broken variant.
contract PursestringsInvariantTest is StdInvariant, Test {
    NetworkHandler internal h;
    BudgetCoreHarness internal core;

    function setUp() public {
        vm.warp(1_800_000_000); // a fixed date; 12:00 UTC-ish within its day
        uint256 m = vm.envOr("MUTANT", uint256(0));
        h = new NetworkHandler(m, true, false, true);
        core = h.core();
        bytes4[] memory sels = new bytes4[](10);
        sels[0] = NetworkHandler.pay.selector;
        sels[1] = NetworkHandler.deliverBatch.selector;
        sels[2] = NetworkHandler.deliverAny.selector;
        sels[3] = NetworkHandler.warp.selector;
        sels[4] = NetworkHandler.tick.selector;
        sels[5] = NetworkHandler.chaos.selector;
        sels[6] = NetworkHandler.duplicate.selector;
        sels[7] = NetworkHandler.deliverNext.selector;
        sels[8] = NetworkHandler.heal.selector;
        sels[9] = NetworkHandler.burst.selector;
        targetContract(address(h));
        targetSelector(FuzzSelector({addr: address(h), selectors: sels}));
    }

    /// (a) Outflows counted by the token (every transfer out of a wallet except to its own vault),
    /// summed over all wallets per day, never exceed the owner's cap for that day. The bound comes
    /// from the test's own record of what the owner set and which of those messages reached the
    /// coordinator (see NetworkHandler._runCore), not from the coordinator. The coordinator's own
    /// day cap must equal it exactly, so a stale or replayed cap change is caught on its own.
    function invariant_a_outflowPerDayWithinOwnersCap() public view {
        uint64 last = core.today() + 1;
        for (uint64 d = h.startDay(); d <= last; d++) {
            assertLe(h.outflowOfDay(d), h.gDayCap(d), "(a) paid out more than the owner's cap for the day");
            assertEq(core.capOfDay(d), h.gDayCap(d), "(a) day cap differs from the owner's configured cap");
        }
    }

    /// (b) Once STOP is in effect on a chain nothing leaves it, and no allowance from an older
    /// epoch is ever spent (checked in the handler after every action).
    function invariant_b_noPaymentAfterStopOrFromOldEpoch() public view {
        assertEq(h.violations(), 0, h.firstViolation());
    }

    /// (s) The owner's STOP, end to end: whenever the network has healed for a bounded time
    /// (NetworkHandler.healAndSettle), every wallet is on the coordinator's epoch, and if the
    /// owner's last action was a STOP, every chain is frozen and no payment succeeds anywhere.
    function invariant_s_ownersStopReachesEveryChain() public view {
        assertEq(h.stopViolations(), 0, h.firstStopViolation());
    }

    /// (c) The coordinator's books: pool + sum(held) == cap for every open day, so the sum
    /// granted (net of confirmed returns) never exceeds the cap.
    function invariant_c_booksConserveAndGrantedWithinCap() public view {
        uint64 last = core.today() + 1;
        for (uint64 d = h.startDay(); d <= last; d++) {
            if (!core.isOpen(d)) continue;
            uint256 held;
            for (uint8 c; c < 3; c++) {
                held += core.heldOf(d, c);
            }
            assertEq(core.poolOf(d) + held, core.capOfDay(d), "(c) books don't conserve");
            assertLe(held, core.capOfDay(d), "(c) granted above cap");
        }
    }

    /// (e) The per-chain lemma the safety argument rests on: for today and tomorrow, the
    /// allowance a wallet has received (net of what it really returned) never exceeds what the
    /// coordinator still counts as held by that chain. Summed over chains this gives (a) for every
    /// day, before any agent has to overspend for the fuzzer to notice.
    function invariant_e_walletAllowanceWithinCoreHeld() public view {
        uint64 t = core.today();
        for (uint64 d = t; d <= t + 1; d++) {
            for (uint8 c; c < 3; c++) {
                (uint128 allowance,) = h.wallets(c).buckets(d);
                assertLe(allowance, core.heldOf(d, c), "(e) wallet allowance above coordinator's held");
            }
        }
    }

    /// (f) The cap invariant in the wallets' own terms (W3): for today and tomorrow, the sum over
    /// chains of each wallet's allowance for the day (unspent + spent) never exceeds the owner's
    /// cap for that day. Refill ahead moves allowance earlier and between chains; this must hold
    /// at every step, not only once the network settles.
    function invariant_f_sumOfAllowancesWithinCap() public view {
        uint64 t = core.today();
        for (uint64 d = t; d <= t + 1; d++) {
            uint256 sum;
            for (uint8 c; c < 3; c++) {
                (uint128 allowance,) = h.wallets(c).buckets(d);
                sum += allowance;
            }
            assertLe(sum, h.gDayCap(d), "(f) sum of allowances (unspent + spent) above the owner's cap");
        }
    }

    /// Token conservation in every wallet: its balance is exactly its unspent allowance plus what
    /// it owes back to the vault (`stranded`). More allowance than tokens would be unbacked
    /// allowance; more tokens than both would be tokens the wallet forgot it owes.
    function invariant_allowanceBackedByTokens() public view {
        for (uint256 c; c < 3; c++) {
            SpendWallet w = h.wallets(c);
            uint256 bal = MockToken(address(h.tokens(c))).balanceOf(address(w));
            assertLe(w.liveUnspent() + w.stranded(), bal, "allowance > balance");
            assertGe(w.liveUnspent() + w.stranded(), bal, "tokens neither allowance nor owed to the vault");
        }
    }
}

/// (d) Liveness-lite: with no drops, no reorgs and no STOP (reorder, duplicates and delay still
/// on), a short chain whose agent keeps retrying is not starved: it may not stay refused for
/// STARVE consecutive retry rounds while, at every one of those retries, the reserve plus its own
/// allowance plus the slack above the floor of peers that are not short themselves covered the
/// need. (Peers that are short keep their allowance; that is the anti ping-pong rule.)
contract PursestringsLivenessTest is Test {
    function livenessRun(uint256 seed, bool production) external returns (uint256) {
        return _liveness(seed, false, production, 0);
    }

    /// Bound derived from the protocol, in 5-minute retry rounds: a peer that asked recently is
    /// protected from reclaim for wantTtl (10 min = 2 rounds), then reclaim + confirmation wait +
    /// re-read (1 round), then the agent's next retry (1 round), plus 1 for a Short that lands
    /// just after a round boundary. Refused with budget available for 6 rounds = starved.
    uint256 internal constant STARVE = 6;

    /// Production timing (TestnetConfig): waits 30/30/16 min, reclaim/want timeouts 40/40/26 min,
    /// Cron every 17.74 min (NetworkHandler.cronEvery, measured), agents retrying every 5 min. Bound derived the same way, in 5-min rounds:
    /// a peer that asked is protected for wantTtl (40 min = 8), the reclaim goes out on the next
    /// react (1), its return waits 30 min (6), the re-read goes out on the next react and comes
    /// back (1), the grant lands (1), the agent's next retry (1), boundary (1), spare (1) = 20.
    uint256 internal constant STARVE_PRODUCTION = 20;

    function testFuzz_liveness_shortChainGetsServed(uint256 seed) public {
        _liveness(seed, false, false, STARVE);
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_liveness_productionTiming(uint256 seed) public {
        _liveness(seed, false, true, STARVE_PRODUCTION);
    }

    /// The same with chain 2 dead for the whole measured period (every callback to it lost) while
    /// its agent keeps asking: chains 0 and 1 must still not starve (R2-2).
    function testFuzz_liveness_othersServedWhileOneChainIsDead(uint256 seed) public {
        _liveness(seed, true, false, STARVE);
    }

    /// Runs one liveness scenario and returns the longest refused-with-budget streak seen (in
    /// 5-minute retry rounds). Asserts it stays below `bound` (0 = measure only).
    function _liveness(uint256 seed, bool chain2Dead, bool production, uint256 bound)
        internal
        returns (uint256 maxStreak)
    {
        vm.warp(1_800_000_000 - (1_800_000_000 % 1 days) + 6 hours); // 06:00, far from midnight
        NetworkHandler h = new NetworkHandler(0, false, production, true);
        for (uint256 i; i < 60; i++) {
            uint256 s = uint256(keccak256(abi.encode(seed, i)));
            uint256 op = s % 6;
            if (op <= 1) h.pay(s >> 8, s >> 32);
            else if (op == 2) h.deliverNext();
            else if (op == 3) h.deliverAny(s >> 8);
            else if (op == 4) h.duplicate(s >> 8);
            else vm.warp(block.timestamp + ((s >> 8) % 120));
        }
        if (production) h.settleProduction(2 hours);
        else h.settle();
        uint256 held2AtDeath;
        if (chain2Dead) {
            h.killChain(2, 1 days);
            held2AtDeath = h.core().heldOf(h.core().today(), 2);
        }

        uint256[3] memory starved; // consecutive rounds refused while budget was available
        uint256 servedAfterShort;
        for (uint256 round; round < (production ? 40 : 20); round++) {
            for (uint8 c; c < 3; c++) {
                uint256 need = h.lastNeed(c);
                if (need == 0) {
                    starved[c] = 0;
                    continue;
                }
                bool available = _slack(h, c, chain2Dead) >= need;
                if (chain2Dead && c == 2) {
                    h.payExact(c, need); // the dead chain's agent keeps asking; not measured
                    // ... but it may absorb at most one more grant (a grant is <= CAP / 4 here)
                    assertLe(
                        h.core().heldOf(h.core().today(), 2),
                        held2AtDeath + h.CAP() / 4,
                        "(d) a dead chain absorbed more than one grant"
                    );
                    continue;
                }
                if (h.payExact(c, need)) {
                    servedAfterShort++;
                    starved[c] = 0;
                } else if (available) {
                    starved[c]++;
                    if (starved[c] > maxStreak) maxStreak = starved[c];
                    if (bound != 0) {
                        assertLt(starved[c], bound, "(d) short chain starved although budget was available");
                    }
                } else {
                    starved[c] = 0;
                }
            }
            if (production) h.settleProduction(300);
            else h.settleFor(5); // ~5 min between retries, under the 10 min want TTL
        }
        assertEq(h.core().today(), h.startDay(), "test must stay within one day");
        emit log_named_uint("short chains served on retry", servedAfterShort);
    }

    /// What could serve chain c: the pool, its own allowance, and the slack above the floor of
    /// peers that aren't short (a dead peer's allowance can't be reclaimed, so it doesn't count).
    function _slack(NetworkHandler h, uint8 c, bool chain2Dead) internal view returns (uint256 slack) {
        BudgetCoreHarness core = h.core();
        uint64 t = core.today();
        slack = h.wallets(c).unspentOf(t) + core.poolOf(t);
        for (uint8 j; j < 3; j++) {
            if (j == c || h.lastNeed(j) > 0 || (chain2Dead && j == 2)) continue;
            uint256 u = h.wallets(j).unspentOf(t);
            if (u > h.FLOOR()) slack += u - h.FLOOR();
        }
    }
}

/// A long seeded walk with all faults on, printing how often each path was exercised.
/// Not an invariant by itself; it reports coverage for SPIKE_RESULT.md and re-checks (a)-(c).
contract PursestringsCoverageWalk is Test {
    function test_coverageWalk() public {
        _walk("walk", 7, vm.envOr("WALK_STEPS", uint256(4000)));
    }

    /// The same walk with busy agents (NetworkHandler.burst) as an eighth action, so refill ahead
    /// by burn rate acts under every fault (W3). A separate walk, so the original one's sequence,
    /// and the mutants it is known to catch, stay as they were.
    function test_coverageWalkWithBursts() public {
        _walk("burst walk", 8, vm.envOr("WALK_STEPS", uint256(4000)));
    }

    function _walk(string memory tag, uint256 ops, uint256 steps) internal {
        vm.warp(1_800_000_000);
        NetworkHandler h = new NetworkHandler(vm.envOr("MUTANT", uint256(0)), true, false, true);
        for (uint256 i; i < steps; i++) {
            uint256 s = uint256(keccak256(abi.encode(tag, i)));
            uint256 op = s % ops;
            if (op == 0) h.pay(s >> 8, s >> 32);
            else if (op == 1) h.deliverBatch(s >> 8);
            else if (op == 2) h.deliverAny(s >> 8);
            else if (op == 3) h.warp(s >> 8);
            else if (op == 4) h.tick();
            else if (op == 5) h.chaos(s >> 8);
            else if (op == 6) h.duplicate(s >> 8);
            else h.burst(s >> 8);
            if (i % 500 == 499) h.healAndSettle();
        }
        console2.log(tag);
        console2.log("steps", steps);
        console2.log("days crossed / outages", h.daysCrossed(), h.outages());
        console2.log("pays ok / refused", h.paysOk(), h.paysRefused());
        console2.log("delivered / dropped", h.delivered(), h.dropped());
        console2.log(
            "duplicated / reorged (all) / of them on a branch that lived",
            h.duplicated(),
            h.orphaned(),
            h.delayedReorgs()
        );
        console2.log("re-reads served from a competing branch", h.branchReads());
        console2.log("heals / of them with the owner's STOP in force", h.heals(), h.healsWhileStopped());
        console2.log("stops / unstops", h.stops(), h.unstops());
        console2.log("cap changes / vault withdrawals", h.capChanges(), h.withdraws());
        console2.log("grants / reclaims sent", h.grantsSent(), h.reclaimsSent());
        console2.log("cancels sent / grants voided", h.cancelsSent(), h.voidsSeen());
        console2.log("confirmed credits", h.credits());
        console2.log("delayed (held back) / replayed (late redelivery)", h.delayed(), h.replayed());
        console2.log("chain partitions (callbacks held, released out of order)", h.partitions());
        console2.log("stale-epoch grants delivered / to an unfrozen wallet", h.staleGrants(), h.staleGrantsUnfrozen());
        console2.log("  ... of them never seen before (the rule-6 path)", h.freshStaleUnfrozen());
        console2.log("max queue", h.maxQueue());
        console2.log("refill ahead: top-ups / reclaims", h.aheadGrants(), h.aheadReclaims());
        string memory why = h.safetyFailure();
        require(bytes(why).length == 0, why);
    }
}
