// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.25;

// TODO: Use this for now, delete when which airdropper contract to use is confirmed
interface IAirdropper {
    function airdrop(bytes memory params) external;
}
