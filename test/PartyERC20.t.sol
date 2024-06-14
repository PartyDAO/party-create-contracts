// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

import { PartyERC20 } from "../src/PartyERC20.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UseImmutableCreate2Factory } from "./util/UseImmutableCreate2Factory.t.sol";
import { PartyTokenAdminERC721 } from "../src/PartyTokenAdminERC721.sol";

contract PartyERC20Test is UseImmutableCreate2Factory {
    PartyERC20 public token;
    PartyTokenAdminERC721 public ownershipNft;

    event MetadataSet(string image, string description);

    function setUp() public override {
        super.setUp();
        ownershipNft = new PartyTokenAdminERC721("Ownership NFT", "ON", address(this));
        token = PartyERC20(
            factory.safeCreate2(bytes32(0), abi.encodePacked(type(PartyERC20).creationCode, abi.encode(ownershipNft)))
        );
        token.initialize("PartyERC20", "PARTY", "MyImage", "MyDescription", 100_000, address(this), address(this), 1);

        ownershipNft.setIsMinter(address(this), true);
        ownershipNft.mint("Ownership NFT", "MyImage", address(this));
    }

    function test_cannotReinit() public {
        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        token.initialize("PartyERC20", "PARTY", "MyImage", "MyDescription", 100_000, address(this), address(this), 1);
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
        emit MetadataSet("NewImage", "NewDescription");
        token.setMetadata("NewImage", "NewDescription");
    }

    function test_setMetadata_onlyNFTHolder() external {
        ownershipNft.transferFrom(address(this), address(2), 1);

        vm.expectRevert(PartyERC20.Unauthorized.selector);
        token.setMetadata("NewImage", "NewDescription");
    }

    function test_VERSION() external view {
        assertEq(token.VERSION(), "0.1.0");
    }
}
