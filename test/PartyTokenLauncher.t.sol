// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.25;

import "forge-std/src/Test.sol";

import "../src/PartyTokenLauncher.sol";

contract PartyTokenLauncherTest is Test {
    PartyTokenLauncher launch;
    PartyTokenAdminERC721 creatorNFT;
    address payable partyDAO;

    uint96 contributionFee = 0.00055 ether;
    uint16 withdrawalFeeBps = 100; // 1%

    function setUp() public {
        partyDAO = payable(vm.createWallet("Party DAO").addr);
        creatorNFT = new PartyTokenAdminERC721("PartyTokenAdminERC721", "PT721", address(this));
        launch = new PartyTokenLauncher(partyDAO, creatorNFT, contributionFee, withdrawalFeeBps);
        creatorNFT.setIsMinter(address(launch), true);
    }

    function testIntegration_launchLifecycle() public {
        address creator = vm.createWallet("Creator").addr;
        address recipient = vm.createWallet("Recipient").addr;
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
            // TODO: Test with merkle root
            merkleRoot: bytes32(0),
            recipient: recipient
        });

        vm.prank(creator);
        uint32 launchId = launch.createLaunch{ value: 1 ether }(erc20Args, launchArgs);

        (IERC20 token,, uint96 totalContributions,,,,,) = launch.launches(launchId);
        uint96 expectedTotalContributions;
        uint96 expectedPartyDAOBalance = contributionFee;
        {
            uint96 expectedTokensReceived =
                launch.convertETHContributedToTokensReceived(launchId, 1 ether - contributionFee);
            expectedTotalContributions = 1 ether - contributionFee;
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

        expectedTotalContributions += 5 ether - contributionFee;
        expectedPartyDAOBalance += contributionFee;
        {
            uint96 expectedTokensReceived =
                launch.convertETHContributedToTokensReceived(launchId, 5 ether - contributionFee);
            (,, totalContributions,,,,,) = launch.launches(launchId);
            assertEq(totalContributions, expectedTotalContributions);
            assertEq(token.balanceOf(contributor1), expectedTokensReceived);
            assertEq(partyDAO.balance, expectedPartyDAOBalance);
        }

        // Step 3: Ragequit from the launch
        vm.startPrank(contributor1);
        token.approve(address(launch), token.balanceOf(contributor1));
        launch.ragequit(launchId);
        vm.stopPrank();

        expectedTotalContributions -= 5 ether - contributionFee;
        {
            uint96 withdrawalFee = (5 ether - contributionFee) * withdrawalFeeBps / 1e4;
            expectedPartyDAOBalance += withdrawalFee;
            assertEq(token.balanceOf(contributor1), 0);
            assertEq(contributor1.balance, 5 ether - contributionFee - withdrawalFee);
            assertEq(partyDAO.balance, expectedPartyDAOBalance);
        }

        // Step 4: Finalize the launch
        uint96 remainingContribution = launchArgs.targetContribution - expectedTotalContributions;
        vm.deal(contributor2, remainingContribution + contributionFee);
        vm.prank(contributor2);
        launch.contribute{ value: launchArgs.targetContribution - expectedTotalContributions + contributionFee }(
            launchId, "Final Contribution", new bytes32[](0)
        );

        expectedTotalContributions += remainingContribution;
        expectedPartyDAOBalance += contributionFee;
        {
            PartyTokenLauncher.LaunchLifecycle lifecycle = launch.getLaunchLifecycle(launchId);
            assertTrue(lifecycle == PartyTokenLauncher.LaunchLifecycle.Finalized);

            uint96 expectedTokensReceived =
                launch.convertETHContributedToTokensReceived(launchId, remainingContribution);
            (,, totalContributions,,,,,) = launch.launches(launchId);
            assertEq(totalContributions, expectedTotalContributions);
            assertEq(token.balanceOf(contributor2), expectedTokensReceived);
            assertEq(partyDAO.balance, expectedPartyDAOBalance);
            assertEq(token.balanceOf(recipient), launchArgs.numTokensForRecipient);
        }
    }

    function test_setContributionFee() public {
        assertEq(launch.contributionFee(), 0.00055 ether);

        uint96 newContributionFee = 0.001 ether;
        vm.prank(partyDAO);
        launch.setContributionFee(newContributionFee);

        // Check updated contribution fee
        assertEq(launch.contributionFee(), newContributionFee);
    }

    function test_setWithdrawalFeeBps() public {
        assertEq(launch.withdrawalFeeBps(), 100);

        uint16 newWithdrawalFeeBps = 50; // 0.5%
        vm.prank(partyDAO);
        launch.setWithdrawalFeeBps(newWithdrawalFeeBps);

        assertEq(launch.withdrawalFeeBps(), newWithdrawalFeeBps);
    }
}
