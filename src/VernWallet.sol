// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "openzeppelin-contracts/contracts/security/Pausable.sol";

/// @title Enhanced VernWallet - Secure wallet for VERN tokens
/// @notice Provides secure deposit/withdrawal functionality with additional safety features
contract VernWallet is ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ============ ERRORS ============

    error Unauthorized();
    error ZeroAmount();
    error InsufficientBalance();
    error TransferFailed();
    error WithdrawalCooldown();
    error DailyLimitExceeded();
    error SingleLimitExceeded();
    error EmergencyNotReady();
    error InvalidRecoveryAddress();

    // ============ STATE VARIABLES ============

    address public immutable owner;
    IERC20 public immutable vern;

    // Emergency features
    address public emergencyRecovery;
    uint256 public constant EMERGENCY_DELAY = 7 days;
    uint256 public emergencyUnlockTime;

    // Rate limiting
    mapping(address => uint256) public lastWithdrawal;
    mapping(address => uint256) public dailyWithdrawn;
    mapping(address => uint256) public lastDayReset;

    uint256 public constant WITHDRAWAL_COOLDOWN = 1 hours;
    uint256 public constant DAILY_WITHDRAWAL_LIMIT = 100_000 * 1e18; // 100k VERN per day
    uint256 public constant MAX_SINGLE_WITHDRAWAL = 50_000 * 1e18; // 50k VERN max per tx

    // ============ EVENTS ============

    event DepositVERN(address indexed sender, uint256 amount);
    event WithdrawVERN(address indexed to, uint256 amount);
    event EmergencyRecoverySet(address indexed newRecovery);
    event EmergencyUnlockInitiated(uint256 unlockTime);
    event EmergencyWithdrawal(address indexed to, uint256 amount);

    // ============ MODIFIERS ============

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier validAmount(uint256 amount) {
        if (amount == 0) revert ZeroAmount();
        _;
    }

    modifier withinLimits(uint256 amount) {
        if (amount > MAX_SINGLE_WITHDRAWAL) revert SingleLimitExceeded();

        // Reset daily counter if new day
        if (block.timestamp >= lastDayReset[msg.sender] + 1 days) {
            dailyWithdrawn[msg.sender] = 0;
            lastDayReset[msg.sender] = block.timestamp;
        }

        if (dailyWithdrawn[msg.sender] + amount > DAILY_WITHDRAWAL_LIMIT) {
            revert DailyLimitExceeded();
        }
        _;
    }

    modifier respectsCooldown() {
        if (block.timestamp < lastWithdrawal[msg.sender] + WITHDRAWAL_COOLDOWN) {
            revert WithdrawalCooldown();
        }
        _;
    }

    // ============ CONSTRUCTOR ============

    constructor(address _vern, address _emergencyRecovery) {
        if (_vern == address(0)) revert InvalidRecoveryAddress();
        if (_emergencyRecovery == address(0)) revert InvalidRecoveryAddress();

        owner = msg.sender;
        vern = IERC20(_vern);
        emergencyRecovery = _emergencyRecovery;

        // Initialize rate limiting
        lastDayReset[msg.sender] = block.timestamp;
    }

    // ============ CORE FUNCTIONS ============

    /// @notice Deposit VERN tokens into wallet
    /// @param amount Amount of VERN to deposit
    function depositVERN(uint256 amount) external nonReentrant whenNotPaused validAmount(amount) {
        uint256 balanceBefore = vern.balanceOf(address(this));
        vern.safeTransferFrom(msg.sender, address(this), amount);
        uint256 balanceAfter = vern.balanceOf(address(this));

        // Verify actual transfer amount (protection against fee-on-transfer tokens)
        uint256 actualAmount = balanceAfter - balanceBefore;
        if (actualAmount == 0) revert TransferFailed();

        emit DepositVERN(msg.sender, actualAmount);
    }

    /// @notice Withdraw VERN tokens (owner only, with rate limits)
    /// @param amount Amount of VERN to withdraw
    function withdrawVERN(uint256 amount)
        external
        onlyOwner
        nonReentrant
        whenNotPaused
        validAmount(amount)
        withinLimits(amount)
        respectsCooldown
    {
        uint256 contractBalance = vern.balanceOf(address(this));
        if (contractBalance < amount) revert InsufficientBalance();

        // Update rate limiting
        dailyWithdrawn[msg.sender] += amount;
        lastWithdrawal[msg.sender] = block.timestamp;

        vern.safeTransfer(owner, amount);
        emit WithdrawVERN(owner, amount);
    }

    /// @notice Emergency withdrawal with time delay (security feature)
    /// @param amount Amount to withdraw in emergency
    function emergencyWithdraw(uint256 amount) external nonReentrant validAmount(amount) {
        if (msg.sender != emergencyRecovery) revert Unauthorized();
        if (block.timestamp < emergencyUnlockTime) revert EmergencyNotReady();

        uint256 contractBalance = vern.balanceOf(address(this));
        if (contractBalance < amount) revert InsufficientBalance();

        vern.safeTransfer(emergencyRecovery, amount);
        emit EmergencyWithdrawal(emergencyRecovery, amount);

        // Reset emergency unlock
        emergencyUnlockTime = 0;
    }

    /// @notice Initiate emergency unlock (starts delay timer)
    function initiateEmergencyUnlock() external {
        if (msg.sender != emergencyRecovery) revert Unauthorized();

        emergencyUnlockTime = block.timestamp + EMERGENCY_DELAY;
        emit EmergencyUnlockInitiated(emergencyUnlockTime);
    }

    /// @notice Batch withdraw multiple amounts (gas optimization)
    /// @param recipients Array of recipient addresses
    /// @param amounts Array of amounts to withdraw
    function batchWithdraw(address[] calldata recipients, uint256[] calldata amounts)
        external
        onlyOwner
        nonReentrant
        whenNotPaused
    {
        if (recipients.length != amounts.length) revert Unauthorized();
        if (recipients.length == 0) revert ZeroAmount();

        uint256 totalAmount = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            totalAmount += amounts[i];
        }

        if (totalAmount > MAX_SINGLE_WITHDRAWAL) revert SingleLimitExceeded();
        if (vern.balanceOf(address(this)) < totalAmount) revert InsufficientBalance();

        // Check rate limits for total amount
        if (block.timestamp >= lastDayReset[msg.sender] + 1 days) {
            dailyWithdrawn[msg.sender] = 0;
            lastDayReset[msg.sender] = block.timestamp;
        }

        if (dailyWithdrawn[msg.sender] + totalAmount > DAILY_WITHDRAWAL_LIMIT) {
            revert DailyLimitExceeded();
        }

        // Update rate limiting
        dailyWithdrawn[msg.sender] += totalAmount;
        lastWithdrawal[msg.sender] = block.timestamp;

        // Execute transfers
        for (uint256 i = 0; i < recipients.length; i++) {
            if (amounts[i] > 0) {
                vern.safeTransfer(recipients[i], amounts[i]);
                emit WithdrawVERN(recipients[i], amounts[i]);
            }
        }
    }

    // ============ ADMIN FUNCTIONS ============

    /// @notice Set new emergency recovery address
    /// @param newRecovery New emergency recovery address
    function setEmergencyRecovery(address newRecovery) external onlyOwner {
        if (newRecovery == address(0)) revert InvalidRecoveryAddress();
        emergencyRecovery = newRecovery;
        emit EmergencyRecoverySet(newRecovery);
    }

    /// @notice Pause contract in case of emergency
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause contract
    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ VIEW FUNCTIONS ============

    /// @notice Get VERN balance of this wallet
    /// @return Current VERN balance
    function getVERNBalance() external view returns (uint256) {
        return vern.balanceOf(address(this));
    }

    /// @notice Get remaining daily withdrawal limit for user
    /// @param user Address to check
    /// @return Remaining withdrawal amount for today
    function getRemainingDailyLimit(address user) external view returns (uint256) {
        if (block.timestamp >= lastDayReset[user] + 1 days) {
            return DAILY_WITHDRAWAL_LIMIT;
        }

        uint256 used = dailyWithdrawn[user];
        return used >= DAILY_WITHDRAWAL_LIMIT ? 0 : DAILY_WITHDRAWAL_LIMIT - used;
    }

    /// @notice Get time until next withdrawal allowed
    /// @param user Address to check
    /// @return Seconds until next withdrawal
    function getWithdrawalCooldown(address user) external view returns (uint256) {
        uint256 nextAllowed = lastWithdrawal[user] + WITHDRAWAL_COOLDOWN;
        return block.timestamp >= nextAllowed ? 0 : nextAllowed - block.timestamp;
    }

    /// @notice Check if emergency withdrawal is ready
    /// @return True if emergency withdrawal can be executed
    function isEmergencyReady() external view returns (bool) {
        return emergencyUnlockTime > 0 && block.timestamp >= emergencyUnlockTime;
    }

    /// @notice Get wallet info summary
    /// @return balance Current VERN balance
    /// @return dailyLimit Remaining daily withdrawal limit
    /// @return cooldown Seconds until next withdrawal
    /// @return emergencyReady Whether emergency withdrawal is ready
    function getWalletInfo()
        external
        view
        returns (uint256 balance, uint256 dailyLimit, uint256 cooldown, bool emergencyReady)
    {
        balance = vern.balanceOf(address(this));

        // Daily limit calculation
        if (block.timestamp >= lastDayReset[owner] + 1 days) {
            dailyLimit = DAILY_WITHDRAWAL_LIMIT;
        } else {
            uint256 used = dailyWithdrawn[owner];
            dailyLimit = used >= DAILY_WITHDRAWAL_LIMIT ? 0 : DAILY_WITHDRAWAL_LIMIT - used;
        }

        // Cooldown calculation
        uint256 nextAllowed = lastWithdrawal[owner] + WITHDRAWAL_COOLDOWN;
        cooldown = block.timestamp >= nextAllowed ? 0 : nextAllowed - block.timestamp;

        // Emergency status
        emergencyReady = emergencyUnlockTime > 0 && block.timestamp >= emergencyUnlockTime;
    }

    // ============ RECEIVE FUNCTION ============

    /// @notice Reject direct ETH deposits
    receive() external payable {
        revert("ETH not accepted");
    }

    /// @notice Reject function calls to non-existent functions
    fallback() external {
        revert("Function not found");
    }
}
