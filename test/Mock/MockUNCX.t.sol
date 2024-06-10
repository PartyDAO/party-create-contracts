// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

import { IUNCX } from "src/external/IUNCX.sol";

contract MockUNCX is IUNCX {
    function lock(IUNCX.LockParams memory lockParams) external payable returns (uint256) {
        lockParams.nftPositionManager.transferFrom(msg.sender, address(this), lockParams.nft_id);
        return lockParams.nft_id + 1;
    }

    function collect(
        uint256 lockId,
        address recipient,
        uint128 amount0Max,
        uint128 amount1Max
    )
        external
        returns (uint256 amount0, uint256 amount1, uint256 fee0, uint256 fee1)
    { }
}
