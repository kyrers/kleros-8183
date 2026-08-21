// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC8183} from "erc8183/ERC8183.sol";
import {IArbitratorV2} from "./interfaces/IArbitratorV2.sol";
import {IArbitrableV2} from "./interfaces/IArbitrableV2.sol";

/// @title KlerosEvaluator
/// @notice ERC-8183 evaluator backed by Kleros arbitration. Submitted work
///         completes optimistically unless the client challenges within the
///         challenge window; a challenge creates a dispute on the arbitrator
///         and the ruling is enforced on the escrow. Design in the README.
contract KlerosEvaluator is IArbitrableV2 {
    uint256 public constant RULING_OPTIONS = 2;
    uint256 public constant RULING_ACCEPT = 1;
    uint256 public constant RULING_REJECT = 2;

    ERC8183 public immutable escrow;
    IArbitratorV2 public immutable arbitrator;
    uint256 public immutable challengeWindow;
    uint256 public immutable minExpiryMargin;
    bytes public arbitratorExtraData;

    mapping(uint256 jobId => bool) public accepted;
    mapping(uint256 jobId => bool) public challenged;
    mapping(uint256 disputeId => uint256 jobId) public disputeToJob;

    event JobAccepted(uint256 indexed jobId);
    event JobRefused(uint256 indexed jobId);
    event Challenged(uint256 indexed jobId, uint256 indexed disputeId);

    error NotJobEvaluator();
    error NotJobClient();
    error JobNotFunded();
    error JobNotSubmitted();
    error AlreadyAccepted();
    error NotAccepted();
    error AlreadyChallenged();
    error ChallengeWindowActive();
    error ChallengeWindowOver();
    error InsufficientArbitrationFee();
    error OnlyArbitrator();
    error UnknownDispute();
    error InvalidRuling();
    error RefundFailed();

    constructor(
        ERC8183 _escrow,
        IArbitratorV2 _arbitrator,
        bytes memory _arbitratorExtraData,
        uint256 _challengeWindow,
        uint256 _minExpiryMargin
    ) {
        escrow = _escrow;
        arbitrator = _arbitrator;
        arbitratorExtraData = _arbitratorExtraData;
        challengeWindow = _challengeWindow;
        minExpiryMargin = _minExpiryMargin;
    }

    /// @notice Creation-time checks only; funding is checked in acceptJob.
    function canAccept(uint256 jobId) external view returns (bool) {
        ERC8183.Job memory job = escrow.getJob(jobId);
        return job.evaluator == address(this) && job.expiredAt >= block.timestamp + minExpiryMargin;
    }

    /// @notice The client asks this contract to serve a funded job. Refusal
    ///         rejects the job on the escrow, refunding the client instantly.
    function acceptJob(uint256 jobId) external {
        ERC8183.Job memory job = escrow.getJob(jobId);
        if (job.evaluator != address(this)) revert NotJobEvaluator();
        if (msg.sender != job.client) revert NotJobClient();
        if (job.status != ERC8183.JobStatus.Funded) revert JobNotFunded();
        if (accepted[jobId]) revert AlreadyAccepted();

        if (job.expiredAt < block.timestamp + minExpiryMargin) {
            escrow.reject(jobId, bytes32(0), "");
            emit JobRefused(jobId);
        } else {
            accepted[jobId] = true;
            emit JobAccepted(jobId);
        }
    }

    /// @notice The client disputes the submitted work within the challenge
    ///         window, paying the arbitration fee. Excess is refunded.
    function challenge(uint256 jobId) external payable {
        if (!accepted[jobId]) revert NotAccepted();
        if (challenged[jobId]) revert AlreadyChallenged();
        ERC8183.Job memory job = escrow.getJob(jobId);
        if (msg.sender != job.client) revert NotJobClient();
        if (job.status != ERC8183.JobStatus.Submitted) revert JobNotSubmitted();
        if (block.timestamp > job.submittedAt + challengeWindow) revert ChallengeWindowOver();

        uint256 cost = arbitrator.arbitrationCost(arbitratorExtraData);
        if (msg.value < cost) revert InsufficientArbitrationFee();
        challenged[jobId] = true;
        uint256 disputeId = arbitrator.createDispute{value: cost}(RULING_OPTIONS, arbitratorExtraData);
        disputeToJob[disputeId] = jobId;
        emit Challenged(jobId, disputeId);

        if (msg.value > cost) {
            (bool success,) = msg.sender.call{value: msg.value - cost}("");
            if (!success) revert RefundFailed();
        }
    }

    /// @notice Completes a job whose challenge window passed unchallenged.
    ///         Callable by anyone.
    function finalize(uint256 jobId) external {
        if (!accepted[jobId]) revert NotAccepted();
        if (challenged[jobId]) revert AlreadyChallenged();
        ERC8183.Job memory job = escrow.getJob(jobId);
        if (job.status != ERC8183.JobStatus.Submitted) revert JobNotSubmitted();
        if (block.timestamp <= job.submittedAt + challengeWindow) revert ChallengeWindowActive();

        escrow.complete(jobId, bytes32(0), "");
    }

    /// @notice Arbitrator callback. Accept and refuse-to-arbitrate complete
    ///         the job; reject refunds the client. The dispute id is passed
    ///         as the escrow's attestation reason.
    function rule(uint256 _disputeID, uint256 _ruling) external {
        if (msg.sender != address(arbitrator)) revert OnlyArbitrator();
        if (_ruling > RULING_OPTIONS) revert InvalidRuling();
        uint256 jobId = disputeToJob[_disputeID];
        if (jobId == 0) revert UnknownDispute();

        emit Ruling(arbitrator, _disputeID, _ruling);
        if (_ruling == RULING_REJECT) {
            escrow.reject(jobId, bytes32(_disputeID), "");
        } else {
            escrow.complete(jobId, bytes32(_disputeID), "");
        }
    }
}
