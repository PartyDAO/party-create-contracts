// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.25;

import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC4906 } from "@openzeppelin/contracts/interfaces/IERC4906.sol";

// TODO: Restrict who can mint tokens (only PartySwapCrowdfund?)
// TODO: The NFT is in a big protocol wide collection called “Party Tokens”
// TODO: The NFT has the image of the token
// TODO: The NFT is transferable
// TODO: The NFT has an attribute that represents if the crowdfund was successful or not

// TODO: Rename contract?
contract PartySwapCreatorERC721 is ERC721, Ownable, IERC4906 {
    error OnlyMinter();

    modifier onlyMinter() {
        if (!isMinter[msg.sender]) revert OnlyMinter();
        _;
    }

    struct TokenMetadata {
        string name;
        string image;
        bool crowdfundSuccessful;
    }

    /// @notice Mapping which stores which addresses are minters.
    mapping(address => bool) public isMinter;

    /// @notice Store the metadata of the token.
    mapping(uint256 => TokenMetadata) internal tokenMetadatas;

    uint256 public totalSupply;

    constructor(string memory name, string memory symbol, address owner) ERC721(name, symbol) Ownable(owner) { }

    function setIsMinter(address who, bool _isMinter) external onlyOwner {
        isMinter[who] = _isMinter;
    }

    function mint(
        string calldata name,
        string calldata image,
        address receiver
    )
        external
        onlyMinter
        returns (uint256)
    {
        uint256 tokenId = ++totalSupply;
        _mint(receiver, tokenId);
        tokenMetadatas[tokenId] = TokenMetadata(name, image, false);

        return tokenId;
    }

    function setCrowdfundSucceeded(uint256 tokenId) external onlyMinter {
        tokenMetadatas[tokenId].crowdfundSuccessful = true;
        emit MetadataUpdate(tokenId);
    }

    /**
     * @dev See {IERC721Metadata-tokenURI}.
     */
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);

        TokenMetadata memory tokenMetadata = tokenMetadatas[tokenId];
        return string.concat(
            "data:application/json;utf8,",
            "{\"name\":\"",
            tokenMetadata.name,
            "\",\"image\":\"",
            tokenMetadata.image,
            "\",\"attributes\":[{\"crowdfund_succeeded\":",
            tokenMetadata.crowdfundSuccessful ? "true" : "false",
            "}]}"
        );
    }

    /**
     * @dev Returns the version of the contract. Decimal versions indicate change in logic. Number change indicates
     * change in ABI.
     */
    function VERSION() external pure returns (string memory) {
        return "0.1.0";
    }
}
