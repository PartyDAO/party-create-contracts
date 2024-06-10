// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.25;

import { Test } from "forge-std/src/Test.sol";
import { LintJSON } from "./util/LintJSON.t.sol";
import { PartyTokenAdminERC721 } from "../src/PartyTokenAdminERC721.sol";

contract PartyTokenAdminERC721Test is Test, LintJSON {
    PartyTokenAdminERC721 adminNft;

    function setUp() public {
        adminNft = new PartyTokenAdminERC721("PartySwapCreatorERC721", "PSC721", address(this));
        adminNft.setIsMinter(address(this), true);
    }

    function test_tokenURI_validateJSON() external {
        adminNft.mint("TestToken", "test_image_url", address(this));
        _lintJSON(adminNft.tokenURI(1));
    }

    function test_tokenURI_validateJSONAfterSucceeded() external {
        uint256 tokenId = adminNft.mint("TestToken", "test_image_url", address(this));
        adminNft.setCrowdfundSucceeded(tokenId);
        _lintJSON(adminNft.tokenURI(tokenId));
    }

    function test_mint_onlyMinter() external {
        adminNft.setIsMinter(address(this), false);
        vm.expectRevert(PartyTokenAdminERC721.OnlyMinter.selector);
        adminNft.mint("TestToken", "test_image_url", address(this));
    }

    function test_setIsMinter_setsStorage(address who) external {
        vm.assume(who != address(this));
        assertEq(adminNft.isMinter(who), false);
        adminNft.setIsMinter(who, true);
        assertEq(adminNft.isMinter(who), true);
    }

    event MetadataUpdate(uint256 _tokenId);

    function test_setCrowdfundSucceeded_eventEmitted() external {
        uint256 tokenId = adminNft.mint("TestToken", "test_image_url", address(this));

        vm.expectEmit(true, true, true, true);
        emit MetadataUpdate(tokenId);
        adminNft.setCrowdfundSucceeded(tokenId);
    }

    function test_setCrowdfundSucceeded_onlyMinter() external {
        uint256 tokenId = adminNft.mint("TestToken", "test_image_url", address(this));
        adminNft.setIsMinter(address(this), false);
        vm.expectRevert(PartyTokenAdminERC721.OnlyMinter.selector);
        adminNft.setCrowdfundSucceeded(tokenId);
    }

    function test_VERSION() external {
        assertEq(adminNft.VERSION(), "0.3.0");
    }
}
