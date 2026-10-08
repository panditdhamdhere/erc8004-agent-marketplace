// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IIdentityRegistry, IReputationRegistry} from "./interfaces/IERC8004.sol";

/// @title AgentMarketplace
/// @author Tech with Pandit (youtube.com/@panditdhamdheretech)
/// @notice A trustless job board for AI agents, built on ERC-8004.
///   1. A client posts a job and escrows ETH or an ERC-20.
///   2. Only an agent registered in the ERC-8004 Identity Registry can accept it
///      (optionally gated by a minimum reputation).
///   3. The agent submits its work.
///   4. The client releases the payment and rates the agent. The marketplace writes that
///      rating to the ERC-8004 Reputation Registry.
///   If the agent never delivers, the client gets a refund after the deadline. If the client
///   goes silent after delivery, the agent can claim the payment after a review period.
/// @dev Demo code for a YouTube tutorial. Not audited. Plain ERC-20s only (no fee-on-transfer
///   or rebasing tokens). Disputes are out of scope; see the ERC-8004 Validation Registry.
contract AgentMarketplace is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────────────────────── Types ───────────────────────────────

    enum Status {
        None,
        Open, // posted, waiting for an agent
        Accepted, // an agent took it
        Submitted, // the agent delivered
        Completed, // paid out
        Refunded // money went back to the client
    }

    struct Job {
        address client;
        address token; // address(0) means ETH
        uint256 amount;
        uint64 deadline; // the agent must deliver before this
        uint64 submittedAt;
        uint64 minReviews; // reputation gate: 0 = no gate
        uint8 minScore; // reputation gate: minimum average rating, 0-100
        Status status;
        uint256 agentId;
        address payee; // agent wallet, locked when the job is accepted
        string specURI; // off-chain job description
    }

    // ─────────────────────────────── Storage ───────────────────────────────

    /// @dev Feedback tags. "starred" = quality rating 0-100 (the spec's own example).
    string public constant TAG1 = "starred";
    string public constant TAG2 = "escrow-job";
    uint64 public constant REVIEW_PERIOD = 3 days;

    IIdentityRegistry public immutable identity;
    IReputationRegistry public immutable reputation;

    uint256 public nextJobId = 1;
    mapping(uint256 jobId => Job) public jobs;

    // ─────────────────────────────── Events ───────────────────────────────

    event JobPosted(
        uint256 indexed jobId,
        address indexed client,
        address token,
        uint256 amount,
        uint64 deadline
    );
    event JobAccepted(uint256 indexed jobId, uint256 indexed agentId, address payee);
    event WorkSubmitted(uint256 indexed jobId, uint256 indexed agentId, string deliverableURI);
    event JobCompleted(
        uint256 indexed jobId, uint256 indexed agentId, uint8 rating, bool feedbackRecorded
    );
    event PaymentClaimed(uint256 indexed jobId, uint256 indexed agentId);
    event JobRefunded(uint256 indexed jobId, address indexed client);

    // ─────────────────────────────── Errors ───────────────────────────────

    error RegistryMismatch();
    error ZeroAmount();
    error BadDeadline();
    error BadScore();
    error WrongValue();
    error WrongStatus();
    error DeadlinePassed();
    error NotClient();
    error AgentNotRegistered(uint256 agentId);
    error NotAgentOperator();
    error SelfDealing();
    error ReputationTooLow(uint64 count, int128 score);
    error TooEarly();
    error TransferFailed();

    constructor(IIdentityRegistry identity_, IReputationRegistry reputation_) {
        // The Reputation Registry knows which Identity Registry it belongs to.
        if (reputation_.getIdentityRegistry() != address(identity_)) revert RegistryMismatch();
        identity = identity_;
        reputation = reputation_;
    }

    // ─────────────────────────────── Client ───────────────────────────────

    /// @notice Post a job and escrow the payment. token = address(0) for ETH.
    function postJob(
        address token,
        uint256 amount,
        uint64 deadline,
        uint64 minReviews,
        uint8 minScore,
        string calldata specURI
    ) external payable nonReentrant returns (uint256 jobId) {
        if (amount == 0) revert ZeroAmount();
        if (deadline <= block.timestamp) revert BadDeadline();
        if (minScore > 100) revert BadScore();
        if (token == address(0) ? msg.value != amount : msg.value != 0) revert WrongValue();

        jobId = nextJobId++;
        Job storage job = jobs[jobId];
        job.client = msg.sender;
        job.token = token;
        job.amount = amount;
        job.deadline = deadline;
        job.minReviews = minReviews;
        job.minScore = minScore;
        job.status = Status.Open;
        job.specURI = specURI;

        emit JobPosted(jobId, msg.sender, token, amount, deadline);

        if (token != address(0)) IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Release the payment and rate the agent (0-100). The rating goes to ERC-8004.
    /// @param feedbackURI  optional off-chain feedback file (e.g. ipfs://...)
    /// @param feedbackHash optional keccak256 of that file (not needed for IPFS)
    function complete(
        uint256 jobId,
        uint8 rating,
        string calldata feedbackURI,
        bytes32 feedbackHash
    ) external nonReentrant {
        Job storage job = jobs[jobId];
        if (msg.sender != job.client) revert NotClient();
        if (job.status != Status.Accepted && job.status != Status.Submitted) revert WrongStatus();
        if (rating > 100) revert BadScore();

        job.status = Status.Completed;

        // A failing feedback call must never block the agent's payment, so we use try/catch.
        bool recorded = false;
        try reputation.giveFeedback(
            job.agentId, int128(uint128(rating)), 0, TAG1, TAG2, "", feedbackURI, feedbackHash
        ) {
            recorded = true;
        } catch {}

        emit JobCompleted(jobId, job.agentId, rating, recorded);
        _pay(job.token, job.payee, job.amount);
    }

    /// @notice Get your money back: any time before an agent accepts, or after the deadline
    ///         if the agent never delivered.
    function refund(uint256 jobId) external nonReentrant {
        Job storage job = jobs[jobId];
        if (msg.sender != job.client) revert NotClient();
        if (job.status == Status.Accepted) {
            if (block.timestamp < job.deadline) revert TooEarly();
        } else if (job.status != Status.Open) {
            revert WrongStatus();
        }

        job.status = Status.Refunded;
        emit JobRefunded(jobId, job.client);
        _pay(job.token, job.client, job.amount);
    }

    // ─────────────────────────────── Agent ───────────────────────────────

    /// @notice Accept an open job as a registered ERC-8004 agent.
    /// @dev msg.sender must be the agent's owner or an approved operator in the Identity Registry.
    function acceptJob(uint256 jobId, uint256 agentId) external nonReentrant {
        Job storage job = jobs[jobId];
        if (job.status != Status.Open) revert WrongStatus();
        if (block.timestamp >= job.deadline) revert DeadlinePassed();

        // 1. Identity: is this a registered agent, and does the caller control it?
        if (!_controlsAgent(msg.sender, agentId)) revert NotAgentOperator();

        // 2. No self-dealing: the client can't hire an agent they control.
        address wallet = identity.getAgentWallet(agentId);
        address payee = wallet != address(0) ? wallet : _ownerOf(agentId);
        if (_controlsAgent(job.client, agentId) || job.client == payee) revert SelfDealing();

        // 3. Reputation gate (optional): only count reviews this marketplace wrote.
        if (job.minReviews > 0) {
            (uint64 count, int128 score) = agentScore(agentId);
            if (count < job.minReviews || score < int128(uint128(job.minScore))) {
                revert ReputationTooLow(count, score);
            }
        }

        job.agentId = agentId;
        job.payee = payee;
        job.status = Status.Accepted;
        emit JobAccepted(jobId, agentId, payee);
    }

    /// @notice Deliver the work before the deadline.
    function submitWork(uint256 jobId, string calldata deliverableURI) external {
        Job storage job = jobs[jobId];
        if (job.status != Status.Accepted) revert WrongStatus();
        if (block.timestamp >= job.deadline) revert DeadlinePassed();
        if (!_controlsAgent(msg.sender, job.agentId)) revert NotAgentOperator();

        job.status = Status.Submitted;
        job.submittedAt = uint64(block.timestamp);
        emit WorkSubmitted(jobId, job.agentId, deliverableURI);
    }

    /// @notice If the client goes silent after delivery, the agent gets paid after REVIEW_PERIOD.
    ///         No rating is written in this case.
    function claim(uint256 jobId) external nonReentrant {
        Job storage job = jobs[jobId];
        if (job.status != Status.Submitted) revert WrongStatus();
        if (block.timestamp < job.submittedAt + REVIEW_PERIOD) revert TooEarly();
        if (!_controlsAgent(msg.sender, job.agentId)) revert NotAgentOperator();

        job.status = Status.Completed;
        emit PaymentClaimed(jobId, job.agentId);
        _pay(job.token, job.payee, job.amount);
    }

    // ─────────────────────────────── Views ───────────────────────────────

    /// @notice An agent's reputation on this marketplace, read from the ERC-8004 Reputation Registry.
    /// @dev getSummary needs a list of trusted reviewers. We trust exactly one: this contract,
    ///      because every review it writes is backed by a paid, escrowed job.
    ///      All our ratings use 0 decimals, so `score` is a plain 0-100 average.
    function agentScore(uint256 agentId) public view returns (uint64 count, int128 score) {
        address[] memory trusted = new address[](1);
        trusted[0] = address(this);
        (count, score,) = reputation.getSummary(agentId, trusted, TAG1, TAG2);
    }

    // ─────────────────────────────── Internal ───────────────────────────────

    /// @dev ownerOf reverts for an agentId that was never registered.
    function _ownerOf(uint256 agentId) internal view returns (address owner) {
        try identity.ownerOf(agentId) returns (address o) {
            owner = o;
        } catch {
            revert AgentNotRegistered(agentId);
        }
    }

    /// @dev Owner, operator (setApprovalForAll) or approved address, in plain ERC-721 terms.
    function _controlsAgent(address who, uint256 agentId) internal view returns (bool) {
        address owner = _ownerOf(agentId);
        return who == owner || identity.isApprovedForAll(owner, who)
            || identity.getApproved(agentId) == who;
    }

    function _pay(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }
}
