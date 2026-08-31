// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC8183} from "erc8183/ERC8183.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {KlerosEvaluator} from "../src/KlerosEvaluator.sol";
import {KlerosEvaluatorView} from "../src/KlerosEvaluatorView.sol";
import {IArbitrableV2} from "../src/interfaces/IArbitrableV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {MockArbitrator} from "./mocks/MockArbitrator.sol";
import {MockTemplateRegistry} from "./mocks/MockTemplateRegistry.sol";

/// @dev A client with no receive function, so the excess refund in challenge() fails.
contract RejectingClient {

}

contract KlerosEvaluatorTest is Test {
    uint256 constant BUDGET = 1000e18;
    uint256 constant CHALLENGE_WINDOW = 1 days;
    uint256 constant MIN_EXPIRY_MARGIN = 14 days;
    uint48 constant JOB_LIFETIME = 30 days;
    string constant TEMPLATE_DATA = "template data";
    string constant TEMPLATE_MAPPINGS = "template mappings";

    ERC8183 escrow;
    TestERC20 token;
    MockArbitrator arbitrator;
    MockTemplateRegistry templateRegistry;
    KlerosEvaluator evaluator;

    address client = makeAddr("client");
    address provider = makeAddr("provider");
    address treasury = makeAddr("treasury");
    address evaluatorFeeRecipient = makeAddr("evaluatorFeeRecipient");

    function setUp() public {
        // The escrow is deployed exactly as its authors intend: implementation
        // behind an ERC1967 proxy, initialized with a treasury and an admin.
        escrow = ERC8183(
            address(
                new ERC1967Proxy(
                    address(new ERC8183()),
                    abi.encodeCall(
                        ERC8183.initialize,
                        (treasury, address(this))
                    )
                )
            )
        );
        token = new TestERC20();
        escrow.setPaymentTokenAllowed(address(token), true);
        arbitrator = new MockArbitrator();
        templateRegistry = new MockTemplateRegistry();
        // Occupy template id 0, so asserting the evaluator's id is meaningful.
        templateRegistry.setDisputeTemplate("", "taken", "");
        evaluator = new KlerosEvaluator(
            address(this),
            escrow,
            arbitrator,
            "",
            CHALLENGE_WINDOW,
            MIN_EXPIRY_MARGIN,
            templateRegistry,
            TEMPLATE_DATA,
            TEMPLATE_MAPPINGS
        );

        vm.deal(client, 1 ether);
    }

    // ************************************* //
    // *             Helpers               * //
    // ************************************* //

    function createFundedJobAs(
        address _client,
        uint48 _lifetime
    ) internal returns (uint256 jobId) {
        token.mint(_client, BUDGET);
        vm.prank(_client);
        jobId = escrow.createJob(
            provider,
            address(evaluator),
            uint48(block.timestamp) + _lifetime,
            "a job",
            address(0),
            0
        );
        vm.prank(provider);
        escrow.setBudget(jobId, address(token), BUDGET, "");
        vm.startPrank(_client);
        token.approve(address(escrow), BUDGET);
        escrow.fund(jobId, address(token), BUDGET, "");
        vm.stopPrank();
    }

    function createFundedJob(
        uint48 _lifetime
    ) internal returns (uint256 jobId) {
        return createFundedJobAs(client, _lifetime);
    }

    function createAcceptedJob() internal returns (uint256 jobId) {
        jobId = createFundedJob(JOB_LIFETIME);
        vm.prank(client);
        evaluator.acceptJob(jobId);
    }

    function createSubmittedJob() internal returns (uint256 jobId) {
        jobId = createAcceptedJob();
        vm.prank(provider);
        escrow.submit(jobId, keccak256("deliverable"), "");
    }

    function challengeJob(uint256 _jobId) internal returns (uint256 disputeId) {
        uint256 cost = arbitrator.COST();
        vm.prank(client);
        evaluator.challenge{value: cost}(_jobId);
        disputeId = arbitrator.disputeCount() - 1;
    }

    function assertJobStatus(
        uint256 _jobId,
        ERC8183.JobStatus _status
    ) internal view {
        assertEq(uint256(escrow.getJob(_jobId).status), uint256(_status));
    }

    // ************************************* //
    // *         Scenario: happy path      * //
    // ************************************* //

    /// Job created, funded, accepted, submitted; nobody challenges; anyone
    /// finalizes after the window and the provider is paid. No dispute, no
    /// arbitration cost.
    function test_HappyPath_OptimisticCompletion() public {
        uint256 jobId = createSubmittedJob();
        assertEq(token.balanceOf(address(escrow)), BUDGET); // escrowed while pending

        vm.warp(block.timestamp + CHALLENGE_WINDOW + 1);
        vm.expectEmit();
        emit ERC8183.JobCompleted(
            jobId,
            address(evaluator),
            "no challenge within window"
        );
        evaluator.finalize(jobId);

        assertJobStatus(jobId, ERC8183.JobStatus.Completed);
        assertEq(token.balanceOf(provider), BUDGET);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(arbitrator.disputeCount(), 0);
    }

    // ************************************* //
    // *        Scenario: disputed path    * //
    // ************************************* //

    /// The client challenges within the window; jurors side with the
    /// provider; the ruling completes the job and the provider is paid.
    function test_DisputedPath_ProviderWins() public {
        uint256 jobId = createSubmittedJob();
        uint256 disputeId = challengeJob(jobId);

        vm.expectEmit();
        emit ERC8183.JobCompleted(
            jobId,
            address(evaluator),
            bytes32(disputeId)
        );
        arbitrator.giveRuling(disputeId, evaluator.RULING_ACCEPT());

        assertJobStatus(jobId, ERC8183.JobStatus.Completed);
        assertEq(token.balanceOf(provider), BUDGET);
    }

    /// The client challenges within the window; jurors side with the client;
    /// the ruling rejects the job and the client is refunded.
    function test_DisputedPath_ClientWins() public {
        uint256 jobId = createSubmittedJob();
        uint256 disputeId = challengeJob(jobId);

        vm.expectEmit();
        emit ERC8183.JobRejected(jobId, address(evaluator), bytes32(disputeId));
        arbitrator.giveRuling(disputeId, evaluator.RULING_REJECT());

        assertJobStatus(jobId, ERC8183.JobStatus.Rejected);
        assertEq(token.balanceOf(client), BUDGET);
        assertEq(token.balanceOf(provider), 0);
    }

    /// Refuse-to-arbitrate falls back to the default path: completion.
    function test_DisputedPath_RefuseToArbitrateCompletes() public {
        uint256 jobId = createSubmittedJob();
        uint256 disputeId = challengeJob(jobId);

        vm.expectEmit();
        emit ERC8183.JobCompleted(
            jobId,
            address(evaluator),
            bytes32(disputeId)
        );
        arbitrator.giveRuling(disputeId, 0);

        assertJobStatus(jobId, ERC8183.JobStatus.Completed);
        assertEq(token.balanceOf(provider), BUDGET);
    }

    /// The view aggregator returns exactly what the dispute template renders.
    function test_View_ReturnsDisputeData() public {
        KlerosEvaluatorView viewer = new KlerosEvaluatorView();
        uint256 jobId = createSubmittedJob();
        vm.prank(provider);
        evaluator.registerDeliverable(
            jobId,
            "ipfs://deliverable",
            keccak256("deliverable")
        );
        uint256 disputeId = challengeJob(jobId);

        KlerosEvaluatorView.DisputeData memory data = viewer.disputeData(
            evaluator,
            disputeId
        );
        assertEq(data.jobId, jobId);
        assertEq(data.escrowAddress, address(escrow));
        assertEq(data.deliverableURI, "ipfs://deliverable");
        assertEq(data.deliverable, keccak256("deliverable"));
        assertEq(data.client, client);
        assertEq(data.provider, provider);
        assertEq(data.description, "a job");
    }

    /// A challenged job with nothing registered reads back empty, it doesn't revert.
    function test_View_EmptyWhenNotRegistered() public {
        KlerosEvaluatorView viewer = new KlerosEvaluatorView();
        uint256 jobId = createSubmittedJob();
        uint256 disputeId = challengeJob(jobId);

        KlerosEvaluatorView.DisputeData memory data = viewer.disputeData(
            evaluator,
            disputeId
        );
        assertEq(data.jobId, jobId);
        assertEq(data.deliverableURI, "");
        assertEq(data.deliverable, bytes32(0));
    }

    /// Unknown dispute ids map to job 0, which reads back as an empty job.
    function test_View_EmptyOnUnknownDispute() public {
        KlerosEvaluatorView viewer = new KlerosEvaluatorView();
        KlerosEvaluatorView.DisputeData memory data = viewer.disputeData(
            evaluator,
            999
        );
        assertEq(data.jobId, 0);
        assertEq(data.client, address(0));
        assertEq(data.description, "");
    }

    // ************************************* //
    // *          dispute template         * //
    // ************************************* //

    function test_Constructor_RegistersDisputeTemplate() public view {
        assertEq(evaluator.templateId(), 1);
        assertEq(templateRegistry.templateTags(1), "Kleros8183Evaluator");
        assertEq(templateRegistry.templateData(1), TEMPLATE_DATA);
        assertEq(templateRegistry.templateDataMappings(1), TEMPLATE_MAPPINGS);
    }

    // ************************************* //
    // *            acceptJob              * //
    // ************************************* //

    function test_AcceptJob_RefusesShortExpiry() public {
        uint256 jobId = createFundedJob(uint48(MIN_EXPIRY_MARGIN) - 1);

        vm.prank(client);
        vm.expectEmit();
        emit ERC8183.JobRejected(
            jobId,
            address(evaluator),
            "expiry inside margin"
        );
        vm.expectEmit();
        emit KlerosEvaluator.JobRefused(jobId);
        evaluator.acceptJob(jobId);

        assertJobStatus(jobId, ERC8183.JobStatus.Rejected);
        assertEq(token.balanceOf(client), BUDGET);
        assertFalse(evaluator.accepted(jobId));
    }

    function test_AcceptJob_RevertsWhenNotClient() public {
        uint256 jobId = createFundedJob(JOB_LIFETIME);
        vm.prank(provider);
        vm.expectRevert(KlerosEvaluator.NotJobClient.selector);
        evaluator.acceptJob(jobId);
    }

    function test_AcceptJob_RevertsWhenNotEvaluator() public {
        vm.prank(client);
        uint256 jobId = escrow.createJob(
            provider,
            makeAddr("otherEvaluator"),
            uint48(block.timestamp) + JOB_LIFETIME,
            "a job",
            address(0),
            0
        );
        vm.prank(client);
        vm.expectRevert(KlerosEvaluator.NotJobEvaluator.selector);
        evaluator.acceptJob(jobId);
    }

    function test_AcceptJob_RevertsWhenNotFunded() public {
        vm.prank(client);
        uint256 jobId = escrow.createJob(
            provider,
            address(evaluator),
            uint48(block.timestamp) + JOB_LIFETIME,
            "a job",
            address(0),
            0
        );
        vm.prank(client);
        vm.expectRevert(KlerosEvaluator.JobNotFunded.selector);
        evaluator.acceptJob(jobId);
    }

    function test_AcceptJob_RevertsWhenAlreadyAccepted() public {
        uint256 jobId = createAcceptedJob();
        vm.prank(client);
        vm.expectRevert(KlerosEvaluator.AlreadyAccepted.selector);
        evaluator.acceptJob(jobId);
    }

    function test_AcceptJob_EmitsJobAccepted() public {
        uint256 jobId = createFundedJob(JOB_LIFETIME);
        vm.prank(client);
        vm.expectEmit();
        emit KlerosEvaluator.JobAccepted(jobId);
        evaluator.acceptJob(jobId);
    }

    function test_CanAccept() public {
        uint256 okJob = createFundedJob(JOB_LIFETIME);
        uint256 shortJob = createFundedJob(uint48(MIN_EXPIRY_MARGIN) - 1);
        assertTrue(evaluator.canAccept(okJob));
        assertFalse(evaluator.canAccept(shortJob));
    }

    // ************************************* //
    // *        registerDeliverable        * //
    // ************************************* //

    function test_RegisterDeliverable_StoresAndEmits() public {
        uint256 jobId = createSubmittedJob();
        vm.prank(provider);
        vm.expectEmit();
        emit KlerosEvaluator.DeliverableRegistered(
            jobId,
            "ipfs://deliverable",
            keccak256("deliverable")
        );
        evaluator.registerDeliverable(
            jobId,
            "ipfs://deliverable",
            keccak256("deliverable")
        );
        assertEq(evaluator.deliverableURIs(jobId), "ipfs://deliverable");
        assertEq(evaluator.deliverableHashes(jobId), keccak256("deliverable"));
    }

    /// Overwriting is allowed while unchallenged; the escrow's hash
    /// commitment is the anchor.
    function test_RegisterDeliverable_OverwriteAllowed() public {
        uint256 jobId = createSubmittedJob();
        vm.startPrank(provider);
        evaluator.registerDeliverable(
            jobId,
            "ipfs://wrong",
            keccak256("wrong")
        );
        evaluator.registerDeliverable(
            jobId,
            "ipfs://fixed",
            keccak256("deliverable")
        );
        vm.stopPrank();
        assertEq(evaluator.deliverableURIs(jobId), "ipfs://fixed");
        assertEq(evaluator.deliverableHashes(jobId), keccak256("deliverable"));
    }

    /// The record freezes at the challenge: the provider cannot change what
    /// jurors are judging mid-dispute.
    function test_RegisterDeliverable_RevertsWhenChallenged() public {
        uint256 jobId = createSubmittedJob();
        vm.prank(provider);
        evaluator.registerDeliverable(
            jobId,
            "ipfs://wrong",
            keccak256("wrong")
        );
        challengeJob(jobId);
        vm.prank(provider);
        vm.expectRevert(KlerosEvaluator.AlreadyChallenged.selector);
        evaluator.registerDeliverable(
            jobId,
            "ipfs://update",
            keccak256("deliverable")
        );
        assertEq(evaluator.deliverableURIs(jobId), "ipfs://wrong");
    }

    /// The record stays frozen after the ruling: no rewriting history.
    function test_RegisterDeliverable_RevertsAfterRuling() public {
        uint256 jobId = createSubmittedJob();
        uint256 disputeId = challengeJob(jobId);
        arbitrator.giveRuling(disputeId, evaluator.RULING_REJECT());

        vm.prank(provider);
        vm.expectRevert(KlerosEvaluator.AlreadyChallenged.selector);
        evaluator.registerDeliverable(
            jobId,
            "ipfs://rewritten-history",
            keccak256("deliverable")
        );
    }

    function test_RegisterDeliverable_RevertsWhenNotProvider() public {
        uint256 jobId = createSubmittedJob();
        vm.prank(client);
        vm.expectRevert(KlerosEvaluator.NotJobProvider.selector);
        evaluator.registerDeliverable(
            jobId,
            "ipfs://deliverable",
            keccak256("deliverable")
        );
    }

    function test_RegisterDeliverable_RevertsWhenNotAccepted() public {
        uint256 jobId = createFundedJob(JOB_LIFETIME);
        vm.prank(provider);
        vm.expectRevert(KlerosEvaluator.NotAccepted.selector);
        evaluator.registerDeliverable(
            jobId,
            "ipfs://deliverable",
            keccak256("deliverable")
        );
    }

    function test_RegisterDeliverable_RevertsWhenNotSubmitted() public {
        uint256 jobId = createAcceptedJob();
        vm.prank(provider);
        vm.expectRevert(KlerosEvaluator.JobNotSubmitted.selector);
        evaluator.registerDeliverable(
            jobId,
            "ipfs://deliverable",
            keccak256("deliverable")
        );
    }

    // ************************************* //
    // *             challenge             * //
    // ************************************* //

    function test_Challenge_RevertsAfterWindow() public {
        uint256 jobId = createSubmittedJob();
        vm.warp(block.timestamp + CHALLENGE_WINDOW + 1);
        uint256 cost = arbitrator.COST();
        vm.prank(client);
        vm.expectRevert(KlerosEvaluator.ChallengeWindowOver.selector);
        evaluator.challenge{value: cost}(jobId);
    }

    function test_Challenge_RevertsWhenNotClient() public {
        uint256 jobId = createSubmittedJob();
        vm.deal(provider, 1 ether);
        uint256 cost = arbitrator.COST();
        vm.prank(provider);
        vm.expectRevert(KlerosEvaluator.NotJobClient.selector);
        evaluator.challenge{value: cost}(jobId);
    }

    function test_Challenge_RevertsWhenNotAccepted() public {
        uint256 jobId = createFundedJob(JOB_LIFETIME);
        uint256 cost = arbitrator.COST();
        vm.prank(client);
        vm.expectRevert(KlerosEvaluator.NotAccepted.selector);
        evaluator.challenge{value: cost}(jobId);
    }

    function test_Challenge_RevertsWhenFeeTooLow() public {
        uint256 jobId = createSubmittedJob();
        uint256 cost = arbitrator.COST() - 1;
        vm.prank(client);
        vm.expectRevert(KlerosEvaluator.InsufficientArbitrationFee.selector);
        evaluator.challenge{value: cost}(jobId);
    }

    function test_Challenge_RevertsWhenAlreadyChallenged() public {
        uint256 jobId = createSubmittedJob();
        challengeJob(jobId);
        uint256 cost = arbitrator.COST();
        vm.prank(client);
        vm.expectRevert(KlerosEvaluator.AlreadyChallenged.selector);
        evaluator.challenge{value: cost}(jobId);
    }

    function test_Challenge_RefundsExcess() public {
        uint256 jobId = createSubmittedJob();
        uint256 balanceBefore = client.balance;

        uint256 cost = arbitrator.COST() + 0.5 ether;
        vm.prank(client);
        evaluator.challenge{value: cost}(jobId);

        assertEq(client.balance, balanceBefore - arbitrator.COST());
        assertEq(address(evaluator).balance, 0);
    }

    function test_Challenge_SucceedsAtWindowBoundary() public {
        uint256 jobId = createSubmittedJob();
        vm.warp(block.timestamp + CHALLENGE_WINDOW); // last allowed moment
        uint256 cost = arbitrator.COST();
        vm.prank(client);
        evaluator.challenge{value: cost}(jobId);
        assertTrue(evaluator.challenged(jobId));
    }

    function test_Challenge_EmitsChallenged() public {
        uint256 jobId = createSubmittedJob();
        uint256 cost = arbitrator.COST();
        vm.prank(client);
        vm.expectEmit();
        emit KlerosEvaluator.Challenged(jobId, 0); // the mock's first dispute id
        evaluator.challenge{value: cost}(jobId);
    }

    function test_Challenge_EmitsDisputeRequest() public {
        uint256 jobId = createSubmittedJob();
        uint256 cost = arbitrator.COST();
        uint256 templateId = evaluator.templateId();
        vm.prank(client);
        vm.expectEmit();
        emit IArbitrableV2.DisputeRequest(arbitrator, 0, jobId, templateId, "");
        evaluator.challenge{value: cost}(jobId);
    }

    function test_Challenge_RevertsWhenRefundFails() public {
        address rejectingClient = address(new RejectingClient());
        vm.deal(rejectingClient, 1 ether);
        uint256 jobId = createFundedJobAs(rejectingClient, JOB_LIFETIME);
        vm.prank(rejectingClient);
        evaluator.acceptJob(jobId);
        vm.prank(provider);
        escrow.submit(jobId, keccak256("deliverable"), "");

        uint256 cost = arbitrator.COST() + 1; // any excess must be refundable
        vm.prank(rejectingClient);
        vm.expectRevert(KlerosEvaluator.RefundFailed.selector);
        evaluator.challenge{value: cost}(jobId);
    }

    // ************************************* //
    // *             finalize              * //
    // ************************************* //

    function test_Finalize_RevertsDuringWindow() public {
        uint256 jobId = createSubmittedJob();
        vm.warp(block.timestamp + CHALLENGE_WINDOW);
        vm.expectRevert(KlerosEvaluator.ChallengeWindowActive.selector);
        evaluator.finalize(jobId);
    }

    function test_Finalize_RevertsWhenDisputePending() public {
        uint256 jobId = createSubmittedJob();
        challengeJob(jobId);
        vm.warp(block.timestamp + CHALLENGE_WINDOW + 1);
        vm.expectRevert(KlerosEvaluator.DisputePending.selector);
        evaluator.finalize(jobId);
    }

    function test_Finalize_RevertsWhenNotSubmitted() public {
        uint256 jobId = createAcceptedJob();
        vm.expectRevert(KlerosEvaluator.JobNotSubmitted.selector);
        evaluator.finalize(jobId);
    }

    // ************************************* //
    // *                rule               * //
    // ************************************* //

    function test_Rule_RevertsWhenNotArbitrator() public {
        uint256 jobId = createSubmittedJob();
        uint256 disputeId = challengeJob(jobId);
        vm.expectRevert(KlerosEvaluator.OnlyArbitrator.selector);
        evaluator.rule(disputeId, 1);
    }

    function test_Rule_RevertsOnUnknownDispute() public {
        vm.prank(address(arbitrator));
        vm.expectRevert(KlerosEvaluator.UnknownDispute.selector);
        evaluator.rule(999, 1);
    }

    function test_Rule_RevertsOnInvalidRuling() public {
        uint256 jobId = createSubmittedJob();
        uint256 disputeId = challengeJob(jobId);
        vm.prank(address(arbitrator));
        vm.expectRevert(KlerosEvaluator.InvalidRuling.selector);
        evaluator.rule(disputeId, 3);
    }

    function test_CollectEvaluatorFees_OwnerCollects() public {
        escrow.setEvaluatorFee(200); // 2%, set by the escrow admin (this test contract)
        uint256 fee = (BUDGET * 200) / 10000;
        uint256 jobId = createSubmittedJob();

        vm.warp(block.timestamp + CHALLENGE_WINDOW + 1);
        evaluator.finalize(jobId);
        assertEq(token.balanceOf(provider), BUDGET - fee);
        assertEq(token.balanceOf(address(evaluator)), fee);

        evaluator.collectEvaluatorFees(token, evaluatorFeeRecipient);
        assertEq(token.balanceOf(evaluatorFeeRecipient), fee);
        assertEq(token.balanceOf(address(evaluator)), 0);
    }

    function test_CollectEvaluatorFees_RevertsWhenNotOwner() public {
        vm.prank(client);
        vm.expectRevert(KlerosEvaluator.OwnerOnly.selector);
        evaluator.collectEvaluatorFees(token, evaluatorFeeRecipient);
    }

    function test_ChangeOwner() public {
        evaluator.changeOwner(client);
        assertEq(evaluator.owner(), client);
        vm.expectRevert(KlerosEvaluator.OwnerOnly.selector);
        evaluator.changeOwner(address(this));
    }

    function test_Rule_EmitsRuling() public {
        uint256 jobId = createSubmittedJob();
        uint256 disputeId = challengeJob(jobId);
        uint256 accept = evaluator.RULING_ACCEPT();

        vm.expectEmit();
        emit IArbitrableV2.Ruling(arbitrator, disputeId, accept);
        arbitrator.giveRuling(disputeId, accept);
    }

    // ************************************* //
    // *           Cross-cutting           * //
    // ************************************* //

    /// Jobs are fully independent: one disputed, one finalized optimistically.
    function test_TwoJobsAreIndependent() public {
        uint256 disputedJob = createSubmittedJob();
        uint256 quietJob = createSubmittedJob();
        uint256 disputeId = challengeJob(disputedJob);

        vm.warp(block.timestamp + CHALLENGE_WINDOW + 1);
        evaluator.finalize(quietJob);
        arbitrator.giveRuling(disputeId, evaluator.RULING_REJECT());

        assertJobStatus(quietJob, ERC8183.JobStatus.Completed);
        assertJobStatus(disputedJob, ERC8183.JobStatus.Rejected);
        assertEq(token.balanceOf(provider), BUDGET); // paid for the quiet job only
        assertEq(token.balanceOf(client), BUDGET); // refunded the disputed job only
    }

    /// Documents the known spec limitation (see README): a pending dispute
    /// gives the escrow no reason to wait. Once the job expires, anyone can
    /// refund the client, and the eventual ruling is no longer enforceable.
    function test_KnownLimitation_ExpiryEndsDisputedJob() public {
        uint256 jobId = createSubmittedJob();
        uint256 disputeId = challengeJob(jobId);

        vm.warp(
            block.timestamp +
                JOB_LIFETIME +
                escrow.EVALUATION_GRACE_PERIOD() +
                1
        );
        escrow.claimRefund(jobId);
        assertJobStatus(jobId, ERC8183.JobStatus.Expired);
        assertEq(token.balanceOf(client), BUDGET);

        uint256 accept = evaluator.RULING_ACCEPT();
        vm.expectRevert(ERC8183.WrongStatus.selector);
        arbitrator.giveRuling(disputeId, accept);
    }
}
