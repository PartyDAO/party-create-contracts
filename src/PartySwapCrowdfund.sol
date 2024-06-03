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


// TODO: There is no duration for the crowdfund. It only ends when the goal is hit.


// TODO: Rename contract?
contract PartySwapCrowdfund {
    using MerkleProof for bytes32[];
    using SafeCast for uint256;

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
        // TODO: Should allow specifying creator address or always default to msg.sender
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
    uint256 public numOfCrowdfunds;
    // TODO: PartyDAO takes a 0.00055 ETH fee on every contribution. This amount is adjustable and applies globally.
    uint96 public constant PARTY_DAO_FEE = 0.00055 ether;
    uint16 public constant WITHDRAWAL_FEE_BPS = 100; // 1%

    /// @dev The ID of the first crowdfund ever created is 1 (not 0).
    mapping(uint256 => Crowdfund) public crowdfunds;

    enum CrowdfundLifecycle {
        Invalid,
        Active,
        Won,
        Finalized
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
    ) external payable returns (uint256 id) {
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
            _contribute(id, crowdfund, crowdfundArgs.creator, initialContribution);
        }
    }

    function getCrowdfundLifecycle(uint256 id) public view returns (CrowdfundLifecycle) {
        return _getCrowdfundLifecycle(crowdfunds[id]);
    }

    function _getCrowdfundLifecycle(Crowdfund memory crowdfund) internal pure returns (CrowdfundLifecycle) {
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

    // TODO: The user can contribute between 1 wei and the amount remaining for the crowdfund to reach its target.
    // TODO: The proportion of the crowdfund target that someone contributes is the proportion of tokens they receive from the allocation for crowdfund participants.
    // TODO: Crowdfund contributions can also have comments which are emitted as an event when you contribute.
    // TODO: Users contribute and get tokens in the same transaction
    function contribute(uint256 id, string calldata comment, bytes32[] calldata merkleProof) public payable {
        Crowdfund storage crowdfund = crowdfunds[id];

        require(getCrowdfundLifecycle(id) == CrowdfundLifecycle.Active, "Crowdfund is not active");
        require(msg.value > 0, "Contribution must be greater than zero");
        require(msg.value <= crowdfund.targetContribution - crowdfund.totalContributions, "Contribution exceeds target");

        // Verify merkle proof if merkleRoot is set
        if (crowdfund.merkleRoot != bytes32(0)) {
            bytes32 leaf = keccak256(abi.encodePacked(msg.sender));
            require(MerkleProof.verify(merkleProof, crowdfund.merkleRoot, leaf), "Invalid merkle proof");
        }

        _contribute(id, crowdfund, msg.sender, msg.value.toUint96());
    }

    function _contribute(uint256 id, Crowdfund memory crowdfund, address contributor, uint96 amount) internal {
        uint96 fee = PARTY_DAO_FEE;
        uint96 contributionAmount = amount - fee;

        uint96 newTotalContributions = crowdfund.totalContributions + contributionAmount;
        require(newTotalContributions <= crowdfund.targetContribution, "Contribution exceeds amount to reach target");

        crowdfunds[id].totalContributions = newTotalContributions;

        // Mint ERC20 tokens to the contributor
        _mint(crowdfund, contributor, contributionAmount);

        if (_getCrowdfundLifecycle(crowdfund) == CrowdfundLifecycle.Won) {
            _finalize(id, crowdfund);
        }
    }

    function _mint(Crowdfund memory crowdfund, address to, uint256 amount) internal {
        // Implement the minting logic here
        // Mint non-transferable tokens to the contributor
    }

    // TODO: When the crowdfund is finalized, the contract integrates with Uniswap V3 to provide liquidity
    // TODO: The remaining token supply is transferred to the liquidity pool.
    // TODO: The LP tokens are locked in a fee locker contract
    // TODO: Fee Collector needs to be updated to be aware of LP NFT owner
    // TODO: When the LP position is created, the tokens become transferable.
    // TODO: At finalization the reserve tokens are sent to the reserve address or airdrop.
    function _finalize(uint256 id, Crowdfund memory crowdfund) internal {
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
