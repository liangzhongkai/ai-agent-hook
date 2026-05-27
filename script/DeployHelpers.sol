// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StdCheats} from "forge-std/StdCheats.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IAlphaToken} from "../src/AlphaToken.sol";
import {ProphetHook} from "../src/ProphetHook.sol";
import {ProphetCard} from "../src/ProphetCard.sol";
import {AlphaToken} from "../src/AlphaToken.sol";
import {AlphaStaking} from "../src/AlphaStaking.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";

/// @notice Shared deployment logic for scripts and tests.
contract DeployHelpers is StdCheats {
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );
    uint160 internal constant CLEAR_HOOK_FLAGS_MASK = ~uint160((1 << 14) - 1);

    struct ProphetStack {
        AlphaToken alpha;
        AgentRegistry registry;
        ProphetCard card;
        AlphaStaking staking;
        ProphetHook hook;
    }

    function hookAddress() public pure returns (address) {
        return address(uint160(uint256(type(uint160).max) & CLEAR_HOOK_FLAGS_MASK | HOOK_FLAGS));
    }

    function deploySystem(IPoolManager poolManager) external returns (ProphetStack memory s) {
        s.alpha = new AlphaToken();
        s.registry = new AgentRegistry();
        s.card = new ProphetCard();
        s.staking = new AlphaStaking(IAlphaToken(address(s.alpha)));

        address hookAddr = hookAddress();
        deployCodeTo(
            "ProphetHook.sol:ProphetHook",
            abi.encode(poolManager, address(s.alpha), address(s.registry), address(s.card)),
            hookAddr
        );
        s.hook = ProphetHook(hookAddr);

        s.alpha.setMinter(hookAddr);
        s.card.setRecorder(hookAddr);
        s.staking.setNotifier(hookAddr);
        s.hook.setAlphaStaking(address(s.staking));
    }
}
