// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {BudgetCore} from "../../src/BudgetCore.sol";

/// BudgetCore with the Reactive glue replaced by plain calls: the test's network model feeds
/// decoded origin events in (as `feeder`) and collects `Intent` events as outgoing callbacks.
contract BudgetCoreHarness is BudgetCore {
    address public immutable feeder;

    event Intent(uint8 indexed chain, bytes payload);

    modifier onlyFeeder() {
        require(msg.sender == feeder, "feeder");
        _;
    }

    constructor(Params memory p, address feeder_) BudgetCore(p) {
        feeder = feeder_;
    }

    function onShort(uint8 c, uint64 day, uint256 shortBy) external onlyFeeder {
        _onShort(c, day, shortBy);
    }

    function onLowWater(uint8 c, uint64 day) external onlyFeeder {
        _onLowWater(c, day);
    }

    function onGrantApplied(uint8 c, uint256 grantId) external onlyFeeder {
        _onGrantApplied(c, grantId);
    }

    function onGrantNotApplied(uint8 c, uint256 grantId, uint64 ts) external onlyFeeder {
        _onGrantNotApplied(c, grantId, ts);
    }

    function onCancelAck(uint8 c, uint256 grantId, bool applied, uint64 ts) external onlyFeeder {
        _onCancelAck(c, grantId, applied, ts);
    }

    function onReclaimed(uint8 c, uint256 reqId, uint256 amount, uint64 ts) external onlyFeeder {
        _onReclaimed(c, reqId, amount, ts);
    }

    function onRolled(uint8 c, uint64 e, uint64 day, uint256 r0, uint256 r1, uint64 ts) external onlyFeeder {
        _onRolled(c, e, day, r0, r1, ts);
    }

    function onEpochAck(uint8 c, uint64 e, uint64 ts) external onlyFeeder {
        _onEpochAck(c, e, ts);
    }

    function onStopPressed(uint8 c, uint64 mark) external onlyFeeder {
        _onStopPressed(c, mark);
    }

    function onVerified(uint8 c, Echo calldata v) external onlyFeeder {
        _onVerified(c, v);
    }

    function onCapSet(uint64 nonce, uint256 newCap) external onlyFeeder {
        _onCapSet(nonce, newCap);
    }

    function onUnstop(uint64 nonce, uint64 e) external onlyFeeder {
        _onUnstop(nonce, e);
    }

    function onTick() external onlyFeeder {
        _onTick();
    }

    function _dispatch(uint8 c, bytes memory payload) internal override {
        emit Intent(c, payload);
    }
}
