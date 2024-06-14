// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.25;

import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC4906 } from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";

contract PartyTokenAdminERC721 is ERC721, Ownable, IERC4906 {
    error OnlyMinter();
    error Unauthorized();

    event ContractURIUpdated();
    event IsMinterSet(address indexed who, bool isMinter);
    event TokenImageSet(uint256 indexed tokenId, string image);

    modifier onlyMinter() {
        if (!isMinter[msg.sender]) revert OnlyMinter();
        _;
    }

    struct TokenMetadata {
        string name;
        string image;
        address erc20;
        address lpLocker;
        uint256 uncxLockId;
    }

    /**
     * @notice Mapping which stores which addresses are minters.
     */
    mapping(address => bool) public isMinter;

    /**
     * @notice Store the metadata for each token.
     */
    mapping(uint256 => TokenMetadata) public tokenMetadatas;

    /**
     * @notice The total supply of the token.
     */
    uint256 public totalSupply;

    /**
     * @notice Contract URI string which is settable by the owner.
     */
    string public contractURI;

    constructor(string memory name, string memory symbol, address owner) ERC721(name, symbol) Ownable(owner) { }

    /**
     * @notice Set if an address is a minter
     * @param who The address to change the minter status
     * @param isMinter_ The new minter status
     */
    function setIsMinter(address who, bool isMinter_) external onlyOwner {
        isMinter[who] = isMinter_;
        emit IsMinterSet(who, isMinter_);
    }

    /**
     * @notice Mints a new token sequentially
     * @param name The name of the new token
     * @param image The image of the new token
     * @param erc20 The address of the ERC20 token this NFT administers
     * @param lpLocker The address of the LP locker this NFT claims from
     * @param receiver The address that will receive the token
     * @return The new token ID
     */
    function mint(
        string calldata name,
        string calldata image,
        address erc20,
        address lpLocker,
        address receiver
    )
        external
        onlyMinter
        returns (uint256)
    {
        uint256 tokenId = ++totalSupply;
        _mint(receiver, tokenId);
        tokenMetadatas[tokenId] = TokenMetadata(name, image, erc20, lpLocker, 0);

        return tokenId;
    }

    /**
     * @notice Set the metadata of a token indicating the launch succeeded
     * @param tokenId The token ID for which the launch succeeded
     * @param uncxLockId The lock ID for the UNCX lock this token is associated with
     */
    function setLaunchSucceeded(uint256 tokenId, uint256 uncxLockId) external onlyMinter {
        if (tokenMetadatas[tokenId].uncxLockId != 0) revert Unauthorized();
        tokenMetadatas[tokenId].uncxLockId = uncxLockId;
        emit MetadataUpdate(tokenId);
    }

    /**
     * @dev See {IERC721Metadata-tokenURI}.
     */
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);

        TokenMetadata memory tokenMetadata = tokenMetadatas[tokenId];

        string memory description;
        if (tokenMetadata.uncxLockId == 0) {
            description = string.concat(
                "This NFT has metadata admin controls over the ERC20 token at ",
                Strings.toHexString(tokenMetadata.erc20),
                ". The holder of this NFT can change the image metadata of the token on-chain."
                " The holder of this NFT will be able to claim LP fees from the permanently locked",
                " LP position if the token launch succeeds. The holder of this NFT cannot perform any",
                " actions that affect this token's functionality or supply."
            );
        } else {
            description = string.concat(
                "This NFT has metadata admin controls over the ERC20 token at ",
                Strings.toHexString(tokenMetadata.erc20),
                ". The holder of this NFT can change the image metadata of the token on-chain.",
                " The holder of this NFT can also claim LP fees from the permanently locked LP position at ",
                Strings.toHexString(tokenMetadata.lpLocker),
                " lockId ",
                Strings.toString(tokenMetadata.uncxLockId),
                ". The holder of this NFT cannot perform any actions that affect this token's functionality or supply."
            );
        }

        return string.concat(
            "data:application/json;utf8,",
            "{\"name\":\"",
            tokenMetadata.name,
            "\",\"description\":\"",
            description,
            "\",\"image\":\"",
            tokenMetadata.image,
            "\",\"attributes\":[{\"launched\":",
            tokenMetadata.uncxLockId != 0 ? "true" : "false",
            "}]}"
        );
    }

    /**
     * @notice Sets the image for an existing token. Also reflected on the paired ERC20.
     * @param tokenId Token ID to set the image for
     * @param image New image string
     */
    function setTokenImage(uint256 tokenId, string calldata image) external {
        if (msg.sender != ownerOf(tokenId)) revert Unauthorized();
        tokenMetadatas[tokenId].image = image;

        emit TokenImageSet(tokenId, image);
    }

    /**
     * @notice Owner function to set the contract URI.
     * @param contractURI_ New contract URI string
     */
    function setContractURI(string memory contractURI_) external onlyOwner {
        contractURI = contractURI_;
        emit ContractURIUpdated();
    }

    /**
     * @dev Returns the version of the contract. Decimal versions indicate change in logic. Number change indicates
     * change in ABI.
     */
    function VERSION() external pure returns (string memory) {
        return "0.4.0";
    }
}
