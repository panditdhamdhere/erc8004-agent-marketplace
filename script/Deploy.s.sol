// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AgentMarketplace} from "../src/AgentMarketplace.sol";
import {IIdentityRegistry, IReputationRegistry} from "../src/interfaces/IERC8004.sol";

/// @notice Deploys AgentMarketplace next to the official ERC-8004 registries.
/// Dry run (no keys, nothing sent):
///   forge script script/Deploy.s.sol --rpc-url $ETH_RPC_URL
/// Real deploy to Sepolia with a Foundry keystore account:
///   forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL --account <name> --broadcast
contract Deploy is Script {
    function run() external returns (AgentMarketplace market) {
        (address identity, address reputation) = registries(block.chainid);
        vm.startBroadcast();
        market = new AgentMarketplace(IIdentityRegistry(identity), IReputationRegistry(reputation));
        vm.stopBroadcast();
        console.log("AgentMarketplace:", address(market));
    }

    /// @dev Addresses from github.com/erc-8004/erc-8004-contracts. Mainnets share one pair,
    ///      testnets share another. Add your chain if it isn't listed.
    function registries(uint256 chainId)
        public
        pure
        returns (address identity, address reputation)
    {
        if (
            chainId == 1 // Ethereum
                || chainId == 8453 // Base
                || chainId == 42161 // Arbitrum One
                || chainId == 10 // OP Mainnet
                || chainId == 137 // Polygon
        ) {
            return (
                0x8004A169FB4a3325136EB29fA0ceB6D2e539a432,
                0x8004BAa17C55a88189AE136b182e5fdA19dE9b63
            );
        }
        if (
            chainId == 11155111 // Ethereum Sepolia
                || chainId == 84532 // Base Sepolia
        ) {
            return (
                0x8004A818BFB912233c491871b3d84c89A494BD9e,
                0x8004B663056A597Dffe9eCcC1965A193B7388713
            );
        }
        revert("ERC-8004 registries not configured for this chain");
    }
}
