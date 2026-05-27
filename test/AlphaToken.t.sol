// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {AlphaToken} from "../src/AlphaToken.sol";

contract AlphaTokenTest is Test {
    AlphaToken internal alpha;
    address internal user = makeAddr("user");

    function setUp() public {
        alpha = new AlphaToken();
    }

    function test_mintByMinter() public {
        alpha.mint(user, 1 ether);
        assertEq(alpha.balanceOf(user), 1 ether);
    }

    function test_mintByNonMinter_reverts() public {
        vm.prank(user);
        vm.expectRevert();
        alpha.mint(user, 1 ether);
    }

    function test_cap_enforced() public {
        // mint up to cap
        alpha.mint(user, 100_000_000 ether);
        vm.expectRevert(AlphaToken.CapExceeded.selector);
        alpha.mint(user, 1);
    }

    function test_setMinter_authorizesNewMinter() public {
        address newMinter = makeAddr("newMinter");
        alpha.setMinter(newMinter);
        vm.prank(newMinter);
        alpha.mint(user, 1 ether);
        assertEq(alpha.balanceOf(user), 1 ether);
    }
}
