// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// TODO: Make non-transferrable by default. All transfers are blocked unless they are coming from the crowdfund or if
// the user is ragequitting.
// TODO: Add function to make transferrable (by who?)

// TODO: Rename contract?
contract PartySwapERC20 is ERC20 {
    event MetadataSet(string image, string description);

    constructor(
        string memory name_,
        string memory symbol_,
        string memory image,
        string memory description,
        uint96 totalSupply_
    )
        ERC20(name_, symbol_)
    {
        _mint(msg.sender, totalSupply_);

        emit MetadataSet(image, description);
    }
}
