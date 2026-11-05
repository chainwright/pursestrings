// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IERC20Min} from "./interfaces/IPursestrings.sol";

/// Transfers that work with tokens returning `true`, nothing (USDT-style) or `false`, and check
/// the result explicitly.
library SafeTransfer {
    /// Reverts unless the transfer succeeded.
    function safeTransfer(IERC20Min token, address to, uint256 amount) internal {
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(IERC20Min.transfer, (to, amount)));
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))) && address(token).code.length > 0, "transfer");
    }

    /// Returns whether the transfer succeeded, with at most `gasLimit` gas. Never reverts.
    function tryTransfer(IERC20Min token, address to, uint256 amount, uint256 gasLimit) internal returns (bool) {
        (bool ok, bytes memory ret) =
            address(token).call{gas: gasLimit}(abi.encodeCall(IERC20Min.transfer, (to, amount)));
        if (!ok || address(token).code.length == 0) return false;
        if (ret.length == 0) return true;
        if (ret.length < 32) return false;
        return abi.decode(ret, (uint256)) == 1;
    }
}
