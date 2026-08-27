// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IDisputeTemplateRegistry} from "../../src/interfaces/IDisputeTemplateRegistry.sol";

/// @dev Minimal registry: stores templates and hands out sequential ids.
contract MockTemplateRegistry is IDisputeTemplateRegistry {
    uint256 public templateCount;
    mapping(uint256 templateId => string) public templateData;
    mapping(uint256 templateId => string) public templateDataMappings;

    function setDisputeTemplate(
        string memory _templateTag,
        string memory _templateData,
        string memory _templateDataMappings
    ) external returns (uint256 templateId) {
        templateId = templateCount++;
        templateData[templateId] = _templateData;
        templateDataMappings[templateId] = _templateDataMappings;
        emit DisputeTemplate(
            templateId,
            _templateTag,
            _templateData,
            _templateDataMappings
        );
    }
}
