// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

interface IAlphaToken {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
}

/// @title $ALPHA — Prophet Hook governance & reward token
/// @notice Minted by ProphetHook to traders whose swap directions correctly anticipated
///         price movement within an epoch. Burnable via Prophet Card upgrades.
contract AlphaToken is ERC20, AccessControl, IAlphaToken {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    /// @notice Total supply hard cap (prevents runaway inflation if a pool misconfigures skim).
    uint256 public constant MAX_SUPPLY = 100_000_000 ether;

    error CapExceeded();

    constructor() ERC20("Prophet Alpha", "ALPHA") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
    }

    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        if (totalSupply() + amount > MAX_SUPPLY) revert CapExceeded();
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyRole(BURNER_ROLE) {
        _burn(from, amount);
    }

    function setMinter(address minter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(MINTER_ROLE, minter);
    }

    function setBurner(address burner) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(BURNER_ROLE, burner);
    }
}
