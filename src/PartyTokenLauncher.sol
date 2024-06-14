// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.25;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { PartyERC20 } from "./PartyERC20.sol";
import { PartyTokenAdminERC721 } from "./PartyTokenAdminERC721.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { IUniswapV3Factory } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { INonfungiblePositionManager } from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";

// TODO: Add functions to move ETH from one token to another with one fn call?
// e.g. ragequitAndContribute(address tokenAddressToRageQuit, address tokenAddressToContributeTo)

// TODO: Rename contract?
contract PartyTokenLauncher is Ownable, IERC721Receiver {
    using MerkleProof for bytes32[];
    using SafeCast for uint256;

    event LaunchCreated(
        uint32 indexed launchId, address indexed creator, IERC20 indexed token, address tokenLiquidityPool
    );
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
    event Finalized(uint32 indexed launchId, uint256 liquidityPoolTokenId);
    event PositionLockerSet(address oldPositionLocker, address newPositionLocker);
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
        PartyERC20 token;
        uint96 targetContribution;
        uint96 totalContributions;
        uint96 numTokensForLP;
        uint96 numTokensForDistribution;
        uint96 numTokensForRecipient;
        bytes32 merkleRoot;
        address recipient;
    }

    PartyTokenAdminERC721 public immutable TOKEN_ADMIN_ERC721;
    INonfungiblePositionManager public immutable POSTION_MANAGER;
    IUniswapV3Factory public immutable UNISWAP_FACTORY;
    uint24 public immutable POOL_FEE;
    int24 public immutable MIN_TICK;
    int24 public immutable MAX_TICK;
    address public immutable WETH;

    // TODO: Pack storage
    uint32 public numOfLaunches;
    uint96 public contributionFee;
    uint16 public withdrawalFeeBps;
    address public positionLocker;

    /// @dev IDs start at 1.
    mapping(uint32 => Launch) public launches;

    constructor(
        address payable partyDAO,
        PartyTokenAdminERC721 tokenAdminERC721,
        INonfungiblePositionManager positionManager,
        IUniswapV3Factory uniswapFactory,
        address weth,
        uint24 poolFee,
        address positionLocker_,
        uint96 contributionFee_,
        uint16 withdrawalFeeBps_
    )
        Ownable(partyDAO)
    {
        TOKEN_ADMIN_ERC721 = tokenAdminERC721;
        POSTION_MANAGER = positionManager;
        UNISWAP_FACTORY = uniswapFactory;
        WETH = weth;
        POOL_FEE = poolFee;

        int24 tickSpacing = uniswapFactory.feeAmountTickSpacing(poolFee);
        MIN_TICK = (-887_272 / tickSpacing) * tickSpacing;
        MAX_TICK = (887_272 / tickSpacing) * tickSpacing;

        positionLocker = positionLocker_;
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

        // Initialize empty Uniswap pool. Will be liquid after launch is successful and finalized.
        (uint256 amount0, uint256 amount1) = WETH < address(token)
            ? (launch.targetContribution, launch.numTokensForLP)
            : (launch.numTokensForLP, launch.targetContribution);

        address pool = UNISWAP_FACTORY.createPool(address(token), WETH, POOL_FEE);
        IUniswapV3Pool(pool).initialize(_calculateSqrtPriceX96(amount0, amount1));

        emit LaunchCreated(id, msg.sender, token, pool);
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

        uint96 tokensReceived = _convertETHContributedToTokensReceived(
            contributionAmount, launch.targetContribution, launch.numTokensForDistribution
        );

        emit Contribute(id, contributor, comment, contributionAmount, tokensReceived, contributionFee_);

        // Check if the crowdfund has reached its target and finalize if necessary
        if (_getLaunchLifecycle(launch) == LaunchLifecycle.Finalized) {
            _finalize(id, launch);
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
        tokensReceived = _convertETHContributedToTokensReceived(
            ethContributed, launch.targetContribution, launch.numTokensForDistribution
        );
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
        ethContributed = _convertTokensReceivedToETHContributed(
            tokensReceived, launch.targetContribution, launch.numTokensForDistribution
        );
    }

    function _convertETHContributedToTokensReceived(
        uint96 ethContributed,
        uint96 targetContribution,
        uint96 numTokensForDistribution
    )
        private
        pure
        returns (uint96 tokensReceived)
    {
        // tokensReceived = ethContributed * numTokensForDistribution / targetContribution
        // Use Math.mulDiv to avoid overflow doing math with uint96s, then safe cast uint256 result to uint96.
        tokensReceived = Math.mulDiv(ethContributed, numTokensForDistribution, targetContribution).toUint96();
    }

    function _convertTokensReceivedToETHContributed(
        uint96 tokensReceived,
        uint96 targetContribution,
        uint96 numTokensForDistribution
    )
        private
        pure
        returns (uint96 ethContributed)
    {
        // tokensReceived = ethContributed * numTokensForDistribution / targetContribution
        // Use Math.mulDiv to avoid overflow doing math with uint96s, then safe cast uint256 result to uint96.
        ethContributed = Math.mulDiv(tokensReceived, targetContribution, numTokensForDistribution).toUint96();
    }

    // TODO: Fee Collector needs to be aware of LP NFT owner
    // TODO: The LP Fee NFT updates an attribute to indicate its been successfully upon finalization
    function _finalize(uint32 launchId, Launch memory launch) private {
        (address token0, address token1) =
            WETH < address(launch.token) ? (WETH, address(launch.token)) : (address(launch.token), WETH);
        (uint256 amount0, uint256 amount1) = WETH < address(launch.token)
            ? (launch.targetContribution, launch.numTokensForLP)
            : (launch.numTokensForLP, launch.targetContribution);

        // Add liquidity to the pool
        launch.token.approve(address(POSTION_MANAGER), launch.numTokensForLP);
        (uint256 tokenId,,,) = POSTION_MANAGER.mint{ value: launch.targetContribution }(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: POOL_FEE,
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );

        // Transfer LP to fee collector contract
        POSTION_MANAGER.safeTransferFrom(
            address(this),
            positionLocker,
            tokenId,
            "" // TODO: Pass data to fee collector contract
        );

        // Transfer tokens to recipient
        if (launch.numTokensForRecipient > 0) {
            launch.token.transfer(launch.recipient, launch.numTokensForRecipient);
        }

        // Unpause token
        launch.token.setPaused(false);

        // Renounce ownership
        launch.token.renounceOwnership();

        emit Finalized(launchId, tokenId);
    }

    function _calculateSqrtPriceX96(uint256 amount0, uint256 amount1) private pure returns (uint160) {
        uint256 numerator = amount1 * 1e18;
        uint256 denominator = amount0;
        return uint160(Math.sqrt(numerator / denominator) * (2 ** 96) / 1e9);
    }

    function ragequit(uint32 launchId) external {
        Launch memory launch = launches[launchId];
        require(_getLaunchLifecycle(launch) == LaunchLifecycle.Active, "Launch is not active");

        uint96 tokensReceived = uint96(launch.token.balanceOf(msg.sender));
        uint96 ethContributed = _convertTokensReceivedToETHContributed(
            tokensReceived, launch.targetContribution, launch.numTokensForDistribution
        );
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

    function setPositionLocker(address positionLocker_) external onlyOwner {
        emit PositionLockerSet(positionLocker, positionLocker_);
        positionLocker = positionLocker_;
    }

    function setContributionFee(uint96 contributionFee_) external onlyOwner {
        emit ContributionFeeSet(contributionFee, contributionFee_);
        contributionFee = contributionFee_;
    }

    function setWithdrawalFeeBps(uint16 withdrawalFeeBps_) external onlyOwner {
        emit WithdrawalFeeBpsSet(withdrawalFeeBps, withdrawalFeeBps_);
        withdrawalFeeBps = withdrawalFeeBps_;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    /**
     * @dev Returns the version of the contract. Decimal versions indicate change in logic. Number change indicates
     *      change in ABI.
     */
    function VERSION() external pure returns (string memory) {
        return "0.3.0";
    }
}
