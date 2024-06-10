// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.25;

import "forge-std/src/Test.sol";
import { WETH9 } from "./mock/WETH.t.sol";
import { MockUniswapV3Factory } from "./mock/MockUniswapV3Factory.t.sol";
import { MockUniswapNonfungiblePositionManager } from "./mock/MockUniswapNonfungiblePositionManager.t.sol";

import "../src/PartySwapCrowdfund.sol";

// TODO: Check emitted events

contract PartySwapCrowdfundTest is Test {
    PartySwapCrowdfund crowdfund;
    PartySwapCreatorERC721 creatorNFT;
    address payable partyDAO;
    address positionLocker;
    INonfungiblePositionManager public positionManager;
    IUniswapV3Factory public uniswapFactory;
    address payable public weth;
    uint24 public poolFee;

    uint96 contributionFee = 0.00055 ether;
    uint16 withdrawalFeeBps = 100; // 1%

    function setUp() public {
        weth = payable(address(new WETH9()));
        uniswapFactory = IUniswapV3Factory(address(new MockUniswapV3Factory()));
        positionManager = INonfungiblePositionManager(
            address(new MockUniswapNonfungiblePositionManager(address(weth), address(uniswapFactory)))
        );
        poolFee = 3000;

        partyDAO = payable(vm.createWallet("Party DAO").addr);
        positionLocker = vm.createWallet("Position Locker").addr;
        creatorNFT = new PartySwapCreatorERC721("PartySwapCreatorERC721", "PSC721", address(this));
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

    function test_constructor_works() public {
        assertEq(address(crowdfund.owner()), partyDAO, "Party DAO address should be correctly set");
        assertEq(address(crowdfund.CREATOR_NFT()), address(creatorNFT), "Creator NFT address should be correctly set");
        assertEq(
            address(crowdfund.POSTION_MANAGER()),
            address(positionManager),
            "Position Manager address should be correctly set"
        );
        assertEq(
            address(crowdfund.UNISWAP_FACTORY()),
            address(uniswapFactory),
            "Uniswap Factory address should be correctly set"
        );
        assertEq(address(crowdfund.WETH()), weth, "WETH address should be correctly set");
        assertEq(crowdfund.POOL_FEE(), poolFee, "Pool fee should be correctly set");
        assertEq(address(crowdfund.positionLocker()), positionLocker, "Position Locker address should be correctly set");
        assertEq(crowdfund.contributionFee(), contributionFee, "Contribution fee should be correctly set");
        assertEq(crowdfund.withdrawalFeeBps(), withdrawalFeeBps, "Withdrawal fee basis points should be correctly set");
    }

    function test_createCrowdfund_works() public returns (uint32 crowdfundId) {
        address creator = vm.createWallet("Creator").addr;
        vm.deal(creator, 1 ether);

        PartySwapCrowdfund.ERC20Args memory erc20Args = PartySwapCrowdfund.ERC20Args({
            name: "NewToken",
            symbol: "NT",
            image: "image_url",
            description: "New Token Description",
            totalSupply: 1_000_000 ether
        });

        PartySwapCrowdfund.CrowdfundArgs memory crowdfundArgs = PartySwapCrowdfund.CrowdfundArgs({
            numTokensForLP: 500_000 ether,
            numTokensForDistribution: 300_000 ether,
            numTokensForRecipient: 200_000 ether,
            targetContribution: 10 ether,
            merkleRoot: bytes32(0),
            recipient: address(0x123)
        });

        vm.prank(creator);
        crowdfundId = crowdfund.createCrowdfund{ value: 1 ether }(erc20Args, crowdfundArgs);

        assertTrue(crowdfund.getCrowdfundLifecycle(crowdfundId) == PartySwapCrowdfund.CrowdfundLifecycle.Active);
        (IERC20 token,, uint96 totalContributions,,,,,) = crowdfund.crowdfunds(crowdfundId);
        uint96 expectedTokensReceived =
            crowdfund.convertETHContributedToTokensReceived(crowdfundId, 1 ether - contributionFee);
        assertEq(token.balanceOf(creator), expectedTokensReceived);
        assertEq(token.totalSupply(), erc20Args.totalSupply);
        assertEq(totalContributions, 1 ether - contributionFee);
        assertEq(creator.balance, 0);
        assertEq(address(crowdfund).balance, 1 ether - contributionFee);
    }

    function test_contribute_works() public {
        uint32 crowdfundId = test_createCrowdfund_works();
        address contributor = vm.createWallet("Contributor").addr;
        vm.deal(contributor, 5 ether);

        vm.prank(contributor);
        crowdfund.contribute{ value: 5 ether }(crowdfundId, "Adding funds", new bytes32[](0));

        (IERC20 token,, uint96 totalContributions,,,,,) = crowdfund.crowdfunds(crowdfundId);
        uint96 expectedTokensReceived =
            crowdfund.convertETHContributedToTokensReceived(crowdfundId, 5 ether - contributionFee);
        assertEq(token.balanceOf(contributor), expectedTokensReceived);
        assertEq(totalContributions, 6 ether - (contributionFee * 2));
        assertEq(contributor.balance, 0);
        assertEq(address(crowdfund).balance, 6 ether - (contributionFee * 2));
    }

    function test_ragequit_works() public {
        uint32 crowdfundId = test_createCrowdfund_works();
        address creator = vm.createWallet("Creator").addr;

        (IERC20 token,,,,,,,) = crowdfund.crowdfunds(crowdfundId);
        uint96 tokenBalance = uint96(token.balanceOf(creator));

        vm.prank(creator);
        crowdfund.ragequit(crowdfundId);

        uint96 expectedETHReturned = crowdfund.convertTokensReceivedToETHContributed(crowdfundId, tokenBalance);
        uint96 withdrawalFee = (expectedETHReturned * withdrawalFeeBps) / 10_000;
        assertEq(creator.balance, expectedETHReturned - withdrawalFee);
        assertEq(token.balanceOf(creator), 0);
        assertEq(partyDAO.balance, contributionFee + withdrawalFee);
        (,, uint96 totalContributions,,,,,) = crowdfund.crowdfunds(crowdfundId);
        assertEq(totalContributions, 0);
    }

    function test_finalize_works() public {
        uint32 crowdfundId = test_createCrowdfund_works();
        address contributor = vm.createWallet("Final Contributor").addr;
        (IERC20 token, uint96 targetContribution, uint96 totalContributions,,,,,) = crowdfund.crowdfunds(crowdfundId);
        uint96 remainingContribution = targetContribution - totalContributions + contributionFee;
        vm.deal(contributor, remainingContribution);

        vm.prank(contributor);
        crowdfund.contribute{ value: remainingContribution }(crowdfundId, "Finalize", new bytes32[](0));

        assertTrue(crowdfund.getCrowdfundLifecycle(crowdfundId) == PartySwapCrowdfund.CrowdfundLifecycle.Finalized);
        (,, totalContributions,,,,,) = crowdfund.crowdfunds(crowdfundId);
        uint96 expectedTokensReceived =
            crowdfund.convertETHContributedToTokensReceived(crowdfundId, remainingContribution - contributionFee);
        assertEq(token.balanceOf(contributor), expectedTokensReceived);
        assertEq(totalContributions, targetContribution);
        assertEq(contributor.balance, 0);
        assertEq(token.balanceOf(address(crowdfund)), 0);
        assertEq(address(crowdfund).balance, 0);
    }

    function test_setPositionLocker_works() public {
        address newPositionLocker = vm.createWallet("New Position Locker").addr;
        vm.prank(partyDAO);
        crowdfund.setPositionLocker(newPositionLocker);

        assertEq(crowdfund.positionLocker(), newPositionLocker);
    }

    function test_setContributionFee_works() public {
        assertEq(crowdfund.contributionFee(), 0.00055 ether);

        uint96 newContributionFee = 0.001 ether;
        vm.prank(partyDAO);
        crowdfund.setContributionFee(newContributionFee);

        // Check updated contribution fee
        assertEq(crowdfund.contributionFee(), newContributionFee);
    }

    function test_setWithdrawalFeeBps_works() public {
        assertEq(crowdfund.withdrawalFeeBps(), 100);

        uint16 newWithdrawalFeeBps = 50; // 0.5%
        vm.prank(partyDAO);
        crowdfund.setWithdrawalFeeBps(newWithdrawalFeeBps);

        assertEq(crowdfund.withdrawalFeeBps(), newWithdrawalFeeBps);
    }
}
