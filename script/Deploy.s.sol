// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {ProphetHook} from "../src/ProphetHook.sol";
import {ProphetCard} from "../src/ProphetCard.sol";
import {AlphaToken, IAlphaToken} from "../src/AlphaToken.sol";
import {AlphaStaking} from "../src/AlphaStaking.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {HookMiner} from "./HookMiner.sol";

/// @notice Deploys the Prophet Hook stack to X Layer (testnet or mainnet).
/// @dev    Requires env var PRIVATE_KEY. Run with:
///         forge script script/Deploy.s.sol:DeployXLayer --rpc-url xlayer_testnet --broadcast -vvvv
contract DeployXLayer is Script {
    /// @notice X Layer testnet PoolManager. Override via env var POOL_MANAGER if different.
    address constant DEFAULT_POOL_MANAGER = 0xA0B4c6737C0D4942A353368AD86eBbf24503Fbba;

    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address poolManagerAddr = vm.envOr("POOL_MANAGER", DEFAULT_POOL_MANAGER);

        vm.startBroadcast(deployerPrivateKey);

        AlphaToken alpha = new AlphaToken();
        AgentRegistry registry = new AgentRegistry();
        ProphetCard card = new ProphetCard();
        AlphaStaking staking = new AlphaStaking(IAlphaToken(address(alpha)));

        vm.stopBroadcast();

        bytes memory constructorArgs = abi.encode(
            IPoolManager(poolManagerAddr), address(alpha), address(registry), address(card)
        );

        (address expectedHookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, HOOK_FLAGS, type(ProphetHook).creationCode, constructorArgs);

        vm.startBroadcast(deployerPrivateKey);

        ProphetHook hook = new ProphetHook{salt: salt}(
            IPoolManager(poolManagerAddr), address(alpha), address(registry), address(card)
        );
        require(address(hook) == expectedHookAddress, "DeployXLayer: hook address mismatch");

        alpha.setMinter(address(hook));
        card.setRecorder(address(hook));
        staking.setNotifier(address(hook));
        hook.setAlphaStaking(address(staking));

        vm.stopBroadcast();

        console.log("====================================================");
        console.log("PROPHET HOOK / Hook the Future submission deployed.");
        console.log("====================================================");
        console.log("PoolManager:     ", poolManagerAddr);
        console.log("AlphaToken:      ", address(alpha));
        console.log("AgentRegistry:   ", address(registry));
        console.log("ProphetCard:     ", address(card));
        console.log("AlphaStaking:    ", address(staking));
        console.log("ProphetHook:     ", address(hook));
        console.log("Hook flags (hex):", vm.toString(uint256(HOOK_FLAGS)));
        console.log("");
        console.log("Pot split:  70% top prophet | 20% LPs (donate) | 10% ALPHA stakers");
        console.log("Stake boost: up to 2.00x score, up to 50% skim discount at 100k ALPHA");
        console.log("");
        console.log("Next step: create a dynamic-fee pool keyed to this hook, then call");
        console.log("hook.configurePool(key, epochBlocks, prophetSkimBps, baseLpFeeBps) BEFORE init.");
    }
}
