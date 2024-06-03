// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// TODO: Make non-transferrable by default. All transfers are blocked unless they are coming from the crowdfund or if the user is ragequitting.
// TODO: Add function to make transferrable (by who?)

// TODO: Rename contract?
contract PartySwapERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_, uint96 totalSupply_) ERC20(name_, symbol_) {
        _mint(msg.sender, totalSupply_);
    }
}

