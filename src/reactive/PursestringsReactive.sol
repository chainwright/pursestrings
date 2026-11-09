// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {BudgetCore} from "../BudgetCore.sol";
import {IWalletEvents, IConsoleEvents} from "../interfaces/IPursestrings.sol";
import {AbstractReactive} from "@reactive/src/base/AbstractReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";
import {CallbackFront} from "./CallbackFront.sol";

/// The reactive contract on Lasna: BudgetCore plus the Reactive glue. It subscribes to the
/// wallets' coordinator events, the home-chain console and a Cron topic, decodes each LogRecord
/// into one BudgetCore input, and turns every intent into a callback request to that chain's
/// front. Fees: reserves deposited with the system contract (`depositTo`) are used first; the
/// system contract can also collect from this contract's balance with pay(), and anyone can
/// clear a debt with coverDebt(). Built on reactive-lib-omni v0.1.0 (AbstractReactive: the system
/// contract is the fixed address 0x8888...8888, `onlySystem`, `pay`, `receive`). Not yet run
/// against the real system contract.
contract PursestringsReactive is BudgetCore, AbstractReactive {
    /// Cron events are emitted on Lasna by this address (DOCS_BRIEF §2).
    address public constant CRON_SOURCE = 0x0000000000000000000000000000000000fffFfF;

    struct Wiring {
        uint256 homeChainId;
        address console;
        uint256[] chainIds;
        address[] wallets;
        address[] fronts;
        /// Callback gasLimit per chain. The proxy withholds extraGas + maxChargeGas from it, so it
        /// must cover those plus the worst wallet entry (see TestnetConfig and test/Gas.t.sol).
        uint64[] callbackGas;
        /// Cron topic0 that drives retries, re-reads and pre-grants when no event arrives
        /// (TestnetConfig.CRON1000). 0 = no Cron (tests only).
        uint256 cronTopic;
    }

    uint256 public immutable homeChainId;
    address public immutable console;
    uint256 public immutable cronTopic;
    uint256[] public chainIds;
    address[] public wallets;
    address[] public fronts;
    uint64[] public callbackGas;

    constructor(Params memory p, Wiring memory w) payable BudgetCore(p) {
        uint256 n = p.nChains;
        require(
            w.chainIds.length == n && w.wallets.length == n && w.fronts.length == n && w.callbackGas.length == n, "len"
        );
        for (uint256 c; c < n; c++) {
            require(w.callbackGas[c] >= 100_000, "callback gas below the network minimum");
        }
        homeChainId = w.homeChainId;
        console = w.console;
        cronTopic = w.cronTopic;
        chainIds = w.chainIds;
        wallets = w.wallets;
        fronts = w.fronts;
        callbackGas = w.callbackGas;

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
        for (uint256 c; c < n; c++) {
            for (uint256 k; k < topics.length; k++) {
                SYSTEM.subscribe(
                    w.chainIds[c], w.wallets[c], uint256(topics[k]), REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
                );
            }
        }
        SYSTEM.subscribe(
            w.homeChainId,
            w.console,
            uint256(IConsoleEvents.CapSet.selector),
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        SYSTEM.subscribe(
            w.homeChainId,
            w.console,
            uint256(IConsoleEvents.Unstop.selector),
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        if (w.cronTopic != 0) {
            SYSTEM.subscribe(block.chainid, CRON_SOURCE, w.cronTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        }
    }

    /// Never filter by reverting: a revert in react() is still billed. Unknown logs are ignored.
    function react(LogRecord calldata log) external onlySystem {
        bytes32 t0 = bytes32(log.topic0);
        if (log.contractAddress == CRON_SOURCE && log.chainId == block.chainid) {
            if (cronTopic != 0 && log.topic0 == cronTopic) _onTick();
            return;
        }
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
            (uint64 day, uint256 unspent, uint64 ts) = abi.decode(log.data, (uint64, uint256, uint64));
            _onLowWater(c, day, unspent, ts);
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
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: chainIds[c],
                recipient: fronts[c],
                gasLimit: callbackGas[c],
                payload: abi.encodeCall(CallbackFront.deliver, (address(0), payload))
            })
        );
    }

    /// Anyone may settle this contract's debt with the system contract from its own balance.
    function coverDebt() external {
        _coverDebt();
    }
}
