// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ERC8183} from "erc8183/ERC8183.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KlerosEvaluator} from "../../src/KlerosEvaluator.sol";

/// @title OptimisticCompletion
/// @dev Demo scenario: a job is accepted, the work is submitted and disclosed,
/// and nobody challenges.
///
/// NOTE This script deliberately stops at the submission: the challenge window
/// (30 min) must pass on-chain before completion is possible, so no single
/// script can run the whole scenario. Once the window passes, anyone
/// completes the job permissionlessly by calling finalize(jobId) on the evaluator.
///
/// Usage:
///   CLIENT_PK=0x... PROVIDER_PK=0x... forge script script/test_scenarios/OptimisticCompletion.s.sol \
///     --rpc-url $ARBITRUM_SEPOLIA_RPC --broadcast
contract OptimisticCompletion is Script {
    ERC8183 constant ESCROW = ERC8183(0x3745128DcE892cD86B926E7F3f1cE50C5Fa2F736);
    KlerosEvaluator constant EVALUATOR = KlerosEvaluator(0xf26b4FA85507914Ae0d3C58ac0D3A30c9C493103);
    IERC20 constant USDC = IERC20(0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d);
    uint256 constant BUDGET = 10e6;

    /// The delivered page and its content hash, pinned at the URI below.
    bytes32 constant DELIVERABLE = 0x085f523631a6195deea2e0e4a11013d22c8f6766d146153bfdf516f1cf05b734;
    string constant DELIVERABLE_URI = "ipfs://bafkreigrieedda2xoc6gtdgtbkynpccip4qvpq6cmdvkywb7vj4sf2bmre";

    function run() external {
        uint256 clientPk = vm.envUint("CLIENT_PK");
        uint256 providerPk = vm.envUint("PROVIDER_PK");
        address provider = vm.addr(providerPk);

        vm.startBroadcast(clientPk);
        uint256 jobId = ESCROW.createJob(
            provider,
            address(EVALUATOR),
            uint48(block.timestamp + 7 days),
            "A web page that shows the text: 'This is a PoC for a Kleros x ERC8183 integration'",
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

        vm.startBroadcast(providerPk);
        ESCROW.submit(jobId, DELIVERABLE, "");
        EVALUATOR.registerDeliverable(jobId, DELIVERABLE_URI, DELIVERABLE);
        vm.stopBroadcast();

        ERC8183.Job memory job = ESCROW.getJob(jobId);
        require(job.status == ERC8183.JobStatus.Submitted, "expected status Submitted");
        require(
            keccak256(bytes(EVALUATOR.deliverableURIs(jobId))) == keccak256(bytes(DELIVERABLE_URI)),
            "deliverable URI not registered"
        );
        console2.log("jobId:", jobId);
        console2.log("submitted and disclosed; finalize after the 30 min challenge window");
    }
}
