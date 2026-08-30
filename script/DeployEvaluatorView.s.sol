// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {KlerosEvaluatorView} from "../src/KlerosEvaluatorView.sol";

/// @title DeployEvaluatorView
/// @dev Deploys the KlerosEvaluatorView aggregator. One deployment serves
/// every evaluator on the chain; its address goes into template/data-mappings.json.
///
/// Usage:
///   forge script script/DeployEvaluatorView.s.sol --rpc-url $ARBITRUM_SEPOLIA_RPC \
///     --private-key $DEPLOYER_PK --broadcast
contract DeployEvaluatorView is Script {
    function run() external {
        vm.startBroadcast();
        KlerosEvaluatorView viewer = new KlerosEvaluatorView();
        vm.stopBroadcast();
        console2.log("KlerosEvaluatorView:", address(viewer));
    }
}
