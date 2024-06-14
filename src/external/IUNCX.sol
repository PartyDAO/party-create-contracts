// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { INonfungiblePositionManager } from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";

interface IUNCX {
    struct LockParams {
        INonfungiblePositionManager nftPositionManager; // the NFT Position manager of the Uniswap V3 fork
        uint256 nft_id; // the nft token_id
        address dustRecipient; // receiver of dust tokens which do not fit into liquidity and initial collection fees
        address owner; // owner of the lock
        address additionalCollector; // an additional address allowed to call collect (ideal for contracts to auto
            // collect without having to use owner)
        address collectAddress; // The address to which automatic collections are sent
        uint256 unlockDate; // unlock date of the lock in seconds
        uint16 countryCode; // the country code of the locker / business
        string feeName; // The fee name key you wish to accept, use "DEFAULT" if in doubt
        bytes[] r; // use an empty array => []
    }

    function lock(LockParams calldata params) external payable returns (uint256);
    function collect(
        uint256 lockId,
        address recipient,
        uint128 amount0Max,
        uint128 amount1Max
    )
        external
        returns (uint256 amount0, uint256 amount1, uint256 fee0, uint256 fee1);
}
