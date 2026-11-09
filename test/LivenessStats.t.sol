// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;
import {Test, console2} from "forge-std/Test.sol";
import {NetworkHandler} from "./harness/NetworkHandler.sol";
import {BudgetCoreHarness} from "./harness/BudgetCoreHarness.sol";
import {PursestringsLivenessTest} from "./Pursestrings.invariant.t.sol";

/// Not a pass/fail test: measures how often the liveness model is non-vacuous and how many
/// refused retry rounds a short chain waits while budget exists (numbers for docs/DESIGN_AND_TESTS.md).
contract LivenessStats is Test {
    function test_livenessStats() public {
        uint256 availRetries;
        uint256 servedAvail;
        uint256 shortRuns;
        uint256 reclaimRuns;
        uint256 maxStreak;
        uint256[6] memory hist;
        for (uint256 seed; seed < 400; seed++) {
            uint256[3] memory streak;
            vm.warp(1_800_000_000 - (1_800_000_000 % 1 days) + 6 hours);
            NetworkHandler h = new NetworkHandler(0, false, false, 1);
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
            bool anyShort;
            for (uint256 round; round < 20; round++) {
                for (uint8 c; c < 3; c++) {
                    uint256 need = h.lastNeed(c);
                    if (need == 0) {
                        streak[c] = 0;
                        continue;
                    }
                    anyShort = true;
                    bool avail = _slack(h, c) >= need;
                    bool ok = h.payExact(c, need);
                    if (avail) {
                        availRetries++;
                        if (ok) servedAvail++;
                    }
                    if (ok) {
                        if (streak[c] > 0) hist[streak[c] > 5 ? 5 : streak[c]]++;
                        streak[c] = 0;
                    } else if (avail) {
                        streak[c]++;
                        if (streak[c] > maxStreak) maxStreak = streak[c];
                    } else {
                        streak[c] = 0;
                    }
                }
                h.settleFor(5);
            }
            if (anyShort) shortRuns++;
            if (h.reclaimsSent() > 0) reclaimRuns++;
        }
        console2.log("runs with a short chain", shortRuns, "of 400");
        console2.log("max refused-with-budget streak (rounds)", maxStreak);
        console2.log("served after 1/2/3 refused rounds", hist[1], hist[2], hist[3]);
        console2.log("served after 4/5+ refused rounds", hist[4], hist[5]);
        console2.log("runs with reclaims", reclaimRuns);
        console2.log("retries with budget available / served", availRetries, servedAvail);
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

    /// The same scenario with production timing: the distribution of refused-with-budget streaks.
    function test_livenessStatsProductionTiming() public {
        PursestringsLivenessTest t = new PursestringsLivenessTest();
        uint256[25] memory hist;
        uint256 worst;
        uint256 seeds = vm.envOr("LIVENESS_SEEDS", uint256(120)); // e.g. LIVENESS_SEEDS=1600
        for (uint256 seed; seed < seeds; seed++) {
            uint256 m = t.livenessRun(seed, true);
            hist[m > 24 ? 24 : m]++;
            if (m > worst) worst = m;
        }
        console2.log("production timing, seeds:", seeds);
        console2.log("worst refused-with-budget streak (5-min rounds)", worst);
        for (uint256 i; i < 25; i++) {
            if (hist[i] > 0) console2.log("  seeds whose worst streak was", i, hist[i]);
        }
    }
}
