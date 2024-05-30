// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

import { Test } from "forge-std/src/Test.sol";
import { CircuitBreakerERC20 } from "../src/CircuitBreakerERC20.sol";

contract CircuitBreakerERC20Test is Test {
    CircuitBreakerERC20 public token;

    function setUp() external {
        token = new CircuitBreakerERC20("CircuitBreakerERC20", "CBK", 100_000, address(this), address(this));
    }

    function test_transfer_locked(address sender) external {
        vm.assume(sender != address(this));
        vm.assume(sender != address(0));
        vm.assume(sender != address(token));

        token.transfer(sender, 1000);

        vm.prank(sender);
        token.transfer(address(this), 100);

        token.setUnpauseTime(block.timestamp + 10);

        vm.expectRevert(CircuitBreakerERC20.TokenPaused.selector);
        vm.startPrank(sender);
        token.transfer(address(2), 100);
        token.approve(address(this), 100);
        vm.stopPrank();

        token.transferFrom(sender, address(this), 100);

        skip(20);
        vm.prank(sender);
        token.transfer(address(2), 100);
    }
}
