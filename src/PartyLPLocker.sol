// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.25;

import { ILocker } from "./interfaces/ILocker.sol";
import { INonfungiblePositionManager } from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IUNCX } from "./external/IUNCX.sol";

contract PartyLPLocker is ILocker, IERC721Receiver {
    error OnlyPositionManager();
    error InvalidFeeBps();
    error InvalidRecipient();

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
        uint256 partyTokenAdminId;
        AdditionalFeeRecipient[] additionalFeeRecipients;
    }

    struct LockStorage {
        address token0;
        address token1;
        uint256 partyTokenAdminId;
        AdditionalFeeRecipient[] additionalFeeRecipients;
    }

    INonfungiblePositionManager public immutable POSITION_MANAGER;
    IERC721 public immutable PARTY_TOKEN_ADMIN;
    IUNCX public immutable UNCX;

    mapping(uint256 => LockStorage) public lockStorages;

    constructor(INonfungiblePositionManager positionManager, IERC721 partyTokenAdmin, IUNCX uncx) {
        POSITION_MANAGER = positionManager;
        PARTY_TOKEN_ADMIN = partyTokenAdmin;
        UNCX = uncx;
    }

    /**
     * @notice Send a UNI-V3 LP NFT to this contract via `safeTransferFrom` to lock it in UNCX and collect fees. The
     * data must be encoded as an LPInfo struct.
     * @dev `additionalFeeRecipients` must contain at least one additional fee recipient. The first member of this array
     * gets all fees if UNCX forces through a collect call bypassing logic in this contract. This is not expected to
     * ever occur.
     */
    function onERC721Received(address, address, uint256 tokenId, bytes calldata data) external returns (bytes4) {
        if (msg.sender != address(POSITION_MANAGER)) revert OnlyPositionManager();

        (LPInfo memory lpInfo, uint256 uncxFlatFee) = abi.decode(data, (LPInfo, uint256));

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
        uint256 lockId = UNCX.lock{ value: uncxFlatFee }(lockParams);

        {
            (, bytes memory res) =
                address(POSITION_MANAGER).staticcall(abi.encodeCall(POSITION_MANAGER.positions, (tokenId)));
            (,, lockStorages[lockId].token0, lockStorages[lockId].token1) =
                abi.decode(res, (uint96, address, address, address));
        }
        lockStorages[lockId].partyTokenAdminId = lpInfo.partyTokenAdminId;

        uint256 token0TotalBps;
        uint256 token1TotalBps;
        for (uint256 i = 0; i < lpInfo.additionalFeeRecipients.length; i++) {
            // Don't allow sending to address(0)
            if (lpInfo.additionalFeeRecipients[i].recipient == address(0)) revert InvalidRecipient();

            lockStorages[lockId].additionalFeeRecipients.push(lpInfo.additionalFeeRecipients[i]);

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

    /**
     * @notice Collect fees for a given UNCX lock
     * @dev Can be called by anyone
     * @param lockId UNCX lock ID
     * @return amount0 Amount of token0 collected total
     * @return amount1 Amount of token1 collected total
     */
    function collect(uint256 lockId) external returns (uint256 amount0, uint256 amount1) {
        LockStorage memory lockStorage = lockStorages[lockId];

        (amount0, amount1,,) = UNCX.collect(lockId, address(this), type(uint128).max, type(uint128).max);

        for (uint256 i = 0; i < lockStorage.additionalFeeRecipients.length; i++) {
            AdditionalFeeRecipient memory recipient = lockStorage.additionalFeeRecipients[i];

            if (recipient.feeType == FeeType.Token0 || recipient.feeType == FeeType.Both) {
                IERC20(lockStorage.token0).transfer(recipient.recipient, amount0 * recipient.percentageBps / 10_000);
            }

            if (recipient.feeType == FeeType.Token1 || recipient.feeType == FeeType.Both) {
                IERC20(lockStorage.token1).transfer(recipient.recipient, amount1 * recipient.percentageBps / 10_000);
            }
        }

        address remainingReceiver = PARTY_TOKEN_ADMIN.ownerOf(lockStorage.partyTokenAdminId);

        IERC20(lockStorage.token0).transfer(remainingReceiver, IERC20(lockStorage.token0).balanceOf(address(this)));
        IERC20(lockStorage.token1).transfer(remainingReceiver, IERC20(lockStorage.token1).balanceOf(address(this)));
    }

    function getFlatLockFee() external view returns (uint96) {
        return uint96(UNCX.getFee("LVP").flatFee);
    }

    /**
     * @dev Returns the version of the contract. Minor versions indicate change in logic. Major version indicates
     * change in ABI.
     */
    function VERSION() external pure returns (string memory) {
        return "0.1.0";
    }

    /// @dev Allow receiving ETH for UNCX flat fee
    receive() external payable { }
}
