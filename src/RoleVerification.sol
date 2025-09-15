// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

contract RoleVerification is Ownable {
    IERC20 public token;

    error AlreadyVerified();
    error NotVerified();
    error Blacklisted();
    error InvalidRole();
    error OnlyDAO();
    error ZeroAmount();
    error Unauthorized();
    error InsufficientBalance();

    enum Role {
        None,
        Agent,
        Lawyer,
        Worker
    }

    struct User {
        Role role;
        bool verified;
        bool blacklisted;
    }

    mapping(address => User) public users;

    address public daoAddress;

    event UserVerified(address indexed user, Role role);
    event UserBlacklisted(address indexed user);
    event UserUnblacklisted(address indexed user);
    event RoleUpdated(address indexed user, Role newRole);
    event DAOUpdated(address oldDAO, address newDAO);
    event TokensWithdrawn(address to, uint256 amount);

    modifier onlyDAO() {
        if (msg.sender != daoAddress) revert OnlyDAO();
        _;
    }

    constructor(address _dao, address _token) {
        if (_dao == address(0) || _token == address(0)) revert Unauthorized();
        daoAddress = _dao;
        token = IERC20(_token);
    }

    // === Registration === //

    function verifyUser(address user, Role role) external onlyOwner {
        if (users[user].blacklisted) revert Blacklisted();
        if (users[user].verified) revert AlreadyVerified();
        if (role == Role.None) revert InvalidRole();
        if (user == address(0)) revert Unauthorized();
        users[user] = User({role: role, verified: true, blacklisted: false});

        users[user].role = role;
        users[user].verified = true;

        emit UserVerified(user, role);
    }

    function updateRole(address user, Role newRole) external onlyOwner {
        if (!users[user].verified) revert NotVerified();
        if (newRole == Role.None) revert InvalidRole();
        if (users[user].blacklisted) revert Blacklisted();

        users[user].role = newRole;
        emit RoleUpdated(user, newRole);
    }

    // === DAO Moderation ===

    function blacklistUser(address user) external onlyDAO {
        if (user == address(0)) revert Unauthorized();
        users[user].blacklisted = true;
        emit UserBlacklisted(user);
    }

    function unblacklistUser(address user) external onlyDAO {
        if (users[user].blacklisted) revert Blacklisted();
        if (users[user].verified) revert AlreadyVerified();
        if (user == address(0)) revert Unauthorized();
        users[user].blacklisted = false;
        emit UserUnblacklisted(user);
    }

    // === Role/Status Getters ===

    function isVerified(address user) public view returns (bool) {
        return users[user].verified && !users[user].blacklisted;
    }

    function getRole(address user) public view returns (Role) {
        return users[user].role;
    }

    function setDAO(address newDAO) external onlyOwner {
        if (newDAO == address(0)) revert Unauthorized();
        emit DAOUpdated(daoAddress, newDAO);
        daoAddress = newDAO;
    }

    function isBlacklisted(address user) public view returns (bool) {
        return users[user].blacklisted;
    }

    function withdraw(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert Unauthorized();
        if (amount == 0) revert ZeroAmount();

        uint256 balance = token.balanceOf(address(this));
        require(balance >= amount, "InsufficientBalance");

        token.transfer(to, amount);

        emit TokensWithdrawn(to, amount);
        require(token.transfer(to, amount), "Transfer failed");
    }
}
