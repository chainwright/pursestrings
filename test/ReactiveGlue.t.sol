// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {BudgetCore} from "../src/BudgetCore.sol";
import {SpendWallet} from "../src/SpendWallet.sol";
import {Vault} from "../src/Vault.sol";
import {OwnerConsole} from "../src/OwnerConsole.sol";
import {IERC20Min, IWalletEvents} from "../src/interfaces/IPursestrings.sol";
import {PursestringsReactive} from "../src/reactive/PursestringsReactive.sol";
import {CallbackFront} from "../src/reactive/CallbackFront.sol";
import {LogRecord, CallbackConfiguration_V_1_0, IReactiveSystem} from "../src/reactive/IReactiveMirror.sol";
import {MockToken} from "./mocks/MockToken.sol";

/// Records subscriptions and callback requests the way the Omni system contract would receive them.
contract MockSystem is IReactiveSystem {
    uint256 public subscriptions;
    uint256 public callbacks;
    uint256 public lastChainId;
    address public lastRecipient;
    uint64 public lastGas;
    bytes public lastPayload;

    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external {
        subscriptions++;
    }

    function requestCallbackV_1_0(CallbackConfiguration_V_1_0 calldata c) external {
        callbacks++;
        lastChainId = c.chainId;
        lastRecipient = c.recipient;
        lastGas = c.gasLimit;
        lastPayload = c.payload;
    }
}

/// The Reactive glue in isolation: subscriptions, react() routing, callback encoding, and the
/// fee-only front's sender checks. One local loop: Short log -> react -> callback -> front -> wallet.
contract ReactiveGlueTest is Test {
    address constant OWNER = address(0xA11CE);
    address constant AGENT = address(0xA6E47);
    address constant PROXY = address(0x9409);
    uint256 constant CAP = 20e6;

    MockSystem sys;
    PursestringsReactive rc;
    OwnerConsole console;
    CallbackFront[3] fronts;
    SpendWallet[3] wallets;
    uint256[3] ids = [uint256(84532), 1301, 11155111];

    function setUp() public {
        vm.warp(1_800_000_000);
        sys = new MockSystem();
        console = new OwnerConsole(OWNER);
        // Deploy order: fronts (need the RC address), wallets (need the front), then the RC.
        // 3 fronts + 3 x (token, vault, wallet) = 12 creations before the RC.
        address rcAddr = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 12);
        for (uint256 c; c < 3; c++) {
            fronts[c] = new CallbackFront(PROXY, rcAddr, OWNER);
        }
        uint256[] memory chainIds = new uint256[](3);
        address[] memory ws = new address[](3);
        address[] memory fs = new address[](3);
        for (uint256 c; c < 3; c++) {
            MockToken t = new MockToken();
            Vault v = new Vault(IERC20Min(address(t)), OWNER);
            SpendWallet w = new SpendWallet(IERC20Min(address(t)), v, address(fronts[c]), OWNER, AGENT, 10e6, 2e6, 1e6);
            vm.startPrank(OWNER);
            v.bind(address(w));
            fronts[c].bind(address(w));
            vm.stopPrank();
            t.mint(address(v), 100 * CAP);
            wallets[c] = w;
            chainIds[c] = ids[c];
            ws[c] = address(w);
            fs[c] = address(fronts[c]);
        }
        BudgetCore.Params memory p = BudgetCore.Params({
            nChains: 3,
            cap: CAP,
            keepFloor: 2e6,
            confirmWait: 60,
            grantTimeout: 300,
            reclaimTimeout: 300,
            verifyTimeout: 120,
            pregrantWindow: 2 hours,
            wantTtl: 600
        });
        rc = new PursestringsReactive(p, sys, ids[0], address(console), chainIds, ws, fs);
        assertEq(address(rc), rcAddr, "address prediction");
    }

    function test_subscribesToEveryCoordinatorEventOnEveryChainPlusConsole() public view {
        assertEq(sys.subscriptions(), 3 * 10 + 2);
    }

    function test_reactOnlyFromSystem() public {
        LogRecord memory l = _shortLog(0, 3e6);
        vm.expectRevert(bytes("system"));
        rc.react(l);
    }

    function test_unknownEmitterIgnored() public {
        LogRecord memory l = _shortLog(0, 3e6);
        l.contractAddress = address(0xBAD);
        vm.prank(address(sys));
        rc.react(l);
        assertEq(sys.callbacks(), 0);
    }

    /// Short on Base Sepolia -> react -> grant callback to Base's front -> (proxy injects the RC
    /// address) -> front forwards applyGrant -> the wallet now holds the allowance in tokens.
    function test_localLoop_shortBecomesAllowance() public {
        LogRecord memory l = _shortLog(0, 3e6);
        vm.prank(address(sys));
        rc.react(l);
        assertEq(sys.callbacks(), 1);
        assertEq(sys.lastChainId(), ids[0]);
        assertEq(sys.lastRecipient(), address(fronts[0]));
        assertEq(sys.lastGas(), rc.CALLBACK_GAS());

        bytes memory delivered = _asProxyWould(sys.lastPayload());
        vm.prank(PROXY);
        (bool ok,) = address(fronts[0]).call(delivered);
        assertTrue(ok, "front rejected the callback");
        uint64 t = wallets[0].today();
        assertGe(wallets[0].unspentOf(t), 3e6, "allowance not applied");
        assertEq(rc.heldOf(t, 0), wallets[0].unspentOf(t), "books match the wallet");
    }

    function test_frontRejectsWrongSenderWrongRcAndForeignSelectors() public {
        bytes memory inner = abi.encodeCall(SpendWallet.applyGrant, (1, wallets[0].today(), 1e6, 0));
        vm.expectRevert(bytes("proxy"));
        fronts[0].deliver(address(rc), inner);

        vm.prank(PROXY);
        vm.expectRevert(bytes("reactive contract"));
        fronts[0].deliver(address(0xBEEF), inner);

        // no generic forwarder: pay() and anything else is refused even from the proxy + RC
        vm.prank(PROXY);
        vm.expectRevert(bytes("selector"));
        fronts[0].deliver(address(rc), abi.encodeCall(SpendWallet.pay, (address(this), 1e6, bytes32(0))));
    }

    function test_walletAcceptsCoordinatorMessagesOnlyFromItsFront() public {
        uint64 t = wallets[0].today();
        vm.expectRevert(bytes("bridge"));
        wallets[0].applyGrant(1, t, 1e6, 0);
    }

    function _shortLog(uint256 c, uint256 shortBy) internal view returns (LogRecord memory l) {
        l.chainId = ids[c];
        l.contractAddress = address(wallets[c]);
        l.topic0 = uint256(IWalletEvents.Short.selector);
        l.data = abi.encode(wallets[c].today(), shortBy, uint64(block.timestamp));
        l.opCode = 1;
    }

    /// The network overwrites the first argument with the requesting reactive contract.
    function _asProxyWould(bytes memory payload) internal view returns (bytes memory) {
        (, bytes memory inner) = abi.decode(_tail(payload), (address, bytes));
        return abi.encodeCall(CallbackFront.deliver, (address(rc), inner));
    }

    function _tail(bytes memory cd) internal pure returns (bytes memory out) {
        out = new bytes(cd.length - 4);
        for (uint256 i; i < out.length; i++) {
            out[i] = cd[i + 4];
        }
    }
}
