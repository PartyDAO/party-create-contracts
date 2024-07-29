// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { INonfungiblePositionManager } from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import { IUniswapV3Factory } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import { MockUniswapV3Deployer } from "./mock/MockUniswapV3Deployer.t.sol";
import { Test } from "forge-std/src/Test.sol";
import { PartyTokenAdminERC721 } from "src/PartyTokenAdminERC721.sol";
import { PartyLPLocker } from "src/PartyLPLocker.sol";
import { PartyERC20 } from "src/PartyERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

contract PartyLPLockerTest is MockUniswapV3Deployer, Test {
    event Locked(
        uint256 indexed tokenId,
        IERC20 indexed token,
        uint256 indexed partyTokenAdminId,
        PartyLPLocker.AdditionalFeeRecipient[] additionalFeeRecipients
    );
    event Collected(
        uint256 indexed tokenId,
        uint256 amount0,
        uint256 amount1,
        PartyLPLocker.AdditionalFeeRecipient[] additionalFeeRecipients
    );

    MockUniswapV3Deployer.UniswapV3Deployment uniswapV3Deployment;
    PartyTokenAdminERC721 adminToken;
    PartyLPLocker locker;
    PartyERC20 token;

    IERC20 token0;
    IERC20 token1;

    uint256 lpTokenId;

    function setUp() external {
        uniswapV3Deployment = _deployUniswapV3();
        adminToken = new PartyTokenAdminERC721("Party Admin", "PA", address(this));
        adminToken.setIsMinter(address(this), true);
        locker = new PartyLPLocker(
            address(this), INonfungiblePositionManager(uniswapV3Deployment.POSITION_MANAGER), adminToken
        );
        token = PartyERC20(Clones.clone(address(new PartyERC20(adminToken))));
        token.initialize("Party Token", "PT", "description", 1 ether, address(this), address(this), 0);

        token.approve(uniswapV3Deployment.POSITION_MANAGER, 0.1 ether);

        token0 = IERC20(uniswapV3Deployment.WETH < address(token) ? uniswapV3Deployment.WETH : address(token));
        token1 = IERC20(uniswapV3Deployment.WETH < address(token) ? address(token) : uniswapV3Deployment.WETH);

        IUniswapV3Factory(uniswapV3Deployment.FACTORY).createPool(address(token0), address(token1), 10_000);
        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            token0: address(token0),
            token1: address(token1),
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

    function test_onERC721Received_lockLp(address additionalFeeRecipient) external {
        vm.assume(additionalFeeRecipient != address(this));
        vm.assume(additionalFeeRecipient != address(0));

        uint256 adminTokenId = adminToken.mint("Party Token", "image", address(this), address(1));

        PartyLPLocker.AdditionalFeeRecipient[] memory additionalFeeRecipients =
            new PartyLPLocker.AdditionalFeeRecipient[](1);
        additionalFeeRecipients[0] = PartyLPLocker.AdditionalFeeRecipient({
            recipient: additionalFeeRecipient,
            percentageBps: 1000,
            feeType: PartyLPLocker.FeeType.Token0
        });
        PartyLPLocker.LPInfo memory lpInfo =
            PartyLPLocker.LPInfo({ partyTokenAdminId: adminTokenId, additionalFeeRecipients: additionalFeeRecipients });

        vm.expectEmit(true, true, true, true);
        emit Locked(lpTokenId, token, adminTokenId, additionalFeeRecipients);

        INonfungiblePositionManager(uniswapV3Deployment.POSITION_MANAGER).safeTransferFrom(
            address(this), address(locker), lpTokenId, abi.encode(lpInfo, 0, token)
        );

        (address storedToken0, address storedToken1, uint256 partyTokenAdminId) = locker.lockStorages(lpTokenId);
        assertEq(storedToken0, address(token0));
        assertEq(storedToken1, address(token1));
        assertEq(partyTokenAdminId, adminTokenId);
        assertEq(additionalFeeRecipients.length, 1);
        assertEq(additionalFeeRecipients[0].recipient, additionalFeeRecipient);
        assertEq(additionalFeeRecipients[0].percentageBps, 1000);
        assertEq(uint8(additionalFeeRecipients[0].feeType), uint8(PartyLPLocker.FeeType.Token0));
    }

    function test_onERC721Received_invalidFeeBps_token0() external {
        uint256 adminTokenId = adminToken.mint("Party Token", "image", address(this), address(1));

        PartyLPLocker.AdditionalFeeRecipient[] memory additionalFeeRecipients =
            new PartyLPLocker.AdditionalFeeRecipient[](2);
        additionalFeeRecipients[0] = PartyLPLocker.AdditionalFeeRecipient({
            recipient: address(this),
            percentageBps: 1000,
            feeType: PartyLPLocker.FeeType.Both
        });
        additionalFeeRecipients[1] = PartyLPLocker.AdditionalFeeRecipient({
            recipient: address(this),
            percentageBps: 9001,
            feeType: PartyLPLocker.FeeType.Token0
        });
        PartyLPLocker.LPInfo memory lpInfo =
            PartyLPLocker.LPInfo({ partyTokenAdminId: adminTokenId, additionalFeeRecipients: additionalFeeRecipients });

        uint96 flatLockFee = locker.getFlatLockFee();
        vm.deal(address(locker), flatLockFee);

        vm.expectRevert(PartyLPLocker.InvalidFeeBps.selector);
        INonfungiblePositionManager(uniswapV3Deployment.POSITION_MANAGER).safeTransferFrom(
            address(this), address(locker), lpTokenId, abi.encode(lpInfo, flatLockFee)
        );
    }

    function test_onERC721Received_invalidFeeBps_token1() external {
        uint256 adminTokenId = adminToken.mint("Party Token", "image", address(this), address(1));

        PartyLPLocker.AdditionalFeeRecipient[] memory additionalFeeRecipients =
            new PartyLPLocker.AdditionalFeeRecipient[](2);
        additionalFeeRecipients[0] = PartyLPLocker.AdditionalFeeRecipient({
            recipient: address(this),
            percentageBps: 1000,
            feeType: PartyLPLocker.FeeType.Token1
        });
        additionalFeeRecipients[1] = PartyLPLocker.AdditionalFeeRecipient({
            recipient: address(this),
            percentageBps: 9001,
            feeType: PartyLPLocker.FeeType.Both
        });
        PartyLPLocker.LPInfo memory lpInfo =
            PartyLPLocker.LPInfo({ partyTokenAdminId: adminTokenId, additionalFeeRecipients: additionalFeeRecipients });

        uint96 flatLockFee = locker.getFlatLockFee();
        vm.deal(address(locker), flatLockFee);

        vm.expectRevert(PartyLPLocker.InvalidFeeBps.selector);
        INonfungiblePositionManager(uniswapV3Deployment.POSITION_MANAGER).safeTransferFrom(
            address(this), address(locker), lpTokenId, abi.encode(lpInfo, flatLockFee)
        );
    }

    function test_onERC721Received_invalidRecipient() external {
        uint256 adminTokenId = adminToken.mint("Party Token", "image", address(this), address(1));

        PartyLPLocker.AdditionalFeeRecipient[] memory additionalFeeRecipients =
            new PartyLPLocker.AdditionalFeeRecipient[](2);
        additionalFeeRecipients[0] = PartyLPLocker.AdditionalFeeRecipient({
            recipient: address(0),
            percentageBps: 1000,
            feeType: PartyLPLocker.FeeType.Token1
        });
        PartyLPLocker.LPInfo memory lpInfo =
            PartyLPLocker.LPInfo({ partyTokenAdminId: adminTokenId, additionalFeeRecipients: additionalFeeRecipients });

        uint96 flatLockFee = locker.getFlatLockFee();
        vm.deal(address(locker), flatLockFee);

        vm.expectRevert(PartyLPLocker.InvalidRecipient.selector);
        INonfungiblePositionManager(uniswapV3Deployment.POSITION_MANAGER).safeTransferFrom(
            address(this), address(locker), lpTokenId, abi.encode(lpInfo, flatLockFee)
        );
    }

    function test_onERC721Received_invalidAdminId() public {
        uint256 adminTokenId = adminToken.mint("Party Token", "image", address(this), address(1));

        PartyLPLocker.LPInfo memory lpInfo = PartyLPLocker.LPInfo({
            partyTokenAdminId: adminTokenId + 1,
            additionalFeeRecipients: new PartyLPLocker.AdditionalFeeRecipient[](0)
        });

        vm.expectRevert(PartyLPLocker.InvalidAdminId.selector);
        INonfungiblePositionManager(uniswapV3Deployment.POSITION_MANAGER).safeTransferFrom(
            address(this), address(locker), lpTokenId, abi.encode(lpInfo, 0)
        );
    }

    function test_onERC721Received_notPositionManager() external {
        vm.expectRevert(PartyLPLocker.OnlyPositionManager.selector);
        locker.onERC721Received(address(0), address(0), 0, "");
    }

    function test_collect_feeDistributed() external {
        address feeRecipient1 = vm.createWallet("FeeRecipient1").addr;
        address feeRecipient2 = vm.createWallet("FeeRecipient2").addr;
        address adminNftHolder = vm.createWallet("AdminNftHolder").addr;

        uint256 adminTokenId = adminToken.mint("Party Token", "image", adminNftHolder, address(token));

        PartyLPLocker.AdditionalFeeRecipient[] memory additionalFeeRecipients =
            new PartyLPLocker.AdditionalFeeRecipient[](2);
        additionalFeeRecipients[0] = PartyLPLocker.AdditionalFeeRecipient({
            recipient: feeRecipient1,
            percentageBps: 2000,
            feeType: PartyLPLocker.FeeType.Both
        });
        additionalFeeRecipients[1] = PartyLPLocker.AdditionalFeeRecipient({
            recipient: feeRecipient2,
            percentageBps: 7000,
            feeType: PartyLPLocker.FeeType.Token0
        });
        PartyLPLocker.LPInfo memory lpInfo =
            PartyLPLocker.LPInfo({ partyTokenAdminId: adminTokenId, additionalFeeRecipients: additionalFeeRecipients });

        INonfungiblePositionManager(uniswapV3Deployment.POSITION_MANAGER).safeTransferFrom(
            address(this), address(locker), lpTokenId, abi.encode(lpInfo, 0, token)
        );

        (uint256 collectedAmount0, uint256 collectedAmount1) = locker.collect(lpTokenId);

        assertEq(collectedAmount0, 0.01 ether);
        assertEq(collectedAmount1, 0.01 ether);

        assertEq(token0.balanceOf(feeRecipient1), 0.002 ether);
        assertEq(token1.balanceOf(feeRecipient1), 0.002 ether);
        assertEq(token0.balanceOf(feeRecipient2), 0.007 ether);
        assertEq(token0.balanceOf(adminNftHolder), 0.001 ether);
        assertEq(token1.balanceOf(adminNftHolder), 0.008 ether);
    }

    function test_withdrawEth_nonNull() external {
        address recipient = vm.createWallet("Recipient").addr;
        vm.deal(address(locker), 1 ether);

        uint256 beforeBalance = recipient.balance;
        assertEq(address(locker).balance, 1 ether);

        locker.sweep(recipient);

        assertEq(address(locker).balance, 0);
        assertEq(recipient.balance, beforeBalance + 1 ether);
    }

    function test_withdrawEth_null() external {
        vm.expectRevert(PartyLPLocker.InvalidRecipient.selector);
        locker.sweep(address(0));
    }

    function test_getAdditionalFeeRecipients() external {
        uint256 adminTokenId = adminToken.mint("Party Token", "image", address(this), address(1));

        address feeRecipient1 = vm.createWallet("FeeRecipient1").addr;
        address feeRecipient2 = vm.createWallet("FeeRecipient2").addr;
        address feeRecipient3 = vm.createWallet("FeeRecipient3").addr;

        PartyLPLocker.LPInfo memory lpInfo;
        {
            PartyLPLocker.AdditionalFeeRecipient[] memory additionalFeeRecipients =
                new PartyLPLocker.AdditionalFeeRecipient[](3);
            additionalFeeRecipients[0] = PartyLPLocker.AdditionalFeeRecipient({
                recipient: feeRecipient1,
                percentageBps: 2000,
                feeType: PartyLPLocker.FeeType.Both
            });
            additionalFeeRecipients[1] = PartyLPLocker.AdditionalFeeRecipient({
                recipient: feeRecipient2,
                percentageBps: 7000,
                feeType: PartyLPLocker.FeeType.Token0
            });
            additionalFeeRecipients[2] = PartyLPLocker.AdditionalFeeRecipient({
                recipient: feeRecipient3,
                percentageBps: 1000,
                feeType: PartyLPLocker.FeeType.Token1
            });
            lpInfo = PartyLPLocker.LPInfo({
                partyTokenAdminId: adminTokenId,
                additionalFeeRecipients: additionalFeeRecipients
            });
        }

        INonfungiblePositionManager(uniswapV3Deployment.POSITION_MANAGER).safeTransferFrom(
            address(this), address(locker), lpTokenId, abi.encode(lpInfo, 0, token)
        );

        PartyLPLocker.AdditionalFeeRecipient[] memory additionalFeeRecipients =
            locker.getAdditionalFeeRecipients(lpTokenId);
        assertEq(additionalFeeRecipients.length, 3);
        assertEq(additionalFeeRecipients[0].recipient, feeRecipient1);
        assertEq(additionalFeeRecipients[1].recipient, feeRecipient2);
        assertEq(additionalFeeRecipients[2].recipient, feeRecipient3);
        assertEq(additionalFeeRecipients[0].percentageBps, 2000);
        assertEq(additionalFeeRecipients[1].percentageBps, 7000);
        assertEq(additionalFeeRecipients[2].percentageBps, 1000);
        assertEq(uint8(additionalFeeRecipients[0].feeType), uint8(PartyLPLocker.FeeType.Both));
        assertEq(uint8(additionalFeeRecipients[1].feeType), uint8(PartyLPLocker.FeeType.Token0));
        assertEq(uint8(additionalFeeRecipients[2].feeType), uint8(PartyLPLocker.FeeType.Token1));
    }

    function test_VERSION() external view {
        assertEq(locker.VERSION(), "1.0.1");
    }
}
