// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {VxHookToken} from "../src/VxHookToken.sol";

contract VxHookTokenTest is Test {
    VxHookToken internal token;
    address internal minter = makeAddr("minter");

    function setUp() public {
        token = new VxHookToken();
    }

    function test_deployerCanMint() public {
        token.mint(minter, 1000);
        assertEq(token.balanceOf(minter), 1000);
    }

    function test_setMinter_allowsNewMinter() public {
        token.setMinter(minter);
        vm.prank(minter);
        token.mint(makeAddr("recipient"), 500);
        assertEq(token.balanceOf(makeAddr("recipient")), 500);
    }

    function test_mint_revertsForNonMinter() public {
        vm.prank(minter);
        vm.expectRevert();
        token.mint(minter, 1);
    }

    function test_metadata() public view {
        assertEq(token.name(), "VxHOOK Governance Token");
        assertEq(token.symbol(), "vxHOOK");
    }
}
