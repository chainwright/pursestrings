// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IWalletInbox} from "../interfaces/IPursestrings.sol";
import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";

/// Fee-only front on each destination chain. It is the wallet's only `bridge`. Built on
/// reactive-lib-omni's AbstractCallback: it accepts a call only from the Reactive callback proxy
/// (`onlyServiceProvider`) AND only when the injected first argument is our reactive contract
/// (`onlyCallbackSender`), and forwards only the five coordinator selectors to one bound wallet.
/// It never forwards arbitrary calldata. Callback fees are paid from this contract's ETH
/// (reserves deposited with the proxy first, then this balance via pay()), never from the budget
/// token.
contract CallbackFront is AbstractCallback {
    address public immutable owner;
    address public wallet;

    constructor(address proxy_, address rc_, address owner_) payable AbstractCallback(IPayable(payable(proxy_)), rc_) {
        owner = owner_;
    }

    function proxy() external view returns (address) {
        return address(_SERVICE_PROVIDER);
    }

    function rc() external view returns (address) {
        return _CALLBACK_SENDER;
    }

    function bind(address wallet_) external {
        require(msg.sender == owner, "owner");
        require(wallet == address(0), "bound");
        wallet = wallet_;
    }

    function deliver(address rvm, bytes calldata payload) external onlyServiceProvider onlyCallbackSender(rvm) {
        require(wallet != address(0), "unbound");
        require(payload.length >= 4, "payload");
        bytes4 sel = bytes4(payload[:4]);
        require(
            sel == IWalletInbox.applyGrant.selector || sel == IWalletInbox.applyReclaim.selector
                || sel == IWalletInbox.applyCancel.selector || sel == IWalletInbox.applyEpoch.selector
                || sel == IWalletInbox.verify.selector,
            "selector"
        );
        (bool ok, bytes memory ret) = wallet.call(payload);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    /// Anyone may settle this front's debt with the proxy from its own balance.
    function coverDebt() external {
        _coverDebt();
    }

    /// The owner can take back the fee float (never the budget: the front holds no budget tokens).
    function withdrawFees(address payable to, uint256 amount) external {
        require(msg.sender == owner, "owner");
        _pay(to, amount);
    }
}
