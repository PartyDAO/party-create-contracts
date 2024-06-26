// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.25;

import "forge-std/src/Test.sol";
import { WETH9 } from "./mock/WETH.t.sol";
import { MockUniswapV3Factory } from "./mock/MockUniswapV3Factory.t.sol";
import { MockUniswapNonfungiblePositionManager } from "./mock/MockUniswapNonfungiblePositionManager.t.sol";
import { MockUNCX, IUNCX } from "./mock/MockUNCX.t.sol";

import "../src/PartyTokenLauncher.sol";

contract PartyTokenLauncherTest is Test {
    PartyTokenLauncher launch;
    PartyERC20 partyERC20Logic;
    PartyTokenAdminERC721 creatorNFT;
    address payable partyDAO;
    PartyLPLocker positionLocker;
    INonfungiblePositionManager public positionManager;
    IUniswapV3Factory public uniswapFactory;
    IUNCX public uncx;
    address payable public weth;
    uint24 public poolFee;

    uint16 finalizationFeeBps = 100; // 1%
    uint16 partyDAOPoolFeeBps = 50; // 0.5%
    uint16 withdrawalFeeBps = 200; // 2%

    function setUp() public {
        weth = payable(address(new WETH9()));
        uniswapFactory = IUniswapV3Factory(address(new MockUniswapV3Factory()));
        positionManager = INonfungiblePositionManager(
            address(new MockUniswapNonfungiblePositionManager(address(weth), address(uniswapFactory)))
        );
        uncx = new MockUNCX();
        poolFee = 3000;

        partyDAO = payable(vm.createWallet("Party DAO").addr);
        creatorNFT = new PartyTokenAdminERC721("PartyTokenAdminERC721", "PTA721", address(this));
        positionLocker = new PartyLPLocker(positionManager, creatorNFT, uncx);
        partyERC20Logic = new PartyERC20(creatorNFT);
        launch = new PartyTokenLauncher(
            partyDAO, creatorNFT, partyERC20Logic, positionManager, uniswapFactory, weth, poolFee, positionLocker
        );
        creatorNFT.setIsMinter(address(launch), true);
    }

    function test_constructor_works() public view {
        assertEq(address(launch.owner()), partyDAO);
        assertEq(address(launch.TOKEN_ADMIN_ERC721()), address(creatorNFT));
        assertEq(address(launch.POSITION_MANAGER()), address(positionManager));
        assertEq(address(launch.UNISWAP_FACTORY()), address(uniswapFactory));
        assertEq(address(launch.WETH()), weth);
        assertEq(launch.POOL_FEE(), poolFee);
        assertEq(address(launch.positionLocker()), address(positionLocker));
    }

    function test_createLaunch_works() public returns (uint32 launchId) {
        address creator = vm.createWallet("Creator").addr;
        address recipient = vm.createWallet("Recipient").addr;
        vm.deal(creator, 1 ether);

        PartyTokenLauncher.LockerFeeRecipient[] memory lockerFeeRecipients =
            new PartyTokenLauncher.LockerFeeRecipient[](1);
        lockerFeeRecipients[0] = PartyTokenLauncher.LockerFeeRecipient({
            recipient: vm.createWallet("AdditionalLPFeeRecipient").addr,
            bps: 1e4
        });

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
            maxContributionPerAddress: 8 ether,
            merkleRoot: bytes32(0),
            recipient: recipient,
            finalizationFeeBps: finalizationFeeBps,
            withdrawalFeeBps: withdrawalFeeBps,
            lockerFeeRecipients: lockerFeeRecipients
        });

        vm.prank(creator);
        launchId = launch.createLaunch{ value: 1 ether }(erc20Args, launchArgs);

        assertTrue(launch.getLaunchLifecycle(launchId) == PartyTokenLauncher.LaunchLifecycle.Active);

        // To avoid stack too deep errors
        (, bytes memory res) = address(launch).staticcall(abi.encodeCall(launch.launches, (launchId)));
        (PartyERC20 token,, uint96 totalContributions) = abi.decode(res, (PartyERC20, uint96, uint96));

        uint96 expectedTokensReceived = launch.convertETHContributedToTokensReceived(launchId, 1 ether);
        assertEq(token.balanceOf(creator), expectedTokensReceived);
        assertEq(token.totalSupply(), erc20Args.totalSupply);
        assertEq(totalContributions, 1 ether);
        assertEq(creator.balance, 0);
        assertEq(address(launch).balance, 1 ether);
    }

    function test_createLaunch_withFullContribution() public returns (uint32 launchId) {
        address creator = vm.createWallet("Creator").addr;
        address recipient = vm.createWallet("Recipient").addr;
        vm.deal(creator, 10 ether);

        PartyTokenLauncher.LockerFeeRecipient[] memory lockerFeeRecipients =
            new PartyTokenLauncher.LockerFeeRecipient[](1);
        lockerFeeRecipients[0] = PartyTokenLauncher.LockerFeeRecipient({
            recipient: vm.createWallet("AdditionalLPFeeRecipient").addr,
            bps: 1e4
        });

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
            maxContributionPerAddress: 10 ether,
            merkleRoot: bytes32(0),
            recipient: recipient,
            finalizationFeeBps: finalizationFeeBps,
            withdrawalFeeBps: withdrawalFeeBps,
            lockerFeeRecipients: lockerFeeRecipients
        });

        vm.prank(creator);
        launchId = launch.createLaunch{ value: 10 ether }(erc20Args, launchArgs);

        assertTrue(launch.getLaunchLifecycle(launchId) == PartyTokenLauncher.LaunchLifecycle.Finalized);
    }

    function test_contribute_works() public {
        uint32 launchId = test_createLaunch_works();
        address contributor = vm.createWallet("Contributor").addr;
        vm.deal(contributor, 5 ether);

        vm.prank(contributor);
        launch.contribute{ value: 5 ether }(launchId, "Adding funds", new bytes32[](0));

        // To avoid stack too deep errors
        (, bytes memory res) = address(launch).staticcall(abi.encodeCall(launch.launches, (launchId)));
        (PartyERC20 token,, uint96 totalContributions) = abi.decode(res, (PartyERC20, uint96, uint96));

        uint96 expectedTokensReceived = launch.convertETHContributedToTokensReceived(launchId, 5 ether);
        assertEq(token.balanceOf(contributor), expectedTokensReceived);
        assertEq(totalContributions, 6 ether);
        assertEq(contributor.balance, 0);
        assertEq(address(launch).balance, 6 ether);
    }

    function test_contribute_cannotExceedMaxContributionPerAddress() public {
        uint32 launchId = test_createLaunch_works();
        address contributor = vm.createWallet("Contributor").addr;
        vm.deal(contributor, 8 ether + 1);

        vm.prank(contributor);
        launch.contribute{ value: 8 ether }(launchId, "", new bytes32[](0));

        vm.prank(contributor);
        vm.expectRevert(
            abi.encodeWithSelector(PartyTokenLauncher.ContributionsExceedsMaxPerAddress.selector, 1, 8 ether, 8 ether)
        );
        launch.contribute{ value: 1 }(launchId, "", new bytes32[](0));
    }

    function test_withdraw_works() public {
        uint32 launchId = test_createLaunch_works();
        address creator = vm.createWallet("Creator").addr;

        // To avoid stack too deep errors
        (, bytes memory res) = address(launch).staticcall(abi.encodeCall(launch.launches, (launchId)));
        (PartyERC20 token,, uint96 totalContributions) = abi.decode(res, (PartyERC20, uint96, uint96));

        uint96 tokenBalance = uint96(token.balanceOf(creator));

        vm.prank(creator);
        uint96 ethReceived = launch.withdraw(launchId);

        uint96 expectedETHReturned = launch.convertTokensReceivedToETHContributed(launchId, tokenBalance);
        uint96 withdrawalFee = (expectedETHReturned * withdrawalFeeBps) / 10_000;
        assertEq(creator.balance, expectedETHReturned - withdrawalFee);
        assertEq(ethReceived, expectedETHReturned - withdrawalFee);
        assertEq(token.balanceOf(creator), 0);
        assertEq(partyDAO.balance, withdrawalFee);
        (, res) = address(launch).staticcall(abi.encodeCall(launch.launches, (launchId)));
        (token,, totalContributions) = abi.decode(res, (PartyERC20, uint96, uint96));
        assertEq(totalContributions, 0);
    }

    function test_finalize_works() public {
        uint32 launchId = test_createLaunch_works();

        address contributor = vm.createWallet("Contributor").addr;
        vm.deal(contributor, 2 ether);
        vm.prank(contributor);
        launch.contribute{ value: 2 ether }(launchId, "", new bytes32[](0));

        address contributor2 = vm.createWallet("Final Contributor").addr;

        // To avoid stack too deep errors
        (, bytes memory res) = address(launch).staticcall(abi.encodeCall(launch.launches, (launchId)));
        (PartyERC20 token,, uint96 totalContributions, uint96 targetContribution) =
            abi.decode(res, (PartyERC20, bytes32, uint96, uint96));

        uint96 remainingContribution = targetContribution - totalContributions;
        vm.deal(contributor2, remainingContribution);

        vm.prank(contributor2);
        launch.contribute{ value: remainingContribution }(launchId, "Finalize", new bytes32[](0));

        assertTrue(launch.getLaunchLifecycle(launchId) == PartyTokenLauncher.LaunchLifecycle.Finalized);

        // To avoid stack too deep errors
        (, res) = address(launch).staticcall(abi.encodeCall(launch.launches, (launchId)));
        (,, totalContributions) = abi.decode(res, (PartyERC20, uint96, uint96));

        uint96 expectedTokensReceived = launch.convertETHContributedToTokensReceived(launchId, remainingContribution);
        assertEq(token.balanceOf(contributor2), expectedTokensReceived);
        assertEq(totalContributions, targetContribution);
        assertEq(contributor2.balance, 0);
        assertEq(token.balanceOf(address(launch)), 0);
        assertEq(address(launch).balance, 0);
        (,, bool launchSuccessful) = creatorNFT.tokenMetadatas(launchId);
        assertEq(launchSuccessful, true);
    }

    function test_setPositionLocker_works() public {
        PartyLPLocker newPositionLocker = new PartyLPLocker(positionManager, creatorNFT, uncx);
        vm.prank(partyDAO);
        launch.setPositionLocker(newPositionLocker);

        assertEq(address(launch.positionLocker()), address(newPositionLocker));
    }

    function test_VERSION_works() public view {
        assertEq(launch.VERSION(), "0.5.0");
    }
}
