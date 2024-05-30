// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { ERC20Permit, Nonces } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { ERC20Votes, ERC20 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract CircuitBreakerERC20 is ERC20Permit, ERC20Votes, Ownable {
    event UnpauseTimeSet(uint256 previousUnpauseTime, uint256 newUnpauseTime);

    error TokenPaused();

    /// @notice Time at which the token becomes unpaused
    uint256 public unpauseTime;

    constructor(
        string memory _name,
        string memory _symbol,
        uint256 _totalSupply,
        address _receiver,
        address _owner
    )
        ERC20(_name, _symbol)
        ERC20Permit(_name)
        Ownable(_owner)
    {
        _mint(_receiver, _totalSupply);
    }

    // The following functions are overrides required by Solidity.
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        if (unpauseTime > block.timestamp && from != owner() && (to != owner() || msg.sender != owner())) {
            revert TokenPaused();
        }
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }

    function setUnpauseTime(uint256 unpauseTime_) external onlyOwner {
        emit UnpauseTimeSet(unpauseTime, unpauseTime_);
        unpauseTime = unpauseTime_;
    }
}
