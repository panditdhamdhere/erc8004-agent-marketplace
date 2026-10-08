// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentMarketplace} from "../src/AgentMarketplace.sol";
import {IIdentityRegistry, IReputationRegistry} from "../src/interfaces/IERC8004.sol";

/// @dev ERC-5267, exposed by the Identity Registry (used to sign the agentWallet proof).
interface IERC5267 {
    function eip712Domain()
        external
        view
        returns (bytes1, string memory, string memory, uint256, address, bytes32, uint256[] memory);
}

/// @notice Every test forks Ethereum mainnet and talks to the official ERC-8004 registries.
contract AgentMarketplaceForkTest is Test {
    // Official ERC-8004 registries (same addresses on Ethereum mainnet and many L2s)
    IIdentityRegistry constant IDENTITY =
        IIdentityRegistry(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432);
    IReputationRegistry constant REPUTATION =
        IReputationRegistry(0x8004BAa17C55a88189AE136b182e5fdA19dE9b63);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    AgentMarketplace market;

    address client = makeAddr("client");
    address agentOwner = makeAddr("agentOwner");
    address stranger = makeAddr("stranger");
    uint256 agentId;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com")));
        market = new AgentMarketplace(IDENTITY, REPUTATION);

        // Clean slate: on a live fork, any address can already hold dust ETH.
        vm.deal(address(market), 0);
        vm.deal(agentOwner, 0);

        // A brand-new agent on the real Identity Registry (mints an ERC-721)
        vm.prank(agentOwner);
        agentId = IDENTITY.register("ipfs://bafy.../agent.json");

        vm.deal(client, 100 ether);
    }

    // ─────────────────────────────── helpers ───────────────────────────────

    function _postEthJob(uint256 amount, uint64 minReviews, uint8 minScore)
        internal
        returns (uint256)
    {
        vm.prank(client);
        return market.postJob{value: amount}(
            address(0),
            amount,
            uint64(block.timestamp + 1 days),
            minReviews,
            minScore,
            "ipfs://job-spec"
        );
    }

    function _status(uint256 jobId) internal view returns (AgentMarketplace.Status status) {
        (,,,,,,, status,,,) = market.jobs(jobId);
    }

    /// @dev Full job for `id`, rated `rating` by the client.
    function _completeJob(uint256 id, uint8 rating) internal {
        uint256 jobId = _postEthJob(0.1 ether, 0, 0);
        vm.prank(IDENTITY.ownerOf(id));
        market.acceptJob(jobId, id);
        vm.prank(client);
        market.complete(jobId, rating, "", bytes32(0));
    }

    // ─────────────────────────────── happy paths ───────────────────────────────

    function test_HappyPath_ETH() public {
        uint256 jobId = _postEthJob(1 ether, 0, 0);
        assertEq(address(market).balance, 1 ether, "escrowed");

        vm.prank(agentOwner);
        market.acceptJob(jobId, agentId);

        vm.prank(agentOwner);
        market.submitWork(jobId, "ipfs://deliverable");

        vm.prank(client);
        market.complete(jobId, 92, "ipfs://feedback.json", bytes32(0));

        // Payment went to the agent's wallet (defaults to the owner)
        assertEq(agentOwner.balance, 1 ether, "agent paid");
        assertEq(address(market).balance, 0, "escrow empty");
        assertEq(uint8(_status(jobId)), uint8(AgentMarketplace.Status.Completed));

        // The rating is on the real ERC-8004 Reputation Registry, written by the marketplace
        (int128 value, uint8 decimals, string memory tag1, string memory tag2, bool revoked) =
            REPUTATION.readFeedback(agentId, address(market), 1);
        assertEq(value, 92);
        assertEq(decimals, 0);
        assertEq(tag1, "starred");
        assertEq(tag2, "escrow-job");
        assertFalse(revoked);

        (uint64 count, int128 score) = market.agentScore(agentId);
        assertEq(count, 1);
        assertEq(score, 92);
    }

    function test_HappyPath_USDC() public {
        deal(address(USDC), client, 500e6);

        vm.startPrank(client);
        USDC.approve(address(market), 250e6);
        uint256 jobId = market.postJob(
            address(USDC), 250e6, uint64(block.timestamp + 1 days), 0, 0, "ipfs://job-spec"
        );
        vm.stopPrank();
        assertEq(USDC.balanceOf(address(market)), 250e6, "escrowed");

        vm.prank(agentOwner);
        market.acceptJob(jobId, agentId);
        vm.prank(client);
        market.complete(jobId, 80, "", bytes32(0));

        assertEq(USDC.balanceOf(agentOwner), 250e6, "agent paid in USDC");
        assertEq(USDC.balanceOf(client), 250e6, "client keeps the rest");
        (uint64 count, int128 score) = market.agentScore(agentId);
        assertEq(count, 1);
        assertEq(score, 80);
    }

    function test_PaysVerifiedAgentWallet() public {
        // The agent owner proves control of a separate payout wallet (EIP-712), per the spec.
        (address wallet, uint256 walletKey) = makeAddrAndKey("agentWallet");
        uint256 sigDeadline = block.timestamp + 2 minutes;
        (, string memory name, string memory version,,,,) =
            IERC5267(address(IDENTITY)).eip712Domain();
        bytes32 domain = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                block.chainid,
                address(IDENTITY)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "AgentWalletSet(uint256 agentId,address newWallet,address owner,uint256 deadline)"
                ),
                agentId,
                wallet,
                agentOwner,
                sigDeadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(walletKey, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        vm.prank(agentOwner);
        IDENTITY.setAgentWallet(agentId, wallet, sigDeadline, abi.encodePacked(r, s, v));
        assertEq(IDENTITY.getAgentWallet(agentId), wallet);

        uint256 jobId = _postEthJob(1 ether, 0, 0);
        vm.prank(agentOwner);
        market.acceptJob(jobId, agentId);
        vm.prank(client);
        market.complete(jobId, 100, "", bytes32(0));

        assertEq(wallet.balance, 1 ether, "paid to agentWallet");
        assertEq(agentOwner.balance, 0, "not to the owner");
    }

    function test_ApprovedOperatorCanAcceptForAgent() public {
        address operator = makeAddr("operator");
        vm.prank(agentOwner);
        IDENTITY.setApprovalForAll(operator, true);

        uint256 jobId = _postEthJob(1 ether, 0, 0);
        vm.prank(operator);
        market.acceptJob(jobId, agentId);

        vm.prank(client);
        market.complete(jobId, 75, "", bytes32(0));
        assertEq(agentOwner.balance, 1 ether, "payment still goes to the agent's wallet");
    }

    // ─────────────────────────────── identity gate ───────────────────────────────

    function test_RevertWhen_AgentNotRegistered() public {
        uint256 jobId = _postEthJob(1 ether, 0, 0);
        uint256 fakeId = type(uint256).max; // never minted on the Identity Registry

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(AgentMarketplace.AgentNotRegistered.selector, fakeId)
        );
        market.acceptJob(jobId, fakeId);
    }

    function test_RevertWhen_CallerDoesNotControlAgent() public {
        uint256 jobId = _postEthJob(1 ether, 0, 0);

        // A stranger tries to take the job using someone else's agentId
        vm.prank(stranger);
        vm.expectRevert(AgentMarketplace.NotAgentOperator.selector);
        market.acceptJob(jobId, agentId);
    }

    // ─────────────────────────────── refunds & timeouts ───────────────────────────────

    function test_Refund_AfterDeadline_WhenAgentNeverDelivers() public {
        uint256 jobId = _postEthJob(1 ether, 0, 0);
        vm.prank(agentOwner);
        market.acceptJob(jobId, agentId);

        // Too early: the agent still has time
        vm.prank(client);
        vm.expectRevert(AgentMarketplace.TooEarly.selector);
        market.refund(jobId);

        vm.warp(block.timestamp + 1 days + 1);
        uint256 before = client.balance;
        vm.prank(client);
        market.refund(jobId);

        assertEq(client.balance, before + 1 ether, "client refunded");
        assertEq(uint8(_status(jobId)), uint8(AgentMarketplace.Status.Refunded));

        // And the agent can't deliver late
        vm.prank(agentOwner);
        vm.expectRevert(AgentMarketplace.WrongStatus.selector);
        market.submitWork(jobId, "ipfs://too-late");
    }

    function test_Refund_OpenJob_AnyTime() public {
        uint256 jobId = _postEthJob(1 ether, 0, 0);
        uint256 before = client.balance;
        vm.prank(client);
        market.refund(jobId);
        assertEq(client.balance, before + 1 ether);

        vm.prank(agentOwner);
        vm.expectRevert(AgentMarketplace.WrongStatus.selector);
        market.acceptJob(jobId, agentId);
    }

    function test_RevertWhen_RefundAfterWorkSubmitted() public {
        uint256 jobId = _postEthJob(1 ether, 0, 0);
        vm.startPrank(agentOwner);
        market.acceptJob(jobId, agentId);
        market.submitWork(jobId, "ipfs://deliverable");
        vm.stopPrank();

        vm.warp(block.timestamp + 2 days);
        vm.prank(client);
        vm.expectRevert(AgentMarketplace.WrongStatus.selector);
        market.refund(jobId);
    }

    function test_AgentClaims_AfterReviewPeriod() public {
        uint256 jobId = _postEthJob(1 ether, 0, 0);
        vm.startPrank(agentOwner);
        market.acceptJob(jobId, agentId);
        market.submitWork(jobId, "ipfs://deliverable");

        vm.expectRevert(AgentMarketplace.TooEarly.selector);
        market.claim(jobId);

        vm.warp(block.timestamp + 3 days);
        market.claim(jobId);
        vm.stopPrank();

        assertEq(agentOwner.balance, 1 ether, "agent paid without a rating");
        (uint64 count,) = market.agentScore(agentId);
        assertEq(count, 0, "no rating written on a claim");
    }

    // ─────────────────────────────── self-review ───────────────────────────────

    function test_RevertWhen_OwnerReviewsOwnAgent_OnRegistry() public {
        // The ERC-8004 Reputation Registry itself blocks self-feedback
        vm.prank(agentOwner);
        vm.expectRevert(bytes("Self-feedback not allowed"));
        REPUTATION.giveFeedback(agentId, 100, 0, "starred", "escrow-job", "", "", bytes32(0));
    }

    function test_RevertWhen_ClientHiresOwnAgent() public {
        // The registry can't see who the client is (the marketplace writes the review),
        // so the marketplace blocks self-dealing itself.
        vm.deal(agentOwner, 1 ether);
        vm.prank(agentOwner);
        uint256 jobId = market.postJob{value: 1 ether}(
            address(0), 1 ether, uint64(block.timestamp + 1 days), 0, 0, "ipfs://job-spec"
        );

        vm.prank(agentOwner);
        vm.expectRevert(AgentMarketplace.SelfDealing.selector);
        market.acceptJob(jobId, agentId);
    }

    function test_FeedbackFailure_DoesNotBlockPayment() public {
        uint256 jobId = _postEthJob(1 ether, 0, 0);
        vm.prank(agentOwner);
        market.acceptJob(jobId, agentId);

        // Trick: the agent makes the marketplace its operator, so the registry now treats
        // the marketplace's review as self-feedback and reverts it.
        vm.prank(agentOwner);
        IDENTITY.setApprovalForAll(address(market), true);

        vm.expectEmit(true, true, false, true, address(market));
        emit AgentMarketplace.JobCompleted(jobId, agentId, 10, false);
        vm.prank(client);
        market.complete(jobId, 10, "", bytes32(0));

        assertEq(agentOwner.balance, 1 ether, "payment released anyway");
    }

    // ─────────────────────────────── reputation gate ───────────────────────────────

    function test_ReputationGate() public {
        // A job that needs at least 1 marketplace review averaging 80+
        uint256 gated = _postEthJob(1 ether, 1, 80);

        // New agent: no history yet
        vm.prank(agentOwner);
        vm.expectRevert(abi.encodeWithSelector(AgentMarketplace.ReputationTooLow.selector, 0, 0));
        market.acceptJob(gated, agentId);

        // A second agent does one job badly (rated 40)
        address badOwner = makeAddr("badOwner");
        vm.prank(badOwner);
        uint256 badAgent = IDENTITY.register("ipfs://bad-agent.json");
        _completeJob(badAgent, 40);
        vm.prank(badOwner);
        vm.expectRevert(abi.encodeWithSelector(AgentMarketplace.ReputationTooLow.selector, 1, 40));
        market.acceptJob(gated, badAgent);

        // Our agent does one job well (rated 90) and now qualifies
        _completeJob(agentId, 90);
        vm.prank(agentOwner);
        market.acceptJob(gated, agentId);
        assertEq(uint8(_status(gated)), uint8(AgentMarketplace.Status.Accepted));
    }

    function test_ReputationGate_IgnoresReviewsFromOutsideTheMarketplace() public {
        // 3 random wallets give the agent 100/100 directly on the registry (Sybil-style)...
        for (uint256 i; i < 3; i++) {
            vm.prank(makeAddr(string(abi.encodePacked("sybil", i))));
            REPUTATION.giveFeedback(agentId, 100, 0, "starred", "escrow-job", "", "", bytes32(0));
        }
        // ...but the marketplace only trusts reviews it wrote itself.
        (uint64 count,) = market.agentScore(agentId);
        assertEq(count, 0);

        uint256 gated = _postEthJob(1 ether, 1, 80);
        vm.prank(agentOwner);
        vm.expectRevert(abi.encodeWithSelector(AgentMarketplace.ReputationTooLow.selector, 0, 0));
        market.acceptJob(gated, agentId);
    }

    // ─────────────────────────────── access control & inputs ───────────────────────────────

    function test_RevertWhen_NotClientCompletes() public {
        uint256 jobId = _postEthJob(1 ether, 0, 0);
        vm.prank(agentOwner);
        market.acceptJob(jobId, agentId);

        vm.prank(agentOwner);
        vm.expectRevert(AgentMarketplace.NotClient.selector);
        market.complete(jobId, 100, "", bytes32(0));
    }

    function test_RevertWhen_StrangerActsForAgentOrClient() public {
        uint256 jobId = _postEthJob(1 ether, 0, 0);

        vm.prank(stranger);
        vm.expectRevert(AgentMarketplace.NotClient.selector);
        market.refund(jobId);

        vm.prank(agentOwner);
        market.acceptJob(jobId, agentId);

        vm.prank(stranger);
        vm.expectRevert(AgentMarketplace.NotAgentOperator.selector);
        market.submitWork(jobId, "ipfs://not-mine");

        vm.prank(agentOwner);
        market.submitWork(jobId, "ipfs://deliverable");
        vm.warp(block.timestamp + 3 days);

        vm.prank(stranger);
        vm.expectRevert(AgentMarketplace.NotAgentOperator.selector);
        market.claim(jobId);
    }

    function test_RevertWhen_AcceptOrSubmitAfterDeadline() public {
        uint256 late = _postEthJob(1 ether, 0, 0);
        uint256 slow = _postEthJob(1 ether, 0, 0);
        vm.prank(agentOwner);
        market.acceptJob(slow, agentId);

        vm.warp(block.timestamp + 1 days);
        vm.startPrank(agentOwner);
        vm.expectRevert(AgentMarketplace.DeadlinePassed.selector);
        market.acceptJob(late, agentId);
        vm.expectRevert(AgentMarketplace.DeadlinePassed.selector);
        market.submitWork(slow, "ipfs://too-late");
        vm.stopPrank();
    }

    function test_RevertWhen_CompletedTwice() public {
        uint256 jobId = _postEthJob(1 ether, 0, 0);
        vm.prank(agentOwner);
        market.acceptJob(jobId, agentId);
        vm.startPrank(client);
        market.complete(jobId, 90, "", bytes32(0));
        vm.expectRevert(AgentMarketplace.WrongStatus.selector);
        market.complete(jobId, 90, "", bytes32(0));
        vm.stopPrank();
    }

    function test_RevertWhen_BadInputs() public {
        uint64 deadline = uint64(block.timestamp + 1 days);
        vm.startPrank(client);

        vm.expectRevert(AgentMarketplace.ZeroAmount.selector);
        market.postJob(address(0), 0, deadline, 0, 0, "");

        vm.expectRevert(AgentMarketplace.WrongValue.selector);
        market.postJob{value: 0.5 ether}(address(0), 1 ether, deadline, 0, 0, "");

        vm.expectRevert(AgentMarketplace.WrongValue.selector);
        market.postJob{value: 1 ether}(address(USDC), 1e6, deadline, 0, 0, "");

        vm.expectRevert(AgentMarketplace.BadDeadline.selector);
        market.postJob{value: 1 ether}(address(0), 1 ether, uint64(block.timestamp), 0, 0, "");

        vm.expectRevert(AgentMarketplace.BadScore.selector);
        market.postJob{value: 1 ether}(address(0), 1 ether, deadline, 1, 101, "");
        vm.stopPrank();

        uint256 jobId = _postEthJob(1 ether, 0, 0);
        vm.prank(agentOwner);
        market.acceptJob(jobId, agentId);
        vm.prank(client);
        vm.expectRevert(AgentMarketplace.BadScore.selector);
        market.complete(jobId, 101, "", bytes32(0));
    }

    function test_RevertWhen_WrongRegistryPair() public {
        vm.expectRevert(AgentMarketplace.RegistryMismatch.selector);
        new AgentMarketplace(IIdentityRegistry(address(USDC)), REPUTATION);
    }

    // ─────────────────────────────── fuzz ───────────────────────────────

    function testFuzz_EscrowAndRating(uint96 amount, uint8 rating) public {
        amount = uint96(bound(amount, 1, 100 ether));
        rating = uint8(bound(rating, 0, 100));

        uint256 jobId = _postEthJob(amount, 0, 0);
        vm.prank(agentOwner);
        market.acceptJob(jobId, agentId);
        vm.prank(client);
        market.complete(jobId, rating, "", bytes32(0));

        assertEq(agentOwner.balance, amount);
        assertEq(address(market).balance, 0);
        (uint64 count, int128 score) = market.agentScore(agentId);
        assertEq(count, 1);
        assertEq(score, int128(uint128(rating)));
    }
}
