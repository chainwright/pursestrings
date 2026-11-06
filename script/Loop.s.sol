// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console2} from "forge-std/Script.sol";
import {SpendWallet} from "../src/SpendWallet.sol";
import {OwnerConsole} from "../src/OwnerConsole.sol";
import {PursestringsReactive} from "../src/reactive/PursestringsReactive.sol";
import {TestnetConfig} from "../src/reactive/TestnetConfig.sol";
import {IERC20Min} from "../src/interfaces/IPursestrings.sol";

/// Origin transactions for the live loop, one per call (forge script ... --sig "<fn>(...)"
/// --broadcast). Keys are read inside the script from environment variables at run time and are
/// never on the command line: AGENT_PRIVATE_KEY for payments, DEPLOYER_PRIVATE_KEY (the owner)
/// for STOP and unstop. RPC URLs from LASNA_RPC_URL / BASE_SEPOLIA_RPC_URL /
/// UNICHAIN_SEPOLIA_RPC_URL; addresses from DEPLOYMENTS_FILE (default deployments/latest.json).
/// chain: 0 = Base Sepolia, 1 = Unichain Sepolia. Amounts in USDC base units (6 decimals).
contract Loop is Script {
    string[2] keys = ["base", "unichain"];
    string[2] rpcs = ["BASE_SEPOLIA_RPC_URL", "UNICHAIN_SEPOLIA_RPC_URL"];

    function _wallet(uint256 chain) internal returns (SpendWallet) {
        string memory j = vm.readFile(vm.envOr("DEPLOYMENTS_FILE", string("deployments/latest.json")));
        vm.createSelectFork(vm.envString(rpcs[chain]));
        return SpendWallet(vm.parseJsonAddress(j, string.concat(".", keys[chain], ".wallet")));
    }

    /// The agent asks for `amount` on `chain`. With less allowance than that, the wallet refuses
    /// and emits Short: the top-up path's origin event. With enough, it pays (to consume budget).
    function pay(uint256 chain, uint256 amount) external {
        SpendWallet w = _wallet(chain);
        uint64 d = w.today();
        console2.log("chain / unspent before", chain, w.unspentOf(d));
        vm.startBroadcast(vm.envUint("AGENT_PRIVATE_KEY"));
        bool ok = w.pay(vm.envAddress("PAYEE_ADDRESS"), amount, keccak256(abi.encode(block.timestamp, amount)));
        vm.stopBroadcast();
        console2.log(ok ? "paid" : "refused (Short emitted if over allowance)", amount);
    }

    /// The owner presses STOP on `chain`: the STOP path's origin event.
    function stop(uint256 chain) external {
        SpendWallet w = _wallet(chain);
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        w.pressStop();
        vm.stopBroadcast();
        console2.log("STOP pressed on chain", chain);
    }

    /// The owner lifts the current frozen epoch (read from the coordinator on Lasna) through the
    /// console on Base Sepolia.
    function unstop() external {
        string memory j = vm.readFile(vm.envOr("DEPLOYMENTS_FILE", string("deployments/latest.json")));
        vm.createSelectFork(vm.envString("LASNA_RPC_URL"));
        PursestringsReactive rc = PursestringsReactive(payable(vm.parseJsonAddress(j, ".coordinator")));
        require(rc.frozen(), "not frozen");
        uint64 e = rc.epoch();
        vm.createSelectFork(vm.envString(rpcs[0]));
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        OwnerConsole(vm.parseJsonAddress(j, ".console")).unstop(e);
        vm.stopBroadcast();
        console2.log("unstop sent for epoch", e);
    }

    /// Fee reserves: `rcWei` lREACT for the coordinator via the system contract's depositTo, and
    /// `frontWei` ETH for each front via its callback proxy's depositTo (DOCS_BRIEF section 5;
    /// the depositTo signature is from the docs, not from reactive-lib-omni, which doesn't declare
    /// it). Sent by the deployer.
    function fundReserves(uint256 rcWei, uint256 frontWei) external {
        string memory j = vm.readFile(vm.envOr("DEPLOYMENTS_FILE", string("deployments/latest.json")));
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address[2] memory proxies = [TestnetConfig.PROXY_BASE_SEPOLIA, TestnetConfig.PROXY_UNICHAIN_SEPOLIA];
        if (rcWei > 0) {
            vm.createSelectFork(vm.envString("LASNA_RPC_URL"));
            require(address(0x8888888888888888888888888888888888888888).code.length > 0, "no system contract");
            vm.startBroadcast(pk);
            (bool ok,) = address(0x8888888888888888888888888888888888888888).call{value: rcWei}(
                abi.encodeWithSignature("depositTo(address)", vm.parseJsonAddress(j, ".coordinator"))
            );
            require(ok, "depositTo(coordinator) failed");
            vm.stopBroadcast();
        }
        for (uint256 i; i < 2 && frontWei > 0; i++) {
            vm.createSelectFork(vm.envString(rpcs[i]));
            // a call to an address without code "succeeds" and would swallow the deposit
            require(proxies[i].code.length > 0, "no callback proxy code at the configured address");
            vm.startBroadcast(pk);
            (bool ok,) = proxies[i].call{value: frontWei}(
                abi.encodeWithSignature(
                    "depositTo(address)", vm.parseJsonAddress(j, string.concat(".", keys[i], ".front"))
                )
            );
            require(ok, "depositTo(front) failed");
            vm.stopBroadcast();
        }
    }

    /// Moves `amount` of the budget token from the deployer to the vault on `chain`.
    function fundVault(uint256 chain, uint256 amount) external {
        string memory j = vm.readFile(vm.envOr("DEPLOYMENTS_FILE", string("deployments/latest.json")));
        vm.createSelectFork(vm.envString(rpcs[chain]));
        string memory k = string.concat(".", keys[chain]);
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        require(
            IERC20Min(vm.parseJsonAddress(j, string.concat(k, ".token")))
                .transfer(vm.parseJsonAddress(j, string.concat(k, ".vault")), amount),
            "transfer"
        );
        vm.stopBroadcast();
    }

    /// The owner sets the daily cap through the console on Base Sepolia (a raise applies today).
    function setCap(uint256 cap) external {
        string memory j = vm.readFile(vm.envOr("DEPLOYMENTS_FILE", string("deployments/latest.json")));
        vm.createSelectFork(vm.envString(rpcs[0]));
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        OwnerConsole(vm.parseJsonAddress(j, ".console")).setCap(cap);
        vm.stopBroadcast();
    }

    /// lREACT from the Reactive testnet faucet: sends `sepEthWei` Base Sepolia ETH to the faucet
    /// contract (DOCS_BRIEF section 4: 1 ETH -> 100 lREACT, at most 5 ETH per tx, anything above
    /// is lost), credited to the deployer on Lasna.
    function faucet(uint256 sepEthWei) external {
        require(sepEthWei <= 5 ether, "the faucet keeps anything above 5 ETH per tx");
        address f = 0x2afaFD298b23b62760711756088F75B7409f5967;
        vm.createSelectFork(vm.envString(rpcs[0]));
        require(f.code.length > 0, "no faucet contract at the configured address");
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(pk);
        (bool ok,) = f.call{value: sepEthWei}(abi.encodeWithSignature("request(address)", vm.addr(pk)));
        require(ok, "faucet request failed");
        vm.stopBroadcast();
    }
}
