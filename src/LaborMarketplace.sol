// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

contract LaborMarketplace is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ===== Errors =====
    error NotAgent();
    error InvalidWorker();
    error JobNotFound();
    error NotJobOwner();
    error AlreadyCompleted();
    error NotVerified();
    error NotAdmin();
    error DuplicateAdmin(address admin);

    IERC20 public vernToken;

    uint256 public jobCounter;

    enum JobStatus {
        Open,
        Completed,
        Cancelled
    }

    struct Job {
        uint256 id;
        address postedBy;
        address worker;
        uint256 propertyId;
        uint256 reward;
        JobStatus status;
        bool gpsVerified;
    }

    mapping(uint256 => Job) public jobs;
    mapping(address => bool) public isWorker;
    mapping(address => bool) public isAgent;

    event AgentRegistered(address indexed agent);
    event WorkerRegistered(address indexed worker);
    event JobPosted(uint256 indexed id, address indexed by, address indexed worker);
    event GPSVerified(uint256 indexed jobId);
    event JobFinalized(uint256 indexed jobId, address worker, uint256 reward);

    constructor(address _vernToken) {
        vernToken = IERC20(_vernToken);
    }

    // === Role Onboarding ===

    function registerWorker(address worker) external onlyOwner {
        isWorker[worker] = true;
        emit WorkerRegistered(worker);
    }

    function registerAgent(address agent) external onlyOwner {
        isAgent[agent] = true;
        emit AgentRegistered(agent);
    }

    // === Job Posting & Matching ===

    function postJob(address worker, uint256 propertyId, uint256 reward) external {
        if (!isAgent[msg.sender]) revert NotAgent();
        if (!isWorker[worker]) revert InvalidWorker();

        vernToken.safeTransferFrom(msg.sender, address(this), reward);

        uint256 id = ++jobCounter;

        jobs[id] = Job({
            id: id,
            postedBy: msg.sender,
            worker: worker,
            propertyId: propertyId,
            reward: reward,
            status: JobStatus.Open,
            gpsVerified: false
        });

        emit JobPosted(id, msg.sender, worker);
    }

    // === GPS Verification (by Oracle or Frontend) ===

    function markGPSVerified(uint256 jobId) external onlyOwner {
        if (jobId == 0 || jobId > jobCounter) revert JobNotFound();
        jobs[jobId].gpsVerified = true;
        emit GPSVerified(jobId);
    }

    // === Job Completion ===

    function finalizeJob(uint256 jobId) external nonReentrant {
        if (jobId == 0 || jobId > jobCounter) revert JobNotFound();

        Job storage job = jobs[jobId];
        if (msg.sender != job.postedBy) revert NotJobOwner();
        if (job.status != JobStatus.Open) revert AlreadyCompleted();
        if (!job.gpsVerified) revert NotVerified();

        job.status = JobStatus.Completed;
        vernToken.safeTransfer(job.worker, job.reward);

        emit JobFinalized(jobId, job.worker, job.reward);
    }

    // === Admin Slash or Cancel ===

    function cancelJob(uint256 jobId) external onlyOwner nonReentrant {
        Job storage job = jobs[jobId];
        if (job.status != JobStatus.Open) revert AlreadyCompleted();

        job.status = JobStatus.Cancelled;
        vernToken.safeTransfer(job.postedBy, job.reward);
    }
}
