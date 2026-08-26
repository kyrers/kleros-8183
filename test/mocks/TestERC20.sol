// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Freely mintable ERC20 used as the jobs' payment token in tests.
contract TestERC20 is ERC20 {
    constructor() ERC20("Test USD", "TUSD") {}

    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }
}
