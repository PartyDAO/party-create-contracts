// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {
    ERC20PermitUpgradeable,
    NoncesUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import { ERC20VotesUpgradeable } from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { PartyTokenAdminERC721 } from "./PartyTokenAdminERC721.sol";

contract PartyERC20 is ERC20PermitUpgradeable, ERC20VotesUpgradeable, OwnableUpgradeable {
    event MetadataSet(string description);
    event PausedSet(bool paused);

    error TokenPaused();
    error Unauthorized();
    error InvalidDelegate();

    /**
     * @notice Whether the token is paused. Can be toggled by owner.
     */
    bool public paused;

    /**
     * @notice The ID of the specific launch admin NFT that owns this collection.
     */
    uint256 public adminNftId;

    /**
     * @notice The NFT collector of launch admin NFTs.
     */
    PartyTokenAdminERC721 public immutable ADMIN_NFT;

    /**
     * @param adminNft Admin NFT contract
     */
    constructor(PartyTokenAdminERC721 adminNft) {
        ADMIN_NFT = adminNft;
    }

    /**
     * @notice Initialize the contract.
     * @param name Name of the token
     * @param symbol Symbol of the token
     * @param description Description of the token (only emitted in event, not stored in contract)
     * @param totalSupply Total supply of the token
     * @param receiver Where the entire supply is initially sent
     * @param owner Initial owner of the contract
     * @param adminNFTId_ Admin NFT ID
     */
    function initialize(
        string memory name,
        string memory symbol,
        string memory description,
        uint256 totalSupply,
        address receiver,
        address owner,
        uint256 adminNFTId_
    )
        external
        initializer
    {
        __ERC20_init(name, symbol);
        __ERC20Permit_init(name);
        __Ownable_init(owner);

        _mint(receiver, totalSupply);
        emit MetadataSet(description);

        adminNftId = adminNFTId_;
    }

    /**
     *  @dev Only owner can transfer functions when paused. They can transfer out or call `transferFrom` to
     * themselves.
     */
    function _update(
        address from,
        address to,
        uint256 value
    )
        internal
        override(ERC20Upgradeable, ERC20VotesUpgradeable)
    {
        address owner = owner();
        if (paused && from != owner && (to != owner || msg.sender != owner)) {
            revert TokenPaused();
        }
        super._update(from, to, value);
    }

    /**
     * @dev Enable owner to spend tokens without approval.
     */
    function _spendAllowance(
        address tokenOwner,
        address tokenSpender,
        uint256 value
    )
        internal
        override(ERC20Upgradeable)
    {
        if (tokenSpender != owner()) {
            super._spendAllowance(tokenOwner, tokenSpender, value);
        }
    }

    /**
     * @notice Set the paused state of the token. Only callable by the owner.
     * @param paused_ The new paused state.
     */
    function setPaused(bool paused_) external onlyOwner {
        if (paused == paused_) return;
        paused = paused_;

        emit PausedSet(paused_);
    }

    /**
     * @notice Emit an event setting the metadata for the token.
     * @dev Only callable by the owner of the admin NFT.
     * @param description  Plain text description of the token.
     */
    function setMetadata(string memory description) external {
        if (msg.sender != ADMIN_NFT.ownerOf(adminNftId)) {
            revert Unauthorized();
        }
        emit MetadataSet(description);
    }

    /**
     * @notice Returns the image for the token.
     */
    function getTokenImage() external view returns (string memory) {
        (, string memory image,) = ADMIN_NFT.tokenMetadatas(adminNftId);
        return image;
    }

    /**
     * @dev Auto self delegate
     */
    function delegates(address account) public view override returns (address) {
        address storedDelegate = super.delegates(account);
        return storedDelegate == address(0) ? account : storedDelegate;
    }

    /**
     * @dev Disable delegating to address(0).
     */
    function delegate(address delegatee) public override {
        if (delegatee == address(0)) {
            revert InvalidDelegate();
        }
        super.delegate(delegatee);
    }

    /**
     * @dev Returns the version of the contract. Decimal versions indicate change in logic. Number change indicates
     *      change in ABI.
     */
    function VERSION() external pure returns (string memory) {
        return "0.2.0";
    }

    /**
     * @notice The following functions are overrides required by Solidity.
     */
    function nonces(address owner) public view override(ERC20PermitUpgradeable, NoncesUpgradeable) returns (uint256) {
        return super.nonces(owner);
    }
}
