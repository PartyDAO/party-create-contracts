// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

import { IUNCX, INonfungiblePositionManager } from "src/external/IUNCX.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

contract MockUNCX is IUNCX, IERC721Receiver {
    struct LockInfo {
        INonfungiblePositionManager nftPositionManager;
        uint256 nft_id;
    }

    mapping(uint256 lockId => LockInfo) private lockInfos;

    function lock(IUNCX.LockParams memory lockParams) external payable returns (uint256) {
        lockParams.nftPositionManager.transferFrom(msg.sender, address(this), lockParams.nft_id);
        lockInfos[lockParams.nft_id + 1] = LockInfo(lockParams.nftPositionManager, lockParams.nft_id);
        return lockParams.nft_id + 1;
    }

    function collect(
        uint256 lockId,
        address recipient,
        uint128 amount0Max,
        uint128 amount1Max
    )
        external
        returns (uint256 amount0, uint256 amount1, uint256, uint256)
    {
        LockInfo memory lockInfo = lockInfos[lockId];
        require(lockInfo.nft_id != 0, "Lock not found");
        (amount0, amount1) = lockInfo.nftPositionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: lockInfo.nft_id,
                recipient: recipient,
                amount0Max: amount0Max,
                amount1Max: amount1Max
            })
        );
    }

    function getFee(string memory) external pure returns (IUNCX.FeeStruct memory) {
        return IUNCX.FeeStruct({
            name: "LVP",
            lpFee: 80,
            collectFee: 100,
            flatFee: 30_000_000_000_000_000,
            flatFeeToken: address(0)
        });
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
