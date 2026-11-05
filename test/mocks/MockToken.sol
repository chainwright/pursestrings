// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// Test-only budget token (6 decimals, reverts on insufficient balance like USDC).
/// It measures what the invariants check: every token that leaves a watched wallet for anywhere
/// other than that wallet's own vault, bucketed by the block-timestamp day of the transfer.
/// The count lives in the token, not in the wallet under test.
contract MockToken {
    uint256 public constant DAY = 1 days;
    mapping(address => uint256) public balanceOf;
    mapping(address => address) public vaultOf;
    mapping(address => mapping(uint64 => uint256)) public outflow;
    mapping(address => uint256) public outflowTotal;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function watch(address wallet, address vault) external {
        vaultOf[wallet] = vault;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        address v = vaultOf[msg.sender];
        if (v != address(0) && to != v) {
            outflow[msg.sender][uint64(block.timestamp / DAY)] += amount;
            outflowTotal[msg.sender] += amount;
        }
        return true;
    }
}
