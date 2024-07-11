// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

import { PartyERC20 } from "../src/PartyERC20.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UseImmutableCreate2Factory } from "./util/UseImmutableCreate2Factory.t.sol";
import { PartyTokenAdminERC721 } from "../src/PartyTokenAdminERC721.sol";
import { Vm } from "forge-std/src/Test.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

contract PartyERC20Test is UseImmutableCreate2Factory {
    PartyERC20 public token;
    PartyTokenAdminERC721 public adminNFTId;

    event MetadataSet(string description);

    function setUp() public override {
        super.setUp();
        adminNFTId = new PartyTokenAdminERC721("Admin NFT", "ON", address(this));
        address tokenImpl =
            factory.safeCreate2(bytes32(0), abi.encodePacked(type(PartyERC20).creationCode, abi.encode(adminNFTId)));

        token = PartyERC20(Clones.clone(tokenImpl));
        token.initialize("PartyERC20", "PARTY", "MyDescription", 100_000, address(this), address(this), 1);

        adminNFTId.setIsMinter(address(this), true);
        adminNFTId.mint("Admin NFT", "MyImage", address(this), address(1));
    }

    function test_cannotReinit() public {
        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        token.initialize("PartyERC20", "PARTY", "MyDescription", 100_000, address(this), address(this), 1);
    }

    function test_transfer_failsWhenPaused(address tokenHolder) external {
        vm.assume(tokenHolder != address(this));
        vm.assume(tokenHolder != address(0));
        vm.assume(tokenHolder != address(token));

        token.transfer(tokenHolder, 1000);

        vm.prank(tokenHolder);
        token.transfer(address(this), 100);

        token.setPaused(true);

        vm.expectRevert(PartyERC20.TokenPaused.selector);
        vm.prank(tokenHolder);
        token.transfer(address(2), 100);
    }

    function test_transferFrom_ownerNoApproval(address tokenHolder) external {
        vm.assume(tokenHolder != address(this));
        vm.assume(tokenHolder != address(0));
        vm.assume(tokenHolder != address(token));

        token.transfer(tokenHolder, 1000);
        token.transferFrom(tokenHolder, address(this), 1000);
    }

    function test_getTokenImage_fetchFromToken() external {
        assertEq(token.getTokenImage(), "MyImage");

        adminNFTId.setTokenImage(1, "NewImage");

        assertEq(token.getTokenImage(), "NewImage");
    }

    function test_transferFrom_needsApproval(address tokenHolder, address spender) external {
        vm.assume(tokenHolder != address(this) && spender != address(this));
        vm.assume(tokenHolder != address(0) && spender != address(0));
        vm.assume(tokenHolder != address(token) && spender != address(token));
        vm.assume(tokenHolder != spender);

        token.transfer(tokenHolder, 1000);

        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1000));
        token.transferFrom(tokenHolder, spender, 1000);
    }

    function test_setMetadata() external {
        vm.expectEmit(true, true, true, true);
        emit MetadataSet("NewDescription");
        token.setMetadata("NewDescription");
    }

    function test_setMetadata_onlyNFTHolder() external {
        adminNFTId.transferFrom(address(this), address(2), 1);

        vm.expectRevert(PartyERC20.Unauthorized.selector);
        token.setMetadata("NewDescription");
    }

    function test_getVotes_verifyAutodelegation() external {
        Vm.Wallet memory steve = vm.createWallet("steve");
        token.transfer(steve.addr, 1000);

        assertEq(token.getVotes(steve.addr), 1000);
    }

    function test_delegate_notAddressZero() external {
        vm.expectRevert(PartyERC20.InvalidDelegate.selector);
        token.delegate(address(0));
    }

    function test_VERSION() external view {
        assertEq(token.VERSION(), "1.0.0");
    }
}
