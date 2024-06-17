// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.25;

import "forge-std/src/Test.sol";

import "../src/PartyTokenLauncher.sol";
import "../src/PartyLPLocker.sol";

contract PartyTokenLauncherForkTest is Test {
    PartyTokenLauncher launch;
    PartyERC20 partyERC20Logic;
    PartyTokenAdminERC721 creatorNFT;
    PartyLPLocker lpLocker;
    IUNCX uncx;
    address payable partyDAO;
    INonfungiblePositionManager public positionManager;
    IUniswapV3Factory public uniswapFactory;
    address payable public weth;
    uint24 public poolFee;

    function setUp() public {
        positionManager = INonfungiblePositionManager(0x1238536071E1c677A632429e3655c799b22cDA52);
        uniswapFactory = IUniswapV3Factory(0x0227628f3F023bb0B980b67D528571c95c6DaC1c);
        weth = payable(positionManager.WETH9());
        poolFee = 3000;

        partyDAO = payable(vm.createWallet("Party DAO").addr);
        uncx = IUNCX(0x6a976ECb2377E7CbB5B48913b0faA1D7446D4dC7);
        lpLocker = new PartyLPLocker(positionManager, creatorNFT, uncx);
        creatorNFT = new PartyTokenAdminERC721("PartyTokenAdminERC721", "PT721", address(this));
        partyERC20Logic = new PartyERC20(creatorNFT);
        launch = new PartyTokenLauncher(
            partyDAO, creatorNFT, partyERC20Logic, positionManager, uniswapFactory, weth, poolFee, address(lpLocker)
        );
        creatorNFT.setIsMinter(address(launch), true);
    }

    function testIntegration_launchLifecycle() public {
        address creator = vm.createWallet("Creator").addr;
        address recipient = vm.createWallet("Recipient").addr;
        PartyTokenLauncher.LockerFeeRecipient[] memory lockerFeeRecipients =
            new PartyTokenLauncher.LockerFeeRecipient[](1);
        lockerFeeRecipients[0] = PartyTokenLauncher.LockerFeeRecipient({
            recipient: vm.createWallet("AdditionalLPFeeRecipient").addr,
            bps: 1e4
        });
        address contributor1 = vm.createWallet("Contributor1").addr;
        address contributor2 = vm.createWallet("Contributor2").addr;

        vm.deal(creator, 1 ether);
        vm.deal(contributor1, 1 ether);
        vm.deal(contributor2, 1 ether);

        // Step 1: Create a new launch
        PartyTokenLauncher.ERC20Args memory erc20Args = PartyTokenLauncher.ERC20Args({
            name: "TestToken",
            symbol: "TT",
            image: "test_image_url",
            description: "Test Description",
            totalSupply: 1_000_000_000e18
        });

        PartyTokenLauncher.LaunchArgs memory launchArgs = PartyTokenLauncher.LaunchArgs({
            numTokensForLP: 500_000_000e18,
            numTokensForDistribution: 300_000_000e18,
            numTokensForRecipient: 200_000_000e18,
            targetContribution: 10 ether,
            maxContributionPerAddress: 9 ether,
            merkleRoot: bytes32(0),
            recipient: recipient,
            finalizationFeeBps: 200, // 2%
            withdrawalFeeBps: 100, // 1%
            lockerFeeRecipients: lockerFeeRecipients
        });

        vm.prank(creator);
        uint32 launchId = launch.createLaunch{ value: 1 ether }(erc20Args, launchArgs);

        PartyERC20 token;
        uint96 totalContributions;
        {
            // To avoid stack too deep errors
            (, bytes memory res) = address(launch).staticcall(abi.encodeCall(launch.launches, (launchId)));
            (token,, totalContributions) = abi.decode(res, (PartyERC20, uint96, uint96));
        }

        uint96 expectedTotalContributions;
        uint96 expectedPartyDAOBalance;
        {
            uint96 expectedTokensReceived = launch.convertETHContributedToTokensReceived(launchId, 1 ether);
            expectedTotalContributions += 1 ether;
            assertEq(totalContributions, expectedTotalContributions);
            assertEq(partyDAO.balance, expectedPartyDAOBalance);
            assertEq(token.totalSupply(), erc20Args.totalSupply);
            assertEq(token.balanceOf(creator), expectedTokensReceived);
            assertEq(token.balanceOf(address(launch)), erc20Args.totalSupply - expectedTokensReceived);
        }

        // Step 2: Contribute to the launch
        vm.deal(contributor1, 5 ether);
        vm.prank(contributor1);
        launch.contribute{ value: 5 ether }(launchId, "Contribution", new bytes32[](0));

        expectedTotalContributions += 5 ether;
        {
            uint96 expectedTokensReceived = launch.convertETHContributedToTokensReceived(launchId, 5 ether);
            (, bytes memory res) = address(launch).staticcall(abi.encodeCall(launch.launches, (launchId)));
            (,, totalContributions) = abi.decode(res, (PartyERC20, uint96, uint96));
            assertEq(totalContributions, expectedTotalContributions);
            assertEq(token.balanceOf(contributor1), expectedTokensReceived);
            assertEq(partyDAO.balance, expectedPartyDAOBalance);
        }

        // Step 3: Withdraw from the launch
        {
            uint96 tokenBalance = uint96(token.balanceOf(contributor1));
            vm.startPrank(contributor1);
            token.approve(address(launch), tokenBalance);
            launch.withdraw(launchId);
            vm.stopPrank();

            uint96 expectedETHReceived = launch.convertTokensReceivedToETHContributed(launchId, tokenBalance);
            expectedTotalContributions -= expectedETHReceived;
            uint96 withdrawalFee = expectedETHReceived * launchArgs.withdrawalFeeBps / 1e4;
            expectedPartyDAOBalance += withdrawalFee;
            assertEq(token.balanceOf(contributor1), 0);
            assertEq(contributor1.balance, expectedETHReceived - withdrawalFee);
            assertEq(partyDAO.balance, expectedPartyDAOBalance);
        }

        // Step 4: Finalize the launch
        uint96 remainingContribution = launchArgs.targetContribution - expectedTotalContributions;
        vm.deal(contributor2, remainingContribution);
        vm.prank(contributor2);
        launch.contribute{ value: remainingContribution }(launchId, "Final Contribution", new bytes32[](0));

        expectedTotalContributions += remainingContribution;
        {
            PartyTokenLauncher.LaunchLifecycle lifecycle = launch.getLaunchLifecycle(launchId);
            assertTrue(lifecycle == PartyTokenLauncher.LaunchLifecycle.Finalized);
        }
        {
            uint96 finalizationFee = launchArgs.finalizationFeeBps * launchArgs.targetContribution / 1e4;
            uint96 tokenUncxFee = 80 * launchArgs.numTokensForLP / 1e4;
            uint96 wethUncxFee = 80 * launchArgs.targetContribution / 1e4;
            expectedPartyDAOBalance += finalizationFee;
            address pool = uniswapFactory.getPool(address(token), weth, poolFee);
            assertApproxEqRel(token.balanceOf(pool), launchArgs.numTokensForLP - tokenUncxFee, 0.001e18); // 0.01%
                // tolerance
            assertApproxEqRel(
                IERC20(weth).balanceOf(pool), launchArgs.targetContribution - finalizationFee - wethUncxFee, 0.001e18
            ); // 0.01% tolerance
        }
        {
            uint96 expectedTokensReceived =
                launch.convertETHContributedToTokensReceived(launchId, remainingContribution);
            {
                // To avoid stack too deep errors
                (, bytes memory res) = address(launch).staticcall(abi.encodeCall(launch.launches, (launchId)));
                (,, totalContributions) = abi.decode(res, (PartyERC20, uint96, uint96));
            }
            assertEq(totalContributions, expectedTotalContributions);
            assertEq(token.balanceOf(contributor2), expectedTokensReceived);
            assertEq(partyDAO.balance, expectedPartyDAOBalance);
            assertEq(token.balanceOf(recipient), launchArgs.numTokensForRecipient);
            assertApproxEqAbs(token.balanceOf(address(launch)), 0, 0.0000000000001e18);
        }
    }
}
