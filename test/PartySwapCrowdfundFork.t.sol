// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.25;

import "forge-std/src/Test.sol";

import "../src/PartySwapCrowdfund.sol";

contract PartySwapCrowdfundForkTest is Test {
    PartySwapCrowdfund crowdfund;
    PartySwapCreatorERC721 creatorNFT;
    address payable partyDAO;
    address positionLocker;
    INonfungiblePositionManager public positionManager;
    IUniswapV3Factory public uniswapFactory;
    address public weth;
    uint24 public poolFee;

    uint96 contributionFee = 0.00055 ether;
    uint16 withdrawalFeeBps = 100; // 1%

    function setUp() public {
        positionManager = INonfungiblePositionManager(0x1238536071E1c677A632429e3655c799b22cDA52);
        uniswapFactory = IUniswapV3Factory(0x0227628f3F023bb0B980b67D528571c95c6DaC1c);
        weth = positionManager.WETH9();
        poolFee = 3000;

        partyDAO = payable(vm.createWallet("Party DAO").addr);
        positionLocker = vm.createWallet("Position Locker").addr;
        creatorNFT = new PartySwapCreatorERC721("PartySwapCreatorERC721", "PSC721", address(this));
        // TODO: Update Uniswap addresses
        crowdfund = new PartySwapCrowdfund(
            partyDAO,
            creatorNFT,
            positionManager,
            uniswapFactory,
            weth,
            poolFee,
            positionLocker,
            contributionFee,
            withdrawalFeeBps
        );
        creatorNFT.setIsMinter(address(crowdfund), true);
    }

    // TODO: Check emitted events
    function testIntegration_crowdfundLifecycle() public {
        address creator = vm.createWallet("Creator").addr;
        address recipient = vm.createWallet("Recipient").addr;
        address contributor1 = vm.createWallet("Contributor1").addr;
        address contributor2 = vm.createWallet("Contributor2").addr;

        vm.deal(creator, 1 ether);
        vm.deal(contributor1, 1 ether);
        vm.deal(contributor2, 1 ether);

        // Step 1: Create a new crowdfund
        PartySwapCrowdfund.ERC20Args memory erc20Args = PartySwapCrowdfund.ERC20Args({
            name: "TestToken",
            symbol: "TT",
            image: "test_image_url",
            description: "Test Description",
            totalSupply: 1_000_000_000e18
        });

        PartySwapCrowdfund.CrowdfundArgs memory crowdfundArgs = PartySwapCrowdfund.CrowdfundArgs({
            numTokensForLP: 500_000_000e18,
            numTokensForDistribution: 300_000_000e18,
            numTokensForRecipient: 200_000_000e18,
            targetContribution: 10 ether,
            // TODO: Test with merkle root
            merkleRoot: bytes32(0),
            recipient: recipient
        });

        vm.prank(creator);
        uint32 crowdfundId = crowdfund.createCrowdfund{ value: 1 ether }(erc20Args, crowdfundArgs);

        (IERC20 token,, uint96 totalContributions,,,,,) = crowdfund.crowdfunds(crowdfundId);
        uint96 expectedTotalContributions;
        uint96 expectedPartyDAOBalance = contributionFee;
        {
            uint96 expectedTokensReceived =
                crowdfund.convertETHContributedToTokensReceived(crowdfundId, 1 ether - contributionFee);
            expectedTotalContributions = 1 ether - contributionFee;
            assertEq(totalContributions, expectedTotalContributions);
            assertEq(partyDAO.balance, expectedPartyDAOBalance);
            assertEq(token.totalSupply(), erc20Args.totalSupply);
            assertEq(token.balanceOf(creator), expectedTokensReceived);
            assertEq(token.balanceOf(address(crowdfund)), erc20Args.totalSupply - expectedTokensReceived);
        }

        // Step 2: Contribute to the crowdfund
        vm.deal(contributor1, 5 ether);
        vm.prank(contributor1);
        crowdfund.contribute{ value: 5 ether }(crowdfundId, "Contribution", new bytes32[](0));

        expectedTotalContributions += 5 ether - contributionFee;
        expectedPartyDAOBalance += contributionFee;
        {
            uint96 expectedTokensReceived =
                crowdfund.convertETHContributedToTokensReceived(crowdfundId, 5 ether - contributionFee);
            (,, totalContributions,,,,,) = crowdfund.crowdfunds(crowdfundId);
            assertEq(totalContributions, expectedTotalContributions);
            assertEq(token.balanceOf(contributor1), expectedTokensReceived);
            assertEq(partyDAO.balance, expectedPartyDAOBalance);
        }

        // Step 3: Ragequit from the crowdfund
        vm.startPrank(contributor1);
        token.approve(address(crowdfund), token.balanceOf(contributor1));
        crowdfund.ragequit(crowdfundId);
        vm.stopPrank();

        expectedTotalContributions -= 5 ether - contributionFee;
        {
            uint96 withdrawalFee = (5 ether - contributionFee) * withdrawalFeeBps / 1e4;
            expectedPartyDAOBalance += withdrawalFee;
            assertEq(token.balanceOf(contributor1), 0);
            // assertEq(contributor1.balance, 5 ether - contributionFee - withdrawalFee);
            assertEq(partyDAO.balance, expectedPartyDAOBalance);
        }

        // Step 4: Finalize the crowdfund
        uint96 remainingContribution = crowdfundArgs.targetContribution - expectedTotalContributions;
        vm.deal(contributor2, remainingContribution + contributionFee);
        vm.prank(contributor2);
        crowdfund.contribute{ value: crowdfundArgs.targetContribution - expectedTotalContributions + contributionFee }(
            crowdfundId, "Final Contribution", new bytes32[](0)
        );

        expectedTotalContributions += remainingContribution;
        expectedPartyDAOBalance += contributionFee;
        {
            PartySwapCrowdfund.CrowdfundLifecycle lifecycle = crowdfund.getCrowdfundLifecycle(crowdfundId);
            assertTrue(lifecycle == PartySwapCrowdfund.CrowdfundLifecycle.Finalized);
        }
        {
            address pool = uniswapFactory.getPool(address(token), weth, poolFee);
            assertApproxEqRel(token.balanceOf(pool), crowdfundArgs.numTokensForLP, 0.001e18); // 0.01% tolerance
            assertApproxEqRel(IERC20(weth).balanceOf(pool), crowdfundArgs.targetContribution, 0.001e18); // 0.01%
                // tolerance
        }
        {
            uint96 expectedTokensReceived =
                crowdfund.convertETHContributedToTokensReceived(crowdfundId, remainingContribution);
            (,, totalContributions,,,,,) = crowdfund.crowdfunds(crowdfundId);
            assertEq(totalContributions, expectedTotalContributions);
            assertEq(token.balanceOf(contributor2), expectedTokensReceived);
            assertEq(partyDAO.balance, expectedPartyDAOBalance);
            assertEq(token.balanceOf(recipient), crowdfundArgs.numTokensForRecipient);
            assertApproxEqAbs(token.balanceOf(address(crowdfund)), 0, 0.0000000000001e18);
        }
    }

    function test_setContributionFee() public {
        assertEq(crowdfund.contributionFee(), 0.00055 ether);

        uint96 newContributionFee = 0.001 ether;
        vm.prank(partyDAO);
        crowdfund.setContributionFee(newContributionFee);

        // Check updated contribution fee
        assertEq(crowdfund.contributionFee(), newContributionFee);
    }

    function test_setWithdrawalFeeBps() public {
        assertEq(crowdfund.withdrawalFeeBps(), 100);

        uint16 newWithdrawalFeeBps = 50; // 0.5%
        vm.prank(partyDAO);
        crowdfund.setWithdrawalFeeBps(newWithdrawalFeeBps);

        assertEq(crowdfund.withdrawalFeeBps(), newWithdrawalFeeBps);
    }
}
