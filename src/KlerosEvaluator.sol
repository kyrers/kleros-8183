// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC8183} from "erc8183/ERC8183.sol";
import {IArbitratorV2} from "./interfaces/IArbitratorV2.sol";
import {IArbitrableV2} from "./interfaces/IArbitrableV2.sol";
import {IDisputeTemplateRegistry} from "./interfaces/IDisputeTemplateRegistry.sol";

/// @title KlerosEvaluator
/// @notice ERC-8183 evaluator backed by Kleros arbitration. Submitted work
/// completes optimistically unless the client challenges within the challenge
/// window; a challenge creates a dispute on the arbitrator and the ruling is
/// enforced on the escrow. Disputes point to a dispute template registered at
/// deployment and providers disclose delivered content via registerDeliverable, making cases readable to jurors.
/// Design choices in the README.
contract KlerosEvaluator is IArbitrableV2 {
    using SafeERC20 for IERC20;

    // ************************************* //
    // *             Structs               * //
    // ************************************* //

    struct DisputeData {
        uint256 jobId;
        address escrowAddress;
        string deliverableURI;
        bytes32 deliverable;
        address client;
        address provider;
        string description;
    }

    // ************************************* //
    // *             Storage               * //
    // ************************************* //

    address public owner; // The owner. Can only change ownership and collect this contract's fee earnings.

    uint256 public constant RULING_OPTIONS = 2; // Number of ruling choices: accept or reject the submission.
    uint256 public constant RULING_ACCEPT = 1; // The submission is acceptable.
    uint256 public constant RULING_REJECT = 2; // The submission is not acceptable.

    ERC8183 public immutable escrow; // The ERC-8183 escrow this contract evaluates for.
    IArbitratorV2 public immutable arbitrator; // The Kleros arbitrator.
    uint256 public immutable challengeWindow; // Seconds after submission during which the client can challenge.
    uint256 public immutable minExpiryMargin; // Minimum seconds between acceptance and job expiry.
    uint256 public immutable templateId; // The dispute template every dispute points to.
    bytes public arbitratorExtraData; // Arbitrator configuration (court, number of jurors).

    mapping(uint256 jobId => bool) public accepted; // Jobs this contract agreed to serve.
    mapping(uint256 jobId => bool) public challenged; // Jobs whose submission was disputed.
    mapping(uint256 disputeId => uint256 jobId) public disputeToJob; // Maps arbitrator dispute IDs to job IDs.
    mapping(uint256 jobId => string) public deliverableURIs; // Provider-disclosed content behind the deliverable hash committed on the escrow.
    mapping(uint256 jobId => bytes32) public deliverableHashes; // Provider-disclosed hash that should match the hash committed on the escrow. Stored here because the escrow does not store it, only emits it, making it hard to access.

    // ************************************* //
    // *              Events               * //
    // ************************************* //

    /// @notice Emitted when this contract agrees to serve a job.
    /// @param _jobId The job.
    event JobAccepted(uint256 indexed _jobId);

    /// @notice Emitted when this contract refuses a job and rejects it on the escrow.
    /// @param _jobId The job.
    event JobRefused(uint256 indexed _jobId);

    /// @notice Emitted when the provider registers the content behind the deliverable hash committed on the escrow.
    /// @param _jobId The job.
    /// @param _deliverableURI Reference to the delivered content.
    /// @param _deliverable The content hash, restating the escrow commitment.
    event DeliverableRegistered(
        uint256 indexed _jobId,
        string _deliverableURI,
        bytes32 _deliverable
    );

    /// @notice Emitted when the client challenges a submission.
    /// @param _jobId The job.
    /// @param _disputeId The dispute created on the arbitrator.
    event Challenged(uint256 indexed _jobId, uint256 indexed _disputeId);

    // ************************************* //
    // *        Function Modifiers         * //
    // ************************************* //

    modifier onlyByOwner() {
        require(owner == msg.sender, OwnerOnly());
        _;
    }

    // ************************************* //
    // *            Constructor            * //
    // ************************************* //

    /// @param _owner The owner.
    /// @param _escrow The ERC-8183 escrow to evaluate for.
    /// @param _arbitrator The Kleros arbitrator.
    /// @param _arbitratorExtraData Arbitrator configuration (court, number of jurors).
    /// @param _challengeWindow Seconds after submission during which the client can challenge.
    /// @param _minExpiryMargin Minimum seconds between acceptance and job expiry.
    /// @param _templateRegistry The dispute template registry.
    /// @param _templateData The dispute template data.
    /// @param _templateDataMappings The dispute template data mappings.
    constructor(
        address _owner,
        ERC8183 _escrow,
        IArbitratorV2 _arbitrator,
        bytes memory _arbitratorExtraData,
        uint256 _challengeWindow,
        uint256 _minExpiryMargin,
        IDisputeTemplateRegistry _templateRegistry,
        string memory _templateData,
        string memory _templateDataMappings
    ) {
        owner = _owner;
        escrow = _escrow;
        arbitrator = _arbitrator;
        arbitratorExtraData = _arbitratorExtraData;
        challengeWindow = _challengeWindow;
        minExpiryMargin = _minExpiryMargin;
        templateId = _templateRegistry.setDisputeTemplate(
            "Kleros8183Evaluator",
            _templateData,
            _templateDataMappings
        );
    }

    // ************************************* //
    // *           Governance              * //
    // ************************************* //

    /// @notice Changes the owner.
    /// @param _owner The address of the new owner.
    function changeOwner(address _owner) external onlyByOwner {
        owner = _owner;
    }

    /// @notice Collects this contract's balance of a token
    /// Some marketplaces might force evaluator fees, and we don't want them to be stuck in this contract.
    /// @param _token The token to collect.
    /// @param _to The address receiving the balance.
    function collectEvaluatorFees(
        IERC20 _token,
        address _to
    ) external onlyByOwner {
        _token.safeTransfer(_to, _token.balanceOf(address(this)));
    }

    // ************************************* //
    // *         State Modifiers           * //
    // ************************************* //

    /// @notice The client asks this contract to serve a funded job. Refusal
    /// rejects the job on the escrow, refunding the client instantly.
    /// @param _jobId The job to accept.
    function acceptJob(uint256 _jobId) external {
        ERC8183.Job memory job = escrow.getJob(_jobId);
        require(job.evaluator == address(this), NotJobEvaluator());
        require(msg.sender == job.client, NotJobClient());
        require(job.status == ERC8183.JobStatus.Funded, JobNotFunded());
        require(!accepted[_jobId], AlreadyAccepted());

        if (job.expiredAt < block.timestamp + minExpiryMargin) {
            escrow.reject(_jobId, "expiry inside margin", "");
            emit JobRefused(_jobId);
        } else {
            accepted[_jobId] = true;
            emit JobAccepted(_jobId);
        }
    }

    /// @notice The provider registers a reference to the content behind the
    /// deliverable hash committed on the escrow, restating that hash, so
    /// jurors can access and verify the content if a dispute arises.
    /// Registering again overwrites, but only until the client challenges:
    /// from the challenge on, the record is frozen, so every juror in the
    /// dispute judges the same evidence.
    /// @param _jobId The job the content belongs to.
    /// @param _deliverableURI Reference to the delivered content.
    /// @param _deliverable The content hash, restating the escrow commitment.
    function registerDeliverable(
        uint256 _jobId,
        string calldata _deliverableURI,
        bytes32 _deliverable
    ) external {
        require(accepted[_jobId], NotAccepted());
        require(!challenged[_jobId], AlreadyChallenged());
        ERC8183.Job memory job = escrow.getJob(_jobId);
        require(msg.sender == job.provider, NotJobProvider());
        require(job.status == ERC8183.JobStatus.Submitted, JobNotSubmitted());

        deliverableURIs[_jobId] = _deliverableURI;
        deliverableHashes[_jobId] = _deliverable;
        emit DeliverableRegistered(_jobId, _deliverableURI, _deliverable);
    }

    /// @notice The client disputes the submitted work within the challenge
    /// window, paying the arbitration fee. Excess is refunded.
    /// @param _jobId The job whose submission is disputed.
    function challenge(uint256 _jobId) external payable {
        require(accepted[_jobId], NotAccepted());
        require(!challenged[_jobId], AlreadyChallenged());
        ERC8183.Job memory job = escrow.getJob(_jobId);
        require(msg.sender == job.client, NotJobClient());
        require(job.status == ERC8183.JobStatus.Submitted, JobNotSubmitted());
        require(
            block.timestamp <= job.submittedAt + challengeWindow,
            ChallengeWindowOver()
        );

        uint256 cost = arbitrator.arbitrationCost(arbitratorExtraData);
        require(msg.value >= cost, InsufficientArbitrationFee());
        challenged[_jobId] = true;
        uint256 disputeId = arbitrator.createDispute{value: cost}(
            RULING_OPTIONS,
            arbitratorExtraData
        );
        disputeToJob[disputeId] = _jobId;
        emit Challenged(_jobId, disputeId);
        emit DisputeRequest(arbitrator, disputeId, _jobId, templateId, "");

        if (msg.value > cost) {
            (bool success, ) = msg.sender.call{value: msg.value - cost}("");
            require(success, RefundFailed());
        }
    }

    /// @notice Completes a job whose challenge window passed unchallenged.
    /// Callable by anyone.
    /// @param _jobId The job to complete.
    function finalize(uint256 _jobId) external {
        require(accepted[_jobId], NotAccepted());
        require(!challenged[_jobId], DisputePending());
        ERC8183.Job memory job = escrow.getJob(_jobId);
        require(job.status == ERC8183.JobStatus.Submitted, JobNotSubmitted());
        require(
            block.timestamp > job.submittedAt + challengeWindow,
            ChallengeWindowActive()
        );

        escrow.complete(_jobId, "no challenge within window", "");
    }

    /// @notice Arbitrator callback. Accept and refuse-to-arbitrate complete
    /// the job; reject refunds the client. The dispute id is passed as the
    /// escrow's attestation reason.
    /// @param _disputeID The dispute.
    /// @param _ruling The final ruling.
    function rule(uint256 _disputeID, uint256 _ruling) external {
        require(msg.sender == address(arbitrator), OnlyArbitrator());
        require(_ruling <= RULING_OPTIONS, InvalidRuling());
        uint256 jobId = disputeToJob[_disputeID];
        require(jobId != 0, UnknownDispute());

        emit Ruling(arbitrator, _disputeID, _ruling);
        if (_ruling == RULING_REJECT) {
            escrow.reject(jobId, bytes32(_disputeID), "");
        } else {
            escrow.complete(jobId, bytes32(_disputeID), "");
        }
    }

    // ************************************* //
    // *           Public Views            * //
    // ************************************* //

    /// @notice A given job dispute's information.
    /// @param _disputeId The dispute in the arbitrator.
    /// @return data The dispute data; empty for unknown disputes.
    function disputeData(
        uint256 _disputeId
    ) external view returns (DisputeData memory data) {
        data.jobId = disputeToJob[_disputeId];
        data.escrowAddress = address(escrow);
        data.deliverableURI = deliverableURIs[data.jobId];
        data.deliverable = deliverableHashes[data.jobId];
        ERC8183.Job memory job = escrow.getJob(data.jobId);
        data.client = job.client;
        data.provider = job.provider;
        data.description = job.description;
    }

    /// @notice Creation-time checks only; funding is checked in acceptJob.
    /// @param _jobId The job to check.
    /// @return Whether the job's shape is acceptable.
    function canAccept(uint256 _jobId) external view returns (bool) {
        ERC8183.Job memory job = escrow.getJob(_jobId);
        return
            job.evaluator == address(this) &&
            job.expiredAt >= block.timestamp + minExpiryMargin;
    }

    // ************************************* //
    // *              Errors               * //
    // ************************************* //

    error OwnerOnly();
    error NotJobEvaluator();
    error NotJobClient();
    error NotJobProvider();
    error JobNotFunded();
    error JobNotSubmitted();
    error AlreadyAccepted();
    error NotAccepted();
    error AlreadyChallenged();
    error DisputePending();
    error ChallengeWindowActive();
    error ChallengeWindowOver();
    error InsufficientArbitrationFee();
    error OnlyArbitrator();
    error UnknownDispute();
    error InvalidRuling();
    error RefundFailed();
}
