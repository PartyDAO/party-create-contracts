// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { INonfungiblePositionManager } from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import { IUniswapV3Factory } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import { MockUniswapV3Deployer } from "./mock/MockUniswapV3Deployer.t.sol";
import { Test } from "forge-std/src/Test.sol";
import { PartyTokenAdminERC721 } from "src/PartyTokenAdminERC721.sol";
import { NFTBoundLPLocker } from "src/NFTBoundLPLocker.sol";
import { MockUNCX } from "./mock/MockUNCX.t.sol";
import { PartyERC20 } from "src/PartyERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract NFTBoundLPLockerTest is MockUniswapV3Deployer, Test {
    MockUniswapV3Deployer.UniswapV3Deployment uniswapV3Deployment;
    PartyTokenAdminERC721 adminToken;
    NFTBoundLPLocker locker;
    MockUNCX uncx;

    uint256 lpTokenId;
    PartyERC20 token;

    function setUp() external {
        uniswapV3Deployment = _deployUniswapV3();
        adminToken = new PartyTokenAdminERC721("Party Admin", "PA", address(this));
        adminToken.setIsMinter(address(this), true);
        uncx = new MockUNCX();
        locker =
            new NFTBoundLPLocker(INonfungiblePositionManager(uniswapV3Deployment.POSITION_MANAGER), adminToken, uncx);
        token = new PartyERC20(
            "Party Token", "PT", "image", "description", 1 ether, address(this), address(this), adminToken, 0
        );

        token.approve(uniswapV3Deployment.POSITION_MANAGER, 0.1 ether);

        address token0 = uniswapV3Deployment.WETH < address(token) ? uniswapV3Deployment.WETH : address(token);
        address token1 = uniswapV3Deployment.WETH < address(token) ? address(token) : uniswapV3Deployment.WETH;

        IUniswapV3Factory(uniswapV3Deployment.FACTORY).createPool(token0, token1, 10_000);
        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: 10_000, // 1 %
            tickLower: 0, // not used in test
            tickUpper: 0, // not used in test
            amount0Desired: 0.1 ether,
            amount1Desired: 0.1 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp + 1
        });

        (lpTokenId,,,) =
            INonfungiblePositionManager(uniswapV3Deployment.POSITION_MANAGER).mint{ value: 0.1 ether }(mintParams);
    }

    function test_constructor() external {
        locker =
            new NFTBoundLPLocker(INonfungiblePositionManager(uniswapV3Deployment.POSITION_MANAGER), adminToken, uncx);

        assertEq(address(locker.POSITION_MANAGER()), uniswapV3Deployment.POSITION_MANAGER);
        assertEq(address(locker.PARTY_TOKEN_ADMIN()), address(adminToken));
        assertEq(address(locker.UNCX()), address(uncx));
    }

    function test_onERC721Received_lockLp(address additionalFeeRecipient) external {
        vm.assume(additionalFeeRecipient != address(this));

        uint256 adminTokenId = adminToken.mint("Party Token", "image", address(this));

        NFTBoundLPLocker.AdditionalFeeRecipient[] memory additionalFeeRecipients =
            new NFTBoundLPLocker.AdditionalFeeRecipient[](1);
        additionalFeeRecipients[0] = NFTBoundLPLocker.AdditionalFeeRecipient({
            recipient: additionalFeeRecipient,
            percentageBps: 1000,
            feeType: NFTBoundLPLocker.FeeType.Token0
        });
        NFTBoundLPLocker.LPInfo memory lpInfo = NFTBoundLPLocker.LPInfo({
            token0: uniswapV3Deployment.WETH,
            token1: address(token),
            partyTokenAdminId: adminTokenId,
            additionalFeeRecipients: additionalFeeRecipients
        });

        INonfungiblePositionManager(uniswapV3Deployment.POSITION_MANAGER).safeTransferFrom(
            address(this), address(locker), lpTokenId, abi.encode(lpInfo)
        );

        vm.assume(INonfungiblePositionManager(uniswapV3Deployment.POSITION_MANAGER).ownerOf(lpTokenId) == address(uncx));
    }

    function test_onERC721Received_invalidFeeBps_token0() external {
        uint256 adminTokenId = adminToken.mint("Party Token", "image", address(this));

        NFTBoundLPLocker.AdditionalFeeRecipient[] memory additionalFeeRecipients =
            new NFTBoundLPLocker.AdditionalFeeRecipient[](2);
        additionalFeeRecipients[0] = NFTBoundLPLocker.AdditionalFeeRecipient({
            recipient: address(this),
            percentageBps: 1000,
            feeType: NFTBoundLPLocker.FeeType.Both
        });
        additionalFeeRecipients[1] = NFTBoundLPLocker.AdditionalFeeRecipient({
            recipient: address(this),
            percentageBps: 9001,
            feeType: NFTBoundLPLocker.FeeType.Token0
        });
        NFTBoundLPLocker.LPInfo memory lpInfo = NFTBoundLPLocker.LPInfo({
            token0: address(0),
            token1: address(0),
            partyTokenAdminId: adminTokenId,
            additionalFeeRecipients: additionalFeeRecipients
        });

        vm.expectRevert(NFTBoundLPLocker.InvalidFeeBps.selector);
        INonfungiblePositionManager(uniswapV3Deployment.POSITION_MANAGER).safeTransferFrom(
            address(this), address(locker), lpTokenId, abi.encode(lpInfo)
        );
    }

    function test_onERC721Received_invalidFeeBps_token1() external {
        uint256 adminTokenId = adminToken.mint("Party Token", "image", address(this));

        NFTBoundLPLocker.AdditionalFeeRecipient[] memory additionalFeeRecipients =
            new NFTBoundLPLocker.AdditionalFeeRecipient[](2);
        additionalFeeRecipients[0] = NFTBoundLPLocker.AdditionalFeeRecipient({
            recipient: address(this),
            percentageBps: 1000,
            feeType: NFTBoundLPLocker.FeeType.Token1
        });
        additionalFeeRecipients[1] = NFTBoundLPLocker.AdditionalFeeRecipient({
            recipient: address(this),
            percentageBps: 9001,
            feeType: NFTBoundLPLocker.FeeType.Both
        });
        NFTBoundLPLocker.LPInfo memory lpInfo = NFTBoundLPLocker.LPInfo({
            token0: address(0),
            token1: address(0),
            partyTokenAdminId: adminTokenId,
            additionalFeeRecipients: additionalFeeRecipients
        });

        vm.expectRevert(NFTBoundLPLocker.InvalidFeeBps.selector);
        INonfungiblePositionManager(uniswapV3Deployment.POSITION_MANAGER).safeTransferFrom(
            address(this), address(locker), lpTokenId, abi.encode(lpInfo)
        );
    }

    function test_onERC721Received_notPositionManager() external {
        vm.expectRevert(NFTBoundLPLocker.OnlyPositionManager.selector);
        locker.onERC721Received(address(0), address(0), 0, "");
    }

    function test_collect_feeDistributed(address additionalFeeRecipient, address adminNftHolder) external {
        vm.assume(additionalFeeRecipient != address(this));
        vm.assume(additionalFeeRecipient != address(0));
        vm.assume(adminNftHolder != address(this));
        vm.assume(adminNftHolder != address(0));
        vm.assume(adminNftHolder != additionalFeeRecipient);
        vm.assume(adminNftHolder != address(locker));
        vm.assume(additionalFeeRecipient != address(locker));

        uint256 adminTokenId = adminToken.mint("Party Token", "image", adminNftHolder);

        NFTBoundLPLocker.AdditionalFeeRecipient[] memory additionalFeeRecipients =
            new NFTBoundLPLocker.AdditionalFeeRecipient[](1);
        additionalFeeRecipients[0] = NFTBoundLPLocker.AdditionalFeeRecipient({
            recipient: additionalFeeRecipient,
            percentageBps: 1000,
            feeType: NFTBoundLPLocker.FeeType.Both
        });
        NFTBoundLPLocker.LPInfo memory lpInfo = NFTBoundLPLocker.LPInfo({
            token0: uniswapV3Deployment.WETH,
            token1: address(token),
            partyTokenAdminId: adminTokenId,
            additionalFeeRecipients: additionalFeeRecipients
        });

        INonfungiblePositionManager(uniswapV3Deployment.POSITION_MANAGER).safeTransferFrom(
            address(this), address(locker), lpTokenId, abi.encode(lpInfo)
        );

        IERC20 token0 = IERC20(uniswapV3Deployment.WETH < address(token) ? uniswapV3Deployment.WETH : address(token));
        IERC20 token1 = IERC20(uniswapV3Deployment.WETH < address(token) ? address(token) : uniswapV3Deployment.WETH);

        (uint256 amount0, uint256 amount1) = locker.collect(lpTokenId + 1);
        assertEq(
            token0.balanceOf(adminToken.ownerOf(adminTokenId)),
            amount0 - 1000 * amount0 / 10_000 /* subtract additional fee */
        );
        assertEq(token1.balanceOf(adminToken.ownerOf(adminTokenId)), amount1 - 1000 * amount1 / 10_000);
    }

    function test_VERSION() external {
        assertEq(locker.VERSION(), "0.1.0");
    }
}
