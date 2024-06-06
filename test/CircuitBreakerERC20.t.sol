// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

import { CircuitBreakerERC20 } from "../src/CircuitBreakerERC20.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { UseImmutableCreate2Factory } from "./util/UseImmutableCreate2Factory.t.sol";
import { PartySwapCreatorERC721 } from "../src/PartySwapCreatorERC721.sol";

contract CircuitBreakerERC20Test is UseImmutableCreate2Factory {
    CircuitBreakerERC20 public token;
    PartySwapCreatorERC721 public ownershipNft;

    event MetadataSet(string image, string description);

    function setUp() public override {
        super.setUp();
        ownershipNft = new PartySwapCreatorERC721("Ownership NFT", "ON", address(this));
        token = CircuitBreakerERC20(
            factory.safeCreate2(
                bytes32(0),
                abi.encodePacked(
                    type(CircuitBreakerERC20).creationCode,
                    abi.encode(
                        "CircuitBreakerERC20",
                        "CBK",
                        "MyImage",
                        "MyDescription",
                        100_000,
                        address(this),
                        address(this),
                        ownershipNft,
                        1
                    )
                )
            )
        );

        ownershipNft.setIsMinter(address(this), true);
        ownershipNft.mint("Ownership NFT", "MyImage", address(this));
    }

    function test_transfer_failsWhenPaused(address tokenHolder) external {
        vm.assume(tokenHolder != address(this));
        vm.assume(tokenHolder != address(0));
        vm.assume(tokenHolder != address(token));

        token.transfer(tokenHolder, 1000);

        vm.prank(tokenHolder);
        token.transfer(address(this), 100);

        token.setPaused(true);

        vm.expectRevert(CircuitBreakerERC20.TokenPaused.selector);
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

        vm.expectRevert(CircuitBreakerERC20.Unauthorized.selector);
        token.setMetadata("NewImage", "NewDescription");
    }

    function test_VERSION() external {
        assertEq(token.VERSION(), "0.1.0");
    }
}
