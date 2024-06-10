// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { MockUniswapV3Deployer } from "./mock/MockUniswapV3Deployer.t.sol";
import { Test } from "forge-std/src/Test.sol";

contract NFTBoundLPLockerTest is MockUniswapV3Deployer, Test {
    MockUniswapV3Deployer.UniswapV3Deployment uniswapV3Deployment;

    function setUp() external {
        uniswapV3Deployment = _deployUniswapV3();
    }
}
