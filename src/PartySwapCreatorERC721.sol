// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

// TODO: Restrict who can mint tokens (only PartySwapCrowdfund?)
// TODO: The NFT is in a big protocol wide collection called “Party Tokens”
// TODO: The NFT has the image of the token
// TODO: The NFT is transferable
// TODO: The NFT has an attribute that represents if the crowdfund was successful or not

// TODO: Rename contract?
contract PartySwapCreatorERC721 is ERC721 {
    constructor(string memory name_, string memory symbol_) ERC721(name_, symbol_) { }

    function mint(address receiver, uint256 id) public {
        _mint(receiver, id);
    }

    /**
     * @dev Returns the version of the contract. Decimal versions indicate change in logic. Number change indicates
     * change in ABI.
     */
    function VERSION() external pure returns (string memory) {
        return "0.1.0";
    }
}
