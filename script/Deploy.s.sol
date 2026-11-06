// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console2} from "forge-std/Script.sol";
import {BudgetCore} from "../src/BudgetCore.sol";
import {SpendWallet} from "../src/SpendWallet.sol";
import {Vault} from "../src/Vault.sol";
import {OwnerConsole} from "../src/OwnerConsole.sol";
import {IERC20Min} from "../src/interfaces/IPursestrings.sol";
import {PursestringsReactive} from "../src/reactive/PursestringsReactive.sol";
import {CallbackFront} from "../src/reactive/CallbackFront.sol";
import {TestnetConfig} from "../src/reactive/TestnetConfig.sol";
import {MockToken} from "../test/mocks/MockToken.sol";

/// Deploys Pursestrings to Lasna (coordinator) + Base Sepolia + Unichain Sepolia (wallets).
///
/// Order, and why addresses are predicted:
///   the fronts pin the coordinator's address (immutable), the wallets pin their front, and the
///   coordinator's constructor needs every wallet and front. So the coordinator's Lasna address
///   is predicted first from the deployer's Lasna nonce, both L2 sides are deployed against it,
///   and the coordinator is deployed last; the script stops if it didn't land at the predicted
///   address. Use a deployer key that sends nothing else on Lasna during the run.
///
/// Environment (names only; nothing secret is ever printed or written):
///   LASNA_RPC_URL, BASE_SEPOLIA_RPC_URL, UNICHAIN_SEPOLIA_RPC_URL
///   DEPLOYER_PRIVATE_KEY      read inside the script at run time (never on the command line)
///   AGENT_ADDRESS             the agent EOA allowed to call pay() (same agent on both chains)
///   PAYEE_ADDRESS             the demo API's payee, allowlisted on both wallets
///   USDC_BASE_SEPOLIA, USDC_UNICHAIN_SEPOLIA   the budget token on each L2 (not needed in dry run)
///   optional: CAP (default 20e6), PER_CALL (10e6), FLOOR (2e6), LOW (1e6),
///             FRONT_FUNDING_WEI (0), RC_FUNDING_WEI (0), DRY_RUN (false), DEPLOYMENTS_FILE
///
/// The deployer is also the owner (it binds vaults, fronts and payees in the same run).
/// DRY_RUN=true deploys a test token on each L2 instead of using USDC and funds each vault from it.
/// The dry run (script/dryrun.sh) runs this same script against three local anvil chains started
/// with the real chain ids, with a stand-in system contract at 0x8888...8888 on the Lasna one.
contract Deploy is Script {
    struct L2 {
        string name;
        string rpcEnv;
        address proxy;
        string tokenEnv;
        uint256 chainId;
        address token;
        address vault;
        address wallet;
        address front;
    }

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        bool dry = vm.envOr("DRY_RUN", false);
        address agent = vm.envAddress("AGENT_ADDRESS");
        address payee = vm.envAddress("PAYEE_ADDRESS");

        uint256 lasna = vm.createFork(vm.envString("LASNA_RPC_URL"));
        L2[2] memory l2;
        l2[0] = L2(
            "base",
            "BASE_SEPOLIA_RPC_URL",
            TestnetConfig.PROXY_BASE_SEPOLIA,
            "USDC_BASE_SEPOLIA",
            0,
            address(0),
            address(0),
            address(0),
            address(0)
        );
        l2[1] = L2(
            "unichain",
            "UNICHAIN_SEPOLIA_RPC_URL",
            TestnetConfig.PROXY_UNICHAIN_SEPOLIA,
            "USDC_UNICHAIN_SEPOLIA",
            0,
            address(0),
            address(0),
            address(0),
            address(0)
        );

        // 1. predict the coordinator's address on Lasna
        vm.selectFork(lasna);
        require(block.chainid == TestnetConfig.LASNA, "LASNA_RPC_URL is not Lasna");
        uint64 lasnaNonce = vm.getNonce(deployer);
        address rcPredicted = vm.computeCreateAddress(deployer, lasnaNonce);
        console2.log("deployer", deployer);
        console2.log("coordinator predicted on Lasna at nonce", lasnaNonce, rcPredicted);

        // 2. each L2: (home chain only) console, then front -> vault -> wallet, then bind
        address consoleAddr;
        for (uint256 i; i < 2; i++) {
            vm.createSelectFork(vm.envString(l2[i].rpcEnv));
            l2[i].chainId = block.chainid;
            require(
                block.chainid == (i == 0 ? TestnetConfig.BASE_SEPOLIA : TestnetConfig.UNICHAIN_SEPOLIA),
                "L2 RPC points at the wrong chain"
            );
            vm.startBroadcast(pk);
            if (i == 0) consoleAddr = address(new OwnerConsole(deployer));
            l2[i].token = dry ? address(new MockToken()) : vm.envAddress(l2[i].tokenEnv);
            CallbackFront front =
                new CallbackFront{value: vm.envOr("FRONT_FUNDING_WEI", uint256(0))}(l2[i].proxy, rcPredicted, deployer);
            Vault vault = new Vault(IERC20Min(l2[i].token), deployer);
            SpendWallet wallet = new SpendWallet(
                IERC20Min(l2[i].token),
                vault,
                address(front),
                deployer,
                agent,
                vm.envOr("PER_CALL", uint256(10e6)),
                vm.envOr("FLOOR", uint256(2e6)),
                vm.envOr("LOW", uint256(1e6))
            );
            vault.bind(address(wallet));
            front.bind(address(wallet));
            wallet.setPayee(payee, true);
            if (dry) MockToken(l2[i].token).mint(address(vault), 100e6);
            vm.stopBroadcast();
            l2[i].front = address(front);
            l2[i].vault = address(vault);
            l2[i].wallet = address(wallet);
        }

        // 3. the coordinator on Lasna, at the predicted address
        vm.selectFork(lasna);
        require(vm.getNonce(deployer) == lasnaNonce, "deployer nonce on Lasna changed: predicted address is stale");
        PursestringsReactive.Wiring memory w;
        w.homeChainId = l2[0].chainId;
        w.console = consoleAddr;
        w.cronTopic = TestnetConfig.CRON1000;
        w.chainIds = new uint256[](2);
        w.wallets = new address[](2);
        w.fronts = new address[](2);
        w.callbackGas = new uint64[](2);
        BudgetCore.Params memory p;
        p.nChains = 2;
        p.cap = vm.envOr("CAP", uint256(20e6));
        p.keepFloor = vm.envOr("FLOOR", uint256(2e6));
        p.pregrantWindow = 2 hours;
        p.heartbeat = TestnetConfig.HEARTBEAT;
        p.chains = new BudgetCore.ChainParams[](2);
        for (uint256 i; i < 2; i++) {
            w.chainIds[i] = l2[i].chainId;
            w.wallets[i] = l2[i].wallet;
            w.fronts[i] = l2[i].front;
            w.callbackGas[i] = TestnetConfig.CALLBACK_GAS_L2;
            p.chains[i] = TestnetConfig.chainParams(TestnetConfig.WAIT_OP_STACK);
        }
        vm.startBroadcast(pk);
        PursestringsReactive rc = new PursestringsReactive{value: vm.envOr("RC_FUNDING_WEI", uint256(0))}(p, w);
        vm.stopBroadcast();
        require(address(rc) == rcPredicted, "coordinator not at the predicted address: redeploy the L2 sides");

        // 4. record the addresses (no secrets)
        string memory j = "deploy";
        vm.serializeAddress(j, "coordinator", address(rc));
        vm.serializeUint(j, "lasnaChainId", block.chainid);
        vm.serializeAddress(j, "console", consoleAddr);
        for (uint256 i; i < 2; i++) {
            string memory k = l2[i].name;
            vm.serializeUint(k, "chainId", l2[i].chainId);
            vm.serializeAddress(k, "token", l2[i].token);
            vm.serializeAddress(k, "vault", l2[i].vault);
            vm.serializeAddress(k, "wallet", l2[i].wallet);
            vm.serializeAddress(k, "front", l2[i].front);
            string memory obj = vm.serializeAddress(k, "proxy", l2[i].proxy);
            vm.serializeString(j, k, obj);
        }
        string memory out = vm.serializeBool(j, "dryRun", dry);
        string memory file = vm.envOr("DEPLOYMENTS_FILE", string("deployments/latest.json"));
        vm.writeJson(out, file);
        console2.log("coordinator", address(rc));
        console2.log("addresses written to", file);
    }
}
