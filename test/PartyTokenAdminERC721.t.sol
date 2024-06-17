// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.25;

import { Test } from "forge-std/src/Test.sol";
import { LintJSON } from "./util/LintJSON.t.sol";
import { PartyTokenAdminERC721 } from "../src/PartyTokenAdminERC721.sol";

contract PartyTokenAdminERC721Test is Test, LintJSON {
    PartyTokenAdminERC721 adminNft;

    function setUp() public {
        adminNft = new PartyTokenAdminERC721("PartyTokenAdminERC721", "PTA721", address(this));
        adminNft.setIsMinter(address(this), true);
    }

    function test_tokenURI_validateJSON() external {
        adminNft.mint("TestToken", "test_image_url", address(this));
        _lintJSON(adminNft.tokenURI(1));
    }

    function test_tokenURI_validateJSONAfterSucceeded() external {
        uint256 tokenId = adminNft.mint("TestToken", "test_image_url", address(this));
        adminNft.setLaunchSucceeded(tokenId);
        _lintJSON(adminNft.tokenURI(tokenId));
    }

    event TokenImageSet(uint256 indexed tokenId, string image);

    function test_setTokenImage_storageReflected() external {
        uint256 tokenId = adminNft.mint("TestToken", "test_image_url", address(this));
        (, string memory image,) = adminNft.tokenMetadatas(tokenId);
        assertEq(image, "test_image_url");

        vm.expectEmit(true, true, true, true);
        emit TokenImageSet(tokenId, "new image url");
        adminNft.setTokenImage(tokenId, "new image url");
        (, image,) = adminNft.tokenMetadatas(tokenId);
        assertEq(image, "new image url");
    }

    function test_setTokenImage_onlyTokenOwner(address tokenReceiver) external {
        vm.assume(tokenReceiver != address(this));
        vm.assume(tokenReceiver != address(0));
        uint256 tokenId = adminNft.mint("TestToken", "test_image_url", tokenReceiver);

        vm.expectRevert(PartyTokenAdminERC721.Unauthorized.selector);
        adminNft.setTokenImage(tokenId, "new image url");
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

    function test_setLaunchSucceeded_eventEmitted() external {
        uint256 tokenId = adminNft.mint("TestToken", "test_image_url", address(this));

        vm.expectEmit(true, true, true, true);
        emit MetadataUpdate(tokenId);
        adminNft.setLaunchSucceeded(tokenId);
    }

    function test_setLaunchSucceeded_onlyMinter() external {
        uint256 tokenId = adminNft.mint("TestToken", "test_image_url", address(this));
        adminNft.setIsMinter(address(this), false);
        vm.expectRevert(PartyTokenAdminERC721.OnlyMinter.selector);
        adminNft.setLaunchSucceeded(tokenId);
    }

    event ContractURIUpdated();

    function test_setContractURI() external {
        vm.expectEmit(true, true, true, true);
        emit ContractURIUpdated();
        adminNft.setContractURI("test_contract_uri");

        assertEq(adminNft.contractURI(), "test_contract_uri");
    }

    function test_VERSION() external view {
        assertEq(adminNft.VERSION(), "0.4.0");
    }
}
