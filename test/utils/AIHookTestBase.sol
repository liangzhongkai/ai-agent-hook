// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Deployers} from "v4-test/utils/Deployers.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {AIHook} from "../../src/AIHook.sol";
import {VxHookToken} from "../../src/VxHookToken.sol";
import {AgentRegistry} from "../../src/AgentRegistry.sol";

/// @notice Shared setup and helpers for AIHook integration tests
abstract contract AIHookTestBase is Test, Deployers {
    using LPFeeLibrary for uint24;

    uint256 internal constant ORACLE_PK = 0xA11CE;
    uint160 internal constant HOOK_FLAGS = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

    AIHook internal hook;
    VxHookToken internal token;
    AgentRegistry internal registry;

    address internal aiOracle;
    address internal insuranceFund;
    address internal agent;
    address internal referrer;

    function setUpAIHook() internal {
        aiOracle = vm.addr(ORACLE_PK);
        insuranceFund = makeAddr("insuranceFund");
        agent = makeAddr("agent");
        referrer = makeAddr("referrer");

        deployFreshManagerAndRouters();

        token = new VxHookToken();
        registry = new AgentRegistry();

        address hookAddr = address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | HOOK_FLAGS));
        deployCodeTo(
            "AIHook.sol:AIHook",
            abi.encode(manager, aiOracle, address(registry), address(token), insuranceFund),
            hookAddr
        );

        hook = AIHook(hookAddr);
        token.setMinter(hookAddr);
        registry.transferOwnership(hookAddr);
    }

    function initDynamicFeePool() internal returns (PoolKey memory poolKey) {
        deployMintAndApprove2Currencies();
        (poolKey,) =
            initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);
    }

    function registerAgent(address who) internal {
        vm.deal(who, 1 ether);
        vm.prank(who);
        registry.register{value: 0.1 ether}();
    }

    function signOracle(uint256 riskScore, address _agent, address _referrer, uint256 deadline)
        internal
        view
        returns (bytes memory signature)
    {
        bytes32 hash = keccak256(abi.encode(riskScore, _agent, _referrer, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ORACLE_PK, digest);
        signature = abi.encodePacked(r, s, v);
    }

    function encodeHookData(uint256 riskScore, address _agent, address _referrer, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes memory signature = signOracle(riskScore, _agent, _referrer, deadline);
        bytes memory data = abi.encode(riskScore, _agent, _referrer, deadline);
        return abi.encode(signature, data);
    }

    function expectedDynamicFee(uint256 riskScore) internal view returns (uint24) {
        uint256 lowRisk = hook.LOW_RISK_THRESHOLD();
        uint256 highRisk = hook.HIGH_RISK_THRESHOLD();
        uint24 minFee = hook.MIN_FEE();
        uint24 maxFee = hook.MAX_FEE();

        if (riskScore <= lowRisk) {
            return minFee;
        }
        if (riskScore >= highRisk) {
            return maxFee;
        }
        return uint24(minFee + ((riskScore - lowRisk) * (maxFee - minFee)) / (highRisk - lowRisk));
    }

    function callBeforeSwap(PoolKey memory poolKey, bytes memory hookData)
        internal
        returns (bytes4 selector, BeforeSwapDelta delta, uint24 fee)
    {
        vm.prank(address(manager));
        return hook.beforeSwap(address(this), poolKey, SWAP_PARAMS, hookData);
    }

    function callAfterSwap(PoolKey memory poolKey, BalanceDelta swapDelta, bytes memory hookData)
        internal
        returns (bytes4 selector, int128 hookDelta)
    {
        vm.prank(address(manager));
        return hook.afterSwap(address(this), poolKey, SWAP_PARAMS, swapDelta, hookData);
    }
}
