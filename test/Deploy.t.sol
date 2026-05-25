// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {DeployHelpers} from "../script/DeployHelpers.sol";
import {DeployXLayer} from "../script/Deploy.s.sol";
import {AIHook} from "../src/AIHook.sol";
import {VxHookToken} from "../src/VxHookToken.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";

contract DeployTest is Test {
    address internal constant AI_ORACLE =
        0x0BF05990ccFc8Aad97c95121C2ded403225DC17a;
    address internal constant INSURANCE_FUND =
        0xdC67b12624a55F09Feea390E106e156c32868506;

    DeployHelpers internal helper;
    DeployXLayer internal deployer;

    function setUp() public {
        helper = new DeployHelpers();
        deployer = new DeployXLayer();
        vm.setEnv("PRIVATE_KEY", "1");
    }

    function test_hookAddress_hasRequiredFlags() public view {
        assertTrue(uint160(helper.hookAddress()) & Hooks.BEFORE_SWAP_FLAG != 0);
        assertTrue(uint160(helper.hookAddress()) & Hooks.AFTER_SWAP_FLAG != 0);
    }

    function test_deploySystem_wiresContracts() public {
        PoolManager manager = new PoolManager(address(this));

        (VxHookToken token, AgentRegistry registry, AIHook hook) = helper
            .deploySystem(
                IPoolManager(address(manager)),
                AI_ORACLE,
                INSURANCE_FUND
            );

        assertEq(hook.aiOracle(), AI_ORACLE);
        assertEq(hook.insuranceFund(), INSURANCE_FUND);
        assertEq(address(hook.agentRegistry()), address(registry));
        assertEq(address(hook.rewardToken()), address(token));
        assertTrue(token.hasRole(token.MINTER_ROLE(), address(hook)));
        assertEq(registry.owner(), address(hook));
    }

    function test_run_executesDeployScript() public {
        deployer.run();
    }
}
