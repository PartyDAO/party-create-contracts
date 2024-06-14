// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.25;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockPool {
    function initialize(uint160) external pure { }

    function transferToken(IERC20 token, address to, uint256 amount) external {
        token.transfer(to, amount);
    }
}
