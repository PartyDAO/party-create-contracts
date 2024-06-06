// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.25;

import { Test } from "forge-std/src/Test.sol";
import { LintJSON } from "./util/LintJSON.t.sol";
import { PartySwapCreatorERC721 } from "../src/PartySwapCreatorERC721.sol";

contract PartySwapCreatorERC721Test is Test, LintJSON {
    PartySwapCreatorERC721 creatorNft;

    function setUp() public {
        creatorNft = new PartySwapCreatorERC721("PartySwapCreatorERC721", "PSC721", address(this));
        creatorNft.setIsMinter(address(this), true);
    }

    function test_tokenURI_validateJSON() external {
        creatorNft.mint("TestToken", "test_image_url", address(this));
        _lintJSON(creatorNft.tokenURI(1));
    }

    function test_tokenURI_validateJSONAfterSucceeded() external {
        uint256 tokenId = creatorNft.mint("TestToken", "test_image_url", address(this));
        creatorNft.setCrowdfundSucceeded(tokenId);
        _lintJSON(creatorNft.tokenURI(tokenId));
    }

    function test_mint_onlyMinter() external {
        creatorNft.setIsMinter(address(this), false);
        vm.expectRevert(PartySwapCreatorERC721.OnlyMinter.selector);
        creatorNft.mint("TestToken", "test_image_url", address(this));
    }

    function test_setIsMinter_setsStorage(address who) external {
        vm.assume(who != address(this));
        assertEq(creatorNft.isMinter(who), false);
        creatorNft.setIsMinter(who, true);
        assertEq(creatorNft.isMinter(who), true);
    }

    event MetadataUpdate(uint256 _tokenId);

    function test_setCrowdfundSucceeded_eventEmitted() external {
        uint256 tokenId = creatorNft.mint("TestToken", "test_image_url", address(this));

        vm.expectEmit(true, true, true, true);
        emit MetadataUpdate(tokenId);
        creatorNft.setCrowdfundSucceeded(tokenId);
    }

    function test_setCrowdfundSucceeded_onlyMinter() external {
        uint256 tokenId = creatorNft.mint("TestToken", "test_image_url", address(this));
        creatorNft.setIsMinter(address(this), false);
        vm.expectRevert(PartySwapCreatorERC721.OnlyMinter.selector);
        creatorNft.setCrowdfundSucceeded(tokenId);
    }

    function test_VERSION() external {
        assertEq(creatorNft.VERSION(), "0.2.0");
    }
}
