// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";

/// Buys lREACT with Ethereum Sepolia ETH through Reactive's Sepolia faucet (1 ETH -> 100 lREACT, max 5 ETH per tx).
/// Key comes from DEPLOYER_PRIVATE_KEY in the environment, never from the command line.
/// forge script script/SepoliaFaucet.s.sol --sig "run(uint256)" <wei> --rpc-url $SEPOLIA_RPC_URL --broadcast
contract SepoliaFaucet is Script {
    address constant FAUCET = 0x9b9BB25f1A81078C544C829c5EB7822d747Cf434;

    function run(uint256 sepEthWei) external {
        require(sepEthWei <= 5 ether, "the faucet keeps anything above 5 ETH per tx");
        require(block.chainid == 11155111, "not Ethereum Sepolia");
        require(FAUCET.code.length > 0, "no faucet contract at the configured address");
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(pk);
        (bool ok,) = FAUCET.call{value: sepEthWei}(abi.encodeWithSignature("request(address)", vm.addr(pk)));
        require(ok, "faucet request failed");
        vm.stopBroadcast();
    }
}
