// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.25;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
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

contract PartyTokenLauncher is Ownable, IERC721Receiver {
    using MerkleProof for bytes32[];
    using SafeCast for uint256;
    using Clones for address;

    event LaunchCreated(
        uint32 indexed launchId,
        address indexed creator,
        IERC20 indexed token,
        address tokenLiquidityPool,
        ERC20Args erc20Args,
        LaunchArgs launchArgs
    );
    event Contribute(
        uint32 indexed launchId,
        address indexed contributor,
        string comment,
        uint96 ethContributed,
        uint96 tokensReceived
    );
    event Withdraw(
        uint32 indexed launchId,
        address indexed contributor,
        uint96 tokensReceived,
        uint96 ethContributed,
        uint96 withdrawalFee
    );
    event Finalized(
        uint32 indexed launchId, IERC20 indexed token, uint256 liquidityPoolTokenId, uint96 ethAmountForPool
    );
    event PositionLockerSet(address oldPositionLocker, address newPositionLocker);
    event RecipientTransfer(uint32 indexed launchId, IERC20 indexed token, address indexed recipient, uint96 numTokens);

    error LaunchInvalid();
    error TargetContributionZero();
    error TotalSupplyMismatch();
    error TotalSupplyExceedsLimit();
    error InvalidMerkleProof();
    error InvalidBps();
    error ContributionZero();
    error ContributionsExceedsMaxPerAddress(
        uint96 newContribution, uint96 existingContributionsByAddress, uint96 maxContributionPerAddress
    );
    error ContributionExceedsTarget(uint96 amountOverTarget, uint96 targetContribution);
    error InvalidLifecycleState(LaunchLifecycle actual, LaunchLifecycle expected);

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
        uint96 maxContributionPerAddress;
        bytes32 merkleRoot;
        address recipient;
        uint16 finalizationFeeBps;
        uint16 partyDAOPoolFeeBps;
        uint16 withdrawalFeeBps;
    }

    struct Launch {
        PartyERC20 token;
        uint96 targetContribution;
        uint96 totalContributions;
        uint96 maxContributionPerAddress;
        uint96 numTokensForLP;
        uint96 numTokensForDistribution;
        uint96 numTokensForRecipient;
        bytes32 merkleRoot;
        address recipient;
        uint16 finalizationFeeBps;
        uint16 withdrawalFeeBps;
        uint16 partyDAOPoolFeeBps;
    }

    PartyTokenAdminERC721 public immutable TOKEN_ADMIN_ERC721;
    PartyERC20 public immutable PARTY_ERC20_LOGIC;
    INonfungiblePositionManager public immutable POSTION_MANAGER;
    IUniswapV3Factory public immutable UNISWAP_FACTORY;
    uint24 public immutable POOL_FEE;
    int24 public immutable MIN_TICK;
    int24 public immutable MAX_TICK;
    address public immutable WETH;

    uint32 public numOfLaunches;
    address public positionLocker;

    /// @dev IDs start at 1.
    mapping(uint32 => Launch) public launches;

    constructor(
        address payable partyDAO,
        PartyTokenAdminERC721 tokenAdminERC721,
        PartyERC20 partyERC20Logic,
        INonfungiblePositionManager positionManager,
        IUniswapV3Factory uniswapFactory,
        address weth,
        uint24 poolFee,
        address positionLocker_
    )
        Ownable(partyDAO)
    {
        TOKEN_ADMIN_ERC721 = tokenAdminERC721;
        PARTY_ERC20_LOGIC = partyERC20Logic;
        POSTION_MANAGER = positionManager;
        UNISWAP_FACTORY = uniswapFactory;
        WETH = weth;
        POOL_FEE = poolFee;

        int24 tickSpacing = uniswapFactory.feeAmountTickSpacing(poolFee);
        MIN_TICK = (-887_272 / tickSpacing) * tickSpacing;
        MAX_TICK = (887_272 / tickSpacing) * tickSpacing;

        positionLocker = positionLocker_;
    }

    function createLaunch(
        ERC20Args memory erc20Args,
        LaunchArgs memory launchArgs
    )
        external
        payable
        returns (uint32 id)
    {
        if (launchArgs.targetContribution == 0) revert TargetContributionZero();
        if (
            erc20Args.totalSupply
                != launchArgs.numTokensForLP + launchArgs.numTokensForDistribution + launchArgs.numTokensForRecipient
        ) {
            revert TotalSupplyMismatch();
        }
        if (erc20Args.totalSupply > type(uint96).max) revert TotalSupplyExceedsLimit();
        if (
            launchArgs.finalizationFeeBps > 1e4 || launchArgs.partyDAOPoolFeeBps > 1e4
                || launchArgs.withdrawalFeeBps > 1e4
        ) {
            revert InvalidBps();
        }

        id = ++numOfLaunches;

        uint256 tokenAdminId = TOKEN_ADMIN_ERC721.mint(erc20Args.name, erc20Args.image, msg.sender);

        // Deploy new ERC20 token. Mints the total supply upfront to this contract.
        PartyERC20 token = PartyERC20(
            address(PARTY_ERC20_LOGIC).cloneDeterministic(
                keccak256(abi.encodePacked(id, block.chainid, block.timestamp))
            )
        );
        token.initialize(
            erc20Args.name,
            erc20Args.symbol,
            erc20Args.description,
            erc20Args.totalSupply,
            address(this),
            address(this),
            tokenAdminId
        );
        token.setPaused(true);

        // Initialize new launch.
        Launch memory launch = launches[id] = Launch({
            token: token,
            targetContribution: launchArgs.targetContribution,
            totalContributions: 0,
            maxContributionPerAddress: launchArgs.maxContributionPerAddress,
            numTokensForLP: launchArgs.numTokensForLP,
            numTokensForDistribution: launchArgs.numTokensForDistribution,
            numTokensForRecipient: launchArgs.numTokensForRecipient,
            merkleRoot: launchArgs.merkleRoot,
            recipient: launchArgs.recipient,
            finalizationFeeBps: launchArgs.finalizationFeeBps,
            partyDAOPoolFeeBps: launchArgs.partyDAOPoolFeeBps,
            withdrawalFeeBps: launchArgs.withdrawalFeeBps
        });

        // Contribute initial amount, if any, and attribute the contribution to the creator
        uint96 initialContribution = msg.value.toUint96();
        if (initialContribution > 0) {
            (launch,) = _contribute(id, launch, msg.sender, initialContribution, "");
        }

        // Initialize empty Uniswap pool. Will be liquid after launch is successful and finalized.
        address pool = _initializeUniswapPool(launch);

        emit LaunchCreated(id, msg.sender, token, pool, erc20Args, launchArgs);
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
            if (!MerkleProof.verifyCalldata(merkleProof, launch.merkleRoot, leaf)) revert InvalidMerkleProof();
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
        LaunchLifecycle launchLifecycle = _getLaunchLifecycle(launch);
        if (launchLifecycle != LaunchLifecycle.Active) {
            revert InvalidLifecycleState(launchLifecycle, LaunchLifecycle.Active);
        }
        if (amount == 0) revert ContributionZero();
        uint96 ethContributed = _convertTokensReceivedToETHContributed(
            uint96(launch.token.balanceOf(msg.sender)), launch.targetContribution, launch.numTokensForDistribution
        );
        if (ethContributed + amount > launch.maxContributionPerAddress) {
            revert ContributionsExceedsMaxPerAddress(amount, ethContributed, launch.maxContributionPerAddress);
        }

        uint96 newTotalContributions = launch.totalContributions + amount;
        if (newTotalContributions > launch.targetContribution) {
            revert ContributionExceedsTarget(
                newTotalContributions - launch.targetContribution, launch.targetContribution
            );
        }

        // Update state
        launches[id].totalContributions = launch.totalContributions = newTotalContributions;

        uint96 tokensReceived =
            _convertETHContributedToTokensReceived(amount, launch.targetContribution, launch.numTokensForDistribution);

        emit Contribute(id, contributor, comment, amount, tokensReceived);

        // Check if the crowdfund has reached its target and finalize if necessary
        if (_getLaunchLifecycle(launch) == LaunchLifecycle.Finalized) {
            _finalize(id, launch);
        }

        // Transfer the tokens to the contributor
        launch.token.transfer(contributor, tokensReceived);

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
        uint96 finalizationFee = (launch.targetContribution * launch.finalizationFeeBps) / 1e4;
        uint96 amountForPool = launch.targetContribution - finalizationFee;

        (address token0, address token1) =
            WETH < address(launch.token) ? (WETH, address(launch.token)) : (address(launch.token), WETH);
        (uint256 amount0, uint256 amount1) = WETH < address(launch.token)
            ? (amountForPool, launch.numTokensForLP)
            : (launch.numTokensForLP, amountForPool);

        // Add liquidity to the pool
        launch.token.approve(address(POSTION_MANAGER), launch.numTokensForLP);
        (uint256 tokenId,,,) = POSTION_MANAGER.mint{ value: amountForPool }(
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

        // Transfer finalization fee to PartyDAO
        payable(owner()).call{ value: finalizationFee, gas: 1e5 }("");

        // Transfer tokens to recipient
        if (launch.numTokensForRecipient > 0) {
            launch.token.transfer(launch.recipient, launch.numTokensForRecipient);

            emit RecipientTransfer(launchId, launch.token, launch.recipient, launch.numTokensForRecipient);
        }

        // Indicate launch succeeded
        TOKEN_ADMIN_ERC721.setLaunchSucceeded(tokenId);

        // Unpause token
        launch.token.setPaused(false);

        // Renounce ownership
        launch.token.renounceOwnership();

        emit Finalized(launchId, launch.token, tokenId, amountForPool);
    }

    function _initializeUniswapPool(Launch memory launch) private returns (address pool) {
        uint96 finalizationFee = launch.finalizationFeeBps * launch.targetContribution / 1e4;
        uint96 amountForPool = launch.targetContribution - finalizationFee;
        (uint256 amount0, uint256 amount1) = WETH < address(launch.token)
            ? (amountForPool, launch.numTokensForLP)
            : (launch.numTokensForLP, amountForPool);

        pool = UNISWAP_FACTORY.createPool(address(launch.token), WETH, POOL_FEE);
        IUniswapV3Pool(pool).initialize(_calculateSqrtPriceX96(amount0, amount1));
    }

    function _calculateSqrtPriceX96(uint256 amount0, uint256 amount1) private pure returns (uint160) {
        uint256 numerator = amount1 * 1e18;
        uint256 denominator = amount0;
        return uint160(Math.sqrt(numerator / denominator) * (2 ** 96) / 1e9);
    }

    function withdraw(uint32 launchId) external returns (uint96 ethReceived) {
        Launch memory launch = launches[launchId];
        LaunchLifecycle launchLifecycle = _getLaunchLifecycle(launch);
        if (launchLifecycle != LaunchLifecycle.Active) {
            revert InvalidLifecycleState(launchLifecycle, LaunchLifecycle.Active);
        }

        uint96 tokensReceived = uint96(launch.token.balanceOf(msg.sender));
        uint96 ethContributed = _convertTokensReceivedToETHContributed(
            tokensReceived, launch.targetContribution, launch.numTokensForDistribution
        );
        uint96 withdrawalFee = (ethContributed * launch.withdrawalFeeBps) / 1e4;
        ethReceived = ethContributed - withdrawalFee;

        // Pull tokens from sender
        launch.token.transferFrom(msg.sender, address(this), tokensReceived);

        // Update launch state
        launches[launchId].totalContributions -= ethContributed;

        // Transfer withdrawal fee to PartyDAO
        payable(owner()).call{ value: withdrawalFee, gas: 1e5 }("");

        // Transfer ETH to sender
        payable(msg.sender).call{ value: ethReceived, gas: 1e5 }("");

        emit Withdraw(launchId, msg.sender, tokensReceived, ethContributed, withdrawalFee);
    }

    function setPositionLocker(address positionLocker_) external onlyOwner {
        emit PositionLockerSet(positionLocker, positionLocker_);
        positionLocker = positionLocker_;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    /**
     * @dev Returns the version of the contract. Decimal versions indicate change in logic. Number change indicates
     *      change in ABI.
     */
    function VERSION() external pure returns (string memory) {
        return "0.5.0";
    }
}
