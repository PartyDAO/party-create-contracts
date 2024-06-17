// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface ILocker {
    function getFlatLockFee() external view returns (uint96);
}
