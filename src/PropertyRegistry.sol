// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";

contract PropertyRegistry is ERC721, Ownable {
    using ECDSA for bytes32;

    error Unauthorized();
    error AlreadySigned();
    error NotAllSigned();
    error AlreadyFinalized();
    error InvalidSignature();
    error AlreadyVerified();
    error NotVerified();
    error Blacklisted();
    error InvalidRole();
    error OnlyDAO();
    error ZeroAmount();

    enum Status {
        Pending,
        Signed,
        Finalized
    }

    struct Property {
        string ipfsHash;
        address agent;
        address landlord;
        address buyer;
        address lawyer;
        Status status;
        address[] signers;
    }

    uint256 public nextPropertyId;
    mapping(address => bool) public isAgent;
    mapping(string => bool) public usedHash;
    mapping(uint256 => Property) public properties;
    mapping(uint256 => address[]) public signers;
    mapping(uint256 => mapping(address => bool)) public hasSigned;

    event PropertyListed(uint256 indexed id, address agent, address landlord, string ipfsHash);
    event PropertySigned(uint256 indexed id, address signer);
    event PropertyFinalized(uint256 indexed id, address buyer);

    constructor() ERC721("VeriNest Property", "VERIPROP") {}

    modifier onlyAgent() {
        require(isAgent[msg.sender], "Not a verified agent");
        _;
    }

    function agentOnlyFunction() external view onlyAgent returns (bool) {
        return true;
    }

    function listProperty(address landlord, address buyer, address lawyer, string calldata ipfsHash)
        external
        onlyAgent
        returns (uint256)
    {
        require(landlord != address(0), "Invalid landlord address");
        require(buyer != address(0), "Invalid buyer address");
        require(lawyer != address(0), "Invalid lawyer address");
        require(bytes(ipfsHash).length > 0, "IPFS hash cannot be empty");
        if (usedHash[ipfsHash]) revert("Hash already used");
        usedHash[ipfsHash] = true;
        uint256 id = nextPropertyId++;
        Property storage p = properties[id];

        p.ipfsHash = ipfsHash;
        p.agent = msg.sender;
        p.landlord = landlord;
        p.buyer = buyer;
        p.lawyer = lawyer;
        p.status = Status.Pending;

        signers[id] = [msg.sender, landlord, buyer, lawyer];

        emit PropertyListed(id, msg.sender, landlord, ipfsHash);
        return id;
    }

    function getProperty(uint256 id) external view returns (string memory, address, address, address, address, uint8) {
        Property storage p = properties[id];
        return (p.ipfsHash, p.agent, p.landlord, p.buyer, p.lawyer, uint8(p.status));
    }

    function signProperty(uint256 id, bytes calldata signature) external {
        Property storage p = properties[id];
        require(isAgent[msg.sender], "Not a verified agent");

        if (msg.sender != p.agent && msg.sender != p.landlord && msg.sender != p.buyer && msg.sender != p.lawyer) {
            revert Unauthorized();
        }

        if (p.status == Status.Finalized) revert AlreadyFinalized();
        if (hasSigned[id][msg.sender]) revert AlreadySigned();

        bytes32 hash = keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32", keccak256(abi.encode(address(this), block.chainid, id, msg.sender))
            )
        );
        address signer = hash.recover(signature);

        if (signer != msg.sender) revert InvalidSignature();

        hasSigned[id][msg.sender] = true;
        emit PropertySigned(id, msg.sender);

        if (_allSigned(id)) {
            p.status = Status.Finalized;
            _mint(p.buyer, id);
            emit PropertyFinalized(id, p.buyer);
        }
    }

    function revokeSignature(uint256 id) external {
        Property storage p = properties[id];
        require(p.status != Status.Finalized, "Already finalized");
        require(hasSigned[id][msg.sender], "Not signed yet");
        hasSigned[id][msg.sender] = false;
    }

    function _allSigned(uint256 id) internal view returns (bool) {
        address[] memory parties = signers[id];
        for (uint256 i = 0; i < parties.length; i++) {
            if (!hasSigned[id][parties[i]]) return false;
        }
        return true;
    }

    function updateMetadata(uint256 id, string calldata newHash) external {
        Property storage p = properties[id];
        require(msg.sender == p.agent, "Only agent");
        require(p.status == Status.Pending, "Already signed");
        p.ipfsHash = newHash;
    }

    function getStatus(uint256 id) external view returns (Status) {
        return properties[id].status;
    }

    function getParties(uint256 id) external view returns (address[] memory) {
        return signers[id];
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        require(_exists(id), "URI query for nonexistent token");
        return string(abi.encodePacked("ipfs://", properties[id].ipfsHash));
    }

    function addAgent(address agent) external onlyOwner {
        isAgent[agent] = true;
    }

    // function registerProperty(address _owner, string memory _hashValue) public onlyAgent {
    //     require(!usedHash[_hashValue], "Hash already used");

    //     properties[nextPropertyId] = Property({
    //         owner: _owner,
    //         hashValue: _hashValue,
    //         exists: true
    //     });

    //     usedHash[_hashValue] = true;
    //     nextPropertyId++;
    // }
}
