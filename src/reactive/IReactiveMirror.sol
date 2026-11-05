// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// Local mirror of the reactive-lib-omni surface this project uses, so the core builds and tests
/// without the library. Field names follow the Omni docs (topic0, not legacy topic_0).
/// W2: replace with `@reactive/src/...` imports and re-check field order against the pinned lib.
struct LogRecord {
    uint256 chainId;
    address contractAddress;
    uint256 topic0;
    uint256 topic1;
    uint256 topic2;
    uint256 topic3;
    bytes data;
    uint256 blockNumber;
    uint256 opCode;
    uint256 blockHash;
    uint256 txHash;
    uint256 logIndex;
}

struct CallbackConfiguration_V_1_0 {
    uint256 chainId;
    address recipient;
    uint64 gasLimit;
    bytes payload;
}

/// Fee vendor (the system contract on Lasna, the callback proxy on a destination chain).
interface IPayable {
    function debt(address contract_) external view returns (uint256);
}

interface IReactiveSystem is IPayable {
    function subscribe(
        uint256 chainId,
        address contractAddress,
        uint256 topic0,
        uint256 topic1,
        uint256 topic2,
        uint256 topic3
    ) external;

    function requestCallbackV_1_0(CallbackConfiguration_V_1_0 calldata config) external;
}
