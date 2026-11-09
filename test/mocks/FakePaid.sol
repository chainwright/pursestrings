// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {MockToken} from "./MockToken.sol";

/// Dry run only (script/dryrun.sh): an attacker contract that is not a registered wallet. In one
/// transaction it emits a Paid event byte-identical to SpendWallet's for the API's callId, payee
/// and price, and really moves that many budget tokens to the payee (minted to itself first). The
/// demo API must still refuse to serve data: the Paid log and the Transfer come from an address
/// that is not one of the deployment's wallets.
contract FakePaid {
    event Paid(bytes32 indexed callId, address indexed payee, uint256 amount, uint64 day, uint64 epoch);

    function fake(MockToken token, address payee, uint256 amount, bytes32 callId) external {
        token.mint(address(this), amount);
        emit Paid(callId, payee, amount, uint64(block.timestamp / 1 days), 0);
        require(token.transfer(payee, amount), "transfer");
    }
}
