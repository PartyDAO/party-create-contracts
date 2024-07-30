// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.25;

import { ILocker } from "./interfaces/ILocker.sol";
import { INonfungiblePositionManager } from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract PartyLPLocker is ILocker, IERC721Receiver, Ownable {
    event Locked(
        uint256 indexed tokenId,
        IERC20 indexed token,
        uint256 indexed partyTokenAdminId,
        AdditionalFeeRecipient[] additionalFeeRecipients
    );
    event Collected(
        uint256 indexed tokenId, uint256 amount0, uint256 amount1, AdditionalFeeRecipient[] additionalFeeRecipients
    );

    error OnlyPositionManager();
    error InvalidFeeBps();
    error InvalidRecipient();
    error MaxAdditionalFeeRecipientsExceeded(uint256 actual, uint256 max);

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

    uint8 public constant MAX_ADDITIONAL_FEE_RECIPIENTS = 25;

    INonfungiblePositionManager public immutable POSITION_MANAGER;
    IERC721 public immutable PARTY_TOKEN_ADMIN;

    /**
     * @notice Get details about a lock by UNI-V3 LP NFT tokenId
     * @return token0 Address of token0 in the UNI-V3 LP
     * @return token1 Address of token1 in the UNI-V3 LP
     * @return partyTokenAdminId ID of the Party token admin NFT
     */
    mapping(uint256 tokenId => LockStorage) public lockStorages;

    constructor(address owner, INonfungiblePositionManager positionManager, IERC721 partyTokenAdmin) Ownable(owner) {
        POSITION_MANAGER = positionManager;
        PARTY_TOKEN_ADMIN = partyTokenAdmin;
    }

    /**
     * @notice Send a UNI-V3 LP NFT to this contract via `safeTransferFrom` to lock it and collect fees.
     * @dev The `data` parameter must be ABI-encoded as (LPInfo, uint256, IERC20) where:
     *      - LPInfo is a struct containing:
     *        - partyTokenAdminId: uint256
     *        - additionalFeeRecipients: AdditionalFeeRecipient[]
     *      - uint256 represents a flat fee (currently unused)
     *      - IERC20 is the token address associated with the UNI-V3 LP
     * @dev `additionalFeeRecipients` should contain at least one additional fee recipient.
     * @param tokenId UNI-V3 LP NFT token ID
     * @param data Encoded data as described above
     * @return bytes4 Magic value to indicate the success of the call
     */
    function onERC721Received(address, address, uint256 tokenId, bytes calldata data) external returns (bytes4) {
        if (msg.sender != address(POSITION_MANAGER)) revert OnlyPositionManager();

        (LPInfo memory lpInfo,, IERC20 token) = abi.decode(data, (LPInfo, uint256, IERC20));

        if (lpInfo.additionalFeeRecipients.length > MAX_ADDITIONAL_FEE_RECIPIENTS) {
            revert MaxAdditionalFeeRecipientsExceeded(
                lpInfo.additionalFeeRecipients.length, MAX_ADDITIONAL_FEE_RECIPIENTS
            );
        }

        {
            (, bytes memory res) =
                address(POSITION_MANAGER).staticcall(abi.encodeCall(POSITION_MANAGER.positions, (tokenId)));
            (,, lockStorages[tokenId].token0, lockStorages[tokenId].token1) =
                abi.decode(res, (uint96, address, address, address));
        }
        lockStorages[tokenId].partyTokenAdminId = lpInfo.partyTokenAdminId;

        uint256 token0TotalBps;
        uint256 token1TotalBps;
        for (uint256 i = 0; i < lpInfo.additionalFeeRecipients.length; i++) {
            if (lpInfo.additionalFeeRecipients[i].recipient == address(0)) revert InvalidRecipient();

            lockStorages[tokenId].additionalFeeRecipients.push(lpInfo.additionalFeeRecipients[i]);

            FeeType feeType = lpInfo.additionalFeeRecipients[i].feeType;
            token0TotalBps += feeType == FeeType.Token0 || feeType == FeeType.Both
                ? lpInfo.additionalFeeRecipients[i].percentageBps
                : 0;
            token1TotalBps += feeType == FeeType.Token1 || feeType == FeeType.Both
                ? lpInfo.additionalFeeRecipients[i].percentageBps
                : 0;
        }

        if (token0TotalBps > 10_000 || token1TotalBps > 10_000) revert InvalidFeeBps();

        emit Locked(tokenId, token, lpInfo.partyTokenAdminId, lpInfo.additionalFeeRecipients);

        return IERC721Receiver.onERC721Received.selector;
    }

    /**
     * @notice Collect fees for a given UNI-V3 LP NFT
     * @dev Can be called by anyone
     * @param tokenId UNI-V3 LP NFT token ID
     * @return amount0 Amount of token0 collected total
     * @return amount1 Amount of token1 collected total
     */
    function collect(uint256 tokenId) external returns (uint256 amount0, uint256 amount1) {
        LockStorage memory lockStorage = lockStorages[tokenId];

        (amount0, amount1) = POSITION_MANAGER.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        // Distribute fees to additional fee recipients
        for (uint256 i = 0; i < lockStorage.additionalFeeRecipients.length; i++) {
            AdditionalFeeRecipient memory recipient = lockStorage.additionalFeeRecipients[i];

            if (recipient.feeType == FeeType.Token0 || recipient.feeType == FeeType.Both) {
                uint256 recipientFee = (amount0 * recipient.percentageBps) / 1e4;
                if (recipientFee > 0) {
                    IERC20(lockStorage.token0).transfer(recipient.recipient, recipientFee);
                }
            }

            if (recipient.feeType == FeeType.Token1 || recipient.feeType == FeeType.Both) {
                uint256 recipientFee = (amount1 * recipient.percentageBps) / 1e4;
                if (recipientFee > 0) {
                    IERC20(lockStorage.token1).transfer(recipient.recipient, recipientFee);
                }
            }
        }

        address remainingReceiver = PARTY_TOKEN_ADMIN.ownerOf(lockStorage.partyTokenAdminId);

        uint256 remainingAmount0 = IERC20(lockStorage.token0).balanceOf(address(this));
        if (remainingAmount0 > 0) IERC20(lockStorage.token0).transfer(remainingReceiver, remainingAmount0);

        uint256 remainingAmount1 = IERC20(lockStorage.token1).balanceOf(address(this));
        if (remainingAmount1 > 0) IERC20(lockStorage.token1).transfer(remainingReceiver, remainingAmount1);

        emit Collected(tokenId, amount0, amount1, lockStorage.additionalFeeRecipients);
    }

    /**
     * @notice Get the flat fee to lock a UNI-V3 LP NFT, if any.
     */
    function getFlatLockFee() external pure returns (uint96) {
        return 0;
    }

    /**
     * @notice Returns the version of the contract. Minor versions indicate
     *         change in logic. Major version indicates change in ABI.
     */
    function VERSION() external pure returns (string memory) {
        return "1.0.1";
    }

    /**
     * @notice Get the additional fee recipients for a given UNI-V3 LP NFT.
     * @param tokenId UNI-V3 LP NFT token ID
     * @return additionalFeeRecipients Additional fee recipients for collected
     *                                 fees besides the owner of the Party token
     *                                 admin NFT token ID
     */
    function getAdditionalFeeRecipients(uint256 tokenId) external view returns (AdditionalFeeRecipient[] memory) {
        return lockStorages[tokenId].additionalFeeRecipients;
    }

    /**
     * @notice Withdraw excess ETH stored in this contract.
     * @param recipient Address ETH should be sent to
     */
    function sweep(address recipient) external onlyOwner {
        if (recipient == address(0)) revert InvalidRecipient();

        uint256 balance = address(this).balance;
        if (balance != 0) recipient.call{ value: balance, gas: 1e5 }("");
    }
}
