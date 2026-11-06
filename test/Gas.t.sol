// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {BudgetCore} from "../src/BudgetCore.sol";
import {SpendWallet} from "../src/SpendWallet.sol";
import {Vault} from "../src/Vault.sol";
import {IERC20Min, IWalletEvents, K_RECLAIM} from "../src/interfaces/IPursestrings.sol";
import {PursestringsReactive} from "../src/reactive/PursestringsReactive.sol";
import {CallbackFront} from "../src/reactive/CallbackFront.sol";
import {TestnetConfig} from "../src/reactive/TestnetConfig.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {MockToken} from "./mocks/MockToken.sol";

/// Stand-in for the system contract when measuring react(): each callback request emits the
/// CallbackRequest event with the full configuration and writes two fresh storage slots. The
/// real contract's cost per request is not known to us; this is meant to be on the heavy side.
contract GasSystem is ISystemContract {
    event CallbackRequest(
        uint256 indexed chainId, address indexed sender, address indexed recipient, uint256 version, bytes configuration
    );

    uint256 public n;
    mapping(bytes32 => uint256) internal slots;

    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external {}

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {}

    function requestCallback(CallbackVersion, bytes memory) external pure {
        revert("unused");
    }

    receive() external payable {}

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory c) external {
        n++;
        slots[keccak256(abi.encode(n, 0))] = c.chainId;
        slots[keccak256(abi.encode(n, 1))] = c.gasLimit;
        emit CallbackRequest(c.chainId, msg.sender, c.recipient, 1, abi.encode(c));
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }
}

/// The reactive contract with a test-only way to fill its retry lists, every entry due.
contract StuffedReactive is PursestringsReactive {
    constructor(Params memory p, Wiring memory w) PursestringsReactive(p, w) {}

    function stuff(uint256 nGrants, uint256 nPending, uint256 nReclaims) external {
        uint64 t = _today();
        for (uint256 i; i < nGrants; i++) {
            uint256 id = nextId++;
            grants[id] = Grant(uint8(i % nChains), G_SENT, 0, t, epoch, 1, 1e6, false);
            inflight[uint8(i % nChains)]++;
            _liveGrants.push(id);
        }
        for (uint256 i; i < nPending; i++) {
            uint256 id = nextId++;
            bytes32 k = _key(K_RECLAIM, uint8(i % nChains), id);
            pending[k] = Pending(K_RECLAIM, uint8(i % nChains), 0, t, 1, 0, id, 1e6, 0);
            _pendingKeys.push(k);
            _pendingPos[k] = _pendingKeys.length;
        }
        for (uint256 i; i < nReclaims; i++) {
            uint256 id = nextId++;
            reclaims[id] = Reclaim(uint8(i % nChains), true, t, 1, 1e6);
            _liveReclaims.push(id);
        }
    }

    /// Stuffed entries whose retry has never been sent (grant never cancelled, re-read never asked).
    function unserviced() external view returns (uint256 g, uint256 p) {
        for (uint256 i; i < _liveGrants.length; i++) {
            if (grants[_liveGrants[i]].st == G_SENT) g++;
        }
        for (uint256 i; i < _pendingKeys.length; i++) {
            if (pending[_pendingKeys[i]].verifySentAt == 0) p++;
        }
    }

    function liveReclaimCount() external view returns (uint256) {
        return _liveReclaims.length;
    }
}

/// Gas: the worst wallet entry points through the front (cold), the callback gas they imply per
/// chain, and the worst react() with long retry lists. Numbers are printed with -vv.
contract GasTest is Test {
    address constant OWNER = address(0xA11CE);
    address constant AGENT = address(0xA6E47);
    address constant PROXY = address(0x9409);
    address constant RC = address(0x7C);
    uint256 constant T0 = 1_800_000_000 - (1_800_000_000 % 1 days);

    /// Allowance for USDC (FiatToken behind a proxy) vs our test token, per token call (transfer
    /// or balanceOf). Not measured: a deliberately generous budget.
    uint256 constant USDC_EXTRA_PER_TOKEN_CALL = 15_000;
    /// Token calls on the worst wallet path (applyGrant: 2 wallet balanceOf, vault balanceOf,
    /// vault transfer, flush transfer).
    uint256 constant TOKEN_CALLS = 5;
    uint256 constant LIMIT_REACT = 600_000; // Reactive's tx cap is 900,000

    MockToken token;
    Vault vault;
    SpendWallet wallet;
    CallbackFront front;
    uint256 nextMsg = 1;

    function _deployWallet() internal {
        token = new MockToken();
        vault = new Vault(IERC20Min(address(token)), OWNER);
        front = new CallbackFront(PROXY, RC, OWNER);
        wallet = new SpendWallet(IERC20Min(address(token)), vault, address(front), OWNER, AGENT, 10e6, 2e6, 1e6);
        vm.startPrank(OWNER);
        vault.bind(address(wallet));
        front.bind(address(wallet));
        vm.stopPrank();
        token.mint(address(vault), 1_000e6);
    }

    function _deliver(bytes memory payload) internal returns (uint256 used) {
        vm.cool(address(wallet));
        vm.cool(address(vault));
        vm.cool(address(token));
        vm.cool(address(front));
        uint256 g = gasleft();
        vm.prank(PROXY);
        front.deliver(RC, payload);
        used = g - gasleft();
    }

    function _grant(uint64 day, uint256 amount, uint64 e) internal returns (uint256) {
        return _deliver(abi.encodeCall(SpendWallet.applyGrant, (nextMsg++, day, amount, e)));
    }

    /// Worst states for each entry point, measured cold through the front.
    function _measureWorst() internal returns (uint256 worst) {
        uint256 snap = vm.snapshotState();
        uint256[6] memory m;

        // (1) applyGrant entering a new epoch: drains today's and tomorrow's buckets, pulls, flushes
        vm.warp(T0 + 23 hours);
        _deployWallet();
        _grant(uint64(block.timestamp / 1 days), 5e6, 0);
        _grant(uint64(block.timestamp / 1 days) + 1, 5e6, 0);
        m[0] = _grant(uint64(block.timestamp / 1 days), 5e6, 1);
        vm.revertToState(snap);

        // (2) applyGrant after an idle stretch: sweeps two past buckets, new epoch, pulls, flushes
        vm.warp(T0 + 23 hours);
        _deployWallet();
        _grant(uint64(block.timestamp / 1 days), 5e6, 0);
        _grant(uint64(block.timestamp / 1 days) + 1, 5e6, 0);
        vm.warp(block.timestamp + 3 days);
        m[1] = _grant(uint64(block.timestamp / 1 days), 5e6, 1);
        vm.revertToState(snap);

        // (3) applyEpoch freeze: drains today's and tomorrow's buckets, flushes
        vm.warp(T0 + 23 hours);
        _deployWallet();
        _grant(uint64(block.timestamp / 1 days), 5e6, 0);
        _grant(uint64(block.timestamp / 1 days) + 1, 5e6, 0);
        m[2] = _deliver(abi.encodeCall(SpendWallet.applyEpoch, (1, true, 0)));
        vm.revertToState(snap);

        // (4) applyEpoch after an idle stretch: sweeps two past buckets, new epoch, flushes
        vm.warp(T0 + 23 hours);
        _deployWallet();
        _grant(uint64(block.timestamp / 1 days), 5e6, 0);
        _grant(uint64(block.timestamp / 1 days) + 1, 5e6, 0);
        vm.warp(block.timestamp + 3 days);
        m[3] = _deliver(abi.encodeCall(SpendWallet.applyEpoch, (1, true, 0)));
        vm.revertToState(snap);

        // (5) applyReclaim, (6) applyCancel of an unseen grant, verify
        vm.warp(T0 + 12 hours);
        _deployWallet();
        uint64 d = uint64(block.timestamp / 1 days);
        _grant(d, 8e6, 0);
        m[4] = _deliver(abi.encodeCall(SpendWallet.applyReclaim, (nextMsg++, d, 5e6)));
        m[5] = _deliver(abi.encodeCall(SpendWallet.applyCancel, (nextMsg++, 999)));
        uint256 v = _deliver(abi.encodeCall(SpendWallet.verify, (K_RECLAIM, nextMsg - 2)));
        vm.revertToState(snap);

        console2.log("cold, through the front, test token:");
        console2.log("  applyGrant, new epoch, 2 buckets drained   ", m[0]);
        console2.log("  applyGrant, 2 past buckets swept, new epoch", m[1]);
        console2.log("  applyEpoch freeze, 2 buckets drained       ", m[2]);
        console2.log("  applyEpoch freeze, 2 past buckets swept    ", m[3]);
        console2.log("  applyReclaim / applyCancel / verify        ", m[4], m[5], v);
        for (uint256 i; i < 6; i++) {
            if (m[i] > worst) worst = m[i];
        }
        if (v > worst) worst = v;
    }

    /// The callback gasLimit per chain covers what the proxy withholds plus 1.5x the worst entry
    /// (with the USDC allowance).
    function test_gas_callbackLimitCoversWorstWalletEntry() public {
        uint256 worst = _measureWorst();
        uint256 need = (worst + USDC_EXTRA_PER_TOKEN_CALL * TOKEN_CALLS) * 3 / 2;
        console2.log("worst measured / with USDC allowance x1.5", worst, need);
        console2.log(
            "L2: withheld + need", TestnetConfig.WITHHELD_L2 + need, "configured", TestnetConfig.CALLBACK_GAS_L2
        );
        console2.log(
            "Sepolia: withheld + need",
            TestnetConfig.WITHHELD_SEPOLIA + need,
            "configured",
            TestnetConfig.CALLBACK_GAS_SEPOLIA
        );
        assertGe(TestnetConfig.CALLBACK_GAS_L2, TestnetConfig.WITHHELD_L2 + need, "L2 callback gas too low");
        assertGe(
            TestnetConfig.CALLBACK_GAS_SEPOLIA, TestnetConfig.WITHHELD_SEPOLIA + need, "Sepolia callback gas too low"
        );
    }

    /// Each worst-case entry runs within (callback gas - withheld) for the L2s, the tighter case.
    function test_gas_worstEntriesRunWithinTheCallbackBudget() public {
        uint256 avail = TestnetConfig.CALLBACK_GAS_L2 - TestnetConfig.WITHHELD_L2;
        vm.warp(T0 + 23 hours);
        _deployWallet();
        _grant(uint64(block.timestamp / 1 days), 5e6, 0);
        _grant(uint64(block.timestamp / 1 days) + 1, 5e6, 0);
        vm.warp(block.timestamp + 3 days);
        vm.cool(address(wallet));
        vm.cool(address(token));
        vm.prank(PROXY);
        (bool ok,) = address(front).call{gas: avail}(
            abi.encodeCall(CallbackFront.deliver, (RC, abi.encodeCall(SpendWallet.applyEpoch, (1, true, 0))))
        );
        assertTrue(ok && wallet.frozen(), "freeze did not fit");
        assertEq(wallet.stranded(), 0, "returns to the vault also fit");
    }

    /// The freeze never depends on a token transfer: with transfers to the vault failing, the
    /// wallet still freezes and drops its allowance; the tokens wait in `stranded` until a later
    /// flush succeeds.
    function test_freezeDoesNotDependOnTheTransfer() public {
        vm.warp(T0 + 12 hours);
        _deployWallet();
        uint64 d = uint64(block.timestamp / 1 days);
        _grant(d, 5e6, 0);
        vm.prank(OWNER);
        wallet.setPayee(address(0xBEEF), true);
        token.setBlocked(address(vault), true);
        _deliver(abi.encodeCall(SpendWallet.applyEpoch, (1, true, 0)));
        assertTrue(wallet.frozen(), "not frozen");
        assertEq(wallet.unspentOf(d), 0, "allowance survived the freeze");
        assertEq(wallet.stranded(), 5e6);
        vm.prank(AGENT);
        assertFalse(wallet.pay(address(0xBEEF), 1e6, bytes32(0)), "paid while frozen");
        token.setBlocked(address(vault), false);
        wallet.flush();
        assertEq(wallet.stranded(), 0);
        assertEq(token.balanceOf(address(vault)), 1_000e6);
    }

    /// F12: a token that delivers less than asked (fee-on-transfer) creates no allowance; what did
    /// arrive goes back to the vault, and the wallet's tokens stay exactly unspent + stranded.
    function test_shortDeliveryCreatesNoAllowance() public {
        vm.warp(T0 + 12 hours);
        _deployWallet();
        uint64 d = uint64(block.timestamp / 1 days);
        token.setFee(address(vault), 100); // the vault's transfers deliver 1% less
        vm.recordLogs();
        _grant(d, 5e6, 0);
        assertEq(wallet.unspentOf(d), 0, "allowance from a short delivery");
        assertEq(token.balanceOf(address(wallet)), wallet.liveUnspent() + wallet.stranded(), "tokens not accounted for");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool notApplied;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == IWalletEvents.GrantNotApplied.selector) notApplied = true;
        }
        assertTrue(notApplied, "the coordinator must hear 'not applied' to get its refund");
    }

    /// Bounded work carries over: with more due entries than one call may look at (12 grants to
    /// cancel, 12 returns to re-read, SCAN = 4), every one is serviced within a few Cron ticks.
    function test_retryListsCarryOverAcrossTicks() public {
        vm.warp(T0 + 12 hours);
        (StuffedReactive rc, GasSystem sys) = _stuffed(12, 12, 0);
        IReactive.LogRecord memory cron;
        cron.chainId = block.chainid;
        cron.contractAddress = 0x0000000000000000000000000000000000fffFfF;
        cron.topic0 = TestnetConfig.CRON1000;
        uint256 ticks;
        for (; ticks < 40; ticks++) {
            (uint256 g, uint256 p) = rc.unserviced();
            if (g == 0 && p == 0) break;
            vm.prank(address(sys));
            rc.react(cron);
            vm.warp(block.timestamp + 300);
        }
        (uint256 gLeft, uint256 pLeft) = rc.unserviced();
        console2.log("Cron ticks until every stuffed entry was serviced", ticks);
        assertEq(pLeft, 0, "a due re-read was never asked (pending cursor stuck?)");
        assertEq(gLeft, 0, "a due cancel was never sent (grant cursor stuck?)");
    }

    // ---------------------------------------------------------------- react()

    function _stuffed(uint256 nG, uint256 nP, uint256 nR) internal returns (StuffedReactive rc, GasSystem sys) {
        vm.etch(0x8888888888888888888888888888888888888888, address(new GasSystem()).code);
        sys = GasSystem(payable(0x8888888888888888888888888888888888888888));
        PursestringsReactive.Wiring memory w;
        w.homeChainId = 1;
        w.console = address(0xC0);
        w.chainIds = new uint256[](3);
        w.wallets = new address[](3);
        w.fronts = new address[](3);
        w.callbackGas = new uint64[](3);
        w.cronTopic = TestnetConfig.CRON1000;
        uint64[] memory waits = new uint64[](3);
        for (uint256 c; c < 3; c++) {
            w.chainIds[c] = 100 + c;
            w.wallets[c] = address(uint160(0x1000 + c));
            w.fronts[c] = address(uint160(0x2000 + c));
            w.callbackGas[c] = TestnetConfig.CALLBACK_GAS_L2;
            waits[c] = 60;
        }
        BudgetCore.Params memory p;
        p.nChains = 3;
        p.cap = 20e6;
        p.keepFloor = 2e6;
        p.pregrantWindow = 2 hours;
        p.heartbeat = TestnetConfig.HEARTBEAT;
        p.chains = new BudgetCore.ChainParams[](3);
        for (uint256 c; c < 3; c++) {
            p.chains[c] = BudgetCore.ChainParams({
                confirmWait: uint32(waits[c]), grantTimeout: 300, reclaimTimeout: 300, verifyTimeout: 120, wantTtl: 600
            });
        }
        rc = new StuffedReactive(p, w);
        rc.stuff(nG, nP, nR);
    }

    function _measureReact(StuffedReactive rc, GasSystem sys, IReactive.LogRecord memory l)
        internal
        returns (uint256 used)
    {
        vm.cool(address(rc));
        vm.cool(address(sys));
        uint256 g = gasleft();
        vm.prank(address(sys));
        rc.react(l);
        used = g - gasleft();
    }

    function _walletLog(uint256 c, bytes32 t0, bytes memory data) internal pure returns (IReactive.LogRecord memory l) {
        l.chainId = 100 + c;
        l.contractAddress = address(uint160(0x1000 + c));
        l.topic0 = uint256(t0);
        l.data = data;
        l.opCode = 1;
    }

    /// Worst react(): every retry list is long and due, a STOP arrives (one epoch message per
    /// chain first), then a Short late in the day (pre-grants + serving). Work per call is bounded,
    /// so the cost doesn't grow with the lists (32 vs 400 entries).
    function test_gas_reactWorstCaseIsBounded() public {
        vm.warp(T0 + 23 hours);
        uint256 worst;
        uint256[2] memory sizes = [uint256(32), 400];
        for (uint256 s; s < 2; s++) {
            uint256 snap = vm.snapshotState();
            (StuffedReactive rc, GasSystem sys) = _stuffed(sizes[s], sizes[s], sizes[s]);
            uint64 t = uint64(block.timestamp / 1 days);
            uint256 gShort = _measureReact(
                rc, sys, _walletLog(0, IWalletEvents.Short.selector, abi.encode(t, 5e6, uint64(block.timestamp)))
            );
            uint256 sent1 = sys.n();
            uint256 gStop =
                _measureReact(rc, sys, _walletLog(1, IWalletEvents.StopPressed.selector, abi.encode(uint64(7))));
            uint256 sent2 = sys.n() - sent1;
            IReactive.LogRecord memory cron;
            cron.chainId = block.chainid;
            cron.contractAddress = 0x0000000000000000000000000000000000fffFfF;
            cron.topic0 = TestnetConfig.CRON1000;
            uint256 gCron = _measureReact(rc, sys, cron);
            console2.log("list size", sizes[s]);
            console2.log("  react gas: Short (pre-grants+serve) / STOP / Cron", gShort, gStop, gCron);
            console2.log("  callback requests: Short / STOP", sent1, sent2);
            assertLe(sent1, rc.MAX_SENDS());
            assertLe(sent2, rc.MAX_SENDS());
            assertTrue(rc.frozen(), "STOP processed");
            if (gShort > worst) worst = gShort;
            if (gStop > worst) worst = gStop;
            if (gCron > worst) worst = gCron;
            vm.revertToState(snap);
        }
        console2.log("worst react() gas", worst, "limit asserted", LIMIT_REACT);
        assertLe(worst, LIMIT_REACT, "react() too heavy");
    }
}
