// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IConsoleEvents} from "./interfaces/IPursestrings.sol";

/// Home-chain owner console. Raising the cap and lifting a STOP are owner-only and enter the
/// coordinator as origin events. STOP itself can be pressed on any chain's wallet.
contract OwnerConsole is IConsoleEvents {
    address public immutable owner;
    uint64 public capNonce;
    uint64 public unstopNonce;

    constructor(address owner_) {
        owner = owner_;
    }

    function setCap(uint256 cap) external {
        require(msg.sender == owner, "owner");
        emit CapSet(++capNonce, cap);
    }

    /// `epoch` names the frozen epoch being lifted, as the owner reads it from Lasna. A delayed
    /// unstop therefore can't lift a later STOP.
    function unstop(uint64 epoch) external {
        require(msg.sender == owner, "owner");
        emit Unstop(++unstopNonce, epoch);
    }
}
