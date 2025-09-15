// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract VERNToken is ERC20, Ownable {
    using SafeERC20 for IERC20;

    struct UserData {
        bool isExempt;
        uint256 vestingEnd;
    }

    error MaxWalletLimitExceeded();
    error Unauthorized();
    error VestingActive();
    error ZeroAmount();
    error InsufficientBalance();

    uint256 public constant TOTAL_SUPPLY = 512_000_000 * 10 ** 18; // 512M VERN
    uint256 public constant CIRCULATING_SUPPLY = 256_000_000 * 1e18; // 256_000_000 VERN
    uint256 public constant LOCKED_SUPPLY = 256_000_000 * 1e18; // 256_000_000 VERN
    uint256 constant HALVING_PERIOD = 5 * 365 days;
    uint256 public constant MAX_USER_WALLET_PERCENT = 2;
    uint256 public constant PCT_ADMIN = 10;
    uint256 public constant PCT_UTILITY = 10;
    uint256 public constant PCT_AGENT = 10; // 10%

    uint256 public constant PCT_AIRDROP = 15;
    uint256 public constant PCT_TREASURY = 5;
    uint256 public constant PCT_STAKING = 25;
    uint256 public constant MAX_WALLET_LIMIT = 1_000_000 * 1e18; // 1,000,000 VERN

    event TokensWithdrawn(address indexed to, uint256 amount);
    event ExemptionSet(address indexed addr, bool isExempt);
    event VestingUpdated(address indexed addr, uint256 vestingEnd);
    event LockedSentToStaking(address indexed staking, uint256 amount);

    mapping(address => bool) public isExempt;
    mapping(address => UserData) public userData;
    mapping(address => uint256) public vestingEnd;

    // ----------------------------
    // Constructor
    // ----------------------------
    constructor(
        address _adminWallet,
        address utilityPool,
        address agentPool,
        address communityAirdropReserve,
        address treasuryDao,
        address stakingContract
    ) ERC20("VeriNest Token", "VERN") {
        require(_adminWallet != address(0), "Invalid admin wallet");

        _mint(address(this), TOTAL_SUPPLY);

        // FIXED: Calculate percentages based on TOTAL_SUPPLY, not CIRCULATING_SUPPLY
        uint256 adminTotal = (TOTAL_SUPPLY * PCT_ADMIN) / 100;
        uint256 utilityTotal = (TOTAL_SUPPLY * PCT_UTILITY) / 100;
        uint256 agentTotal = (TOTAL_SUPPLY * PCT_AGENT) / 100;
        uint256 airdropTotal = (TOTAL_SUPPLY * PCT_AIRDROP) / 100;
        uint256 treasuryTotal = (TOTAL_SUPPLY * PCT_TREASURY) / 100;

        // Single admin allocation
        userData[_adminWallet] = UserData(true, block.timestamp + 5 * 365 days);
        _transfer(address(this), _adminWallet, adminTotal);

        // Other allocations
        if (utilityPool != address(0)) {
            _transfer(address(this), utilityPool, utilityTotal);
        }
        if (agentPool != address(0)) {
            _transfer(address(this), agentPool, agentTotal);
        }
        if (communityAirdropReserve != address(0)) {
            _transfer(address(this), communityAirdropReserve, airdropTotal);
        }
        if (treasuryDao != address(0)) {
            _transfer(address(this), treasuryDao, treasuryTotal);
        }

        // Calculate remaining balance for staking
        uint256 remainingBalance = balanceOf(address(this));

        // Only transfer to staking contract if it's not address(0) AND there are tokens
        if (stakingContract != address(0) && remainingBalance > 0) {
            _transfer(address(this), stakingContract, remainingBalance);
            emit LockedSentToStaking(stakingContract, remainingBalance);
        }

        // Owner exempt
        userData[msg.sender].isExempt = true;
    }

    // Add this function to VERNToken.sol
    function setStakingAddress(address stakingContract) external onlyOwner {
        require(stakingContract != address(0), "Invalid staking contract");

        // Calculate the locked amount that should be transferred
        uint256 adminTotal = (CIRCULATING_SUPPLY * PCT_ADMIN) / 100;
        uint256 utilityTotal = (CIRCULATING_SUPPLY * PCT_UTILITY) / 100;
        uint256 agentTotal = (CIRCULATING_SUPPLY * PCT_AGENT) / 100;
        uint256 airdropTotal = (CIRCULATING_SUPPLY * PCT_AIRDROP) / 100;
        uint256 treasuryTotal = (CIRCULATING_SUPPLY * PCT_TREASURY) / 100;

        uint256 distributed = adminTotal + utilityTotal + agentTotal + airdropTotal + treasuryTotal;
        uint256 locked = LOCKED_SUPPLY - distributed;

        // Transfer the locked tokens to the staking contract
        _transfer(address(this), stakingContract, locked);
        emit LockedSentToStaking(stakingContract, locked);
    }

    function transferFromContract(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Invalid address");
        require(amount > 0, "Invalid amount");
        require(balanceOf(address(this)) >= amount, "Insufficient balance");

        _transfer(address(this), to, amount);
    }

    /// @notice Add or remove exempted address (admin only)
    function setExempt(address addr, bool exempt) external onlyOwner {
        isExempt[addr] = exempt;
        userData[addr].isExempt = exempt;
        emit ExemptionSet(addr, exempt);
    }

    /// @notice Manually set vesting end time
    function setVesting(address addr, uint256 timestamp) external onlyOwner {
        vestingEnd[addr] = timestamp;
        userData[addr].vestingEnd = timestamp;
        emit VestingUpdated(addr, timestamp);
    }

    /// @notice Withdraw tokens from contract (admin only)
    function withdrawTokens(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert Unauthorized();
        if (amount == 0) revert ZeroAmount();

        uint256 balance = balanceOf(address(this));
        if (amount > balance) revert InsufficientBalance();

        _transfer(address(this), to, amount);
        emit TokensWithdrawn(to, amount);
    }

    /// @notice Withdraw all tokens from contract (admin only)
    function withdrawAllTokens(address to) external onlyOwner {
        if (to == address(0)) revert Unauthorized();

        uint256 balance = balanceOf(address(this));
        if (balance == 0) revert InsufficientBalance();

        _transfer(address(this), to, balance);
        emit TokensWithdrawn(to, balance);
    }

    /// @notice Get the vesting end time for an address
    function getVestingEnd(address addr) external view returns (uint256) {
        return userData[addr].vestingEnd;
    }

    function isVestingActive(address addr) external view returns (bool) {
        return block.timestamp < userData[addr].vestingEnd;
    }

    function getVestingInfo(address addr) external view returns (uint256 endTime, bool isActive) {
        endTime = userData[addr].vestingEnd;
        isActive = block.timestamp < endTime;
    }
}
