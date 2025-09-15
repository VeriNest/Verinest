// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

contract VeriNestDAO is Ownable {
    IERC20 public immutable vern;
    uint256 public constant MIN_PROPOSAL_STAKE = 1_000 * 1e18;
    uint256 public constant TOTAL_SUPPLY = 512_000_000 * 1e18;

    enum ProposalType {
        UPGRADE,
        TREASURY_MOVE,
        MODERATION,
        OTHER
    }

    enum ProposalStatus {
        Pending,
        Approved,
        Rejected,
        Executed
    }

    struct Proposal {
        uint256 id;
        address proposer;
        ProposalType pType;
        string description;
        uint256 deadline;
        uint256 forVotes;
        uint256 againstVotes;
        ProposalStatus status;
    }

    struct EmergencyVote {
        uint256 totalWeight;
        mapping(address => bool) hasVoted;
    }

    uint256 public proposalCount;

    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => bool) public isValidProposal;
    mapping(address => uint256) public lastProposalTime;
    mapping(uint256 => EmergencyVote) public emergencyOverrides;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(uint256 => mapping(address => bool)) public emergencyHasVoted;

    event ProposalCreated(uint256 indexed id, address indexed proposer, ProposalType pType);
    event Voted(uint256 indexed id, address voter, bool support, uint256 weight);
    event EmergencyTriggered(uint256 indexed id);
    event ProposalExecuted(uint256 indexed id);

    constructor(address _vern) {
        vern = IERC20(_vern);
    }

    function createProposal(ProposalType pType, string memory description) external {
        require(vern.balanceOf(msg.sender) >= MIN_PROPOSAL_STAKE, "Insufficient stake");
        require(block.timestamp > lastProposalTime[msg.sender] + 1 days, "Cooldown");

        proposalCount++;
        Proposal storage p = proposals[proposalCount];
        p.id = proposalCount;
        p.proposer = msg.sender;
        p.pType = pType;
        p.description = description;
        p.deadline = block.timestamp + 3 days;
        p.status = ProposalStatus.Pending;

        lastProposalTime[msg.sender] = block.timestamp;
        isValidProposal[proposalCount] = true;

        emit ProposalCreated(p.id, msg.sender, pType);
    }

    function vote(uint256 id, bool support) external {
        Proposal storage p = proposals[id];
        require(block.timestamp <= p.deadline, "Voting ended");
        require(!hasVoted[id][msg.sender], "Already voted");

        uint256 weight = vern.balanceOf(msg.sender);
        require(weight > 0, "No VERN tokens");

        hasVoted[id][msg.sender] = true;

        if (support) {
            p.forVotes += weight;
        } else {
            p.againstVotes += weight;
        }

        emit Voted(id, msg.sender, support, weight);
    }

    function finalizeProposal(uint256 id) external {
        Proposal storage p = proposals[id];
        require(block.timestamp > p.deadline, "Still active");
        require(p.status == ProposalStatus.Pending, "Already finalized");

        if (p.forVotes > p.againstVotes) {
            p.status = ProposalStatus.Approved;
        } else {
            p.status = ProposalStatus.Rejected;
        }
    }

    // 🔑 Only the single admin (owner) can execute proposals
    function executeProposal(uint256 id) external onlyOwner {
        Proposal storage p = proposals[id];
        require(p.status == ProposalStatus.Approved, "Not approved");
        p.status = ProposalStatus.Executed;

        // Add custom logic here depending on proposal type
        emit ProposalExecuted(id);
    }

    function emergencyOverride(uint256 id) external {
        EmergencyVote storage ev = emergencyOverrides[id];
        require(!emergencyHasVoted[id][msg.sender], "Already voted");

        uint256 weight = vern.balanceOf(msg.sender);
        require(weight > 0, "No VERN tokens");

        emergencyHasVoted[id][msg.sender] = true;
        ev.totalWeight += weight;

        if (ev.totalWeight >= (TOTAL_SUPPLY * 70) / 100) {
            proposals[id].status = ProposalStatus.Rejected;
            emit EmergencyTriggered(id);
        }
    }

    // View helpers
    function getProposal(uint256 id)
        external
        view
        returns (
            address proposer,
            ProposalType pType,
            string memory description,
            uint256 deadline,
            uint256 forVotes,
            uint256 againstVotes,
            ProposalStatus status
        )
    {
        Proposal storage p = proposals[id];
        return (p.proposer, p.pType, p.description, p.deadline, p.forVotes, p.againstVotes, p.status);
    }

    function getProposalCount() external view returns (uint256) {
        return proposalCount;
    }

    function getProposalStatus(uint256 id) external view returns (ProposalStatus) {
        return proposals[id].status;
    }

    function getProposalVotes(uint256 id) external view returns (uint256 forVotes, uint256 againstVotes) {
        Proposal storage p = proposals[id];
        return (p.forVotes, p.againstVotes);
    }
}
