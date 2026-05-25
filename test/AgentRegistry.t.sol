// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";

contract AgentRegistryTest is Test {
    AgentRegistry internal registry;
    address internal agent = makeAddr("agent");

    receive() external payable {}

    function setUp() public {
        registry = new AgentRegistry();
    }

    function test_register_succeedsWithMinStake() public {
        vm.deal(agent, 1 ether);
        vm.prank(agent);
        registry.register{value: 0.1 ether}();

        assertTrue(registry.isRegistered(agent));
        assertEq(registry.reputation(agent), 500);
    }

    function test_register_revertsOnInsufficientStake() public {
        vm.deal(agent, 1 ether);
        vm.prank(agent);
        vm.expectRevert("Insufficient stake");
        registry.register{value: 0.09 ether}();
    }

    function test_register_revertsWhenAlreadyRegistered() public {
        vm.deal(agent, 1 ether);
        vm.prank(agent);
        registry.register{value: 0.1 ether}();

        vm.prank(agent);
        vm.expectRevert("Already registered");
        registry.register{value: 0.1 ether}();
    }

    function test_unstake_requiresDelay() public {
        vm.deal(agent, 1 ether);
        vm.prank(agent);
        registry.register{value: 0.1 ether}();

        vm.prank(agent);
        registry.requestUnstake();

        vm.prank(agent);
        vm.expectRevert("Too early");
        registry.unstake();

        vm.warp(block.timestamp + 7 days);
        vm.prank(agent);
        registry.unstake();

        assertFalse(registry.isRegistered(agent));
    }

    function test_increaseReputation_capsAtMax() public {
        vm.deal(agent, 1 ether);
        vm.prank(agent);
        registry.register{value: 0.1 ether}();

        registry.increaseReputation(agent, 10_000);
        assertEq(registry.reputation(agent), 10_000);
    }

    function test_decreaseReputation_floorsAtZero() public {
        vm.deal(agent, 1 ether);
        vm.prank(agent);
        registry.register{value: 0.1 ether}();

        registry.decreaseReputation(agent, 1000);
        assertEq(registry.reputation(agent), 0);
    }

    function test_slash_transfersToOwner() public {
        vm.deal(agent, 1 ether);
        vm.prank(agent);
        registry.register{value: 0.1 ether}();

        uint256 ownerBefore = address(this).balance;
        registry.slash(agent, 0.05 ether);
        assertEq(address(this).balance, ownerBefore + 0.05 ether);
    }

    function test_slash_revertsForUnregistered() public {
        vm.expectRevert("Not registered");
        registry.slash(agent, 0.01 ether);
    }

    function test_slash_capsAtStakedAmount() public {
        vm.deal(agent, 1 ether);
        vm.prank(agent);
        registry.register{value: 0.1 ether}();

        uint256 ownerBefore = address(this).balance;
        registry.slash(agent, 1 ether);
        assertEq(address(this).balance, ownerBefore + 0.1 ether);
        (, uint256 stakedAmount,,) = registry.agents(agent);
        assertEq(stakedAmount, 0);
    }

    function test_requestUnstake_revertsWhenNotRegistered() public {
        vm.prank(agent);
        vm.expectRevert("Not registered");
        registry.requestUnstake();
    }

    function test_unstake_revertsWithoutRequest() public {
        vm.deal(agent, 1 ether);
        vm.prank(agent);
        registry.register{value: 0.1 ether}();

        vm.prank(agent);
        vm.expectRevert("Too early");
        registry.unstake();
    }

    function test_increaseReputation_revertsUnauthorized() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert("Unauthorized");
        registry.increaseReputation(agent, 1);
    }

    function test_increaseReputation_ownerCanUpdateUnregisteredAgent() public {
        registry.increaseReputation(agent, 50);
        assertEq(registry.reputation(agent), 50);
    }

    function test_decreaseReputation_partialDecrease() public {
        vm.deal(agent, 1 ether);
        vm.prank(agent);
        registry.register{value: 0.1 ether}();

        registry.decreaseReputation(agent, 100);
        assertEq(registry.reputation(agent), 400);
    }

    function test_decreaseReputation_revertsUnauthorized() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert("Unauthorized");
        registry.decreaseReputation(agent, 1);
    }

    function test_register_emitsAgentRegistered() public {
        vm.deal(agent, 1 ether);
        vm.expectEmit(true, false, false, true);
        emit AgentRegistry.AgentRegistered(agent, 0.1 ether);
        vm.prank(agent);
        registry.register{value: 0.1 ether}();
    }
}
