// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.25;

import { INonfungiblePositionManager } from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IWETH } from "./external/IWETH.sol";
import { IUNCX } from "./external/IUNCX.sol";

contract NFTBoundLPLocker is IERC721Receiver, ReentrancyGuard {
    error OnlyPositionManager();
    error InvalidFeeBps();

    enum FeeType {
        Token0,
        Token1,
        Both
    }

    struct AdditionalFeeRecipient {
        address recipient;
        uint16 percentageBps;
        FeeType feeType;
    }

    struct LPInfo {
        address token0;
        address token1;
        uint256 partyTokenAdminId;
        AdditionalFeeRecipient[] additionalFeeRecipients;
    }

    INonfungiblePositionManager public immutable POSITION_MANAGER;
    IWETH public immutable WETH;
    IERC721 public immutable PARTY_TOKEN_ADMIN;
    IUNCX public immutable UNCX;

    mapping(uint256 => LPInfo) public lpInfos;

    constructor(INonfungiblePositionManager positionManager, IWETH weth, IERC721 partyTokenAdmin, IUNCX uncx) {
        POSITION_MANAGER = positionManager;
        WETH = weth;
        PARTY_TOKEN_ADMIN = partyTokenAdmin;
        UNCX = uncx;
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata data) external returns (bytes4) {
        if (msg.sender != address(POSITION_MANAGER)) revert OnlyPositionManager();

        LPInfo memory lpInfo = abi.decode(data, (LPInfo));

        // First lock in UNCX to get lockId
        IUNCX.LockParams memory lockParams = IUNCX.LockParams({
            nftPositionManager: POSITION_MANAGER,
            nft_id: tokenId,
            dustRecipient: lpInfo.additionalFeeRecipients[0].recipient,
            owner: address(this),
            additionalCollector: address(0),
            collectAddress: lpInfo.additionalFeeRecipients[0].recipient,
            unlockDate: type(uint256).max,
            countryCode: 0,
            feeName: "LVP",
            r: new bytes[](0)
        });

        POSITION_MANAGER.approve(address(UNCX), tokenId);
        uint256 lockId = UNCX.lock(lockParams);

        lpInfos[lockId].partyTokenAdminId = lpInfo.partyTokenAdminId;
        (,, lpInfos[lockId].token0, lpInfos[lockId].token1,,,,,,,,) = POSITION_MANAGER.positions(tokenId);

        uint256 token0TotalBps;
        uint256 token1TotalBps;
        for (uint256 i = 0; i < lpInfo.additionalFeeRecipients.length; i++) {
            lpInfos[lockId].additionalFeeRecipients.push(lpInfo.additionalFeeRecipients[i]);

            FeeType feeType = lpInfo.additionalFeeRecipients[i].feeType;
            token0TotalBps += feeType == FeeType.Token0 || feeType == FeeType.Both
                ? lpInfo.additionalFeeRecipients[i].percentageBps
                : 0;
            token1TotalBps += feeType == FeeType.Token1 || feeType == FeeType.Both
                ? lpInfo.additionalFeeRecipients[i].percentageBps
                : 0;
        }

        if (token0TotalBps > 10_000 || token1TotalBps > 10_000) revert InvalidFeeBps();

        return IERC721Receiver.onERC721Received.selector;
    }

    function collect(uint256 lockId) external nonReentrant {
        LPInfo memory lpInfo = lpInfos[lockId];

        (uint256 amount0, uint256 amount1,,) = UNCX.collect(lockId, address(this), type(uint128).max, type(uint128).max);

        if (lpInfo.token0 == address(WETH)) {
            WETH.withdraw(amount0);
        }
        if (lpInfo.token1 == address(WETH)) {
            WETH.withdraw(amount1);
        }

        for (uint256 i = 0; i < lpInfo.additionalFeeRecipients.length; i++) {
            AdditionalFeeRecipient memory recipient = lpInfo.additionalFeeRecipients[i];

            if (recipient.feeType == FeeType.Token0 || recipient.feeType == FeeType.Both) {
                if (lpInfo.token0 == address(WETH)) {
                    recipient.recipient.call{ value: amount0 * recipient.percentageBps / 10_000, gas: 10_000 }("");
                } else {
                    IERC20(lpInfo.token0).transfer(recipient.recipient, amount0 * recipient.percentageBps / 10_000);
                }
            }

            if (recipient.feeType == FeeType.Token1 || recipient.feeType == FeeType.Both) {
                if (lpInfo.token1 == address(WETH)) {
                    recipient.recipient.call{ value: amount1 * recipient.percentageBps / 10_000, gas: 10_000 }("");
                } else {
                    IERC20(lpInfo.token1).transfer(recipient.recipient, amount1 * recipient.percentageBps / 10_000);
                }
            }
        }

        address remainingReceiver = PARTY_TOKEN_ADMIN.ownerOf(lpInfo.partyTokenAdminId);

        if (lpInfo.token0 == address(WETH)) {
            remainingReceiver.call{ value: address(this).balance, gas: 10_000 }("");
        } else {
            IERC20(lpInfo.token0).transfer(remainingReceiver, IERC20(lpInfo.token0).balanceOf(address(this)));
        }

        if (lpInfo.token1 == address(WETH)) {
            remainingReceiver.call{ value: address(this).balance, gas: 10_000 }("");
        } else {
            IERC20(lpInfo.token1).transfer(remainingReceiver, IERC20(lpInfo.token1).balanceOf(address(this)));
        }
    }

    /**
     * @notice Enable unwrapping WETH
     */
    receive() external payable { }

    /**
     * @dev Returns the version of the contract. Minor versions indicate change in logic. Major version indicates
     * change in ABI.
     */
    function VERSION() external pure returns (string memory) {
        return "0.1.0";
    }
}
