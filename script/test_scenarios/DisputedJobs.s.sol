// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ERC8183} from "erc8183/ERC8183.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KlerosEvaluator} from "../../src/KlerosEvaluator.sol";

/// @title DisputedJobs
/// @dev Demo scenario: three jobs under the same agreement are submitted and
/// challenged, creating three real disputes in the Agentic Commerce Court:
///   1. the delivered page satisfies the agreement (honest verdict: accept);
///   2. the delivered page does not (honest verdict: reject);
///   3. the provider registers nothing (policy rule 1: reject, never RtA).
///
/// NOTE After this script, the disputes are in the court's hands: sortition,
/// juror votes, and period passing happen on the arbitrator.
/// Then executeRuling triggers rule() on the evaluator and the escrow settles.
///
/// Usage:
///   CLIENT_PK=0x... PROVIDER_PK=0x... forge script script/test_scenarios/DisputedJobs.s.sol \
///     --rpc-url $ARBITRUM_SEPOLIA_RPC --broadcast
contract DisputedJobs is Script {
    ERC8183 constant ESCROW = ERC8183(0x3745128DcE892cD86B926E7F3f1cE50C5Fa2F736);
    KlerosEvaluator constant EVALUATOR = KlerosEvaluator(0xf26b4FA85507914Ae0d3C58ac0D3A30c9C493103);
    IERC20 constant USDC = IERC20(0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d);
    uint256 constant BUDGET = 10e6;

    string constant AGREEMENT =
        "A web page that shows the text: 'This is a PoC for a Kleros x ERC8183 integration'";

    /// The satisfying page and its content hash, pinned at the URI below.
    bytes32 constant PASS_DELIVERABLE = 0x085f523631a6195deea2e0e4a11013d22c8f6766d146153bfdf516f1cf05b734;
    string constant PASS_URI = "ipfs://bafkreigrieedda2xoc6gtdgtbkynpccip4qvpq6cmdvkywb7vj4sf2bmre";

    /// The failing page and its content hash.
    bytes32 constant FAIL_DELIVERABLE = 0xf33ec42672eca9218e82e09d360a5084941d2213cc069831c17ea5986aac7cf8;
    string constant FAIL_URI = "ipfs://bafkreif2y3eqjyhfimabz23vrurtbmibz3zfzujurlvbwp4pmwrgavradm";

    /// A commitment whose content is never registered.
    bytes32 constant UNDISCLOSED_DELIVERABLE = keccak256("undisclosed demo deliverable");

    function run() external {
        uint256 clientPk = vm.envUint("CLIENT_PK");
        uint256 providerPk = vm.envUint("PROVIDER_PK");
        address provider = vm.addr(providerPk);
        uint256 cost = EVALUATOR.arbitrator().arbitrationCost(
            EVALUATOR.arbitratorExtraData()
        );

        uint256[3] memory jobIds;

        vm.startBroadcast(clientPk);
        USDC.approve(address(ESCROW), 3 * BUDGET);
        for (uint256 i = 0; i < 3; i++) {
            jobIds[i] = ESCROW.createJob(
                provider,
                address(EVALUATOR),
                uint48(block.timestamp + 7 days),
                AGREEMENT,
                address(0),
                0
            );
        }
        vm.stopBroadcast();

        vm.startBroadcast(providerPk);
        for (uint256 i = 0; i < 3; i++) {
            ESCROW.setBudget(jobIds[i], address(USDC), BUDGET, "");
        }
        vm.stopBroadcast();

        vm.startBroadcast(clientPk);
        for (uint256 i = 0; i < 3; i++) {
            ESCROW.fund(jobIds[i], address(USDC), BUDGET, "");
            EVALUATOR.acceptJob(jobIds[i]);
        }
        vm.stopBroadcast();

        vm.startBroadcast(providerPk);
        ESCROW.submit(jobIds[0], PASS_DELIVERABLE, "");
        EVALUATOR.registerDeliverable(jobIds[0], PASS_URI, PASS_DELIVERABLE);
        ESCROW.submit(jobIds[1], FAIL_DELIVERABLE, "");
        EVALUATOR.registerDeliverable(jobIds[1], FAIL_URI, FAIL_DELIVERABLE);
        ESCROW.submit(jobIds[2], UNDISCLOSED_DELIVERABLE, "");
        vm.stopBroadcast();

        vm.startBroadcast(clientPk);
        for (uint256 i = 0; i < 3; i++) {
            EVALUATOR.challenge{value: cost}(jobIds[i]);
        }
        vm.stopBroadcast();

        for (uint256 i = 0; i < 3; i++) {
            require(EVALUATOR.challenged(jobIds[i]), "job not challenged");
        }
        console2.log("satisfying delivery, jobId:", jobIds[0]);
        console2.log("failing delivery, jobId:", jobIds[1]);
        console2.log("undisclosed delivery, jobId:", jobIds[2]);
        console2.log("arbitration cost paid per dispute (wei):", cost);
    }
}
