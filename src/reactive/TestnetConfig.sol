// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

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

    /// Cron on Lasna: Cron1000 fires about every 1000 blocks (~18 min at ~1.1 s blocks), about
    /// 78 reactive txs and ~1-2.3 lREACT a day (DOCS_BRIEF §5). Cron10000 (~3 h) is the cheap
    /// fallback. Cron100 and below cost 10x+ more and are not used.
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
    /// Each chain hears from the coordinator at least this often (a re-read, ~1 callback per chain
    /// per hour), so a lost STOP press is carried back within about an hour plus a Cron tick even
    /// if nothing else happens on that chain. Cron1000 paces it: one chain per tick at most.
    uint64 internal constant HEARTBEAT = 1 hours;

    uint64 internal constant WAIT_SEPOLIA = 16 minutes;
    uint64 internal constant WAIT_OP_STACK = 30 minutes;

    /// Callback gasLimit per chain = withheld + 1.5 x (measured worst wallet entry through the
    /// front with the test token + an allowance for USDC's heavier transfers), rounded up.
    /// Derivation and the check that it still holds: test/Gas.t.sol.
    uint64 internal constant CALLBACK_GAS_SEPOLIA = 700_000;
    uint64 internal constant CALLBACK_GAS_L2 = 600_000;
}
