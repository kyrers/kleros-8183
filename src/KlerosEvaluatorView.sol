// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC8183} from "erc8183/ERC8183.sol";
import {KlerosEvaluator} from "./KlerosEvaluator.sol";

/// @title KlerosEvaluatorView
/// @notice Read-only aggregator packaging everything the dispute template needs into one call.
/// Returning a struct means this should work with any version of the kleros-sdk.
contract KlerosEvaluatorView {
    struct DisputeData {
        uint256 jobId;
        address escrowAddress;
        string deliverableURI;
        bytes32 deliverable;
        address client;
        address provider;
        string description;
    }

    /// @notice Everything the dispute template renders, in one read.
    /// @param _evaluator The evaluator that created the dispute.
    /// @param _disputeId The dispute in the arbitrator.
    /// @return data The template's data.
    function disputeData(
        KlerosEvaluator _evaluator,
        uint256 _disputeId
    ) external view returns (DisputeData memory data) {
        data.jobId = _evaluator.disputeToJob(_disputeId);
        ERC8183 escrow = _evaluator.escrow();
        data.escrowAddress = address(escrow);
        data.deliverableURI = _evaluator.deliverableURIs(data.jobId);
        data.deliverable = _evaluator.deliverableHashes(data.jobId);
        ERC8183.Job memory job = escrow.getJob(data.jobId);
        data.client = job.client;
        data.provider = job.provider;
        data.description = job.description;
    }
}
