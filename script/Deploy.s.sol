// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import "forge-std/src/Script.sol";
import "../src/PartyTokenLauncher.sol";

contract MyScript is Script {
    function run() external {
        vm.startBroadcast();

        // PartyTokenLauncher crowdfund = new PartyTokenLauncher();

        vm.stopBroadcast();
    }
}
