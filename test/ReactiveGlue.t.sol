// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, Vm} from "forge-std/Test.sol";
import {BudgetCore} from "../src/BudgetCore.sol";
import {SpendWallet} from "../src/SpendWallet.sol";
import {Vault} from "../src/Vault.sol";
import {OwnerConsole} from "../src/OwnerConsole.sol";
import {IERC20Min, IWalletEvents, IConsoleEvents} from "../src/interfaces/IPursestrings.sol";
import {PursestringsReactive} from "../src/reactive/PursestringsReactive.sol";
import {CallbackFront} from "../src/reactive/CallbackFront.sol";
import {TestnetConfig} from "../src/reactive/TestnetConfig.sol";
import {LogRecord, CallbackConfiguration_V_1_0, IReactiveSystem} from "../src/reactive/IReactiveMirror.sol";
import {MockToken} from "./mocks/MockToken.sol";

/// Records subscriptions and callback requests the way the Omni system contract would receive
/// them, and plays fee vendor (debt, pay) for the fee tests.
contract MockSystem is IReactiveSystem {
    uint256 public subscriptions;
    uint256 public cronSubscriptions;
    CallbackConfiguration_V_1_0[] internal reqs;
    mapping(address => uint256) public debt;

    function subscribe(uint256, address contractAddress, uint256, uint256, uint256, uint256) external {
        subscriptions++;
        if (contractAddress == 0x0000000000000000000000000000000000fffFfF) cronSubscriptions++;
    }

    function requestCallbackV_1_0(CallbackConfiguration_V_1_0 calldata c) external {
        reqs.push(c);
    }

    function callbacks() external view returns (uint256) {
        return reqs.length;
    }

    function request(uint256 i) external view returns (CallbackConfiguration_V_1_0 memory) {
        return reqs[i];
    }

    function setDebt(address a, uint256 d) external {
        debt[a] = d;
    }

    receive() external payable {}
}

/// The Reactive glue: subscriptions, every react() route, callback encoding, Cron, fees, and the
/// fee-only front's checks. The loop tests run real wallet logs through react() (not the fuzz
/// handler's own decoder) and real callback payloads through the proxy -> front -> wallet path.
contract ReactiveGlueTest is Test {
    address constant OWNER = address(0xA11CE);
    address constant AGENT = address(0xA6E47);
    address constant PROXY = address(0x9409);
    address constant PAYEE = address(0xBEEF);
    uint256 constant CAP = 20e6;

    MockSystem sys;
    PursestringsReactive rc;
    OwnerConsole console;
    CallbackFront[3] fronts;
    SpendWallet[3] wallets;
    uint256[3] ids = [uint256(84532), 1301, 11155111];
    uint256 pumped; // callback requests already delivered
    mapping(uint256 => uint256) routed; // topic0 => logs that went through react()

    function setUp() public {
        vm.warp(1_800_000_000 - (1_800_000_000 % 1 days) + 6 hours);
        sys = new MockSystem();
        console = new OwnerConsole(OWNER);
        // Deploy order: fronts (need the RC address), wallets (need the front), then the RC.
        // 3 fronts + 3 x (token, vault, wallet) = 12 creations before the RC.
        address rcAddr = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 12);
        for (uint256 c; c < 3; c++) {
            fronts[c] = new CallbackFront(PROXY, rcAddr, OWNER);
        }
        PursestringsReactive.Wiring memory w;
        w.system = sys;
        w.homeChainId = ids[0];
        w.console = address(console);
        w.chainIds = new uint256[](3);
        w.wallets = new address[](3);
        w.fronts = new address[](3);
        w.callbackGas = new uint64[](3);
        w.cronTopic = TestnetConfig.CRON1000;
        for (uint256 c; c < 3; c++) {
            MockToken t = new MockToken();
            Vault v = new Vault(IERC20Min(address(t)), OWNER);
            SpendWallet wl = new SpendWallet(IERC20Min(address(t)), v, address(fronts[c]), OWNER, AGENT, 10e6, 2e6, 1e6);
            vm.startPrank(OWNER);
            v.bind(address(wl));
            fronts[c].bind(address(wl));
            wl.setPayee(PAYEE, true);
            vm.stopPrank();
            t.mint(address(v), 100 * CAP);
            wallets[c] = wl;
            w.chainIds[c] = ids[c];
            w.wallets[c] = address(wl);
            w.fronts[c] = address(fronts[c]);
            w.callbackGas[c] = c == 2 ? TestnetConfig.CALLBACK_GAS_SEPOLIA : TestnetConfig.CALLBACK_GAS_L2;
        }
        BudgetCore.Params memory p;
        p.nChains = 3;
        p.cap = CAP;
        p.keepFloor = 2e6;
        p.pregrantWindow = 2 hours;
        p.heartbeat = TestnetConfig.HEARTBEAT;
        p.chains = new BudgetCore.ChainParams[](3);
        p.chains[0] = TestnetConfig.chainParams(TestnetConfig.WAIT_OP_STACK);
        p.chains[1] = TestnetConfig.chainParams(TestnetConfig.WAIT_OP_STACK);
        p.chains[2] = TestnetConfig.chainParams(TestnetConfig.WAIT_SEPOLIA);
        rc = new PursestringsReactive(p, w);
        assertEq(address(rc), rcAddr, "address prediction");
    }

    // ------------------------------------------------------------- wiring

    function test_subscribesToEveryCoordinatorEventOnEveryChainPlusConsoleAndCron() public view {
        assertEq(sys.subscriptions(), 3 * 10 + 2 + 1);
        assertEq(sys.cronSubscriptions(), 1);
    }

    function test_reactOnlyFromSystem() public {
        LogRecord memory l = _log(0, IWalletEvents.Short.selector, abi.encode(_today(), 3e6, uint64(block.timestamp)));
        vm.expectRevert(bytes("system"));
        rc.react(l);
    }

    function test_unknownEmitterIgnored() public {
        LogRecord memory l = _log(0, IWalletEvents.Short.selector, abi.encode(_today(), 3e6, uint64(block.timestamp)));
        l.contractAddress = address(0xBAD);
        vm.prank(address(sys));
        rc.react(l);
        assertEq(sys.callbacks(), 0);
    }

    /// Short on Base Sepolia -> react -> grant callback to Base's front -> (proxy injects the RC
    /// address) -> front forwards applyGrant -> the wallet now holds the allowance in tokens.
    function test_localLoop_shortBecomesAllowance() public {
        _react(_log(0, IWalletEvents.Short.selector, abi.encode(_today(), 3e6, uint64(block.timestamp))));
        assertEq(_count(SpendWallet.applyGrant.selector), 1, "one grant");
        CallbackConfiguration_V_1_0 memory r = sys.request(_first(SpendWallet.applyGrant.selector));
        assertEq(r.chainId, ids[0]);
        assertEq(r.recipient, address(fronts[0]));
        assertEq(r.gasLimit, TestnetConfig.CALLBACK_GAS_L2);
        _pump();
        uint64 t = _today();
        assertGe(wallets[0].unspentOf(t), 3e6, "allowance not applied");
        assertEq(rc.heldOf(t, 0), wallets[0].unspentOf(t), "books match the wallet");
    }

    /// R2-2: while a chain's grant is unanswered, that chain gets no other grant, however often
    /// its agent asks; once the wallet answers, it can be served again.
    function test_oneUnansweredGrantPerChain() public {
        for (uint256 k; k < 5; k++) {
            _react(_log(0, IWalletEvents.Short.selector, abi.encode(_today(), 2e6, uint64(block.timestamp))));
            vm.warp(block.timestamp + 301);
        }
        assertEq(_count(SpendWallet.applyGrant.selector), 1, "a second grant while the first is unanswered");
        assertEq(rc.inflight(0), 1);
        assertEq(rc.poolOf(_today()), CAP - 2e6, "only one grant's worth left the pool");
        uint256 before = sys.callbacks();
        _pump(); // the wallet applies it and answers; the still-open want is served in that react()
        assertGt(_count(SpendWallet.applyGrant.selector), 1, "served again after the answer");
        assertGt(sys.callbacks(), before);
    }

    // --------------------------------------------------------------- Cron

    /// A Cron tick alone (no origin event) drives the loop: late in the day it pre-grants tomorrow.
    function test_cronTickDrivesPregrants() public {
        vm.warp(block.timestamp + 17 hours); // 23:00, after a long idle: heartbeats are due too
        _react(_cron(TestnetConfig.CRON1000));
        assertTrue(rc.isOpen(_today() + 1), "tomorrow not opened by the tick");
        assertGe(_count(SpendWallet.applyGrant.selector), 1, "pre-grants start on the first tick");
        vm.warp(block.timestamp + 17 minutes);
        _react(_cron(TestnetConfig.CRON1000)); // the next tick finishes them
        assertEq(_count(SpendWallet.applyGrant.selector), 3, "one pre-grant per chain");
        _pump();
        assertGt(wallets[2].unspentOf(_today() + 1), 0);
    }

    function test_cronFromOtherTopicOrChainIgnored() public {
        vm.warp(block.timestamp + 17 hours);
        _react(_cron(TestnetConfig.CRON10000)); // not the subscribed topic
        LogRecord memory l = _cron(TestnetConfig.CRON1000);
        l.chainId = ids[0]; // a "cron" log from another chain
        _react(l);
        assertEq(sys.callbacks(), 0);
    }

    // ------------------------------------------------- every route, end to end

    /// Runs real wallet events through react() for every route: Short, LowWater, GrantApplied,
    /// Reclaimed, Verified (credit after the per-chain wait), StopPressed, EpochAck, Rolled,
    /// CapSet, Unstop, CancelAck, GrantNotApplied; books and wallets agree at the end.
    function test_everyRouteEndToEnd() public {
        uint64 t = _today();
        // Short x2 -> grants -> GrantApplied; pool empty
        _payAndPump(0, 10e6);
        _payAndPump(1, 10e6);
        assertEq(rc.poolOf(t), 0);
        // LowWater: chain 0 spends below the low-water mark
        for (uint256 k; k < 10; k++) {
            _payAndPump(0, 1e6);
        }
        // a want on chain 2 after the TTL: reclaims -> Reclaimed -> (wait) -> verify -> Verified
        vm.warp(block.timestamp + rc.chainParams(0).wantTtl + 1);
        _payAndPump(2, 5e6);
        assertGt(rc.pendingCount(), 0, "reclaims admitted as pending");
        vm.warp(block.timestamp + TestnetConfig.WAIT_OP_STACK + 1);
        _react(_cron(TestnetConfig.CRON1000));
        _pump();
        _react(_cron(TestnetConfig.CRON1000));
        _pump();
        assertGt(rc.poolOf(t) + wallets[2].unspentOf(t), 0, "a confirmed reclaim was credited");
        // CapSet from the console
        vm.prank(OWNER);
        console.setCap(30e6);
        _feed(address(console), ids[0]);
        assertEq(rc.cap(), 30e6);
        assertEq(rc.capOfDay(t), 30e6, "raise applies to today");
        // StopPressed on chain 1 -> frozen epoch -> EpochAck + Rolled from every chain
        vm.prank(OWNER);
        wallets[1].pressStop();
        _feed(address(wallets[1]), ids[1]);
        assertTrue(rc.frozen());
        _pump();
        for (uint256 c; c < 3; c++) {
            assertTrue(wallets[c].frozen(), "every wallet frozen");
        }
        // Unstop naming the frozen epoch
        uint64 e = rc.epoch();
        vm.prank(OWNER);
        console.unstop(e);
        _feed(address(console), ids[0]);
        assertFalse(rc.frozen());
        _pump();
        // CancelAck: a grant callback that never arrives is cancelled after the timeout
        vm.recordLogs();
        vm.prank(AGENT);
        wallets[0].pay(PAYEE, 9e6, bytes32("late"));
        _route(vm.getRecordedLogs());
        assertGt(sys.callbacks(), pumped, "grant requested");
        pumped = sys.callbacks(); // ... and lost
        vm.warp(block.timestamp + rc.chainParams(0).grantTimeout + 1);
        _react(_cron(TestnetConfig.CRON1000));
        _pump();
        // GrantNotApplied: a grant the vault can't fund
        Vault v2 = wallets[2].vault();
        vm.prank(OWNER);
        v2.withdraw(OWNER, 100 * CAP);
        _payAndPump(2, 3e6);
        vm.warp(block.timestamp + TestnetConfig.WAIT_SEPOLIA + 1);
        for (uint256 k; k < 4; k++) {
            _react(_cron(TestnetConfig.CRON1000));
            _pump();
        }
        // books vs wallets, for every chain
        for (uint8 c; c < 3; c++) {
            assertLe(wallets[c].unspentOf(t), rc.heldOf(t, c), "wallet allowance above held");
        }
        bytes32[13] memory all = [
            IWalletEvents.Short.selector,
            IWalletEvents.LowWater.selector,
            IWalletEvents.GrantApplied.selector,
            IWalletEvents.GrantNotApplied.selector,
            IWalletEvents.Reclaimed.selector,
            IWalletEvents.CancelAck.selector,
            IWalletEvents.Rolled.selector,
            IWalletEvents.EpochAck.selector,
            IWalletEvents.StopPressed.selector,
            IWalletEvents.Verified.selector,
            IConsoleEvents.CapSet.selector,
            IConsoleEvents.Unstop.selector,
            bytes32(TestnetConfig.CRON1000)
        ];
        for (uint256 i; i < all.length; i++) {
            assertGt(
                routed[uint256(all[i])], 0, string.concat("a react() route was never exercised: #", vm.toString(i))
            );
        }
        assertGt(rc.epochAcked(2), 0, "Sepolia epoch ack confirmed through Verified after its 16 min wait");
        assertEq(rc.epochAcked(0), 0, "Base ack still inside its 30 min wait");
    }

    // --------------------------------------------------------------- fees

    function test_feesOnlyTheVendorCollects_andAnyoneCanCoverDebt() public {
        vm.deal(address(rc), 1 ether);
        vm.expectRevert(bytes("vendor only"));
        rc.pay(1);
        vm.prank(address(sys));
        rc.pay(0.1 ether);
        assertEq(address(sys).balance, 0.1 ether);
        sys.setDebt(address(rc), 0.2 ether);
        rc.coverDebt();
        assertEq(address(sys).balance, 0.3 ether);
        // the front: proxy collects, owner withdraws the float
        vm.deal(address(fronts[0]), 1 ether);
        vm.expectRevert(bytes("vendor only"));
        fronts[0].pay(1);
        vm.prank(PROXY);
        fronts[0].pay(0.1 ether);
        vm.expectRevert(bytes("owner"));
        fronts[0].withdrawFees(payable(address(this)), 1);
        vm.prank(OWNER);
        fronts[0].withdrawFees(payable(OWNER), 0.5 ether);
        assertEq(OWNER.balance, 0.5 ether);
    }

    // -------------------------------------------------------------- front

    function test_frontRejectsWrongSenderWrongRcForeignSelectorsAndUnbound() public {
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

        // a front with no wallet bound refuses (instead of a silent, billed no-op)
        CallbackFront unbound = new CallbackFront(PROXY, address(rc), OWNER);
        vm.prank(PROXY);
        vm.expectRevert(bytes("unbound"));
        unbound.deliver(address(rc), inner);
    }

    function test_walletAcceptsCoordinatorMessagesOnlyFromItsFront() public {
        uint64 t = wallets[0].today();
        vm.expectRevert(bytes("bridge"));
        wallets[0].applyGrant(1, t, 1e6, 0);
    }

    // ------------------------------------------------------------- helpers

    function _innerSel(uint256 i) internal view returns (bytes4) {
        (, bytes memory inner) = abi.decode(_tail(sys.request(i).payload), (address, bytes));
        return bytes4(inner);
    }

    function _count(bytes4 sel) internal view returns (uint256 n) {
        for (uint256 i; i < sys.callbacks(); i++) {
            if (_innerSel(i) == sel) n++;
        }
    }

    function _first(bytes4 sel) internal view returns (uint256) {
        for (uint256 i; i < sys.callbacks(); i++) {
            if (_innerSel(i) == sel) return i;
        }
        revert("none");
    }

    function _today() internal view returns (uint64) {
        return uint64(block.timestamp / 1 days);
    }

    function _react(LogRecord memory l) internal {
        routed[l.topic0]++;
        vm.prank(address(sys));
        rc.react(l);
    }

    function _log(uint256 c, bytes32 t0, bytes memory data) internal view returns (LogRecord memory l) {
        l.chainId = ids[c];
        l.contractAddress = address(wallets[c]);
        l.topic0 = uint256(t0);
        l.data = data;
        l.opCode = 1;
    }

    function _cron(uint256 topic) internal view returns (LogRecord memory l) {
        l.chainId = block.chainid;
        l.contractAddress = 0x0000000000000000000000000000000000fffFfF;
        l.topic0 = topic;
        l.opCode = 1;
    }

    /// The agent pays on chain c; every log the wallet emits goes through react(); every
    /// resulting callback is delivered; repeat until quiet.
    function _payAndPump(uint8 c, uint256 amt) internal {
        vm.recordLogs();
        vm.prank(AGENT);
        wallets[c].pay(PAYEE, amt, bytes32(gasleft()));
        _route(vm.getRecordedLogs());
        _pump();
    }

    function _feed(address emitter, uint256 chainId) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != emitter) continue;
            _react(_toRecord(logs[i], chainId));
        }
    }

    function _pump() internal {
        for (uint256 guard; guard < 50 && pumped < sys.callbacks(); guard++) {
            CallbackConfiguration_V_1_0 memory r = sys.request(pumped++);
            uint256 c = r.chainId == ids[0] ? 0 : r.chainId == ids[1] ? 1 : 2;
            (, bytes memory inner) = abi.decode(_tail(r.payload), (address, bytes));
            vm.recordLogs();
            vm.prank(PROXY);
            (bool ok,) =
                address(fronts[c]).call{gas: r.gasLimit}(abi.encodeCall(CallbackFront.deliver, (address(rc), inner)));
            assertTrue(ok, "callback failed");
            _route(vm.getRecordedLogs());
        }
    }

    function _route(Vm.Log[] memory logs) internal {
        for (uint256 i; i < logs.length; i++) {
            for (uint256 c; c < 3; c++) {
                if (logs[i].emitter == address(wallets[c])) _react(_toRecord(logs[i], ids[c]));
            }
        }
    }

    function _toRecord(Vm.Log memory g, uint256 chainId) internal pure returns (LogRecord memory l) {
        l.chainId = chainId;
        l.contractAddress = g.emitter;
        l.topic0 = uint256(g.topics[0]);
        if (g.topics.length > 1) l.topic1 = uint256(g.topics[1]);
        if (g.topics.length > 2) l.topic2 = uint256(g.topics[2]);
        if (g.topics.length > 3) l.topic3 = uint256(g.topics[3]);
        l.data = g.data;
        l.opCode = g.topics.length;
    }

    function _tail(bytes memory cd) internal pure returns (bytes memory out) {
        out = new bytes(cd.length - 4);
        for (uint256 i; i < out.length; i++) {
            out[i] = cd[i + 4];
        }
    }
}
