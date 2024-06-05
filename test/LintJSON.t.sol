// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import "forge-std/src/Test.sol";

contract LintJSON is Test {
    function _lintJSON(string memory json) internal {
        if (vm.envOr("COVERAGE", false)) {
            // Don't check if we're running coverage
            return;
        }

        vm.writeFile("./out/lint-json.json", json);
        string[] memory inputs = new string[](3);
        inputs[0] = "npx";
        inputs[1] = "ts-node";
        inputs[2] = "./utils/lint-json.ts";
        bytes memory ffiResp = vm.ffi(inputs);

        uint256 resAsInt;
        assembly {
            resAsInt := mload(add(ffiResp, 0x20))
        }
        if (resAsInt != 1) {
            revert("JSON lint failed");
        }
    }
}
