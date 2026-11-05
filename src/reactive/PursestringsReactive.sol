// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {BudgetCore} from "../BudgetCore.sol";
import {IWalletEvents, IConsoleEvents} from "../interfaces/IPursestrings.sol";
import {LogRecord, CallbackConfiguration_V_1_0, IReactiveSystem} from "./IReactiveMirror.sol";
import {CallbackFront} from "./CallbackFront.sol";

/// The reactive contract on Lasna: BudgetCore plus the Reactive glue. It subscribes to the
/// wallets' coordinator events and the home-chain console, decodes each LogRecord into one
/// BudgetCore input, and turns every intent into a callback request to that chain's front.
/// Not exercised against the real system contract yet (that is the W1 live-loop step).
contract PursestringsReactive is BudgetCore {
    uint256 internal constant REACTIVE_IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;
    uint64 public constant CALLBACK_GAS = 300_000;

    IReactiveSystem public immutable SYSTEM;
    uint256 public immutable homeChainId;
    address public immutable console;
    uint256[] public chainIds;
    address[] public wallets;
    address[] public fronts;

    constructor(
        Params memory p,
        IReactiveSystem system_,
        uint256 homeChainId_,
        address console_,
        uint256[] memory chainIds_,
        address[] memory wallets_,
        address[] memory fronts_
    ) payable BudgetCore(p) {
        require(chainIds_.length == p.nChains && wallets_.length == p.nChains && fronts_.length == p.nChains, "len");
        SYSTEM = system_;
        homeChainId = homeChainId_;
        console = console_;
        chainIds = chainIds_;
        wallets = wallets_;
        fronts = fronts_;

        bytes32[10] memory topics = [
            IWalletEvents.Short.selector,
            IWalletEvents.LowWater.selector,
            IWalletEvents.GrantApplied.selector,
            IWalletEvents.GrantNotApplied.selector,
            IWalletEvents.Reclaimed.selector,
            IWalletEvents.CancelAck.selector,
            IWalletEvents.Rolled.selector,
            IWalletEvents.EpochAck.selector,
            IWalletEvents.StopPressed.selector,
            IWalletEvents.Verified.selector
        ];
        for (uint256 c; c < chainIds_.length; c++) {
            for (uint256 k; k < topics.length; k++) {
                system_.subscribe(
                    chainIds_[c], wallets_[c], uint256(topics[k]), REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
                );
            }
        }
        system_.subscribe(
            homeChainId_, console_, uint256(IConsoleEvents.CapSet.selector), REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        system_.subscribe(
            homeChainId_, console_, uint256(IConsoleEvents.Unstop.selector), REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
    }

    /// Never filter by reverting: a revert in react() is still billed. Unknown logs are ignored.
    function react(LogRecord calldata log) external {
        require(msg.sender == address(SYSTEM), "system");
        bytes32 t0 = bytes32(log.topic0);
        if (log.chainId == homeChainId && log.contractAddress == console) {
            if (t0 == IConsoleEvents.CapSet.selector) {
                (uint64 nonce, uint256 nc) = abi.decode(log.data, (uint64, uint256));
                _onCapSet(nonce, nc);
            } else if (t0 == IConsoleEvents.Unstop.selector) {
                (uint64 nonce, uint64 e) = abi.decode(log.data, (uint64, uint64));
                _onUnstop(nonce, e);
            }
            return;
        }
        (bool found, uint8 c) = _chainOf(log.chainId, log.contractAddress);
        if (!found) return;
        if (t0 == IWalletEvents.Short.selector) {
            (uint64 day, uint256 shortBy,) = abi.decode(log.data, (uint64, uint256, uint64));
            _onShort(c, day, shortBy);
        } else if (t0 == IWalletEvents.LowWater.selector) {
            (uint64 day,,) = abi.decode(log.data, (uint64, uint256, uint64));
            _onLowWater(c, day);
        } else if (t0 == IWalletEvents.GrantApplied.selector) {
            _onGrantApplied(c, log.topic1);
        } else if (t0 == IWalletEvents.GrantNotApplied.selector) {
            (, uint64 ts) = abi.decode(log.data, (uint8, uint64));
            _onGrantNotApplied(c, log.topic1, ts);
        } else if (t0 == IWalletEvents.Reclaimed.selector) {
            (, uint256 amount, uint64 ts) = abi.decode(log.data, (uint64, uint256, uint64));
            _onReclaimed(c, log.topic1, amount, ts);
        } else if (t0 == IWalletEvents.CancelAck.selector) {
            (bool applied, uint64 ts) = abi.decode(log.data, (bool, uint64));
            _onCancelAck(c, log.topic2, applied, ts);
        } else if (t0 == IWalletEvents.Rolled.selector) {
            (uint64 day, uint256 r0, uint256 r1, uint64 ts) = abi.decode(log.data, (uint64, uint256, uint256, uint64));
            _onRolled(c, uint64(log.topic1), day, r0, r1, ts);
        } else if (t0 == IWalletEvents.EpochAck.selector) {
            (, uint64 ts) = abi.decode(log.data, (bool, uint64));
            _onEpochAck(c, uint64(log.topic1), ts);
        } else if (t0 == IWalletEvents.StopPressed.selector) {
            _onStopPressed(c, abi.decode(log.data, (uint64)));
        } else if (t0 == IWalletEvents.Verified.selector) {
            _onVerified(c, abi.decode(log.data, (Echo)));
        }
    }

    function _chainOf(uint256 chainId, address emitter) internal view returns (bool, uint8) {
        for (uint8 c; c < chainIds.length; c++) {
            if (chainIds[c] == chainId && wallets[c] == emitter) return (true, c);
        }
        return (false, 0);
    }

    /// The network overwrites the first argument (here `rvm`) with this contract's address.
    function _dispatch(uint8 c, bytes memory payload) internal override {
        SYSTEM.requestCallbackV_1_0(
            CallbackConfiguration_V_1_0({
                chainId: chainIds[c],
                recipient: fronts[c],
                gasLimit: CALLBACK_GAS,
                payload: abi.encodeCall(CallbackFront.deliver, (address(0), payload))
            })
        );
    }
}
