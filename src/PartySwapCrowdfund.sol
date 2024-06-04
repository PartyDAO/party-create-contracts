// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.25;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { CircuitBreakerERC20 } from "./CircuitBreakerERC20.sol";
import { PartySwapCreatorERC721 } from "./PartySwapCreatorERC721.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// TODO: Add functions to move ETH from one token to another with one fn call?
// e.g. ragequitAndContribute(address tokenAddressToRageQuit, address tokenAddressToContributeTo)

// TODO: Rename contract?
contract PartySwapCrowdfund is Ownable {
    using MerkleProof for bytes32[];
    using SafeCast for uint256;

    event CrowdfundCreated(uint32 indexed crowdfundId, address indexed creator, IERC20 indexed token);
    event Contribute(
        uint32 indexed crowdfundId,
        address indexed contributor,
        string comment,
        uint96 ethContributed,
        uint96 tokensReceived,
        uint96 contributionFee
    );
    event Ragequit(
        uint32 indexed crowdfundId,
        address indexed contributor,
        uint96 tokensReceived,
        uint96 ethContributed,
        uint96 withdrawalFee
    );
    event Finalized(uint32 indexed crowdfundId, address tokenLiquidityPool);
    event ContributionFeeSet(uint96 oldContributionFee, uint96 newContributionFee);
    event WithdrawalFeeBpsSet(uint16 oldWithdrawalFeeBps, uint16 newWithdrawalFeeBps);

    error CrowdfundInvalid();

    enum CrowdfundLifecycle {
        Active,
        Finalized
    }

    struct ERC20Args {
        string name;
        string symbol;
        string image;
        string description;
        uint96 totalSupply;
    }

    struct CrowdfundArgs {
        uint96 numTokensForLP;
        uint96 numTokensForDistribution;
        uint96 numTokensForRecipient;
        uint96 targetContribution;
        bytes32 merkleRoot;
        address recipient;
    }

    struct Crowdfund {
        IERC20 token;
        uint96 targetContribution;
        uint96 totalContributions;
        uint96 numTokensForLP;
        uint96 numTokensForDistribution;
        uint96 numTokensForRecipient;
        bytes32 merkleRoot;
        address recipient;
    }

    PartySwapCreatorERC721 public immutable CREATOR_NFT;

    uint32 public numOfCrowdfunds;
    uint96 public contributionFee;
    uint16 public withdrawalFeeBps;

    /// @dev IDs start at 1.
    mapping(uint32 => Crowdfund) public crowdfunds;

    constructor(
        address payable partyDAO,
        PartySwapCreatorERC721 creatorNFT,
        uint96 contributionFee_,
        uint16 withdrawalFeeBps_
    )
        Ownable(partyDAO)
    {
        CREATOR_NFT = creatorNFT;
        contributionFee = contributionFee_;
        withdrawalFeeBps = withdrawalFeeBps_;
    }

    function createCrowdfund(
        ERC20Args memory erc20Args,
        CrowdfundArgs memory crowdfundArgs
    )
        external
        payable
        returns (uint32 id)
    {
        require(crowdfundArgs.targetContribution > 0, "Target contribution must be greater than zero");
        require(
            erc20Args.totalSupply
                >= crowdfundArgs.numTokensForLP + crowdfundArgs.numTokensForDistribution
                    + crowdfundArgs.numTokensForRecipient,
            "Total supply must be at least the sum of tokens"
        );

        id = ++numOfCrowdfunds;

        // Deploy new ERC20 token. Mints the total supply upfront to this contract.
        CircuitBreakerERC20 token = new CircuitBreakerERC20{ salt: keccak256(abi.encodePacked(id, block.chainid)) }(
            erc20Args.name,
            erc20Args.symbol,
            erc20Args.image,
            erc20Args.description,
            erc20Args.totalSupply,
            address(this),
            address(this)
        );
        token.setPaused(true);

        // Create new creator NFT. ID of new NFT should correspond to the ID of the crowdfund.
        CREATOR_NFT.mint(erc20Args.name, erc20Args.image, msg.sender);

        // Initialize new crowdfund.
        Crowdfund memory crowdfund = crowdfunds[id] = Crowdfund({
            token: token,
            targetContribution: crowdfundArgs.targetContribution,
            totalContributions: 0,
            numTokensForLP: crowdfundArgs.numTokensForLP,
            numTokensForDistribution: crowdfundArgs.numTokensForDistribution,
            numTokensForRecipient: crowdfundArgs.numTokensForRecipient,
            merkleRoot: crowdfundArgs.merkleRoot,
            recipient: crowdfundArgs.recipient
        });

        // Contribute initial amount, if any, and attribute the contribution to the creator
        uint96 initialContribution = msg.value.toUint96();
        if (initialContribution > 0) {
            (crowdfund,) = _contribute(id, crowdfund, msg.sender, initialContribution, "");
        }

        emit CrowdfundCreated(id, msg.sender, token);
    }

    function getCrowdfundLifecycle(uint32 crowdfundId) public view returns (CrowdfundLifecycle) {
        return _getCrowdfundLifecycle(crowdfunds[crowdfundId]);
    }

    function _getCrowdfundLifecycle(Crowdfund memory crowdfund) private pure returns (CrowdfundLifecycle) {
        if (crowdfund.targetContribution == 0) {
            revert CrowdfundInvalid();
        } else if (crowdfund.totalContributions >= crowdfund.targetContribution) {
            return CrowdfundLifecycle.Finalized;
        } else {
            return CrowdfundLifecycle.Active;
        }
    }

    function contribute(
        uint32 crowdfundId,
        string calldata comment,
        bytes32[] calldata merkleProof
    )
        public
        payable
        returns (uint96 tokensReceived)
    {
        Crowdfund memory crowdfund = crowdfunds[crowdfundId];

        // Verify merkle proof if merkle root is set
        if (crowdfund.merkleRoot != bytes32(0)) {
            bytes32 leaf = keccak256(abi.encodePacked(msg.sender));
            require(MerkleProof.verifyCalldata(merkleProof, crowdfund.merkleRoot, leaf), "Invalid merkle proof");
        }

        (crowdfund, tokensReceived) = _contribute(crowdfundId, crowdfund, msg.sender, msg.value.toUint96(), comment);
    }

    function _contribute(
        uint32 id,
        Crowdfund memory crowdfund,
        address contributor,
        uint96 amount,
        string memory comment
    )
        private
        returns (Crowdfund memory, uint96)
    {
        require(_getCrowdfundLifecycle(crowdfund) == CrowdfundLifecycle.Active, "Crowdfund is not active");
        require(amount > 0, "Contribution must be greater than zero");

        uint96 contributionFee_ = contributionFee;
        uint96 contributionAmount = amount - contributionFee_;

        uint96 newTotalContributions = crowdfund.totalContributions + contributionAmount;
        require(newTotalContributions <= crowdfund.targetContribution, "Contribution exceeds amount to reach target");

        // Update state
        crowdfunds[id].totalContributions = crowdfund.totalContributions = newTotalContributions;

        uint96 tokensReceived = _convertETHContributedToTokensReceived(
            contributionAmount, crowdfund.targetContribution, crowdfund.numTokensForLP
        );

        emit Contribute(id, contributor, comment, contributionAmount, tokensReceived, contributionFee_);

        // Check if the crowdfund has reached its target and finalize if necessary
        if (_getCrowdfundLifecycle(crowdfund) == CrowdfundLifecycle.Finalized) {
            _finalize(crowdfund);
        }

        // Transfer the tokens to the contributor
        crowdfund.token.transfer(contributor, tokensReceived);

        // Transfer the ETH contribution fee to PartyDAO
        payable(owner()).call{ value: contributionFee_, gas: 1e5 }("");

        return (crowdfund, tokensReceived);
    }

    function convertETHContributedToTokensReceived(
        uint32 crowdfundId,
        uint96 ethContributed
    )
        external
        view
        returns (uint96 tokensReceived)
    {
        Crowdfund memory crowdfund = crowdfunds[crowdfundId];
        tokensReceived = _convertETHContributedToTokensReceived(
            ethContributed, crowdfund.targetContribution, crowdfund.numTokensForLP
        );
    }

    function convertTokensReceivedToETHContributed(
        uint32 crowdfundId,
        uint96 tokensReceived
    )
        external
        view
        returns (uint96 ethContributed)
    {
        Crowdfund memory crowdfund = crowdfunds[crowdfundId];
        ethContributed = _convertTokensReceivedToETHContributed(
            tokensReceived, crowdfund.targetContribution, crowdfund.numTokensForLP
        );
    }

    function _convertETHContributedToTokensReceived(
        uint96 ethContributed,
        uint96 targetContribution,
        uint96 numTokensForLP
    )
        private
        pure
        returns (uint96 tokensReceived)
    {
        // tokensReceived = ethContributed * numTokensForLP / targetContribution
        // Use Math.mulDiv to avoid overflow doing math with uint96s, then safe cast uint256 result to uint96.
        tokensReceived = Math.mulDiv(ethContributed, numTokensForLP, targetContribution).toUint96();
    }

    function _convertTokensReceivedToETHContributed(
        uint96 tokensReceived,
        uint96 targetContribution,
        uint96 numTokensForLP
    )
        private
        pure
        returns (uint96 ethContributed)
    {
        // ethContributed = tokensReceived * targetContribution / numTokensForLP
        // Use Math.mulDiv to avoid overflow doing math with uint96s, then safe cast uint256 result to uint96.
        ethContributed = Math.mulDiv(tokensReceived, targetContribution, numTokensForLP).toUint96();
    }

    // TODO: When the crowdfund is finalized, the contract integrates with Uniswap V3 to provide liquidity. The
    // remaining token supply is transferred to the liquidity pool.
    // TODO: The LP tokens are locked in a fee locker contract
    // TODO: Fee Collector needs to be aware of LP NFT owner
    // TODO: The LP Fee NFT updates an attribute to indicate its been successfully upon finalization
    // TODO: When the LP position is created, the tokens become transferable.
    // TODO: Unpause token and abdicate ownership
    function _finalize(Crowdfund memory crowdfund) private {
        // Transfer tokens to recipient
        crowdfund.token.transfer(crowdfund.recipient, crowdfund.numTokensForRecipient);
    }

    function ragequit(uint32 crowdfundId) external {
        Crowdfund memory crowdfund = crowdfunds[crowdfundId];
        require(_getCrowdfundLifecycle(crowdfund) == CrowdfundLifecycle.Active, "Crowdfund is not active");

        uint96 tokensReceived = uint96(crowdfund.token.balanceOf(msg.sender));
        uint96 ethContributed = _convertTokensReceivedToETHContributed(
            tokensReceived, crowdfund.targetContribution, crowdfund.numTokensForLP
        );
        uint96 withdrawalFee = (ethContributed * withdrawalFeeBps) / 1e4;

        // Pull tokens from sender
        crowdfund.token.transferFrom(msg.sender, address(this), tokensReceived);

        // Update crowdfund state
        crowdfunds[crowdfundId].totalContributions -= ethContributed;

        // Transfer withdrawal fee to PartyDAO
        payable(owner()).call{ value: withdrawalFee, gas: 1e5 }("");

        // Transfer ETH to sender
        payable(msg.sender).call{ value: ethContributed - withdrawalFee, gas: 1e5 }("");

        emit Ragequit(crowdfundId, msg.sender, tokensReceived, ethContributed - withdrawalFee, withdrawalFee);
    }

    function setContributionFee(uint96 contributionFee_) external onlyOwner {
        emit ContributionFeeSet(contributionFee, contributionFee_);
        contributionFee = contributionFee_;
    }

    function setWithdrawalFeeBps(uint16 withdrawalFeeBps_) external onlyOwner {
        emit WithdrawalFeeBpsSet(withdrawalFeeBps, withdrawalFeeBps_);
        withdrawalFeeBps = withdrawalFeeBps_;
    }

    /**
     * @dev Returns the version of the contract. Decimal versions indicate change in logic. Number change indicates
     *      change in ABI.
     */
    function VERSION() external pure returns (string memory) {
        return "0.2.0";
    }
}
