// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {AIHook} from "../src/AIHook.sol";
import {VxHookToken} from "../src/VxHookToken.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {HookMiner} from "./HookMiner.sol";

contract DeployXLayer is Script {
    address constant POOL_MANAGER = 0xA0B4c6737C0D4942A353368AD86eBbf24503Fbba;
    address constant AI_ORACLE = 0x0BF05990ccFc8Aad97c95121C2ded403225DC17a;
    address constant INSURANCE_FUND =
        0xdC67b12624a55F09Feea390E106e156c32868506;

    uint160 internal constant HOOK_FLAGS =
        uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        VxHookToken rewardToken = new VxHookToken();
        AgentRegistry agentRegistry = new AgentRegistry();

        vm.stopBroadcast();

        bytes memory constructorArgs = abi.encode(
            IPoolManager(POOL_MANAGER),
            AI_ORACLE,
            address(agentRegistry),
            address(rewardToken),
            INSURANCE_FUND
        );

        (address expectedHookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_FACTORY,
            HOOK_FLAGS,
            type(AIHook).creationCode,
            constructorArgs
        );

        vm.startBroadcast(deployerPrivateKey);

        AIHook hook = new AIHook{salt: salt}(
            IPoolManager(POOL_MANAGER),
            AI_ORACLE,
            address(agentRegistry),
            address(rewardToken),
            INSURANCE_FUND
        );
        require(
            address(hook) == expectedHookAddress,
            "DeployXLayer: hook address mismatch"
        );

        rewardToken.setMinter(address(hook));
        agentRegistry.transferOwnership(address(hook));

        vm.stopBroadcast();

        console.log("VxHookToken deployed at:", address(rewardToken));
        console.log("AgentRegistry deployed at:", address(agentRegistry));
        console.log("AIHook deployed at:", address(hook));
    }
}
