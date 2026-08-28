// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ERC8183} from "erc8183/ERC8183.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {KlerosEvaluator} from "../src/KlerosEvaluator.sol";
import {IArbitratorV2} from "../src/interfaces/IArbitratorV2.sol";
import {IDisputeTemplateRegistry} from "../src/interfaces/IDisputeTemplateRegistry.sol";

/// @title Deploy
/// @dev Deploys the PoC stack on Arbitrum Sepolia against the Kleros v2 testnet
/// deployment: ERC-8183 escrow (implementation behind an ERC1967 proxy) and the
/// KlerosEvaluator. Jobs pay in Circle's testnet USDC.
///
/// Usage:
///   forge script script/Deploy.s.sol --rpc-url $ARBITRUM_SEPOLIA_RPC \
///     --private-key $DEPLOYER_PK --broadcast
contract Deploy is Script {
    /// Kleros v2 Arbitrum Sepolia testnet deployment.
    IArbitratorV2 constant KLEROS_CORE =
        IArbitratorV2(0xE8442307d36e9bf6aB27F1A009F95CE8E11C3479);
    IDisputeTemplateRegistry constant TEMPLATE_REGISTRY =
        IDisputeTemplateRegistry(0xe763d31Cb096B4bc7294012B78FC7F148324ebcb);

    address constant USDC = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d;

    /// Agentic Commerce Court, 3 jurors, classic dispute kit.
    uint256 constant COURT_ID = 8;
    uint256 constant NB_JURORS = 3;
    uint256 constant DISPUTE_KIT_CLASSIC = 1;

    uint256 constant CHALLENGE_WINDOW = 30 minutes;
    uint256 constant MIN_EXPIRY_MARGIN = 2 days;

    // For the purpose of showing how evaluator fees are handled. 0% fee is valid too.
    uint256 constant EVALUATOR_FEE_BP = 200;

    function run() external {
        string memory templateData = vm.readFile(
            "template/dispute-template.json"
        );
        string memory templateDataMappings = vm.readFile(
            "template/data-mappings.json"
        );

        vm.startBroadcast();
        address deployer = msg.sender;

        ERC8183 escrow = ERC8183(
            address(
                new ERC1967Proxy(
                    address(new ERC8183()),
                    abi.encodeCall(ERC8183.initialize, (deployer, deployer))
                )
            )
        );
        escrow.setPaymentTokenAllowed(USDC, true);
        escrow.setEvaluatorFee(EVALUATOR_FEE_BP);

        KlerosEvaluator evaluator = new KlerosEvaluator(
            deployer,
            escrow,
            KLEROS_CORE,
            abi.encode(COURT_ID, NB_JURORS, DISPUTE_KIT_CLASSIC),
            CHALLENGE_WINDOW,
            MIN_EXPIRY_MARGIN,
            TEMPLATE_REGISTRY,
            templateData,
            templateDataMappings
        );

        vm.stopBroadcast();

        console2.log("ERC8183 escrow (proxy):", address(escrow));
        console2.log("KlerosEvaluator:", address(evaluator));
        console2.log("templateId:", evaluator.templateId());
    }
}
