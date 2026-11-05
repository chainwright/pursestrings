// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IPayable} from "./IReactiveMirror.sol";

/// Fee settlement, the AbstractPayer pattern from reactive-lib-omni: the vendor (Lasna's system
/// contract for the reactive contract, the callback proxy for a front) collects fees with
/// pay(amount) from this contract's own balance, and anyone can settle a debt with coverDebt().
/// Reserves deposited with the vendor (`depositTo`) are used first; this balance is the backup.
/// A contract in debt receives nothing, so keeping a balance here is what keeps it running.
abstract contract Payer {
    event FeePaid(address to, uint256 amount);

    function _vendor() internal view virtual returns (address);

    receive() external payable {}

    function pay(uint256 amount) external {
        require(msg.sender == _vendor(), "vendor only");
        _payTo(msg.sender, amount);
    }

    function coverDebt() external {
        address v = _vendor();
        _payTo(v, IPayable(v).debt(address(this)));
    }

    function _payTo(address to, uint256 amount) internal {
        require(address(this).balance >= amount, "insufficient funds");
        if (amount == 0) return;
        (bool ok,) = payable(to).call{value: amount}("");
        require(ok, "fee transfer failed");
        emit FeePaid(to, amount);
    }
}
