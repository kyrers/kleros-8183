// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IArbitratorV2} from "../../src/interfaces/IArbitratorV2.sol";
import {IArbitrableV2} from "../../src/interfaces/IArbitrableV2.sol";

/// @dev Minimal IArbitratorV2 for local tests: fixed native-currency cost,
/// dispute IDs starting at 0 like KlerosCore, and a giveRuling helper for
/// tests to deliver the final ruling to the arbitrable.
contract MockArbitrator is IArbitratorV2 {
    uint256 public constant COST = 0.01 ether;

    uint256 public disputeCount;
    mapping(uint256 disputeId => IArbitrableV2) public disputeToArbitrable;
    mapping(uint256 disputeId => uint256) public rulings;

    error InsufficientPayment();
    error TokenFeesNotSupported();
    error UnknownDispute();

    function createDispute(uint256, bytes calldata) external payable returns (uint256 disputeID) {
        require(msg.value >= COST, InsufficientPayment());
        disputeID = disputeCount++;
        disputeToArbitrable[disputeID] = IArbitrableV2(msg.sender);
        emit DisputeCreation(disputeID, IArbitrableV2(msg.sender));
    }

    function createDispute(uint256, bytes calldata, IERC20, uint256) external pure returns (uint256) {
        revert TokenFeesNotSupported();
    }

    function arbitrationCost(bytes calldata) external pure returns (uint256) {
        return COST;
    }

    function arbitrationCost(bytes calldata, IERC20) external pure returns (uint256) {
        revert TokenFeesNotSupported();
    }

    function currentRuling(uint256 _disputeID) external view returns (uint256 ruling, bool tied, bool overridden) {
        return (rulings[_disputeID], false, false);
    }

    function giveRuling(uint256 _disputeID, uint256 _ruling) external {
        IArbitrableV2 arbitrable = disputeToArbitrable[_disputeID];
        require(address(arbitrable) != address(0), UnknownDispute());
        rulings[_disputeID] = _ruling;
        arbitrable.rule(_disputeID, _ruling);
    }
}
