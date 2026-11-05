// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// Minimal ERC-20 surface the protocol needs. Nothing else is ever called on the budget token
/// (no approve, no transferFrom): outflows happen only through SpendWallet.pay().
interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

// Verification kinds: what the coordinator asks a chain to re-confirm before crediting.
uint8 constant K_RECLAIM = 1; // "reclaim reqId was applied, returning amount z"
uint8 constant K_VOID = 2; // "grant id was never applied and is tombstoned"
uint8 constant K_ROLL = 3; // "on epoch e the wallet returned (today, tomorrow) to its vault"
uint8 constant K_EPOCH = 4; // "the wallet is at epoch >= e"

/// Messages the coordinator (BudgetCore on Lasna) sends to one chain. In production each is the
/// payload of a Reactive callback, delivered through the callback proxy and a fee-only front
/// that forwards only these selectors.
interface IWalletInbox {
    function applyGrant(uint256 id, uint64 day, uint256 amount, uint64 epoch) external;
    function applyReclaim(uint256 id, uint64 day, uint256 amount) external;
    function applyCancel(uint256 id, uint256 grantId) external;
    function applyEpoch(uint64 epoch, bool frozen, uint64 pressSeenAt) external;
    function verify(uint8 kind, uint256 key) external;
}

/// Origin-chain events. The first group is what the reactive contract subscribes to.
/// Every event carries the origin block timestamp (`ts`), because a LogRecord carries a block
/// number but not a time, and the confirmation rule is time-based.
interface IWalletEvents {
    event Short(uint64 day, uint256 shortBy, uint64 ts);
    event LowWater(uint64 day, uint256 unspent, uint64 ts);
    event GrantApplied(uint256 indexed grantId, uint64 day, uint256 amount, uint64 ts);
    event GrantNotApplied(uint256 indexed grantId, uint8 reason, uint64 ts);
    event Reclaimed(uint256 indexed reqId, uint64 day, uint256 amount, uint64 ts);
    event CancelAck(uint256 indexed reqId, uint256 indexed grantId, bool applied, uint64 ts);
    event Rolled(uint64 indexed epoch, uint64 day, uint256 today, uint256 tomorrow, uint64 ts);
    event EpochAck(uint64 indexed epoch, bool frozen, uint64 ts);
    event StopPressed(uint64 mark);
    event Verified(
        uint8 kind, uint256 key, bool ok, uint64 day, uint256 a0, uint256 a1, uint64 appliedAt, uint64 ts
    );

    // Local only (not subscribed by the reactive contract).
    event Paid(bytes32 indexed callId, address indexed payee, uint256 amount, uint64 day, uint64 epoch);
    event Refused(bytes32 indexed callId, uint8 reason);
    event Swept(uint64 day, uint256 amount);
}

/// Owner configuration, emitted on the home chain (never a direct call on Lasna).
interface IConsoleEvents {
    event CapSet(uint64 nonce, uint256 cap);
    event Unstop(uint64 nonce, uint64 epoch);
}
