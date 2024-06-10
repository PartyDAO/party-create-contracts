// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import "forge-std/src/Script.sol";
import "../src/PartyTokenLauncher.sol"; // Update the import to the correct contract

contract MyScript is Script {
    function run() external {
        vm.startBroadcast();

        // PartySwapCrowdfund crowdfund = new PartySwapCrowdfund();

        vm.stopBroadcast();
    }
}
