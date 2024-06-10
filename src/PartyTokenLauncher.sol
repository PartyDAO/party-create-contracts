// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.25;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { PartyERC20 } from "./PartyERC20.sol";
import { PartyTokenAdminERC721 } from "./PartyTokenAdminERC721.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// TODO: Add functions to move ETH from one token to another with one fn call?
// e.g. ragequitAndContribute(address tokenAddressToRageQuit, address tokenAddressToContributeTo)

// TODO: Rename contract?
contract PartyTokenLauncher is Ownable {
    using MerkleProof for bytes32[];
    using SafeCast for uint256;

    event LaunchCreated(uint32 indexed launchId, address indexed creator, IERC20 indexed token);
    event Contribute(
        uint32 indexed launchId,
        address indexed contributor,
        string comment,
        uint96 ethContributed,
        uint96 tokensReceived,
        uint96 contributionFee
    );
    event Ragequit(
        uint32 indexed launchId,
        address indexed contributor,
        uint96 tokensReceived,
        uint96 ethContributed,
        uint96 withdrawalFee
    );
    event Finalized(uint32 indexed launchId, address tokenLiquidityPool);
    event ContributionFeeSet(uint96 oldContributionFee, uint96 newContributionFee);
    event WithdrawalFeeBpsSet(uint16 oldWithdrawalFeeBps, uint16 newWithdrawalFeeBps);

    error LaunchInvalid();

    enum LaunchLifecycle {
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

    struct LaunchArgs {
        uint96 numTokensForLP;
        uint96 numTokensForDistribution;
        uint96 numTokensForRecipient;
        uint96 targetContribution;
        bytes32 merkleRoot;
        address recipient;
    }

    struct Launch {
        IERC20 token;
        uint96 targetContribution;
        uint96 totalContributions;
        uint96 numTokensForLP;
        uint96 numTokensForDistribution;
        uint96 numTokensForRecipient;
        bytes32 merkleRoot;
        address recipient;
    }

    PartyTokenAdminERC721 public immutable TOKEN_ADMIN_ERC721;

    uint32 public numOfLaunches;
    uint96 public contributionFee;
    uint16 public withdrawalFeeBps;

    /// @dev IDs start at 1.
    mapping(uint32 => Launch) public launches;

    constructor(
        address payable partyDAO,
        PartyTokenAdminERC721 tokenAdminERC721,
        uint96 contributionFee_,
        uint16 withdrawalFeeBps_
    )
        Ownable(partyDAO)
    {
        TOKEN_ADMIN_ERC721 = tokenAdminERC721;
        contributionFee = contributionFee_;
        withdrawalFeeBps = withdrawalFeeBps_;
    }

    function createLaunch(
        ERC20Args memory erc20Args,
        LaunchArgs memory launchArgs
    )
        external
        payable
        returns (uint32 id)
    {
        require(launchArgs.targetContribution > 0, "Target contribution must be greater than zero");
        require(
            erc20Args.totalSupply
                >= launchArgs.numTokensForLP + launchArgs.numTokensForDistribution + launchArgs.numTokensForRecipient,
            "Total supply must be at least the sum of tokens"
        );

        id = ++numOfLaunches;

        uint256 tokenAdminId = TOKEN_ADMIN_ERC721.mint(erc20Args.name, erc20Args.image, msg.sender);

        // Deploy new ERC20 token. Mints the total supply upfront to this contract.
        PartyERC20 token = new PartyERC20{ salt: keccak256(abi.encodePacked(id, block.chainid)) }(
            erc20Args.name,
            erc20Args.symbol,
            erc20Args.image,
            erc20Args.description,
            erc20Args.totalSupply,
            address(this),
            address(this),
            TOKEN_ADMIN_ERC721,
            tokenAdminId
        );
        token.setPaused(true);

        // Initialize new launch.
        Launch memory launch = launches[id] = Launch({
            token: token,
            targetContribution: launchArgs.targetContribution,
            totalContributions: 0,
            numTokensForLP: launchArgs.numTokensForLP,
            numTokensForDistribution: launchArgs.numTokensForDistribution,
            numTokensForRecipient: launchArgs.numTokensForRecipient,
            merkleRoot: launchArgs.merkleRoot,
            recipient: launchArgs.recipient
        });

        // Contribute initial amount, if any, and attribute the contribution to the creator
        uint96 initialContribution = msg.value.toUint96();
        if (initialContribution > 0) {
            (launch,) = _contribute(id, launch, msg.sender, initialContribution, "");
        }

        emit LaunchCreated(id, msg.sender, token);
    }

    function getLaunchLifecycle(uint32 launchId) public view returns (LaunchLifecycle) {
        return _getLaunchLifecycle(launches[launchId]);
    }

    function _getLaunchLifecycle(Launch memory launch) private pure returns (LaunchLifecycle) {
        if (launch.targetContribution == 0) {
            revert LaunchInvalid();
        } else if (launch.totalContributions >= launch.targetContribution) {
            return LaunchLifecycle.Finalized;
        } else {
            return LaunchLifecycle.Active;
        }
    }

    function contribute(
        uint32 launchId,
        string calldata comment,
        bytes32[] calldata merkleProof
    )
        public
        payable
        returns (uint96 tokensReceived)
    {
        Launch memory launch = launches[launchId];

        // Verify merkle proof if merkle root is set
        if (launch.merkleRoot != bytes32(0)) {
            bytes32 leaf = keccak256(abi.encodePacked(msg.sender));
            require(MerkleProof.verifyCalldata(merkleProof, launch.merkleRoot, leaf), "Invalid merkle proof");
        }

        (launch, tokensReceived) = _contribute(launchId, launch, msg.sender, msg.value.toUint96(), comment);
    }

    function _contribute(
        uint32 id,
        Launch memory launch,
        address contributor,
        uint96 amount,
        string memory comment
    )
        private
        returns (Launch memory, uint96)
    {
        require(_getLaunchLifecycle(launch) == LaunchLifecycle.Active, "Launch is not active");
        require(amount > 0, "Contribution must be greater than zero");

        uint96 contributionFee_ = contributionFee;
        uint96 contributionAmount = amount - contributionFee_;

        uint96 newTotalContributions = launch.totalContributions + contributionAmount;
        require(newTotalContributions <= launch.targetContribution, "Contribution exceeds amount to reach target");

        // Update state
        launches[id].totalContributions = launch.totalContributions = newTotalContributions;

        uint96 tokensReceived =
            _convertETHContributedToTokensReceived(contributionAmount, launch.targetContribution, launch.numTokensForLP);

        emit Contribute(id, contributor, comment, contributionAmount, tokensReceived, contributionFee_);

        // Check if the launch has reached its target and finalize if necessary
        if (_getLaunchLifecycle(launch) == LaunchLifecycle.Finalized) {
            _finalize(launch);
        }

        // Transfer the tokens to the contributor
        launch.token.transfer(contributor, tokensReceived);

        // Transfer the ETH contribution fee to PartyDAO
        payable(owner()).call{ value: contributionFee_, gas: 1e5 }("");

        return (launch, tokensReceived);
    }

    function convertETHContributedToTokensReceived(
        uint32 launchId,
        uint96 ethContributed
    )
        external
        view
        returns (uint96 tokensReceived)
    {
        Launch memory launch = launches[launchId];
        tokensReceived =
            _convertETHContributedToTokensReceived(ethContributed, launch.targetContribution, launch.numTokensForLP);
    }

    function convertTokensReceivedToETHContributed(
        uint32 launchId,
        uint96 tokensReceived
    )
        external
        view
        returns (uint96 ethContributed)
    {
        Launch memory launch = launches[launchId];
        ethContributed =
            _convertTokensReceivedToETHContributed(tokensReceived, launch.targetContribution, launch.numTokensForLP);
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

    // TODO: When the launch is finalized, the contract integrates with Uniswap V3 to provide liquidity. The
    // remaining token supply is transferred to the liquidity pool.
    // TODO: The LP tokens are locked in a fee locker contract
    // TODO: Fee Collector needs to be aware of LP NFT owner
    // TODO: The LP Fee NFT updates an attribute to indicate its been successfully upon finalization
    // TODO: When the LP position is created, the tokens become transferable.
    // TODO: Unpause token and abdicate ownership
    function _finalize(Launch memory launch) private {
        // Transfer tokens to recipient
        launch.token.transfer(launch.recipient, launch.numTokensForRecipient);
    }

    function ragequit(uint32 launchId) external {
        Launch memory launch = launches[launchId];
        require(_getLaunchLifecycle(launch) == LaunchLifecycle.Active, "Launch is not active");

        uint96 tokensReceived = uint96(launch.token.balanceOf(msg.sender));
        uint96 ethContributed =
            _convertTokensReceivedToETHContributed(tokensReceived, launch.targetContribution, launch.numTokensForLP);
        uint96 withdrawalFee = (ethContributed * withdrawalFeeBps) / 1e4;

        // Pull tokens from sender
        launch.token.transferFrom(msg.sender, address(this), tokensReceived);

        // Update launch state
        launches[launchId].totalContributions -= ethContributed;

        // Transfer withdrawal fee to PartyDAO
        payable(owner()).call{ value: withdrawalFee, gas: 1e5 }("");

        // Transfer ETH to sender
        payable(msg.sender).call{ value: ethContributed - withdrawalFee, gas: 1e5 }("");

        emit Ragequit(launchId, msg.sender, tokensReceived, ethContributed - withdrawalFee, withdrawalFee);
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
        return "0.3.0";
    }
}
