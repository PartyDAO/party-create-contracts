// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { ERC20Permit, Nonces } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { ERC20Votes, ERC20 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract CircuitBreakerERC20 is ERC20Permit, ERC20Votes, Ownable {
    event MetadataSet(string image, string description);
    event PausedSet(bool paused);

    error TokenPaused();

    /// @notice Whether the token is paused. Can be toggled by owner.
    bool public paused;

    constructor(
        string memory name,
        string memory symbol,
        string memory image,
        string memory description,
        uint256 totalSupply,
        address receiver,
        address owner
    )
        ERC20(name, symbol)
        ERC20Permit(name)
        Ownable(owner)
    {
        _mint(receiver, totalSupply);
        emit MetadataSet(image, description);
    }

    /// @notice Only owner can transfer functions when paused. They can transfer out or call `transferFrom` to
    /// themselves.
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        address owner = owner();
        if (paused && from != owner && (to != owner || msg.sender != owner)) {
            revert TokenPaused();
        }
        super._update(from, to, value);
    }

    /// @dev Enable owner to spend tokens without approval.
    function _spendAllowance(address tokenOwner, address tokenSpender, uint256 value) internal override(ERC20) {
        if (tokenSpender != owner()) {
            super._spendAllowance(tokenOwner, tokenSpender, value);
        }
    }

    // The following functions are overrides required by Solidity.
    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }

    function setPaused(bool _paused) external onlyOwner {
        if (paused == _paused) return;
        paused = _paused;

        emit PausedSet(paused);
    }

    /**
     * @dev Returns the version of the contract. Decimal versions indicate change in logic. Number change indicates
     *      change in ABI.
     */
    function VERSION() external pure returns (string memory) {
        return "1.0.0";
    }
}
