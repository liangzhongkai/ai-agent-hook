// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StdCheats} from "forge-std/StdCheats.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {AIHook} from "../src/AIHook.sol";
import {VxHookToken} from "../src/VxHookToken.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";

/// @notice Shared deployment logic for scripts and tests.
/// @dev Uses deployCodeTo to place the hook at a permission-valid address (local/test only).
contract DeployHelpers is StdCheats {
    uint160 internal constant HOOK_FLAGS = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
    uint160 internal constant CLEAR_HOOK_FLAGS_MASK = ~uint160((1 << 14) - 1);

    function hookAddress() public pure returns (address) {
        return address(uint160(uint256(type(uint160).max) & CLEAR_HOOK_FLAGS_MASK | HOOK_FLAGS));
    }

    function deploySystem(IPoolManager poolManager, address aiOracle, address insuranceFund)
        external
        returns (VxHookToken rewardToken, AgentRegistry agentRegistry, AIHook hook)
    {
        rewardToken = new VxHookToken();
        agentRegistry = new AgentRegistry();

        address hookAddr = hookAddress();
        deployCodeTo(
            "AIHook.sol:AIHook",
            abi.encode(poolManager, aiOracle, address(agentRegistry), address(rewardToken), insuranceFund),
            hookAddr
        );
        hook = AIHook(hookAddr);

        rewardToken.setMinter(hookAddr);
        agentRegistry.transferOwnership(hookAddr);
    }
}
