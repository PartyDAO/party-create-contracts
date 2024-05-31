// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

contract PartySwapCrowdfund {
    using MerkleProof for bytes32[];

    struct Crowdfund {
        IERC20 token;
        uint96 targetContribution;
        uint96 totalContributions;
        uint96 numTokensForLP;
        uint96 numTokensForDistribution;
        bool isFinalized;
        bytes32 merkleRoot;
    }

    mapping(uint256 => Crowdfund) public crowdfunds;
    uint256 public numOfCrowdfunds;
    uint256 public constant PARTY_DAO_FEE = 0.00055 ether;
    uint256 public constant WITHDRAWAL_FEE_BPS = 100; // 1%

    enum CrowdfundLifecycle {
        Invalid,
        Active,
        Won,
        Finalized
    }

    function createCrowdfund(
        string memory name,
        string memory symbol,
        uint96 targetContribution,
        uint96 numTokensForLP,
        uint96 numTokensForDistribution,
        uint96 totalSupply, // Unused for now
        bytes32 merkleRoot
    ) external returns (uint256) {
        require(targetContribution > 0, "Target contribution must be greater than zero");
        require(totalSupply >= numTokensForLP + numTokensForDistribution, "Total supply must be at least the sum of tokens for LP and distribution");

        // Deploy the ERC20 token
        ERC20 token = new ERC20(name, symbol);

        crowdfunds[numOfCrowdfunds] = Crowdfund({
            token: token,
            targetContribution: targetContribution,
            totalContributions: 0,
            numTokensForLP: numTokensForLP,
            numTokensForDistribution: numTokensForDistribution,
            isFinalized: false,
            merkleRoot: merkleRoot
        });

        return numOfCrowdfunds++;
    }

    function getCrowdfundLifecycle(uint256 id) public view returns (CrowdfundLifecycle) {
        Crowdfund storage crowdfund = crowdfunds[id];

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

    function contribute(uint256 id, string calldata comment, bytes32[] calldata merkleProof) external payable {
        Crowdfund storage crowdfund = crowdfunds[id];

        require(getCrowdfundLifecycle(id) == CrowdfundLifecycle.Active, "Crowdfund is not active");
        require(msg.value > 0, "Contribution must be greater than zero");
        require(msg.value <= crowdfund.targetContribution - crowdfund.totalContributions, "Contribution exceeds target");

        // Verify merkle proof if merkleRoot is set
        if (crowdfund.merkleRoot != bytes32(0)) {
            bytes32 leaf = keccak256(abi.encodePacked(msg.sender));
            require(MerkleProof.verify(merkleProof, crowdfund.merkleRoot, leaf), "Invalid merkle proof");
        }

        uint256 fee = PARTY_DAO_FEE;
        uint256 contributionAmount = msg.value - fee;
        crowdfund.totalContributions += uint96(contributionAmount);

        _mint(crowdfund, msg.sender, contributionAmount); // Mint ERC20 tokens to the contributor

        if (getCrowdfundLifecycle(id) == CrowdfundLifecycle.Won) {
            _finalize(crowdfund);
        }
    }

    function _mint(Crowdfund storage crowdfund, address to, uint256 amount) internal {
        // Implement the minting logic here
        // Mint non-transferable tokens to the contributor
    }

    function _finalize(Crowdfund storage crowdfund) internal {
        require(!crowdfund.isFinalized, "Crowdfund already is finalized");

        // Integrate with Uniswap V3 to provide liquidity
        // Transfer the remaining token supply to the liquidity pool
        // Lock LP tokens in a fee locker contract

        crowdfund.isFinalized = true;
    }

    function withdraw(uint256 id) external {
        Crowdfund storage crowdfund = crowdfunds[id];
        require(getCrowdfundLifecycle(id) == CrowdfundLifecycle.Active, "Crowdfund is not active");

        // Implement the logic for contributors to withdraw their ETH contribution
        // and return the tokens they received
    }
}
