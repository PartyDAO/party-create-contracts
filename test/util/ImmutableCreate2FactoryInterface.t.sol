// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

interface ImmutableCreate2FactoryInterface {
    function safeCreate2(
        bytes32 salt,
        bytes calldata initializationCode
    )
        external
        payable
        returns (address deploymentAddress);

    function findCreate2Address(
        bytes32 salt,
        bytes calldata initCode
    )
        external
        view
        returns (address deploymentAddress);

    function findCreate2AddressViaHash(
        bytes32 salt,
        bytes32 initCodeHash
    )
        external
        view
        returns (address deploymentAddress);

    function hasBeenDeployed(address deploymentAddress) external view returns (bool);
}
