// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IERC20Min} from "./interfaces/IPursestrings.sol";
import {SafeTransfer} from "./SafeTransfer.sol";

/// Holds the owner's funds on one chain. Only its bound wallet can draw from it, and only by
/// asking for an exact amount; the wallet returns unused allowance here. Money never leaves the chain.
contract Vault {
    using SafeTransfer for IERC20Min;

    IERC20Min public immutable token;
    address public immutable owner;
    address public wallet;

    event Bound(address wallet);
    event Released(uint256 amount);
    event Withdrawn(address to, uint256 amount);

    constructor(IERC20Min token_, address owner_) {
        token = token_;
        owner = owner_;
    }

    function bind(address wallet_) external {
        require(msg.sender == owner, "owner");
        require(wallet == address(0), "bound");
        wallet = wallet_;
        emit Bound(wallet_);
    }

    /// Moves `amount` to the wallet if the vault can cover it in full. Never partial: a grant
    /// either becomes real tokens in the wallet or does not apply at all.
    function release(uint256 amount) external returns (bool) {
        require(msg.sender == wallet, "wallet");
        if (token.balanceOf(address(this)) < amount) return false;
        token.safeTransfer(wallet, amount);
        emit Released(amount);
        return true;
    }

    function withdraw(address to, uint256 amount) external {
        require(msg.sender == owner, "owner");
        token.safeTransfer(to, amount);
        emit Withdrawn(to, amount);
    }
}
