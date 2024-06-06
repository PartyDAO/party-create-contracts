// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.25;

import { INonfungiblePositionManager } from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IWETH } from "./external/IWETH.sol";

contract NFTBoundLPLocker is IERC721Receiver {
    error OnlyPositionManager();
    error InvalidFeeBps();

    enum FeeType {
        TokenA,
        TokenB,
        Both
    }

    struct AdditionalFeeRecipient {
        address recipient;
        uint16 percentageBps;
        FeeType feeType;
    }

    struct LPInfo {
        uint256 lpOwnerTokenId;
        AdditionalFeeRecipient[] additionalFeeRecipients;
    }

    INonfungiblePositionManager public immutable POSITION_MANAGER;
    IWETH public immutable WETH;
    IERC721 public immutable LP_OWNER_NFT;

    mapping(uint256 => LPInfo) public lpInfos;

    constructor(INonfungiblePositionManager positionManager_, IWETH weth_, IERC721 lpOwnerNft_) {
        POSITION_MANAGER = positionManager_;
        WETH = weth_;
        LP_OWNER_NFT = lpOwnerNft_;
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata data) external returns (bytes4) {
        if (msg.sender != address(POSITION_MANAGER)) revert OnlyPositionManager();

        LPInfo memory lpInfo = abi.decode(data, (LPInfo));
        lpInfos[tokenId].lpOwnerTokenId = lpInfo.lpOwnerTokenId;

        uint256 tokenATotalBps;
        uint256 tokenBTotalBps;
        for (uint256 i = 0; i < lpInfo.additionalFeeRecipients.length; i++) {
            lpInfos[tokenId].additionalFeeRecipients.push(lpInfo.additionalFeeRecipients[i]);

            FeeType feeType = lpInfo.additionalFeeRecipients[i].feeType;
            tokenATotalBps += feeType == FeeType.TokenA || feeType == FeeType.Both
                ? lpInfo.additionalFeeRecipients[i].percentageBps
                : 0;
            tokenBTotalBps += feeType == FeeType.TokenB || feeType == FeeType.Both
                ? lpInfo.additionalFeeRecipients[i].percentageBps
                : 0;
        }

        if (tokenATotalBps > 10_000 || tokenBTotalBps > 10_000) revert InvalidFeeBps();

        return IERC721Receiver.onERC721Received.selector;
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
