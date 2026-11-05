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
        h = new NetworkHandler(m, true);
        core = h.core();
        bytes4[] memory sels = new bytes4[](9);
        sels[0] = NetworkHandler.pay.selector;
        sels[1] = NetworkHandler.deliverBatch.selector;
        sels[2] = NetworkHandler.deliverAny.selector;
        sels[3] = NetworkHandler.warp.selector;
        sels[4] = NetworkHandler.tick.selector;
        sels[5] = NetworkHandler.chaos.selector;
        sels[6] = NetworkHandler.duplicate.selector;
        sels[7] = NetworkHandler.deliverNext.selector;
        sels[8] = NetworkHandler.heal.selector;
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

    /// Every unit of allowance is backed by a token in the wallet.
    function invariant_allowanceBackedByTokens() public view {
        for (uint256 c; c < 3; c++) {
            SpendWallet w = h.wallets(c);
            assertLe(w.liveUnspent(), MockToken(address(h.tokens(c))).balanceOf(address(w)), "allowance > balance");
        }
    }
}

/// (d) Liveness-lite: with no drops, no reorgs and no STOP (reorder, duplicates and delay still
/// on), a short chain whose agent keeps retrying is not starved: it may not stay refused for
/// STARVE consecutive retry rounds while, at every one of those retries, the reserve plus its own
/// allowance plus the slack above the floor of peers that are not short themselves covered the
/// need. (Peers that are short keep their allowance; that is the anti ping-pong rule.)
contract PursestringsLivenessTest is Test {
    /// Bound derived from the protocol, in 5-minute retry rounds: a peer that asked recently is
    /// protected from reclaim for wantTtl (10 min = 2 rounds), then reclaim + confirmation wait +
    /// re-read (1 round), then the agent's next retry (1 round), plus 1 for a Short that lands
    /// just after a round boundary. Refused with budget available for 6 rounds = starved.
    uint256 internal constant STARVE = 6;

    function testFuzz_liveness_shortChainGetsServed(uint256 seed) public {
        vm.warp(1_800_000_000 - (1_800_000_000 % 1 days) + 6 hours); // 06:00, far from midnight
        NetworkHandler h = new NetworkHandler(0, false);
        for (uint256 i; i < 60; i++) {
            uint256 s = uint256(keccak256(abi.encode(seed, i)));
            uint256 op = s % 6;
            if (op <= 1) h.pay(s >> 8, s >> 32);
            else if (op == 2) h.deliverNext();
            else if (op == 3) h.deliverAny(s >> 8);
            else if (op == 4) h.duplicate(s >> 8);
            else vm.warp(block.timestamp + ((s >> 8) % 120));
        }
        h.settle();

        uint256[3] memory starved; // consecutive rounds refused while budget was available
        uint256 servedAfterShort;
        for (uint256 round; round < 20; round++) {
            for (uint8 c; c < 3; c++) {
                uint256 need = h.lastNeed(c);
                if (need == 0) {
                    starved[c] = 0;
                    continue;
                }
                bool available = _slack(h, c) >= need;
                if (h.payExact(c, need)) {
                    servedAfterShort++;
                    starved[c] = 0;
                } else if (available) {
                    starved[c]++;
                    assertLt(starved[c], STARVE, "(d) short chain starved although budget was available");
                } else {
                    starved[c] = 0;
                }
            }
            h.settleFor(5); // ~5 min between retries, under the 10 min want TTL
        }
        assertEq(h.core().today(), h.startDay(), "test must stay within one day");
        emit log_named_uint("short chains served on retry", servedAfterShort);
    }

    function _slack(NetworkHandler h, uint8 c) internal view returns (uint256 slack) {
        BudgetCoreHarness core = h.core();
        uint64 t = core.today();
        slack = h.wallets(c).unspentOf(t) + core.poolOf(t);
        for (uint8 j; j < 3; j++) {
            if (j == c || h.lastNeed(j) > 0) continue;
            uint256 u = h.wallets(j).unspentOf(t);
            if (u > h.FLOOR()) slack += u - h.FLOOR();
        }
    }
}

/// A long seeded walk with all faults on, printing how often each path was exercised.
/// Not an invariant by itself; it reports coverage for SPIKE_RESULT.md and re-checks (a)-(c).
contract PursestringsCoverageWalk is Test {
    function test_coverageWalk() public {
        vm.warp(1_800_000_000);
        NetworkHandler h = new NetworkHandler(vm.envOr("MUTANT", uint256(0)), true);
        uint256 steps = vm.envOr("WALK_STEPS", uint256(4000));
        for (uint256 i; i < steps; i++) {
            uint256 s = uint256(keccak256(abi.encode("walk", i)));
            uint256 op = s % 7;
            if (op == 0) h.pay(s >> 8, s >> 32);
            else if (op == 1) h.deliverBatch(s >> 8);
            else if (op == 2) h.deliverAny(s >> 8);
            else if (op == 3) h.warp(s >> 8);
            else if (op == 4) h.tick();
            else if (op == 5) h.chaos(s >> 8);
            else h.duplicate(s >> 8);
            if (i % 500 == 499) h.healAndSettle();
        }
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
        string memory why = h.safetyFailure();
        require(bytes(why).length == 0, why);
    }
}
