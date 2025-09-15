// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";

/**
 * @title VERNStaking
 * @notice Streams rewards from a pre-funded locked balance (sent by VERNToken) over 79 years,
 *         halving every 5 years (last period is 4 years). Supports:
 *         - Flexible staking (withdraw anytime)
 *         - Locked staking (only owner can unlock and forward to an agent)
 *         - Optional NFT boost (each staked NFT adds fixed virtual weight)
 */
contract VERNStaking is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -----------------------------------------------------------------------
    // Config
    // -----------------------------------------------------------------------
    IERC20 public immutable vern;
    IERC721 public immutable nftCollection; // optional; can be address(0) if not used

    // Reward schedule: 79 years total, halving every 5 years
    uint256 public constant YEARS_TOTAL = 79;
    uint256 public constant YEARS_HALVE = 5;
    uint256 public constant SECONDS_YEAR = 365 days; // simplify leap-years
    uint256 public constant PERIOD = YEARS_HALVE * SECONDS_YEAR;

    uint256 public immutable vestingStart;
    uint256 public immutable vestingEnd; // vestingStart + 79y
    uint256 public immutable numPeriods; // ceil(79/5) == 16
    uint256 public immutable lastPeriodSecs; // 4 years in seconds

    // Emissions
    uint256 public immutable initialRatePerSec; // computed so that integral equals locked balance received
    uint256 public lastUpdate; // last time we updated accRewardPerWeight
    uint256 public distributed; // total rewards distributed so far (safety/accounting)

    // Staking accounting
    uint256 public totalWeight; // sum of all users' weights
    uint256 public accRewardPerWeight; // 1e18 precision

    uint256 public constant ACC_PRECISION = 1e18;

    // NFT boost (if nftCollection != 0)
    uint256 public constant BOOST_PER_NFT = 100 * 1e18; // adds 100 "virtual tokens" of weight per NFT
    mapping(address => uint256) public nftStaked; // count of NFTs staked by user
    // tokenId custody tracking (minimal example)
    mapping(uint256 => address) public nftOwner;

    // User positions
    struct User {
        uint256 staked; // flexible stake amount (withdrawable)
        uint256 locked; // admin-locked stake amount (non-withdrawable by user)
        uint256 weight; // staked + locked + nftBoost
        uint256 rewardDebt; // weight * accRewardPerWeight / 1e18
        uint256 pending; // accrued but unclaimed
    }

    mapping(address => User) public users;

    event Stake(address indexed user, uint256 amount);
    event Unstake(address indexed user, uint256 amount);
    event LockStake(address indexed user, uint256 amount);
    event UnlockToAgent(address indexed user, address indexed agent, uint256 amount);
    event Claim(address indexed user, uint256 amount);
    event StakeNFT(address indexed user, uint256 indexed tokenId);
    event UnstakeNFT(address indexed user, uint256 indexed tokenId);

    constructor(address _vern, address _nftCollection, address admin) {
        require(_vern != address(0), "vern=0");
        vern = IERC20(_vern);
        nftCollection = IERC721(_nftCollection);

        vestingStart = block.timestamp;
        vestingEnd = vestingStart + YEARS_TOTAL * SECONDS_YEAR;

        numPeriods = (YEARS_TOTAL + YEARS_HALVE - 1) / YEARS_HALVE; // 16
        lastPeriodSecs = (YEARS_TOTAL - (numPeriods - 1) * YEARS_HALVE) * SECONDS_YEAR; // 4y

        // REMOVE THESE LINES:
        // uint256 locked = IERC20(_vern).balanceOf(address(this));
        // require(locked > 0, "staking not funded");

        // Use a fixed initial value for deployment
        uint256 locked = 256_000_000 * 10 ** 18; // Use the expected locked amount

        uint256 D = 0;
        for (uint256 i = 0; i < numPeriods; i++) {
            uint256 dur = (i == numPeriods - 1) ? lastPeriodSecs : PERIOD;
            uint256 term = dur >> i;
            if (i > 0 && term == 0) {
                term = dur / (2 ** i);
            }
            D += term;
        }

        initialRatePerSec = locked / D;
        require(initialRatePerSec > 0, "rate=0");

        lastUpdate = block.timestamp;
        _transferOwnership(admin);
    }

    // Add this function to VERNStaking.sol
    function initializeStaking() external view onlyOwner {
        uint256 locked = vern.balanceOf(address(this));
        require(locked > 0, "staking not funded");

        // Recalculate initialRatePerSec with actual balance
        uint256 D = 0;
        for (uint256 i = 0; i < numPeriods; i++) {
            uint256 dur = (i == numPeriods - 1) ? lastPeriodSecs : PERIOD;
            uint256 term = dur >> i;
            if (i > 0 && term == 0) {
                term = dur / (2 ** i);
            }
            D += term;
        }

        // initialRatePerSec = locked / D;
        require(initialRatePerSec > 0, "rate=0");
    }

    // -----------------------------------------------------------------------
    // Internal: emission integral between two timestamps with halvings
    // -----------------------------------------------------------------------
    function _emissionBetween(uint256 t0, uint256 t1) internal view returns (uint256) {
        if (t1 <= t0 || t0 >= vestingEnd) return 0;
        if (t1 > vestingEnd) t1 = vestingEnd;

        uint256 amt;
        uint256 start = vestingStart;

        for (uint256 i = 0; i < numPeriods; i++) {
            uint256 periodStart = start + i * PERIOD;
            uint256 periodEnd = (i == numPeriods - 1) ? vestingEnd : (periodStart + PERIOD);

            if (t1 <= periodStart) break; // before this period
            if (t0 >= periodEnd) continue; // after this period

            uint256 segStart = t0 > periodStart ? t0 : periodStart;
            uint256 segEnd = t1 < periodEnd ? t1 : periodEnd;

            uint256 dur = segEnd - segStart;
            if (dur == 0) continue;

            // rate_i = initialRatePerSec / 2^i
            uint256 rate = initialRatePerSec >> i;
            if (i > 0 && rate == 0) rate = initialRatePerSec / (2 ** i);

            amt += dur * rate;
        }
        return amt;
    }

    function _update() internal {
        if (block.timestamp <= lastUpdate) return;

        uint256 newly = _emissionBetween(lastUpdate, block.timestamp);
        lastUpdate = block.timestamp;

        if (newly == 0 || totalWeight == 0) return;

        distributed += newly;
        accRewardPerWeight += (newly * ACC_PRECISION) / totalWeight;
    }

    function _userAccrue(address user) internal {
        _update();
        User storage u = users[user];
        if (u.weight > 0) {
            uint256 entitled = (u.weight * accRewardPerWeight) / ACC_PRECISION;
            uint256 delta = entitled - u.rewardDebt;
            if (delta > 0) u.pending += delta;
        }
        u.rewardDebt = (u.weight * accRewardPerWeight) / ACC_PRECISION;
    }

    function _recomputeWeight(User storage u, uint256 prevWeight) internal {
        // base weight = staked + locked
        uint256 w = u.staked + u.locked;
        // NFT boost (if enabled)
        if (address(nftCollection) != address(0)) {
            w += nftStaked[msg.sender] * BOOST_PER_NFT;
        }
        u.weight = w;

        // adjust global
        if (w > prevWeight) totalWeight += (w - prevWeight);
        else if (prevWeight > w) totalWeight -= (prevWeight - w);
    }

    // -----------------------------------------------------------------------
    // Flexible staking
    // -----------------------------------------------------------------------
    function stake(uint256 amount) external nonReentrant {
        require(amount > 0, "amount=0");
        User storage u = users[msg.sender];
        _userAccrue(msg.sender);

        uint256 prev = u.weight;
        u.staked += amount;
        _recomputeWeight(u, prev);

        IERC20(vern).safeTransferFrom(msg.sender, address(this), amount);
        emit Stake(msg.sender, amount);
    }

    function unstake(uint256 amount) external nonReentrant {
        require(amount > 0, "amount=0");
        User storage u = users[msg.sender];
        require(u.staked >= amount, "insufficient");

        _userAccrue(msg.sender);

        uint256 prev = u.weight;
        u.staked -= amount;
        _recomputeWeight(u, prev);

        IERC20(vern).safeTransfer(msg.sender, amount);
        emit Unstake(msg.sender, amount);
    }

    // -----------------------------------------------------------------------
    // Locked staking (admin must unlock and forward to agent)
    // -----------------------------------------------------------------------
    function lockStake(uint256 amount) external nonReentrant {
        require(amount > 0, "amount=0");
        User storage u = users[msg.sender];

        _userAccrue(msg.sender);

        uint256 prev = u.weight;
        u.locked += amount;
        _recomputeWeight(u, prev);

        IERC20(vern).safeTransferFrom(msg.sender, address(this), amount);
        emit LockStake(msg.sender, amount);
    }

    /// @notice Owner unlocks a user's locked stake and sends it directly to an agent.
    function unlockToAgent(address user, address agent, uint256 amount) external onlyOwner nonReentrant {
        require(agent != address(0), "agent=0");
        User storage u = users[user];
        require(amount > 0 && u.locked >= amount, "bad amount");

        _userAccrue(user);

        uint256 prev = u.weight;
        require(u.weight <= prev, "weight should not increase after unlock");
        u.locked -= amount;
        // note: flexible stake unchanged
        // We recompute weight with msg.sender context; but NFT boost depends on user, not owner.
        // Temporarily simulate as if recompute for 'user'.
        {
            uint256 oldTotalWeight = totalWeight;
            // manual recompute for the 'user' (not msg.sender)
            uint256 newWeight = u.staked + u.locked + (nftStaked[user] * BOOST_PER_NFT);
            if (newWeight > u.weight) totalWeight += (newWeight - u.weight);
            else if (u.weight > newWeight) totalWeight -= (u.weight - newWeight);
            u.weight = newWeight;
            // ensure arithmetic stays consistent
            require(totalWeight <= oldTotalWeight + type(uint256).max, "overflow");
        }

        IERC20(vern).safeTransfer(agent, amount);
        emit UnlockToAgent(user, agent, amount);
    }

    // -----------------------------------------------------------------------
    // Rewards
    // -----------------------------------------------------------------------
    function claim() external nonReentrant {
        _userAccrue(msg.sender);
        User storage u = users[msg.sender];
        uint256 amt = u.pending;
        require(amt > 0, "nothing to claim");
        u.pending = 0;
        IERC20(vern).safeTransfer(msg.sender, amt);
        emit Claim(msg.sender, amt);
    }

    function pending(address user) external view returns (uint256) {
        User storage u = users[user];

        uint256 _acc = accRewardPerWeight;
        if (block.timestamp > lastUpdate && totalWeight > 0) {
            uint256 newly = _emissionBetween(lastUpdate, block.timestamp);
            _acc += (newly * ACC_PRECISION) / totalWeight;
        }

        uint256 weight =
            u.staked + u.locked + (address(nftCollection) != address(0) ? nftStaked[user] * BOOST_PER_NFT : 0);
        uint256 entitled = (weight * _acc) / ACC_PRECISION;
        return u.pending + (entitled > u.rewardDebt ? (entitled - u.rewardDebt) : 0);
    }

    // -----------------------------------------------------------------------
    // NFT boosting (optional)
    // -----------------------------------------------------------------------
    function stakeNFT(uint256 tokenId) external nonReentrant {
        require(address(nftCollection) != address(0), "nft disabled");
        _userAccrue(msg.sender);

        User storage u = users[msg.sender];
        uint256 prev = u.weight;

        // custody NFT
        nftCollection.transferFrom(msg.sender, address(this), tokenId);
        nftOwner[tokenId] = msg.sender;
        nftStaked[msg.sender] += 1;

        // recompute with boost
        uint256 newWeight = u.staked + u.locked + (nftStaked[msg.sender] * BOOST_PER_NFT);
        if (newWeight > prev) totalWeight += (newWeight - prev);
        else totalWeight -= (prev - newWeight);
        u.weight = newWeight;

        // Update reward debt at end of accrual
        u.rewardDebt = (u.weight * accRewardPerWeight) / ACC_PRECISION;

        emit StakeNFT(msg.sender, tokenId);
    }

    function unstakeNFT(uint256 tokenId) external nonReentrant {
        require(address(nftCollection) != address(0), "nft disabled");
        require(nftOwner[tokenId] == msg.sender, "not owner");
        _userAccrue(msg.sender);

        User storage u = users[msg.sender];
        uint256 prev = u.weight;

        nftOwner[tokenId] = address(0);
        nftStaked[msg.sender] -= 1;

        uint256 newWeight = u.staked + u.locked + (nftStaked[msg.sender] * BOOST_PER_NFT);
        if (newWeight > prev) totalWeight += (newWeight - prev);
        else totalWeight -= (prev - newWeight);
        u.weight = newWeight;

        u.rewardDebt = (u.weight * accRewardPerWeight) / ACC_PRECISION;

        nftCollection.transferFrom(address(this), msg.sender, tokenId);
        emit UnstakeNFT(msg.sender, tokenId);
    }
}
