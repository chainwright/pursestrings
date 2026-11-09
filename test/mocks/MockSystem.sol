// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

/// Records subscriptions and callback requests the way the Omni system contract would receive
/// them, and plays fee vendor (debt, pay) for the fee tests. Etched at the real system address
/// (0x8888...8888, reactive-lib-omni's `SYSTEM`).
contract MockSystem is ISystemContract {
    uint256 public subscriptions;
    uint256 public cronSubscriptions;
    ISystemContract.CallbackConfiguration_V_1_0[] internal reqs;
    mapping(address => uint256) public debt;

    function subscribe(uint256, address contractAddress, uint256, uint256, uint256, uint256) external {
        subscriptions++;
        if (contractAddress == 0x0000000000000000000000000000000000fffFfF) cronSubscriptions++;
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {}

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory c) external {
        reqs.push(c);
    }

    function requestCallback(CallbackVersion, bytes memory config) external {
        reqs.push(abi.decode(config, (ISystemContract.CallbackConfiguration_V_1_0)));
    }

    function callbacks() external view returns (uint256) {
        return reqs.length;
    }

    function request(uint256 i) external view returns (ISystemContract.CallbackConfiguration_V_1_0 memory) {
        return reqs[i];
    }

    function setDebt(address a, uint256 d) external {
        debt[a] = d;
    }

    receive() external payable {}

    /// Reserves deposit (Reactive's docs): accepted and counted, nothing more.
    mapping(address => uint256) public reserves;

    function depositTo(address c) external payable {
        reserves[c] += msg.value;
    }

    /// getCallbacks as Reactive's docs describe it: per reactive tx, (block, requesting contract,
    /// index, destination chain id, destination tx hash, error). The dry run's relay records them.
    struct CallbackRecord {
        uint256 blockNumber;
        address sender;
        uint256 index;
        uint256 chainId;
        uint256 txHash;
        bytes error;
    }

    mapping(uint256 => CallbackRecord[]) internal recorded;

    function recordCallback(uint256 reactiveTx, address sender, uint256 chainId, uint256 destTx) external {
        recorded[reactiveTx].push(
            CallbackRecord(block.number, sender, recorded[reactiveTx].length, chainId, destTx, "")
        );
    }

    function getCallbacks(uint256 reactiveTx) external view returns (CallbackRecord[] memory) {
        return recorded[reactiveTx];
    }
}
