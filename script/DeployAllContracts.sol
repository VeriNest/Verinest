// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import "../src/VERNToken.sol";
import "../src/VERNStaking.sol";
import "../src/VeriNestDAO.sol";
import "../src/PropertyRegistry.sol";
import "../src/RoleVerification.sol";
import "../src/LaborMarketplace.sol";
import "../src/VernWallet.sol";
import "../src/EscrowVault.sol";
import "../src/Governance.sol";
import "../src/Whistleblower.sol";

/// @notice Optimized deployment script for Core Blockchain
contract DeployAllContracts is Script {
    function run() external {
        vm.startBroadcast();

        console.log("=== Starting Deployment on Core Blockchain ===");

        // Configuration - reduced variables
        address admin = 0x53C3687e77Af2b44036212C635a4184D2883659d;

        // Use inline arrays to reduce variables
        address[5] memory multisigSigners = [
            0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC,
            0xDDdDddDdDdddDDddDDddDDDDdDdDDdDDdDDDDDDd,
            0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE,
            0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF,
            0x1010101010101010101010101010101010101010
        ];

        console.log("Admin:", admin);

        // ============================
        // DEPLOYMENT SEQUENCE
        // ============================

        // 1) Deploy VERNToken with address(0) for staking
        console.log("\n1) Deploying VERNToken...");
        VERNToken vernToken = new VERNToken(
            admin,
            0x7777777777777777777777777777777777777777, // utilityPool
            0x8888888888888888888888888888888888888888, // agentPool
            0x9999999999999999999999999999999999999999, // communityAirdrop
            0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa, // treasuryDao
            address(0) // Temporary zero address
        );
        console.log("VERNToken deployed at:", address(vernToken));

        // 2) Deploy VERNStaking
        console.log("\n2) Deploying VERNStaking...");
        VERNStaking vernStaking = new VERNStaking(
            address(vernToken),
            address(0), // nftCollection
            admin
        );
        console.log("VERNStaking deployed at:", address(vernStaking));

        // 3) Funding staking contract
        console.log("\n3) Funding staking contract...");
        uint256 contractBalance = vernToken.balanceOf(address(vernToken));
        vernToken.withdrawTokens(address(vernStaking), contractBalance);
        console.log("Transferred", contractBalance / 10 ** 18, "VERN to staking");

        // 4) Deploy VeriNestDAO
        console.log("\n4) Deploying VeriNestDAO...");
        VeriNestDAO dao = new VeriNestDAO(address(vernToken));
        console.log("VeriNestDAO deployed at:", address(dao));

        // 5) Deploy RoleVerification
        console.log("\n5) Deploying RoleVerification...");
        RoleVerification roleVerification = new RoleVerification(address(dao), address(vernToken));
        console.log("RoleVerification deployed at:", address(roleVerification));

        // 6) Deploy Governance
        console.log("\n6) Deploying Governance...");
        Governance governance = new Governance(address(vernToken), multisigSigners);
        console.log("Governance deployed at:", address(governance));

        // 7) Deploy PropertyRegistry
        console.log("\n7) Deploying PropertyRegistry...");
        PropertyRegistry propertyRegistry = new PropertyRegistry();
        console.log("PropertyRegistry deployed at:", address(propertyRegistry));

        // 8) Deploy EscrowVault
        console.log("\n8) Deploying EscrowVault...");
        EscrowVault escrowVault = new EscrowVault(address(vernToken), address(dao));
        console.log("EscrowVault deployed at:", address(escrowVault));

        // 9) Deploy LaborMarketplace
        console.log("\n9) Deploying LaborMarketplace...");
        LaborMarketplace laborMarketplace = new LaborMarketplace(address(vernToken));
        console.log("LaborMarketplace deployed at:", address(laborMarketplace));

        // 10) Deploy VernWallet
        console.log("\n10) Deploying VernWallet...");
        VernWallet vernWallet = new VernWallet(
            address(vernToken),
            0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB // emergencyRecovery
        );
        console.log("VernWallet deployed at:", address(vernWallet));

        // 11) Deploy Whistleblower - FIXED: Use inline parameters
        console.log("\n11) Deploying Whistleblower...");
        Whistleblower whistleblower = new Whistleblower(
            address(vernToken),
            address(dao),
            admin // moderator
        );
        console.log("Whistleblower deployed at:", address(whistleblower));

        // Post-deployment setup
        console.log("\n=== Post-deployment configuration ===");
        roleVerification.setDAO(address(dao));
        propertyRegistry.addAgent(admin);
        laborMarketplace.registerAgent(admin);
        laborMarketplace.registerWorker(admin);

        vm.stopBroadcast();

        console.log("\n=== DEPLOYMENT COMPLETE ===");
    }
}