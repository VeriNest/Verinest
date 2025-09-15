// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./RoleVerification.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";

interface IRoleVerification {
    function isVerified(address user) external view returns (bool);
    function getRole(address user) external view returns (uint8);
}

contract EscrowVault is Ownable, ReentrancyGuard {
    using ECDSA for bytes32;

    // -----------------------------
    // Errors
    // -----------------------------
    error AlreadyApproved();
    error NotParticipant();
    error NotFinalized();
    error FundsNotAvailable();
    error TimeoutNotReached();
    error AlreadyReleased();
    error NotAdmin();
    error InvalidAdmin();
    error DuplicateAdmin();
    error TooManyAdmins();

    IERC20 public immutable vernToken;
    address public dao; // emergency override

    uint8 constant ROLE_AGENT = 3;
    uint8 constant ROLE_LAWYER = 4;
    uint256 public escrowCounter;
    uint256 public constant TIMEOUT = 7 days;

    enum Role {
        None,
        Buyer,
        Seller,
        Agent,
        Lawyer
    }

    struct Escrow {
        uint256 id;
        uint256 amount;
        address buyer;
        address seller;
        address agent;
        address lawyer;
        bool released;
        uint256 createdAt;
        mapping(address => bool) approved;
    }

    mapping(address => bool) public approved;
    mapping(uint256 => Escrow) private escrows;

    event EscrowCreated(uint256 indexed id, uint256 amount);
    event Approved(uint256 indexed id, address signer);
    event Released(uint256 indexed id, address to);
    event Cancelled(uint256 indexed id);
    event EscrowFinalized(uint256 indexed id);

    constructor(address _vern, address _dao) {
        vernToken = IERC20(_vern);
        dao = _dao;
    }

    modifier onlyDAO() {
        require(msg.sender == dao, "Only DAO");
        _;
    }

    function createEscrow(address seller, address agent, address lawyer, uint256 amount) external returns (uint256) {
        require(amount > 0, "Zero amount");

        vernToken.transferFrom(msg.sender, address(this), amount);

        uint256 id = escrowCounter++;
        Escrow storage e = escrows[id];

        e.id = id;
        e.amount = amount;
        e.buyer = msg.sender;
        e.seller = seller;
        e.agent = agent;
        e.lawyer = lawyer;
        e.createdAt = block.timestamp;

        emit EscrowCreated(id, amount);
        return id;
    }

    function approve(uint256 id, bytes calldata signature) external nonReentrant {
        Escrow storage e = escrows[id];
        require(!_hasReleased(e), "Already released");

        address sender = msg.sender;
        if (sender != e.buyer && sender != e.seller && sender != e.agent && sender != e.lawyer) revert NotParticipant();

        if (e.approved[sender]) revert AlreadyApproved();

        bytes32 hash = keccak256(abi.encodePacked(address(this), id, sender, e.createdAt)).toEthSignedMessageHash();
        address recovered = hash.recover(signature);
        require(recovered == sender, "Invalid signature");

        e.approved[sender] = true;

        emit Approved(id, sender);

        if (_allApproved(e)) {
            _release(id);
        }
    }

    function _release(uint256 id) internal {
        Escrow storage e = escrows[id];
        e.released = true;
        vernToken.transfer(e.seller, e.amount);
        emit Released(id, e.seller);
    }

    function cancelAfterTimeout(uint256 id) external nonReentrant {
        Escrow storage e = escrows[id];

        require(!_hasReleased(e), "Already released");
        require(block.timestamp >= e.createdAt + TIMEOUT, "Timeout not reached");
        vernToken.transfer(e.buyer, e.amount);
        e.released = true;

        emit Cancelled(id);
    }

    function forceRelease(uint256 id) external onlyDAO nonReentrant {
        Escrow storage e = escrows[id];
        require(!_hasReleased(e), "Already released");
        _release(id);
    }

    function _hasReleased(Escrow storage e) internal view returns (bool) {
        return e.released;
    }

    function _allApproved(Escrow storage e) internal view returns (bool) {
        return e.approved[e.buyer] && e.approved[e.seller] && e.approved[e.agent] && e.approved[e.lawyer];
    }

    function cancelByBuyer(uint256 id) external {
        Escrow storage e = escrows[id];
        require(msg.sender == e.buyer, "Not buyer");
        require(!_hasReleased(e), "Already released");
        require(!_allApproved(e), "Already approved");

        e.released = true;
        // vernToken.safeTransfer(e.buyer, e.amount);
        emit Cancelled(id);
    }

    function _atLeastNApproved(Escrow storage e, uint256 n) internal view returns (bool) {
        uint256 count;
        if (e.approved[e.buyer]) count++;
        if (e.approved[e.seller]) count++;
        if (e.approved[e.agent]) count++;
        if (e.approved[e.lawyer]) count++;
        return count >= n;
    }

    function setDAO(address newDAO) external onlyOwner {
        dao = newDAO;
    }

    function getEscrowParticipants(uint256 id)
        external
        view
        returns (address buyer, address seller, address agent, address lawyer, uint256 amount, bool released)
    {
        Escrow storage e = escrows[id];
        return (e.buyer, e.seller, e.agent, e.lawyer, e.amount, e.released);
    }

    function isApproved(uint256 id, address user) external view returns (bool) {
        return escrows[id].approved[user];
    }

    function getEscrowCount() external view returns (uint256) {
        return escrowCounter;
    }

    function getEscrow(uint256 id) internal view returns (Escrow storage) {
        return escrows[id];
    }

    function getEscrowFields(uint256 id) external view returns (address buyer, address seller, uint256 amount) {
        Escrow storage esc = escrows[id];
        return (esc.buyer, esc.seller, esc.amount);
    }

    function getEscrowStatus(uint256 id) external view returns (bool released, uint256 createdAt) {
        Escrow storage esc = escrows[id];
        return (esc.released, esc.createdAt);
    }

    function getEscrowApproved(uint256 id, address user) external view returns (bool) {
        return escrows[id].approved[user];
    }

    function getEscrowByIdPublic(uint256 id)
        external
        view
        returns (uint256, uint256, address, address, address, address, bool, uint256)
    {
        Escrow storage esc = escrows[id];
        return (esc.id, esc.amount, esc.buyer, esc.seller, esc.agent, esc.lawyer, esc.released, esc.createdAt);
    }
}
