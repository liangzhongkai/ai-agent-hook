// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "../src/base/BaseHook.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {ImmutableState} from "v4-periphery/base/ImmutableState.sol";
import {AIHookTestBase} from "./utils/AIHookTestBase.sol";

/// @notice Covers BaseHook routing, access control, and unimplemented hook endpoints
contract BaseHookTest is AIHookTestBase {
    using LPFeeLibrary for uint24;

    PoolKey internal poolKey;

    function setUp() public {
        setUpAIHook();
        poolKey = initDynamicFeePool();
    }

    function test_onlyPoolManager_blocksExternalCaller() public {
        bytes memory hookData = encodeHookData(1000, address(0), address(0), block.timestamp + 1 hours);
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeSwap(address(this), poolKey, SWAP_PARAMS, hookData);
    }

    function test_beforeInitialize_revertsHookNotImplemented() public {
        vm.prank(address(manager));
        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hook.beforeInitialize(address(this), poolKey, SQRT_PRICE_1_1);
    }

    function test_afterInitialize_revertsHookNotImplemented() public {
        vm.prank(address(manager));
        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hook.afterInitialize(address(this), poolKey, SQRT_PRICE_1_1, 0);
    }

    function test_beforeAddLiquidity_revertsHookNotImplemented() public {
        vm.prank(address(manager));
        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hook.beforeAddLiquidity(address(this), poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    function test_afterAddLiquidity_revertsHookNotImplemented() public {
        vm.prank(address(manager));
        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hook.afterAddLiquidity(
            address(this), poolKey, LIQUIDITY_PARAMS, BalanceDelta.wrap(0), BalanceDelta.wrap(0), ZERO_BYTES
        );
    }

    function test_beforeRemoveLiquidity_revertsHookNotImplemented() public {
        vm.prank(address(manager));
        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hook.beforeRemoveLiquidity(address(this), poolKey, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    function test_afterRemoveLiquidity_revertsHookNotImplemented() public {
        vm.prank(address(manager));
        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hook.afterRemoveLiquidity(
            address(this), poolKey, REMOVE_LIQUIDITY_PARAMS, BalanceDelta.wrap(0), BalanceDelta.wrap(0), ZERO_BYTES
        );
    }

    function test_beforeDonate_revertsHookNotImplemented() public {
        vm.prank(address(manager));
        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hook.beforeDonate(address(this), poolKey, 1, 1, ZERO_BYTES);
    }

    function test_afterDonate_revertsHookNotImplemented() public {
        vm.prank(address(manager));
        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hook.afterDonate(address(this), poolKey, 1, 1, ZERO_BYTES);
    }

    function test_beforeSwap_delegatesToImplementation() public {
        bytes memory hookData = encodeHookData(1000, address(0), address(0), block.timestamp + 1 hours);
        vm.prank(address(manager));
        (, , uint24 fee) = hook.beforeSwap(address(this), poolKey, SWAP_PARAMS, hookData);
        assertTrue(fee.isOverride());
        assertEq(fee.removeOverrideFlag(), hook.MIN_FEE());
    }

    function test_afterSwap_delegatesToImplementation() public {
        bytes memory hookData = encodeHookData(1000, address(0), referrer, block.timestamp + 1 hours);
        vm.prank(address(manager));
        hook.afterSwap(address(this), poolKey, SWAP_PARAMS, BalanceDelta.wrap(-10000 << 128), hookData);
        assertEq(token.balanceOf(referrer), 15);
    }
}
