// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "./PartySwapERC20.sol";
import "./PartySwapCreatorERC721.sol";

// TODO: Justify why this is a singleton. Concerns around all ERC20s total supply
// and all ETH contributions held by one contract (honeypot)? In an L2 world,
// gas less of concern?

// TODO: Add functions to move ETH from one token to another with one fn call?
// e.g. ragequitAndContribute(address tokenAddressToRageQuit, address tokenAddressToContributeTo)

// TODO: Rename contract?
contract PartySwapCrowdfund {
    using MerkleProof for bytes32[];
    using SafeCast for uint256;

    event Contributed(uint32 crowdfundId, address contributor, uint96 ethContributed, uint96 tokensReceived, string comment);

    struct ERC20Args {
        string name;
        string symbol;
        string description; // Unused for now
        uint96 totalSupply; // Unused for now
    }

    // TODO: recipientType: ‘address’ | ‘airdrop’
    // TODO: recipientAddress -or- recipientAirdropParams
    struct CrowdfundArgs {
        uint96 numTokensForRecipient;
        uint96 numTokensForLP;
        uint96 numTokensForDistribution;
        uint96 targetContribution;
        bytes32 merkleRoot;
        // TODO: Should allow specifying creator address or always default to msg.sender?
        address creator;
    }

    struct Crowdfund {
        IERC20 token;
        uint96 targetContribution;
        uint96 totalContributions;
        uint96 numTokensForLP;
        uint96 numTokensForDistribution;
        bytes32 merkleRoot;
        bool isFinalized;
    }

    PartySwapCreatorERC721 public creatorNFT;
    uint32 public numOfCrowdfunds;
    // TODO: PartyDAO takes a 0.00055 ETH fee on every contribution. This amount is adjustable and applies globally.
    uint96 public partyDaoFee;
    // TODO: PartyDAO collects a 1% fee on ETH if they withdraw. This fee percentage should be adjustable
    uint16 public withdrawalFeeBps;

    /// @dev The ID of the first crowdfund ever created is 1 (not 0).
    mapping(uint32 => Crowdfund) public crowdfunds;

    enum CrowdfundLifecycle {
        Invalid,
        Active,
        Won,
        Finalized
    }

    constructor (uint96 partyDaoFee_, uint16 withdrawalFeeBps_) {
        partyDaoFee = partyDaoFee_;
        withdrawalFeeBps = withdrawalFeeBps_;
    }

    // STEPS:
    // 1. Create new ERC20.
    // 2. Initialize new Crowdfund.

    // DETAILS:
    // - Allow creator to contribute to the crowdfund for the token upon creation.
    // - When the token is created, the creator receives an LP Fee NFT.
    // TODO: Set ratio for ERC20s received : ETH contributed upon crowdfund creation?
    function createCrowdfund(
        ERC20Args memory erc20Args,
        CrowdfundArgs memory crowdfundArgs
    ) external payable returns (uint32 id) {
        require(crowdfundArgs.targetContribution > 0, "Target contribution must be greater than zero");
        require(erc20Args.totalSupply >= crowdfundArgs.numTokensForLP + crowdfundArgs.numTokensForDistribution + crowdfundArgs.numTokensForRecipient, "Total supply must be at least the sum of tokens");

        // Deploy new ERC20 token. Mints the total supply upfront to this contract.
        IERC20 token = new PartySwapERC20(erc20Args.name, erc20Args.symbol, erc20Args.totalSupply);

        // Create new creator NFT. ID of new NFT should correspond to the ID of the crowdfund.
        id = ++numOfCrowdfunds;
        creatorNFT.mint(crowdfundArgs.creator, id);

        // Initialize new crowdfund.
        Crowdfund memory crowdfund = crowdfunds[id] = Crowdfund({
            token: token,
            targetContribution: crowdfundArgs.targetContribution,
            totalContributions: 0,
            numTokensForLP: crowdfundArgs.numTokensForLP,
            numTokensForDistribution: crowdfundArgs.numTokensForDistribution,
            merkleRoot: crowdfundArgs.merkleRoot,
            isFinalized: false
        });

        // Contribute initial amount, if any, attributed to the creator
        uint96 initialContribution = msg.value.toUint96();
        if (initialContribution > 0) {
            _contribute(id, crowdfund, crowdfundArgs.creator, initialContribution, "");
        }
    }

    function getCrowdfundLifecycle(uint32 id) public view returns (CrowdfundLifecycle) {
        return _getCrowdfundLifecycle(crowdfunds[id]);
    }

    function _getCrowdfundLifecycle(Crowdfund memory crowdfund) private pure returns (CrowdfundLifecycle) {
        if (crowdfund.targetContribution == 0) {
            return CrowdfundLifecycle.Invalid;
        } else if (crowdfund.isFinalized) {
            return CrowdfundLifecycle.Finalized;
        } else if (crowdfund.totalContributions >= crowdfund.targetContribution) {
            return CrowdfundLifecycle.Won;
        } else {
            return CrowdfundLifecycle.Active;
        }
    }

    function contribute(uint32 id, string calldata comment, bytes32[] calldata merkleProof) public payable {
        Crowdfund memory crowdfund = crowdfunds[id];

        require(getCrowdfundLifecycle(id) == CrowdfundLifecycle.Active, "Crowdfund is not active");
        require(msg.value > 0, "Contribution must be greater than zero");

        // Verify merkle proof if merkleRoot is set
        if (crowdfund.merkleRoot != bytes32(0)) {
            bytes32 leaf = keccak256(abi.encodePacked(msg.sender));
            require(MerkleProof.verify(merkleProof, crowdfund.merkleRoot, leaf), "Invalid merkle proof");
        }

        _contribute(id, crowdfund, msg.sender, msg.value.toUint96(), comment);
    }

    function _contribute(uint32 id, Crowdfund memory crowdfund, address contributor, uint96 amount, string memory comment) private {
        uint96 contributionFee = partyDaoFee;
        uint96 contributionAmount = amount - contributionFee;

        uint96 newTotalContributions = crowdfund.totalContributions + contributionAmount;
        require(newTotalContributions <= crowdfund.targetContribution, "Contribution exceeds amount to reach target");

        crowdfunds[id].totalContributions = newTotalContributions;

        uint96 tokensReceived = _convertETHContributedToTokensReceived(contributionAmount, crowdfund.targetContribution, crowdfund.numTokensForLP);

        emit Contributed(id, contributor, amount, tokensReceived, comment);

        if (_getCrowdfundLifecycle(crowdfund) == CrowdfundLifecycle.Won) {
            _finalize(id, crowdfund);
        }

        crowdfund.token.transfer(contributor, tokensReceived);
    }

    function _convertETHContributedToTokensReceived(uint96 ethContributed, uint96 targetContribution, uint96 numTokensForLP) private pure returns (uint96 tokensReceived) {
        tokensReceived = (ethContributed * numTokensForLP) / targetContribution;
    }

    // TODO: When the crowdfund is finalized, the contract integrates with Uniswap V3 to provide liquidity
    // TODO: The remaining token supply is transferred to the liquidity pool.
    // TODO: The LP tokens are locked in a fee locker contract
    // TODO: Fee Collector needs to be updated to be aware of LP NFT owner
    // TODO: When the LP position is created, the tokens become transferable.
    // TODO: At finalization the reserve tokens are sent to the reserve address or airdrop.
    function _finalize(uint32 id, Crowdfund memory crowdfund) private {
        require(!crowdfund.isFinalized, "Crowdfund already is finalized");

        crowdfunds[id].isFinalized = true;
    }

    // TODO: Crowdfund participants can withdraw and get their ETH contribution back in exchange for returning the tokens they received while the crowdfund is still happening (“ragequitting”)
    // TODO: They can only ragequit with their entire balance, no partial rage quitting
    // TODO: PartyDAO collects a 1% fee on ETH if they withdraw. This fee percentage should be adjustable. Fee is global for all crowdfunds. If adjusted, affects all crowdfunds, not just new ones
    function ragequit(uint256 id) external {
        // Crowdfund storage crowdfund = crowdfunds[id];
        // require(getCrowdfundLifecycle(id) == CrowdfundLifecycle.Active, "Crowdfund is not active");

        // Implement the logic for contributors to withdraw their ETH contribution
        // and return the tokens they received
    }
}
