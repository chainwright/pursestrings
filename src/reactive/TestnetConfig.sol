// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {BudgetCore} from "../BudgetCore.sol";

/// Deployment numbers for the testnet live loop (Lasna <-> Sepolia, Base Sepolia, Unichain
/// Sepolia). Sources: DOCS_BRIEF.md (proxies, extraGas/maxChargeGas read on-chain 04.11.2026,
/// Cron topics) and test/Gas.t.sol (measured wallet gas). Nothing here has been deployed yet.
library TestnetConfig {
    uint256 internal constant LASNA = 5318007;
    uint256 internal constant SEPOLIA = 11155111;
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint256 internal constant UNICHAIN_SEPOLIA = 1301;

    address internal constant PROXY_SEPOLIA = 0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4;
    address internal constant PROXY_BASE_SEPOLIA = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;
    address internal constant PROXY_UNICHAIN_SEPOLIA = 0x775c9B990ADe401060B78D0e98684eEf8d2466C1;

    /// Gas the callback proxy withholds from every callback's gasLimit (extraGas + maxChargeGas).
    uint64 internal constant WITHHELD_SEPOLIA = 150_000 + 50_000;
    uint64 internal constant WITHHELD_L2 = 80_000 + 50_000;

    /// Cron on Lasna: Cron1000 fires every 1000 blocks: ~17.74 min at the 1.064 s per block
    /// measured over 10,000 blocks on 06.11.2026 (the model's default), ~81 reactive txs a day. With
    /// the heartbeat answers that is a few lREACT a day by the documented fee formula (up to ~4.6
    /// for Cron alone if every tick were the heaviest measured); unmeasured. Cron10000 (~3 h) is
    /// the cheap fallback. Cron100 and below cost 10x+ more and are not used.
    uint256 internal constant CRON1000 = 0xe20b31294d84c3661ddc8f423abb9c70310d0cf172aa2714ead78029b325e3f4;
    uint256 internal constant CRON10000 = 0xd214e1d84db704ed42d37f538ea9bf71e44ba28bc1cc088b2f5deca654677a56;

    /// Confirmation wait per chain: a return is credited only once it has existed on its origin
    /// chain this long (re-read included), so the design is safe while every reorg is shallower.
    /// Set above finality, conservatively, until Reactive confirms what it delivers (head, safe or
    /// finalized blocks):
    ///  - Sepolia finalizes after 2 epochs = 64 slots x 12 s = 12.8 min. Wait: 16 min.
    ///  - Base Sepolia and Unichain Sepolia (OP Stack) are final once their batch is in a
    ///    finalized L1 block: batch posting (minutes) + 12.8 min. We have not measured either.
    ///    Wait: 30 min.
    /// The cost is latency on the donor path only (reclaims, voided grants, epoch rolls); the
    /// reserve top-up path never waits.
    /// Each chain gets a heartbeat (a re-read) once this much time has passed since its last one,
    /// on the next react: within 40 min + one Cron period P (in practice ceil(40 / P) * P: 51 min
    /// at P = 17 min, 53.2 at the measured 17.74). The re-read re-announces a lost STOP press at once, so a lost
    /// press with an idle pressing agent reaches every chain within about that plus a minute of
    /// delivery (test/ProductionTiming.t.sol sweeps P = 17-19.5 min: 51-59 min). About 3
    /// callbacks per ~51-56 min in an idle system.
    uint64 internal constant HEARTBEAT = 40 minutes;

    /// Refill ahead by burn rate (W3, from the 09.11 live numbers: top-up p50 2 s, chain to chain
    /// ~30 min, Cron1000 17.66 min observed):
    ///  - a top-up covers 1 h of the chain's measured rate (at least one chunk, cap / 10);
    ///  - it goes out once the projection says < 20 min of spending is left: one Cron period
    ///    (17.66 min) plus margin, so it lands on the last tick before the chain runs dry, and the
    ///    2-s top-up path is never on a payment's critical path;
    ///  - the donor path starts once < 90 min is left and the pool can't give the top-up: the
    ///    reclaim goes out within one Cron period, is credited after the 30-min wait plus up to
    ///    one more period, which is ~65 min, ahead of the 20-min top-up point.
    uint32 internal constant REFILL_HORIZON = 1 hours;
    uint32 internal constant REFILL_LEAD = 20 minutes;
    uint32 internal constant RECLAIM_LEAD = 90 minutes;

    /// Idle heartbeat (W3, W1 gate P2-2). While no agent has spent or asked for 2 h, each chain is
    /// beaten every 120 min instead of 40: ~11.6 beats a day per chain instead of ~27 at the observed
    /// 17.66-min Cron. A lost STOP press then reaches every chain within ceil(120 / P) x P + delivery
    /// (~126 min) while nothing is being spent, and within one 40-min cycle of the first sign of
    /// spending (a Short, a LowWater, a reading with more spent). Measured costs: live/W3_2026-11-09.md.
    uint64 internal constant IDLE_HEARTBEAT = 120 minutes;
    uint64 internal constant IDLE_AFTER = 2 hours;

    uint64 internal constant WAIT_SEPOLIA = 16 minutes;
    uint64 internal constant WAIT_OP_STACK = 30 minutes;

    /// Production timing for a chain, derived from its confirmation wait so the ratios hold:
    ///  - grantTimeout 10 min: a grant is answered within seconds; Cron (~17.74 min, measured) is the clock.
    ///  - verifyTimeout 5 min: one re-read round trip.
    ///  - reclaimTimeout = wait + 2 x verifyTimeout: an unanswered reclaim is closed only after its
    ///    return could have been confirmed (the core also never closes one whose return is pending).
    ///  - wantTtl = reclaimTimeout: a want lives as long as the donor path it may trigger.
    /// Sepolia: wait 16, reclaim/want 26 min. Base/Unichain Sepolia: wait 30, reclaim/want 40 min.
    function chainParams(uint64 wait) internal pure returns (BudgetCore.ChainParams memory p) {
        p.confirmWait = uint32(wait);
        p.grantTimeout = 10 minutes;
        p.verifyTimeout = 5 minutes;
        p.reclaimTimeout = uint32(wait) + 2 * p.verifyTimeout;
        p.wantTtl = p.reclaimTimeout;
    }

    /// Callback gasLimit per chain = withheld + 1.5 x (measured worst wallet entry through the
    /// front with the test token + an allowance for USDC's heavier transfers), rounded up.
    /// Derivation and the check that it still holds: test/Gas.t.sol.
    uint64 internal constant CALLBACK_GAS_SEPOLIA = 700_000;
    uint64 internal constant CALLBACK_GAS_L2 = 700_000;
}
