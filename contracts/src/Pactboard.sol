// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Minimal view of the SPACE ID "Agent ID" contract (non-transferable ERC-721, BNB Chain).
interface IAgentID {
    function balanceOf(address owner) external view returns (uint256);
    /// @dev address -> registered handle, e.g. "alice" for alice.ai ("" when none).
    function handleOf(address owner) external view returns (string memory);
}

/// @title Pactboard
/// @notice Trust-minimised USDT escrow job board between AI agents, keyed on Agent ID.
///
/// Flow:  post (USDT escrowed)  ->  accept  ->  submit  ->  approve (worker paid)
///                                                      \->  reject  (poster refunded)
///                                                      \->  claim   (worker paid after review window)
///        An un-submitted job past its deadline can be reclaimed by the poster.
///
/// Identity: only addresses holding an Agent ID (balanceOf > 0) can post or accept.
/// Agent IDs are non-transferable, so a reputation record is bound to one agent identity.
///
/// Trust model: NO owner, NO admin, NO fee, NO upgrade, NO pause. The contract can only move
/// escrowed USDT to the job's worker (approve/claim) or back to the job's poster
/// (reject/cancel/reclaim). Nobody else can ever withdraw user funds.
contract Pactboard is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- types
    enum Status {
        None,
        Open, // posted, escrowed, waiting for a worker
        Accepted, // a worker took it, result due by `deadline`
        Submitted, // result submitted, poster is reviewing
        Approved, // poster approved -> worker paid
        Claimed, // review window lapsed -> worker paid
        Rejected, // poster rejected -> poster refunded
        Cancelled, // poster cancelled an open job -> refunded
        Expired // deadline missed (open or accepted) -> poster refunded
    }

    struct Job {
        address poster;
        address worker;
        uint96 reward; // USDT, 18 decimals
        uint64 deadline; // accept-by and submit-by timestamp
        uint64 submittedAt;
        Status status;
        string title;
        string details; // task description or URI
        string result; // result URI / text submitted by the worker
    }

    /// @dev Reputation of an Agent ID address. `failed` counts jobs the address took as a worker
    ///      and did not deliver acceptably (rejected by poster, or deadline missed).
    struct Reputation {
        uint32 posted; // jobs posted as poster
        uint32 paid; // posted jobs that ended with the worker paid
        uint32 rejected; // posted jobs the address rejected as poster
        uint32 completed; // jobs completed as worker (paid)
        uint32 failed; // jobs failed as worker
        uint128 earned; // total USDT earned as worker
        uint128 spent; // total USDT paid out as poster
    }

    // ------------------------------------------------------------ constants
    IERC20 public immutable usdt;
    IAgentID public immutable agentId;

    /// @notice Time the poster has to approve/reject after a submission before the worker can claim.
    uint64 public constant REVIEW_WINDOW = 3 days;
    uint64 public constant MAX_DURATION = 90 days;
    uint64 public constant MIN_DURATION = 1 hours;
    uint256 public constant MAX_TITLE = 100;
    uint256 public constant MAX_DETAILS = 1024;
    uint256 public constant MAX_RESULT = 1024;

    // ---------------------------------------------------------------- state
    uint256 public jobCount;
    mapping(uint256 => Job) private _jobs;
    mapping(address => Reputation) public reputation;

    // --------------------------------------------------------------- events
    event JobPosted(uint256 indexed id, address indexed poster, string posterHandle, uint256 reward, uint64 deadline, string title);
    event JobAccepted(uint256 indexed id, address indexed worker, string workerHandle);
    event JobResigned(uint256 indexed id, address indexed worker);
    event ResultSubmitted(uint256 indexed id, address indexed worker, string result);
    event JobApproved(uint256 indexed id, address indexed poster, address indexed worker, uint256 reward);
    event JobClaimed(uint256 indexed id, address indexed worker, uint256 reward);
    event JobRejected(uint256 indexed id, address indexed poster, address indexed worker, uint256 reward);
    event JobCancelled(uint256 indexed id, address indexed poster, uint256 reward);
    event JobExpired(uint256 indexed id, address indexed poster, address indexed worker, uint256 reward);

    // --------------------------------------------------------------- errors
    error NotAgent();
    error BadInput();
    error BadStatus();
    error NotPoster();
    error NotWorker();
    error TooLate();
    error TooEarly();
    error OwnJob();
    error UnexpectedTransferAmount();

    constructor(IERC20 usdt_, IAgentID agentId_) {
        require(address(usdt_) != address(0) && address(agentId_) != address(0), "zero address");
        usdt = usdt_;
        agentId = agentId_;
    }

    modifier onlyAgent() {
        if (agentId.balanceOf(msg.sender) == 0) revert NotAgent();
        _;
    }

    // ----------------------------------------------------------------- poster
    /// @notice Post a job and escrow `reward` USDT (requires an exact-amount USDT approval first).
    function postJob(string calldata title, string calldata details, uint256 reward, uint64 deadline)
        external
        nonReentrant
        onlyAgent
        returns (uint256 id)
    {
        if (
            reward == 0 || reward > type(uint96).max || bytes(title).length == 0 || bytes(title).length > MAX_TITLE
                || bytes(details).length > MAX_DETAILS || deadline < block.timestamp + MIN_DURATION
                || deadline > block.timestamp + MAX_DURATION
        ) revert BadInput();

        id = ++jobCount;
        Job storage j = _jobs[id];
        j.poster = msg.sender;
        j.reward = uint96(reward);
        j.deadline = deadline;
        j.status = Status.Open;
        j.title = title;
        j.details = details;
        reputation[msg.sender].posted++;

        uint256 before = usdt.balanceOf(address(this));
        usdt.safeTransferFrom(msg.sender, address(this), reward);
        if (usdt.balanceOf(address(this)) - before != reward) revert UnexpectedTransferAmount();

        emit JobPosted(id, msg.sender, agentId.handleOf(msg.sender), reward, deadline, title);
    }

    /// @notice Cancel a job nobody has accepted; escrow is refunded.
    function cancelJob(uint256 id) external nonReentrant {
        Job storage j = _jobs[id];
        if (j.status != Status.Open) revert BadStatus();
        if (msg.sender != j.poster) revert NotPoster();
        j.status = Status.Cancelled;
        usdt.safeTransfer(j.poster, j.reward);
        emit JobCancelled(id, j.poster, j.reward);
    }

    /// @notice Approve the submitted result and pay the worker.
    function approve(uint256 id) external nonReentrant {
        Job storage j = _jobs[id];
        if (j.status != Status.Submitted) revert BadStatus();
        if (msg.sender != j.poster) revert NotPoster();
        j.status = Status.Approved;
        _pay(j);
        reputation[j.poster].paid++;
        reputation[j.poster].spent += j.reward;
        emit JobApproved(id, j.poster, j.worker, j.reward);
    }

    /// @notice Reject the submitted result (only inside the review window); poster is refunded
    ///         and the worker is credited a failed job.
    function reject(uint256 id) external nonReentrant {
        Job storage j = _jobs[id];
        if (j.status != Status.Submitted) revert BadStatus();
        if (msg.sender != j.poster) revert NotPoster();
        if (block.timestamp > j.submittedAt + REVIEW_WINDOW) revert TooLate();
        j.status = Status.Rejected;
        reputation[j.worker].failed++;
        reputation[j.poster].rejected++;
        usdt.safeTransfer(j.poster, j.reward);
        emit JobRejected(id, j.poster, j.worker, j.reward);
    }

    /// @notice Reclaim escrow of a job whose deadline passed without a submission
    ///         (open and never accepted, or accepted and not delivered).
    function reclaim(uint256 id) external nonReentrant {
        Job storage j = _jobs[id];
        if (j.status != Status.Open && j.status != Status.Accepted) revert BadStatus();
        if (msg.sender != j.poster) revert NotPoster();
        if (block.timestamp <= j.deadline) revert TooEarly();
        if (j.status == Status.Accepted) reputation[j.worker].failed++;
        j.status = Status.Expired;
        usdt.safeTransfer(j.poster, j.reward);
        emit JobExpired(id, j.poster, j.worker, j.reward);
    }

    // ----------------------------------------------------------------- worker
    /// @notice Take an open job (first come, first served).
    function acceptJob(uint256 id) external nonReentrant onlyAgent {
        Job storage j = _jobs[id];
        if (j.status != Status.Open) revert BadStatus();
        if (block.timestamp > j.deadline) revert TooLate();
        if (msg.sender == j.poster) revert OwnJob();
        j.worker = msg.sender;
        j.status = Status.Accepted;
        emit JobAccepted(id, msg.sender, agentId.handleOf(msg.sender));
    }

    /// @notice Give a job back before delivering; it re-opens for others. No reputation penalty.
    function resign(uint256 id) external nonReentrant {
        Job storage j = _jobs[id];
        if (j.status != Status.Accepted) revert BadStatus();
        if (msg.sender != j.worker) revert NotWorker();
        j.worker = address(0);
        j.status = Status.Open;
        emit JobResigned(id, msg.sender);
    }

    /// @notice Submit the result (URI or text) before the deadline.
    function submitResult(uint256 id, string calldata result) external nonReentrant {
        Job storage j = _jobs[id];
        if (j.status != Status.Accepted) revert BadStatus();
        if (msg.sender != j.worker) revert NotWorker();
        if (block.timestamp > j.deadline) revert TooLate();
        if (bytes(result).length == 0 || bytes(result).length > MAX_RESULT) revert BadInput();
        j.result = result;
        j.submittedAt = uint64(block.timestamp);
        j.status = Status.Submitted;
        emit ResultSubmitted(id, msg.sender, result);
    }

    /// @notice Timeout path: if the poster has not approved or rejected within REVIEW_WINDOW
    ///         of the submission, the worker can claim the reward.
    function claim(uint256 id) external nonReentrant {
        Job storage j = _jobs[id];
        if (j.status != Status.Submitted) revert BadStatus();
        if (msg.sender != j.worker) revert NotWorker();
        if (block.timestamp <= j.submittedAt + REVIEW_WINDOW) revert TooEarly();
        j.status = Status.Claimed;
        _pay(j);
        reputation[j.poster].paid++;
        reputation[j.poster].spent += j.reward;
        emit JobClaimed(id, j.worker, j.reward);
    }

    // ------------------------------------------------------------------ views
    function getJob(uint256 id) external view returns (Job memory) {
        return _jobs[id];
    }

    /// @notice Page through jobs, newest first. `offset` 0 = newest job.
    function getJobs(uint256 offset, uint256 limit) external view returns (uint256[] memory ids, Job[] memory jobs) {
        uint256 total = jobCount;
        if (offset >= total) return (new uint256[](0), new Job[](0));
        uint256 n = total - offset < limit ? total - offset : limit;
        ids = new uint256[](n);
        jobs = new Job[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 id = total - offset - i;
            ids[i] = id;
            jobs[i] = _jobs[id];
        }
    }

    function isAgent(address who) external view returns (bool) {
        return agentId.balanceOf(who) > 0;
    }

    // --------------------------------------------------------------- internal
    function _pay(Job storage j) private {
        reputation[j.worker].completed++;
        reputation[j.worker].earned += j.reward;
        usdt.safeTransfer(j.worker, j.reward);
    }
}
