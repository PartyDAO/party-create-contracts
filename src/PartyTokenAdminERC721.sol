// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.25;

import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC4906 } from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import { LibString } from "solady/src/utils/LibString.sol";

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
        bool launchSuccessful;
        address token;
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
     * @param receiver The address that will receive the token
     * @param token The address of the token managed by the given token ID
     * @return The new token ID
     */
    function mint(
        string calldata name,
        string calldata image,
        address receiver,
        address token
    )
        external
        onlyMinter
        returns (uint256)
    {
        uint256 tokenId = ++totalSupply;
        _mint(receiver, tokenId);
        tokenMetadatas[tokenId] = TokenMetadata(name, image, false, token);

        return tokenId;
    }

    /**
     * @notice Set the metadata of a token indicating the launch succeeded
     * @param tokenId The token ID for which the launch succeeded
     */
    function setLaunchSucceeded(uint256 tokenId) external onlyMinter {
        tokenMetadatas[tokenId].launchSuccessful = true;
        emit MetadataUpdate(tokenId);
    }

    /**
     * @dev See {IERC721Metadata-tokenURI}.
     */
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);

        TokenMetadata memory tokenMetadata = tokenMetadatas[tokenId];
        string memory description =
            "The holder of this NFT can claim LP fees from a permanently locked LP position for this token.";

        return string.concat(
            "data:application/json;utf8,",
            "{\"name\":\"",
            LibString.escapeJSON(tokenMetadata.name),
            "\",\"description\":\"",
            description,
            "\",\"image\":\"",
            LibString.escapeJSON(tokenMetadata.image),
            "\",\"attributes\":[{\"trait_type\":\"Launched\",\"value\":",
            tokenMetadata.launchSuccessful ? "\"True\"" : "\"False\"",
            "},{\"trait_type\":\"Token Address\",\"value\":\"",
            LibString.toHexString(tokenMetadata.token),
            "\"}]}"
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
        emit MetadataUpdate(tokenId);
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
