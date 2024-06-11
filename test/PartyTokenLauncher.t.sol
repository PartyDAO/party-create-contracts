// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.25;

import "forge-std/src/Test.sol";
import { WETH9 } from "./mock/WETH.t.sol";
import { MockUniswapV3Factory } from "./mock/MockUniswapV3Factory.t.sol";
import { MockUniswapNonfungiblePositionManager } from "./mock/MockUniswapNonfungiblePositionManager.t.sol";

import "../src/PartyTokenLauncher.sol";

contract PartyTokenLauncherTest is Test {
    PartyTokenLauncher launch;
    PartyTokenAdminERC721 creatorNFT;
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
        creatorNFT = new PartyTokenAdminERC721("PartyTokenAdminERC721", "PTA721", address(this));
        launch = new PartyTokenLauncher(
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
        creatorNFT.setIsMinter(address(launch), true);
    }

    function test_constructor_works() public view {
        assertEq(address(launch.owner()), partyDAO);
        assertEq(address(launch.TOKEN_ADMIN_ERC721()), address(creatorNFT));
        assertEq(
            address(launch.POSTION_MANAGER()),
            address(positionManager)
        );
        assertEq(
            address(launch.UNISWAP_FACTORY()),
            address(uniswapFactory)
        );
        assertEq(address(launch.WETH()), weth);
        assertEq(launch.POOL_FEE(), poolFee);
        assertEq(address(launch.positionLocker()), positionLocker);
        assertEq(launch.contributionFee(), contributionFee);
        assertEq(launch.withdrawalFeeBps(), withdrawalFeeBps);
    }

    function test_createLaunch_works() public returns (uint32 launchId) {
        address creator = vm.createWallet("Creator").addr;
        vm.deal(creator, 1 ether);

        PartyTokenLauncher.ERC20Args memory erc20Args = PartyTokenLauncher.ERC20Args({
            name: "NewToken",
            symbol: "NT",
            image: "image_url",
            description: "New Token Description",
            totalSupply: 1_000_000 ether
        });

        PartyTokenLauncher.LaunchArgs memory launchArgs = PartyTokenLauncher.LaunchArgs({
            numTokensForLP: 500_000 ether,
            numTokensForDistribution: 300_000 ether,
            numTokensForRecipient: 200_000 ether,
            targetContribution: 10 ether,
            merkleRoot: bytes32(0),
            recipient: address(0x123)
        });

        vm.prank(creator);
        launchId = launch.createLaunch{ value: 1 ether }(erc20Args, launchArgs);

        assertTrue(launch.getLaunchLifecycle(launchId) == PartyTokenLauncher.LaunchLifecycle.Active);
        (IERC20 token,, uint96 totalContributions,,,,,) = launch.launches(launchId);
        uint96 expectedTokensReceived =
            launch.convertETHContributedToTokensReceived(launchId, 1 ether - contributionFee);
        assertEq(token.balanceOf(creator), expectedTokensReceived);
        assertEq(token.totalSupply(), erc20Args.totalSupply);
        assertEq(totalContributions, 1 ether - contributionFee);
        assertEq(creator.balance, 0);
        assertEq(address(launch).balance, 1 ether - contributionFee);
    }

    function test_contribute_works() public {
        uint32 launchId = test_createLaunch_works();
        address contributor = vm.createWallet("Contributor").addr;
        vm.deal(contributor, 5 ether);

        vm.prank(contributor);
        launch.contribute{ value: 5 ether }(launchId, "Adding funds", new bytes32[](0));

        (IERC20 token,, uint96 totalContributions,,,,,) = launch.launches(launchId);
        uint96 expectedTokensReceived =
            launch.convertETHContributedToTokensReceived(launchId, 5 ether - contributionFee);
        assertEq(token.balanceOf(contributor), expectedTokensReceived);
        assertEq(totalContributions, 6 ether - (contributionFee * 2));
        assertEq(contributor.balance, 0);
        assertEq(address(launch).balance, 6 ether - (contributionFee * 2));
    }

    function test_ragequit_works() public {
        uint32 launchId = test_createLaunch_works();
        address creator = vm.createWallet("Creator").addr;

        (IERC20 token,,,,,,,) = launch.launches(launchId);
        uint96 tokenBalance = uint96(token.balanceOf(creator));

        vm.prank(creator);
        launch.ragequit(launchId);

        uint96 expectedETHReturned = launch.convertTokensReceivedToETHContributed(launchId, tokenBalance);
        uint96 withdrawalFee = (expectedETHReturned * withdrawalFeeBps) / 10_000;
        assertEq(creator.balance, expectedETHReturned - withdrawalFee);
        assertEq(token.balanceOf(creator), 0);
        assertEq(partyDAO.balance, contributionFee + withdrawalFee);
        (,, uint96 totalContributions,,,,,) = launch.launches(launchId);
        assertEq(totalContributions, 0);
    }

    function test_finalize_works() public {
        uint32 launchId = test_createLaunch_works();
        address contributor = vm.createWallet("Final Contributor").addr;
        (IERC20 token, uint96 targetContribution, uint96 totalContributions,,,,,) = launch.launches(launchId);
        uint96 remainingContribution = targetContribution - totalContributions + contributionFee;
        vm.deal(contributor, remainingContribution);

        vm.prank(contributor);
        launch.contribute{ value: remainingContribution }(launchId, "Finalize", new bytes32[](0));

        assertTrue(launch.getLaunchLifecycle(launchId) == PartyTokenLauncher.LaunchLifecycle.Finalized);
        (,, totalContributions,,,,,) = launch.launches(launchId);
        uint96 expectedTokensReceived =
            launch.convertETHContributedToTokensReceived(launchId, remainingContribution - contributionFee);
        assertEq(token.balanceOf(contributor), expectedTokensReceived);
        assertEq(totalContributions, targetContribution);
        assertEq(contributor.balance, 0);
        assertEq(token.balanceOf(address(launch)), 0);
        assertEq(address(launch).balance, 0);
    }

    function test_setPositionLocker_works() public {
        address newPositionLocker = vm.createWallet("New Position Locker").addr;
        vm.prank(partyDAO);
        launch.setPositionLocker(newPositionLocker);

        assertEq(launch.positionLocker(), newPositionLocker);
    }

    function test_setContributionFee_works() public {
        assertEq(launch.contributionFee(), 0.00055 ether);

        uint96 newContributionFee = 0.001 ether;
        vm.prank(partyDAO);
        launch.setContributionFee(newContributionFee);

        // Check updated contribution fee
        assertEq(launch.contributionFee(), newContributionFee);
    }

    function test_setWithdrawalFeeBps_works() public {
        assertEq(launch.withdrawalFeeBps(), 100);

        uint16 newWithdrawalFeeBps = 50; // 0.5%
        vm.prank(partyDAO);
        launch.setWithdrawalFeeBps(newWithdrawalFeeBps);

        assertEq(launch.withdrawalFeeBps(), newWithdrawalFeeBps);
    }

    function test_VERSION_works() public view {
        assertEq(launch.VERSION(), "0.3.0");
    }
}
