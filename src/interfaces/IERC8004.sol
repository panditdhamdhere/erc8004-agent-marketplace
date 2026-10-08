// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal ERC-8004 interfaces: only what the marketplace and its tests use.
/// Signatures follow the spec (eips.ethereum.org/EIPS/eip-8004) and match the
/// verified source of the deployed registries (github.com/erc-8004/erc-8004-contracts, v2.0.0).

/// @dev The Identity Registry is an ERC-721 (+ URIStorage). agentId == tokenId.
interface IIdentityRegistry {
    function register(string calldata agentURI) external returns (uint256 agentId);
    function getAgentWallet(uint256 agentId) external view returns (address);
    function setAgentWallet(
        uint256 agentId,
        address newWallet,
        uint256 deadline,
        bytes calldata signature
    ) external;

    // Standard ERC-721 functions, used to check who controls an agent.
    function ownerOf(uint256 agentId) external view returns (address);
    function getApproved(uint256 agentId) external view returns (address);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function setApprovalForAll(address operator, bool approved) external;
    function transferFrom(address from, address to, uint256 agentId) external;
}

interface IReputationRegistry {
    function giveFeedback(
        uint256 agentId,
        int128 value,
        uint8 valueDecimals,
        string calldata tag1,
        string calldata tag2,
        string calldata endpoint,
        string calldata feedbackURI,
        bytes32 feedbackHash
    ) external;

    function getSummary(
        uint256 agentId,
        address[] calldata clientAddresses,
        string calldata tag1,
        string calldata tag2
    ) external view returns (uint64 count, int128 summaryValue, uint8 summaryValueDecimals);

    function readFeedback(uint256 agentId, address clientAddress, uint64 feedbackIndex)
        external
        view
        returns (
            int128 value,
            uint8 valueDecimals,
            string memory tag1,
            string memory tag2,
            bool isRevoked
        );

    function getIdentityRegistry() external view returns (address);
}
