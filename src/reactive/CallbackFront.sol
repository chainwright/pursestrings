// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IWalletInbox} from "../interfaces/IPursestrings.sol";

/// Fee-only front on each destination chain. It is the wallet's only `bridge`. It accepts a call
/// only from the Reactive callback proxy AND only when the injected first argument is our reactive
/// contract, and forwards only the five coordinator selectors to one bound wallet. It never
/// forwards arbitrary calldata. Callback fees are paid from this contract's ETH, never from the
/// budget. (W2: fee settlement with the proxy, owner withdraw of the fee float, gauge.)
contract CallbackFront {
    address public immutable proxy;
    address public immutable rc;
    address public immutable owner;
    address public wallet;

    constructor(address proxy_, address rc_, address owner_) payable {
        proxy = proxy_;
        rc = rc_;
        owner = owner_;
    }

    function bind(address wallet_) external {
        require(msg.sender == owner, "owner");
        require(wallet == address(0), "bound");
        wallet = wallet_;
    }

    function deliver(address rvm, bytes calldata payload) external {
        require(msg.sender == proxy, "proxy");
        require(rvm == rc, "reactive contract");
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

    receive() external payable {}
}
