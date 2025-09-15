// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "openzeppelin-contracts/contracts/security/Pausable.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";

contract Whistleblower is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // Error codes
    error AlreadyReported(address reporter);
    error InvalidTarget();
    error InvalidReason();
    error NotModerator();
    error NotDAO();
    error FalseReport();
    error ZeroAddress();
    error ReportAlreadyReviewed();

    // Enums
    enum UserRole {
        None,
        Agent,
        Lawyer,
        Worker
    }
    enum ReportStatus {
        Pending,
        Valid,
        Invalid
    }

    // Structs
    struct Report {
        address reporter;
        address target;
        string reason;
        uint256 timestamp;
        ReportStatus status;
        UserRole role;
    }

    // State
    IERC20 public vern;
    address public dao;
    address public moderator;
    uint256 public rewardMin = 200 * 1e18;
    uint256 public rewardMax = 500 * 1e18;
    uint256 public reportCooldown = 7 days;
    mapping(address => uint256) public lastReport;
    mapping(uint256 => Report) public reports;
    uint256 public reportCounter;

    // Events
    event ReportFiled(uint256 indexed reportId, address indexed reporter, address indexed target, UserRole role);
    event ReportReviewed(uint256 indexed reportId, ReportStatus status, uint256 reward);
    event ModeratorChanged(address newModerator);
    event DAOChanged(address newDAO);

    constructor(address _vern, address _dao, address _moderator) {
        if (_vern == address(0) || _dao == address(0) || _moderator == address(0)) revert ZeroAddress();
        vern = IERC20(_vern);
        dao = _dao;
        moderator = _moderator;
    }

    modifier onlyModerator() {
        if (msg.sender != moderator) revert NotModerator();
        _;
    }

    modifier onlyDAO() {
        if (msg.sender != dao) revert NotDAO();
        _;
    }

    function fileReport(address _target, string calldata _reason, UserRole _role) external whenNotPaused {
        if (_target == address(0) || _target == msg.sender) revert InvalidTarget();
        if (bytes(_reason).length == 0) revert InvalidReason();
        if (block.timestamp < lastReport[msg.sender] + reportCooldown) revert AlreadyReported(msg.sender);

        reportCounter++;
        reports[reportCounter] = Report({
            reporter: msg.sender,
            target: _target,
            reason: _reason,
            timestamp: block.timestamp,
            status: ReportStatus.Pending,
            role: _role
        });

        lastReport[msg.sender] = block.timestamp;
        emit ReportFiled(reportCounter, msg.sender, _target, _role);
    }

    function reviewReport(uint256 reportId, bool isValid) external onlyModerator nonReentrant whenNotPaused {
        Report storage rep = reports[reportId];
        if (rep.status != ReportStatus.Pending) revert ReportAlreadyReviewed();

        if (isValid) {
            rep.status = ReportStatus.Valid;
            uint256 randomness =
                uint256(keccak256(abi.encodePacked(block.timestamp, reportId, msg.sender, blockhash(block.number - 1))));
            uint256 reward = rewardMin + (randomness % (rewardMax - rewardMin + 1));
            vern.safeTransfer(rep.reporter, reward);
            emit ReportReviewed(reportId, ReportStatus.Valid, reward);
        } else {
            rep.status = ReportStatus.Invalid;
            emit ReportReviewed(reportId, ReportStatus.Invalid, 0);
        }
    }

    // DAO functions
    function updateModerator(address _new) external onlyDAO {
        if (_new == address(0)) revert ZeroAddress();
        moderator = _new;
        emit ModeratorChanged(_new);
    }

    function updateDAO(address _new) external onlyDAO {
        if (_new == address(0)) revert ZeroAddress();
        dao = _new;
        emit DAOChanged(_new);
    }

    function setRewardBounds(uint256 _min, uint256 _max) external onlyDAO {
        rewardMin = _min;
        rewardMax = _max;
    }

    function setCooldown(uint256 _cooldown) external onlyDAO {
        reportCooldown = _cooldown;
    }

    function pause() external onlyDAO {
        _pause();
    }

    function unpause() external onlyDAO {
        _unpause();
    }
}
