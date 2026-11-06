// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console2} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {SpendWallet} from "../src/SpendWallet.sol";
import {Vault} from "../src/Vault.sol";
import {IWalletEvents} from "../src/interfaces/IPursestrings.sol";
import {PursestringsReactive} from "../src/reactive/PursestringsReactive.sol";
import {CallbackFront} from "../src/reactive/CallbackFront.sol";
import {TestnetConfig} from "../src/reactive/TestnetConfig.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";
import {MockSystem} from "../test/mocks/MockSystem.sol";

/// Read-only checks of a deployment (never broadcasts; needs no key):
///   run()           wiring: every address points where it must, on every chain (live or dry run)
///   simulateLoop()  dry run only: on forks of the local chains, plays the Reactive Network
///                   (the stand-in system contract records callback requests; the proxy is
///                   impersonated) and runs Short -> react -> grant callback -> wallet ->
///                   GrantApplied -> react through the deployed contracts.
/// Env: LASNA_RPC_URL, BASE_SEPOLIA_RPC_URL, UNICHAIN_SEPOLIA_RPC_URL, AGENT_ADDRESS,
///      DEPLOYMENTS_FILE (default deployments/latest.json).
contract Check is Script {
    address constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    string[2] keys = ["base", "unichain"];
    string[2] rpcs = ["BASE_SEPOLIA_RPC_URL", "UNICHAIN_SEPOLIA_RPC_URL"];
    address[2] proxies = [TestnetConfig.PROXY_BASE_SEPOLIA, TestnetConfig.PROXY_UNICHAIN_SEPOLIA];

    function _json() internal view returns (string memory) {
        return vm.readFile(vm.envOr("DEPLOYMENTS_FILE", string("deployments/latest.json")));
    }

    function _addr(string memory j, string memory path) internal pure returns (address) {
        return vm.parseJsonAddress(j, path);
    }

    function run() external {
        string memory j = _json();
        address rcAddr = _addr(j, ".coordinator");
        uint256[2] memory forks;
        for (uint256 i; i < 2; i++) {
            forks[i] = vm.createSelectFork(vm.envString(rpcs[i]));
            string memory k = string.concat(".", keys[i]);
            CallbackFront front = CallbackFront(payable(_addr(j, string.concat(k, ".front"))));
            SpendWallet wallet = SpendWallet(_addr(j, string.concat(k, ".wallet")));
            Vault vault = Vault(_addr(j, string.concat(k, ".vault")));
            require(front.rc() == rcAddr, "front does not pin the coordinator");
            require(front.proxy() == proxies[i], "front does not trust the callback proxy");
            require(front.wallet() == address(wallet), "front not bound to the wallet");
            require(wallet.bridge() == address(front), "wallet's bridge is not its front");
            require(address(wallet.vault()) == address(vault), "wallet's vault mismatch");
            require(vault.wallet() == address(wallet), "vault not bound to the wallet");
            require(address(wallet.token()) == _addr(j, string.concat(k, ".token")), "token mismatch");
            require(wallet.agent() == vm.envAddress("AGENT_ADDRESS"), "agent mismatch");
            console2.log(keys[i], "wiring ok, vault balance", vault.token().balanceOf(address(vault)));
        }
        vm.createSelectFork(vm.envString("LASNA_RPC_URL"));
        PursestringsReactive rc = PursestringsReactive(payable(rcAddr));
        require(rcAddr.code.length > 0, "no coordinator code on Lasna");
        for (uint256 i; i < 2; i++) {
            string memory k = string.concat(".", keys[i]);
            require(rc.wallets(i) == _addr(j, string.concat(k, ".wallet")), "coordinator's wallet mismatch");
            require(rc.fronts(i) == _addr(j, string.concat(k, ".front")), "coordinator's front mismatch");
            require(rc.chainIds(i) == vm.parseJsonUint(j, string.concat(k, ".chainId")), "chain id mismatch");
            require(rc.callbackGas(i) == TestnetConfig.CALLBACK_GAS_L2, "callback gas mismatch");
        }
        require(rc.console() == _addr(j, ".console"), "console mismatch");
        require(rc.cronTopic() == TestnetConfig.CRON1000, "cron topic mismatch");
        console2.log("coordinator wiring ok", rcAddr);
    }

    /// Dry run only (needs the stand-in system contract at 0x8888...8888 on the Lasna chain).
    function simulateLoop() external {
        string memory j = _json();
        require(vm.parseJsonBool(j, ".dryRun"), "simulateLoop is for the dry run only");
        PursestringsReactive rc = PursestringsReactive(payable(_addr(j, ".coordinator")));
        uint256 lasna = vm.createSelectFork(vm.envString("LASNA_RPC_URL"));
        MockSystem sys = MockSystem(payable(SYSTEM_ADDR));
        console2.log("subscriptions recorded by the system stand-in", sys.subscriptions());
        require(sys.subscriptions() == 2 * 10 + 2 + 1, "expected 23 subscriptions");
        uint256 before = sys.callbacks();

        // the agent on Base Sepolia is refused for $3: the wallet emits Short(day, 3e6, ts)
        uint256 base = vm.createSelectFork(vm.envString(rpcs[0]));
        SpendWallet wallet = SpendWallet(_addr(j, ".base.wallet"));
        CallbackFront front = CallbackFront(payable(_addr(j, ".base.front")));
        uint64 day = wallet.today();
        vm.recordLogs();
        vm.prank(vm.envAddress("AGENT_ADDRESS"));
        require(!wallet.pay(vm.envAddress("PAYEE_ADDRESS"), 3e6, bytes32("dry")), "expected a refusal");
        IReactive.LogRecord memory l = _record(vm.getRecordedLogs(), address(wallet), IWalletEvents.Short.selector);

        // Reactive delivers the log to the coordinator on Lasna
        vm.selectFork(lasna);
        vm.prank(SYSTEM_ADDR);
        rc.react(l);
        uint256 grantIdx = type(uint256).max;
        for (uint256 i = before; i < sys.callbacks(); i++) {
            ISystemContract.CallbackConfiguration_V_1_0 memory r = sys.request(i);
            (, bytes memory inner) = abi.decode(_tail(r.payload), (address, bytes));
            if (bytes4(inner) == SpendWallet.applyGrant.selector) grantIdx = i;
        }
        require(grantIdx != type(uint256).max, "no grant requested");
        ISystemContract.CallbackConfiguration_V_1_0 memory g = sys.request(grantIdx);
        require(g.recipient == address(front) && g.chainId == TestnetConfig.BASE_SEPOLIA, "grant routed wrong");
        console2.log("grant callback requested, gas limit", g.gasLimit);

        // the proxy delivers it to the front on Base Sepolia, injecting the coordinator's address
        vm.selectFork(base);
        (, bytes memory payload) = abi.decode(_tail(g.payload), (address, bytes));
        vm.recordLogs();
        vm.prank(TestnetConfig.PROXY_BASE_SEPOLIA);
        (bool ok,) = address(front).call{gas: g.gasLimit}(abi.encodeCall(CallbackFront.deliver, (address(rc), payload)));
        require(ok, "callback failed");
        require(wallet.unspentOf(day) >= 3e6, "allowance not applied");
        IReactive.LogRecord memory ack =
            _record(vm.getRecordedLogs(), address(wallet), IWalletEvents.GrantApplied.selector);
        uint256 unspent = wallet.unspentOf(day);
        console2.log("allowance on Base Sepolia after the grant", unspent);

        // the GrantApplied answer goes back to the coordinator
        vm.selectFork(lasna);
        vm.prank(SYSTEM_ADDR);
        rc.react(ack);
        require(rc.inflight(0) == 0, "grant still in flight after its answer");
        require(rc.heldOf(day, 0) >= unspent, "wallet allowance above the coordinator's held");
        console2.log("dry-run loop ok: Short -> react -> grant callback -> wallet -> GrantApplied -> react");
    }

    function _record(Vm.Log[] memory logs, address emitter, bytes32 t0)
        internal
        view
        returns (IReactive.LogRecord memory l)
    {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != emitter || logs[i].topics[0] != t0) continue;
            l.chainId = block.chainid;
            l.contractAddress = emitter;
            l.topic0 = uint256(t0);
            if (logs[i].topics.length > 1) l.topic1 = uint256(logs[i].topics[1]);
            if (logs[i].topics.length > 2) l.topic2 = uint256(logs[i].topics[2]);
            l.data = logs[i].data;
            l.opCode = logs[i].topics.length;
            return l;
        }
        revert("expected log not emitted");
    }

    function _tail(bytes memory cd) internal pure returns (bytes memory out) {
        out = new bytes(cd.length - 4);
        for (uint256 i; i < out.length; i++) {
            out[i] = cd[i + 4];
        }
    }
}
