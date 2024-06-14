// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { ERC20Permit, Nonces } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { ERC20Votes, ERC20 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import { PartyTokenAdminERC721 } from "./PartyTokenAdminERC721.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract PartyERC20 is ERC20Permit, ERC20Votes, Ownable {
    event MetadataSet(string description);
    event PausedSet(bool paused);

    error TokenPaused();
    error Unauthorized();

    /**
     * @notice Whether the token is paused. Can be toggled by owner.
     */
    bool public paused;

    /**
     * @notice The NFT collector of launch admin NFTs.
     */
    PartyTokenAdminERC721 public immutable OWNERSHIP_NFT;

    /**
     * @notice The ID of the specific launch admin NFT that owns this collection.
     */
    uint256 public immutable OWNERSHIP_NFT_ID;

    /**
     * @param name Name of the token
     * @param symbol Symbol of the token
     * @param description Description of the token (only emitted in event, not stored in contract)
     * @param totalSupply Total supply of the token
     * @param receiver Where the entire supply is initially sent
     * @param owner Initial owner of the contract
     * @param ownershipNft Ownership NFT contract
     * @param ownershipNFTIds Ownership NFT ID
     */
    constructor(
        string memory name,
        string memory symbol,
        string memory description,
        uint256 totalSupply,
        address receiver,
        address owner,
        PartyTokenAdminERC721 ownershipNft,
        uint256 ownershipNFTIds
    )
        ERC20(name, symbol)
        ERC20Permit(name)
        Ownable(owner)
    {
        _mint(receiver, totalSupply);
        emit MetadataSet(description);

        OWNERSHIP_NFT = ownershipNft;
        OWNERSHIP_NFT_ID = ownershipNFTIds;
    }

    /**
     *  @dev Only owner can transfer functions when paused. They can transfer out or call `transferFrom` to
     * themselves.
     */
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        address owner = owner();
        if (paused && from != owner && (to != owner || msg.sender != owner)) {
            revert TokenPaused();
        }
        super._update(from, to, value);
    }

    /**
     * @dev Enable owner to spend tokens without approval.
     */
    function _spendAllowance(address tokenOwner, address tokenSpender, uint256 value) internal override(ERC20) {
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
     * @dev Only callable by the owner of the ownership NFT.
     * @param description  Plain text description of the token.
     */
    function setMetadata(string memory description) external {
        if (msg.sender != OWNERSHIP_NFT.ownerOf(OWNERSHIP_NFT_ID)) {
            revert Unauthorized();
        }
        emit MetadataSet(description);
    }

    /**
     * @notice Returns the image for the token.
     */
    function getTokenImage() external view returns (string memory) {
        (, string memory image,) = OWNERSHIP_NFT.tokenMetadatas(OWNERSHIP_NFT_ID);
        return image;
    }

    /**
     * @notice Auto self delegate
     */
    function delegates(address account) public view override returns (address) {
        address delegate = super.delegates(account);
        return delegate == address(0) ? account : delegate;
    }

    /**
     * @dev Returns the version of the contract. Decimal versions indicate change in logic. Number change indicates
     *      change in ABI.
     */
    function VERSION() external pure returns (string memory) {
        return "0.1.0";
    }

    /**
     * @notice The following functions are overrides required by Solidity.
     */
    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
