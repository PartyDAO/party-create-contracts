// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { PartySwapERC20 } from "./PartySwapERC20.sol";
import { PartySwapCreatorERC721 } from "./PartySwapCreatorERC721.sol";
import { IAirdropper } from "./IAirdropper.sol";

// TODO: Justify why this is a singleton. Concerns around all ERC20s total supply
// and all ETH contributions held by one contract (honeypot)? In an L2 world,
// gas less of concern?

// TODO: Add functions to move ETH from one token to another with one fn call?
// e.g. ragequitAndContribute(address tokenAddressToRageQuit, address tokenAddressToContributeTo)

// TODO: Rename contract?
contract PartySwapCrowdfund {
    using SafeERC20 for IERC20;
    using MerkleProof for bytes32[];
    using SafeCast for uint256;

    event Contributed(uint32 indexed crowdfundId, address indexed contributor, string comment, uint96 ethContributed, uint96 tokensReceived, uint96 contributionFee);
    event Ragequitted(uint32 indexed crowdfundId, address indexed contributor, uint96 tokensReceived, uint96 ethContributed, uint96 withdrawalFee);
    event ContributionFeeSet(uint96 oldContributionFee, uint96 newContributionFee);
    event WithdrawalFeeBpsSet(uint16 oldWithdrawalFeeBps, uint16 newWithdrawalFeeBps);

    enum CrowdfundLifecycle {
        Invalid,
        Active,
        Finalized
    }


    enum RecipientType {
        Address,
        Airdrop
    }


    struct ERC20Args {
        string name;
        string symbol;
        string image;
        string description;
        uint96 totalSupply;
    }

    struct CrowdfundArgs {
        RecipientType recipientType;
        // Depending on the recipient type, this will be an address or params for the airdrop
        bytes recipientData;
        uint96 numTokensForLP;
        uint96 numTokensForDistribution;
        uint96 numTokensForRecipient;
        uint96 targetContribution;
        bytes32 merkleRoot;
        address creator;
    }

    struct Crowdfund {
        IERC20 token;
        RecipientType recipientType;
        bytes recipientData;
        uint96 targetContribution;
        uint96 totalContributions;
        uint96 numTokensForLP;
        uint96 numTokensForDistribution;
        uint96 numTokensForRecipient;
        bytes32 merkleRoot;
    }

    address payable public immutable PARTY_DAO;
    IAirdropper public immutable AIRDROPPER;
    PartySwapCreatorERC721 public immutable CREATOR_NFT;

    uint32 public numOfCrowdfunds;
    uint96 public contributionFee;
    uint16 public withdrawalFeeBps;

    /// @dev IDs start at 1.
    mapping(uint32 => Crowdfund) public crowdfunds;

    modifier onlyPartyDao() {
        require(msg.sender == PARTY_DAO, "Only Party DAO can call this function");
        _;
    }

    constructor (address payable partyDAO, IAirdropper airdropper, PartySwapCreatorERC721 creatorNFT, uint96 contributionFee_, uint16 withdrawalFeeBps_) {
        PARTY_DAO = partyDAO;
        AIRDROPPER = airdropper;
        CREATOR_NFT = creatorNFT;
        contributionFee = contributionFee_;
        withdrawalFeeBps = withdrawalFeeBps_;
    }

    // STEPS:
    // 1. Create new ERC20.
    // 2. Initialize new Crowdfund.

    // DETAILS:
    // - Allow creator to contribute to the crowdfund for the token upon creation.
    // - When the token is created, the creator receives an LP Fee NFT.
    function createCrowdfund(
        ERC20Args memory erc20Args,
        CrowdfundArgs memory crowdfundArgs
    ) external payable returns (uint32 id) {
        require(crowdfundArgs.targetContribution > 0, "Target contribution must be greater than zero");
        require(erc20Args.totalSupply >= crowdfundArgs.numTokensForLP + crowdfundArgs.numTokensForDistribution + crowdfundArgs.numTokensForRecipient, "Total supply must be at least the sum of tokens");

        // Deploy new ERC20 token. Mints the total supply upfront to this contract.
        IERC20 token = new PartySwapERC20(erc20Args.name, erc20Args.symbol, erc20Args.image, erc20Args.description, erc20Args.totalSupply);

        // Create new creator NFT. ID of new NFT should correspond to the ID of the crowdfund.
        id = ++numOfCrowdfunds;
        CREATOR_NFT.mint(crowdfundArgs.creator, id);

        // Initialize new crowdfund.
        Crowdfund memory crowdfund = crowdfunds[id] = Crowdfund({
            token: token,
            recipientType: crowdfundArgs.recipientType,
            recipientData: crowdfundArgs.recipientData,
            targetContribution: crowdfundArgs.targetContribution,
            totalContributions: 0,
            numTokensForLP: crowdfundArgs.numTokensForLP,
            numTokensForDistribution: crowdfundArgs.numTokensForDistribution,
            numTokensForRecipient: crowdfundArgs.numTokensForRecipient,
            merkleRoot: crowdfundArgs.merkleRoot
        });

        // Contribute initial amount, if any, and attribute the contribution to the creator
        uint96 initialContribution = msg.value.toUint96();
        if (initialContribution > 0) {
            (crowdfund, ) = _contribute(id, crowdfund, crowdfundArgs.creator, initialContribution, "");
        }
    }

    function getCrowdfundLifecycle(uint32 crowdfundId) public view returns (CrowdfundLifecycle) {
        return _getCrowdfundLifecycle(crowdfunds[crowdfundId]);
    }

    function _getCrowdfundLifecycle(Crowdfund memory crowdfund) private pure returns (CrowdfundLifecycle) {
        if (crowdfund.targetContribution == 0) {
            return CrowdfundLifecycle.Invalid;
        } else if (crowdfund.totalContributions >= crowdfund.targetContribution) {
            return CrowdfundLifecycle.Finalized;
        } else {
            return CrowdfundLifecycle.Active;
        }
    }

    function contribute(uint32 crowdfundId, string calldata comment, bytes32[] calldata merkleProof) public payable returns (uint96 tokensReceived) {
        Crowdfund memory crowdfund = crowdfunds[crowdfundId];

        // Verify merkle proof if merkle root is set
        if (crowdfund.merkleRoot != bytes32(0)) {
            bytes32 leaf = keccak256(abi.encodePacked(msg.sender));
            require(MerkleProof.verify(merkleProof, crowdfund.merkleRoot, leaf), "Invalid merkle proof");
        }

        (crowdfund, tokensReceived) = _contribute(crowdfundId, crowdfund, msg.sender, msg.value.toUint96(), comment);
    }

    function _contribute(uint32 id, Crowdfund memory crowdfund, address contributor, uint96 amount, string memory comment) private returns (Crowdfund memory, uint96) {
        require(_getCrowdfundLifecycle(crowdfund) == CrowdfundLifecycle.Active, "Crowdfund is not active");
        require(msg.value > 0, "Contribution must be greater than zero");

        uint96 contributionFee_ = contributionFee;
        uint96 contributionAmount = amount - contributionFee_;

        uint96 newTotalContributions = crowdfund.totalContributions + contributionAmount;
        require(newTotalContributions <= crowdfund.targetContribution, "Contribution exceeds amount to reach target");


        crowdfunds[id].totalContributions = crowdfund.totalContributions = newTotalContributions;

        uint96 tokensReceived = _convertETHContributedToTokensReceived(contributionAmount, crowdfund.targetContribution, crowdfund.numTokensForLP);

        emit Contributed(id, contributor, comment, amount, tokensReceived, contributionFee_);

        if (_getCrowdfundLifecycle(crowdfund) == CrowdfundLifecycle.Finalized) {
            _finalize(crowdfund);
        }

        crowdfund.token.transfer(contributor, tokensReceived);

        payable(PARTY_DAO).call{value: contributionFee_, gas: 1e5}("");

        return (crowdfund, tokensReceived);
    }

    function convertETHContributedToTokensReceived(uint32 crowdfundId, uint96 ethContributed) external view returns (uint96 tokensReceived) {
        Crowdfund memory crowdfund = crowdfunds[crowdfundId];
        tokensReceived = _convertETHContributedToTokensReceived(ethContributed, crowdfund.targetContribution, crowdfund.numTokensForLP);
    }

    function convertTokensReceivedToETHContributed(uint32 crowdfundId, uint96 tokensReceived) external view returns (uint96 ethContributed) {
        Crowdfund memory crowdfund = crowdfunds[crowdfundId];
        ethContributed = _convertTokensReceivedToETHContributed(tokensReceived, crowdfund.targetContribution, crowdfund.numTokensForLP);
    }

    function _convertETHContributedToTokensReceived(uint96 ethContributed, uint96 targetContribution, uint96 numTokensForLP) private pure returns (uint96 tokensReceived) {
        // tokensReceived = ethContributed * numTokensForLP / targetContribution
        // Use Math.mulDiv to avoid overflow doing math with uint96s, then safe cast uint256 result to uint96.
        tokensReceived = Math.mulDiv(ethContributed, numTokensForLP, targetContribution).toUint96();
    }

    function _convertTokensReceivedToETHContributed(uint96 tokensReceived, uint96 targetContribution, uint96 numTokensForLP) private pure returns (uint96 ethContributed) {
        // ethContributed = tokensReceived * targetContribution / numTokensForLP
        // Use Math.mulDiv to avoid overflow doing math with uint96s, then safe cast uint256 result to uint96.
        ethContributed = Math.mulDiv(tokensReceived, targetContribution, numTokensForLP).toUint96();
    }

    // TODO: When the crowdfund is finalized, the contract integrates with Uniswap V3 to provide liquidity. The remaining token supply is transferred to the liquidity pool.
    // TODO: The LP tokens are locked in a fee locker contract
    // TODO: Fee Collector needs to be aware of LP NFT owner
    // TODO: The LP Fee NFT updates an attribute to indicate its been successfully upon finalization
    // TODO: When the LP position is created, the tokens become transferable.
    function _finalize(Crowdfund memory crowdfund) private {
        // Transfer tokens to recipient
        if (crowdfund.recipientType == RecipientType.Address) {
            address recipient = abi.decode(crowdfund.recipientData, (address));
            crowdfund.token.transfer(recipient, crowdfund.numTokensForRecipient);
        } else if (crowdfund.recipientType == RecipientType.Airdrop) {
            crowdfund.token.transfer(address(AIRDROPPER), crowdfund.numTokensForRecipient);
            AIRDROPPER.airdrop(crowdfund.recipientData);
        }
    }

    function ragequit(uint32 crowdfundId) external {
        Crowdfund memory crowdfund = crowdfunds[crowdfundId];
        require(_getCrowdfundLifecycle(crowdfund) == CrowdfundLifecycle.Active, "Crowdfund is not active");

        uint96 tokensReceived = uint96(crowdfund.token.balanceOf(msg.sender));
        uint96 ethContributed = _convertTokensReceivedToETHContributed(tokensReceived, crowdfund.targetContribution, crowdfund.numTokensForLP);
        uint96 withdrawalFee = uint96(Math.mulDiv(ethContributed, withdrawalFeeBps, 1e4));

        // Pull tokens from sender
        crowdfund.token.safeTransferFrom(msg.sender, address(this), tokensReceived);

        // Update crowdfund state
        crowdfunds[crowdfundId].totalContributions -= ethContributed;

        // Transfer withdrawal fee to PartyDAO
        payable(PARTY_DAO).call{value: withdrawalFee, gas: 1e5}("");

        // Transfer ETH to sender
        payable(msg.sender).call{value: ethContributed - withdrawalFee, gas: 1e5}("");

        emit Ragequitted(crowdfundId, msg.sender, tokensReceived, ethContributed, withdrawalFee);
    }

    function setContributionFee(uint96 contributionFee_) external onlyPartyDao {
        emit ContributionFeeSet(contributionFee, contributionFee_);
        contributionFee = contributionFee_;
    }

    function setWithdrawalFeeBps(uint16 withdrawalFeeBps_) external onlyPartyDao {
        emit WithdrawalFeeBpsSet(withdrawalFeeBps, withdrawalFeeBps_);
        withdrawalFeeBps = withdrawalFeeBps_;
    }
}
