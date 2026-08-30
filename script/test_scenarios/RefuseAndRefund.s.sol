// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ERC8183} from "erc8183/ERC8183.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KlerosEvaluator} from "../../src/KlerosEvaluator.sol";

/// @title RefuseAndRefund
/// @dev Demo scenario: the evaluator refuses a job whose expiry is inside
/// the minimum margin, rejecting it on the escrow and refunding the client.
///
/// Usage:
///   CLIENT_PK=0x... PROVIDER_PK=0x... forge script script/test_scenarios/RefuseAndRefund.s.sol \
///     --rpc-url $ARBITRUM_SEPOLIA_RPC --broadcast
contract RefuseAndRefund is Script {
    ERC8183 constant ESCROW = ERC8183(0x3745128DcE892cD86B926E7F3f1cE50C5Fa2F736);
    KlerosEvaluator constant EVALUATOR = KlerosEvaluator(0xf26b4FA85507914Ae0d3C58ac0D3A30c9C493103);
    IERC20 constant USDC = IERC20(0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d);
    uint256 constant BUDGET = 10e6;

    function run() external {
        uint256 clientPk = vm.envUint("CLIENT_PK");
        uint256 providerPk = vm.envUint("PROVIDER_PK");
        address client = vm.addr(clientPk);
        address provider = vm.addr(providerPk);
        uint256 startBalance = USDC.balanceOf(client);

        vm.startBroadcast(clientPk);
        uint256 jobId = ESCROW.createJob(
            provider,
            address(EVALUATOR),
            uint48(block.timestamp + 1 days), // Inside the 2-day margin: the evaluator must refuse.
            "Refusal smoke test - expiry too close",
            address(0),
            0
        );
        vm.stopBroadcast();

        vm.startBroadcast(providerPk);
        ESCROW.setBudget(jobId, address(USDC), BUDGET, "");
        vm.stopBroadcast();

        vm.startBroadcast(clientPk);
        USDC.approve(address(ESCROW), BUDGET);
        ESCROW.fund(jobId, address(USDC), BUDGET, "");
        EVALUATOR.acceptJob(jobId);
        vm.stopBroadcast();

        ERC8183.Job memory job = ESCROW.getJob(jobId);
        require(job.status == ERC8183.JobStatus.Rejected, "expected status Rejected");
        require(USDC.balanceOf(client) == startBalance, "expected full refund");
        console2.log("jobId:", jobId);
        console2.log("refused, rejected on escrow, client refunded in full");
    }
}
