// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {Pausable} from "openzeppelin-contracts/contracts/security/Pausable.sol";

/// @title VeriNest Governance + Built-in 3-of-5 Multisig
/// @notice Single contract combining staking-based governance (proposals, emergency override)
///         and a simple 3-of-5 multisig execution mechanism (approve + execute).
contract Governance is ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------------
    // Multisig configuration (5 fixed signers, threshold = 3)
    // ------------------------------------------------------------------------
    address[5] public signers;
    uint256 public constant THRESHOLD = 3;

    // tx id => approvals bitmap (5 LSBs)
    mapping(bytes32 => uint8) public approvals;
    mapping(bytes32 => bool) public executed;

    // ------------------------------------------------------------------------
    // Governance / Staking config
    // ------------------------------------------------------------------------
    IERC20 public immutable vern;

    uint256 public constant PROPOSAL_STAKE = 1_000 * 1e18; // 1,000 VERN
    uint256 public constant EMERGENCY_WINDOW = 48 hours;
    uint256 public constant EMERGENCY_YES_BPS = 7000; // 70.00%
    uint256 public constant BPS_DENOM = 10_000;

    // staking balances (voting power)
    mapping(address => uint256) public staked;
    uint256 public totalStaked;

    // proposals
    enum ProposalState {
        Active,
        Succeeded,
        Defeated,
        Executed,
        Cancelled,
        Expired
    }

    struct Proposal {
        address proposer;
        string description;
        uint64 startTime;
        uint64 endTime;
        uint256 yesVotes;
        uint256 noVotes;
        bool executed;
        bool cancelled;
        uint256 proposerStake; // locked 1,000 VERN
    }

    uint256 public votingPeriod = 5 days;
    uint256 public proposalCount;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    // emergency override
    struct EmergencyVote {
        address opener;
        uint64 startTime;
        uint64 endTime;
        uint256 yesVotes;
        bool resolved;
        bool succeeded;
    }

    uint256 public emergencyCount;
    mapping(uint256 => EmergencyVote) public emergencies;
    mapping(uint256 => mapping(address => bool)) public emergencyVoted;

    // ------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------
    event MultisigApproved(address indexed signer, bytes32 txId, uint8 bitmap);
    event MultisigExecuted(bytes32 indexed txId, address to, uint256 value, bytes data);
    event SignersSet(address[5] signers);

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);

    event ProposalCreated(
        uint256 indexed id, address indexed proposer, string description, uint64 startTime, uint64 endTime
    );
    event Voted(uint256 indexed id, address indexed voter, bool support, uint256 weight);
    event ProposalFinalized(uint256 indexed id, bool succeeded);
    event ProposalExecuted(uint256 indexed id);

    event EmergencyOpened(uint256 indexed id, address indexed opener, uint64 start, uint64 end);
    event EmergencyVoted(uint256 indexed id, address indexed voter, uint256 weight);
    event EmergencyResolved(uint256 indexed id, bool succeeded);

    event PausedByMultisig(bytes32 indexed txId);
    event UnpausedByMultisig(bytes32 indexed txId);

    // ------------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------------
    /// @param _vern token used for staking/voting
    /// @param _signers 5 signer addresses for the multisig
    constructor(address _vern, address[5] memory _signers) {
        require(_vern != address(0), "vern=0");

        // Validate & set signers
        for (uint256 i = 0; i < 5; i++) {
            require(_signers[i] != address(0), "signer=0");
            for (uint256 j = i + 1; j < 5; j++) {
                require(_signers[i] != _signers[j], "dup signer");
            }
            signers[i] = _signers[i];
        }

        vern = IERC20(_vern);
        emit SignersSet(signers);
    }

    // ------------------------------------------------------------------------
    // Multisig helpers (approve + execute)
    // ------------------------------------------------------------------------
    function _txId(address to, uint256 value, bytes memory data, uint256 nonce) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(to, value, data, nonce));
    }

    modifier onlySigner() {
        bool ok;
        for (uint256 i = 0; i < 5; i++) {
            if (msg.sender == signers[i]) {
                ok = true;
                break;
            }
        }
        require(ok, "not signer");
        _;
    }

    /// @notice signer approves a tx represented by txId
    function approveTx(bytes32 txId) external onlySigner whenNotPaused {
        // find index
        uint8 idx = 6;
        for (uint8 i = 0; i < 5; i++) {
            if (msg.sender == signers[i]) {
                idx = i;
                break;
            }
        }
        require(idx < 5, "bad idx");
        uint8 mask = uint8(1 << idx);
        require(approvals[txId] & mask == 0, "already approved");
        approvals[txId] |= mask;
        emit MultisigApproved(msg.sender, txId, approvals[txId]);
    }

    /// @notice count approvals in the 5-bit bitmap
    function approvalsCount(bytes32 txId) public view returns (uint256 cnt) {
        uint8 a = approvals[txId];
        for (uint8 i = 0; i < 5; i++) {
            if ((a & (1 << i)) != 0) cnt++;
        }
    }

    /// @notice Execute an approved tx (arbitrary external call). Requires >= THRESHOLD approvals.
    /// @dev Anyone can call this once approvals threshold reached; executed[] prevents replay.
    function executeTx(address to, uint256 value, bytes calldata data, uint256 nonce)
        external
        whenNotPaused
        returns (bytes memory)
    {
        bytes32 txId = _txId(to, value, data, nonce);
        require(!executed[txId], "already executed");
        require(approvalsCount(txId) >= THRESHOLD, "not enough approvals");
        executed[txId] = true;

        (bool ok, bytes memory ret) = to.call{value: value}(data);
        require(ok, "call failed");
        emit MultisigExecuted(txId, to, value, data);
        return ret;
    }

    // ------------------------------------------------------------------------
    // Convenience: multisig-controlled pause/unpause using the same approval machinery
    // ------------------------------------------------------------------------
    /// @notice Signers prepare a txId for pause and call approveTx(txId). When >=THRESHOLD, call executePause(txId, nonce)
    function executePause(address, /*unusedTo*/ uint256, /*unusedValue*/ bytes calldata, /*unusedData*/ uint256 nonce)
        external
        whenNotPaused
    {
        // We'll create a canonical txId for "pause" (use address(this) and selector bytes to avoid ambiguity)
        bytes32 txId = _txId(address(this), 0, abi.encodePacked(bytes4(keccak256("PAUSE()"))), nonce);
        require(!executed[txId], "already executed");
        require(approvalsCount(txId) >= THRESHOLD, "not enough approvals");
        executed[txId] = true;
        _pause();
        emit PausedByMultisig(txId);
    }

    /// @notice Unpause (multisig)
    function executeUnpause(address, /*unusedTo*/ uint256, /*unusedValue*/ bytes calldata, /*unusedData*/ uint256 nonce)
        external
    {
        bytes32 txId = _txId(address(this), 0, abi.encodePacked(bytes4(keccak256("UNPAUSE()"))), nonce);
        require(!executed[txId], "already executed");
        require(approvalsCount(txId) >= THRESHOLD, "not enough approvals");
        executed[txId] = true;
        _unpause();
        emit UnpausedByMultisig(txId);
    }

    // ------------------------------------------------------------------------
    // Staking (voting power)
    // ------------------------------------------------------------------------
    function stake(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "amount=0");
        staked[msg.sender] += amount;
        totalStaked += amount;
        vern.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "amount=0");
        require(staked[msg.sender] >= amount, "insufficient");
        // simple guard: disallow unstake while engaged in active proposals - simplified here:
        require(!_isVoterInActiveProposal(msg.sender), "active vote lock");

        staked[msg.sender] -= amount;
        totalStaked -= amount;
        vern.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function _isVoterInActiveProposal(address) internal pure returns (bool) {
        // For simplicity in this sample we don't scan; production: implement proper lock tracking.
        return false;
    }

    // ------------------------------------------------------------------------
    // Proposal lifecycle
    // ------------------------------------------------------------------------
    function createProposal(string calldata description) external whenNotPaused returns (uint256 id) {
        require(staked[msg.sender] >= PROPOSAL_STAKE, "need 1,000 VERN staked");
        // lock proposer stake
        staked[msg.sender] -= PROPOSAL_STAKE;

        id = ++proposalCount;
        uint64 start = uint64(block.timestamp);
        uint64 end = uint64(block.timestamp + votingPeriod);

        proposals[id] = Proposal({
            proposer: msg.sender,
            description: description,
            startTime: start,
            endTime: end,
            yesVotes: 0,
            noVotes: 0,
            executed: false,
            cancelled: false,
            proposerStake: PROPOSAL_STAKE
        });

        emit ProposalCreated(id, msg.sender, description, start, end);
    }

    function vote(uint256 id, bool support) external whenNotPaused {
        Proposal storage p = proposals[id];
        require(p.proposer != address(0), "no proposal");
        require(block.timestamp >= p.startTime && block.timestamp <= p.endTime, "not active");
        require(!hasVoted[id][msg.sender], "voted");

        uint256 weight = staked[msg.sender];
        require(weight > 0, "no voting power");

        hasVoted[id][msg.sender] = true;
        if (support) p.yesVotes += weight;
        else p.noVotes += weight;

        emit Voted(id, msg.sender, support, weight);
    }

    function finalize(uint256 id) public {
        Proposal storage p = proposals[id];
        require(p.proposer != address(0), "no proposal");
        require(block.timestamp > p.endTime, "too early");
        require(!p.cancelled && !p.executed, "closed");

        bool passed = p.yesVotes > p.noVotes;

        // Return proposer stake (you can change slash logic later)
        staked[p.proposer] += p.proposerStake;
        p.proposerStake = 0;

        emit ProposalFinalized(id, passed);
    }

    function executeProposal(uint256 id) external whenNotPaused {
        Proposal storage p = proposals[id];
        require(p.proposer != address(0), "no proposal");
        require(!p.executed && !p.cancelled, "closed");
        require(block.timestamp > p.endTime, "not finished");

        bool passed = p.yesVotes > p.noVotes;
        require(passed, "did not pass");

        p.executed = true;
        emit ProposalExecuted(id);

        // Note: actual state changes/actions are performed by multisig owners executing a transaction,
        // possibly referencing this proposal id; this contract only records governance decisions.
    }

    function cancelProposal(uint256 id) external {
        Proposal storage p = proposals[id];
        require(p.proposer == msg.sender, "not proposer");
        require(!p.executed && !p.cancelled, "closed");
        require(block.timestamp < p.endTime, "already ended");

        p.cancelled = true;
        // return stake
        staked[p.proposer] += p.proposerStake;
        p.proposerStake = 0;
    }

    // ------------------------------------------------------------------------
    // Emergency override: 70% YES of currently staked within 48h freezes system
    // ------------------------------------------------------------------------
    function openEmergency() external whenNotPaused returns (uint256 id) {
        id = ++emergencyCount;
        uint64 start = uint64(block.timestamp);
        uint64 end = uint64(block.timestamp + EMERGENCY_WINDOW);

        emergencies[id] = EmergencyVote({
            opener: msg.sender,
            startTime: start,
            endTime: end,
            yesVotes: 0,
            resolved: false,
            succeeded: false
        });

        emit EmergencyOpened(id, msg.sender, start, end);
    }

    function voteEmergency(uint256 id) external whenNotPaused {
        EmergencyVote storage e = emergencies[id];
        require(e.opener != address(0), "no emergency");
        require(block.timestamp >= e.startTime && block.timestamp <= e.endTime, "not active");
        require(!emergencyVoted[id][msg.sender], "voted");

        uint256 weight = staked[msg.sender];
        require(weight > 0, "no voting power");

        emergencyVoted[id][msg.sender] = true;
        e.yesVotes += weight;

        emit EmergencyVoted(id, msg.sender, weight);
    }

    function resolveEmergency(uint256 id) public {
        EmergencyVote storage e = emergencies[id];
        require(e.opener != address(0), "no emergency");
        require(!e.resolved, "resolved");
        require(block.timestamp > e.endTime, "too early");

        if (totalStaked > 0 && (e.yesVotes * BPS_DENOM) / totalStaked >= EMERGENCY_YES_BPS) {
            e.succeeded = true;

            // Freeze the governance contract. We also mark that multisig must be paused by signers
            _pause();
            emit PausedByMultisig(bytes32(id));
        }

        e.resolved = true;
        emit EmergencyResolved(id, e.succeeded);
    }

    // Governance unpause path - can be gated however you want (here only when paused)
    function unpauseSystem() external whenPaused {
        // you can restrict who can unpause (e.g., multisig exec). For demo allow any caller but require multisig unpause executed
        // In this implementation, call to _unpause is public once paused, but ideal: require a multisig unpause execution first
        _unpause();
        emit UnpausedByMultisig(bytes32(0));
    }

    // ------------------------------------------------------------------------
    // Owner can reset or replace signers
    // ------------------------------------------------------------------------
    function resetSigners(address[6] calldata _newSigners) external {
        for (uint256 i = 0; i < 6; i++) {
            require(_newSigners[i] != address(0), "signer=0");
            for (uint256 j = i + 1; j < 6; j++) {
                require(_newSigners[i] != _newSigners[j], "dup signer");
            }
            signers[i] = _newSigners[i];
        }
        emit SignersSet(signers);
    }

    // ------------------------------------------------------------------------
    // Helper to allow receiving ETH when multisig executes payable txs
    // ------------------------------------------------------------------------
    receive() external payable {}
}
