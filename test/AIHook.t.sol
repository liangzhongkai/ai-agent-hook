// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {AIHook} from "../src/AIHook.sol";
import {AIHookTestBase} from "./utils/AIHookTestBase.sol";

contract AIHookTest is AIHookTestBase {
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

    PoolKey internal poolKey;

    function setUp() public {
        setUpAIHook();
        poolKey = initDynamicFeePool();
    }

    // ---------- deployment & permissions ----------

    function test_constructorStoresDependencies() public view {
        assertEq(hook.aiOracle(), aiOracle);
        assertEq(address(hook.agentRegistry()), address(registry));
        assertEq(address(hook.rewardToken()), address(token));
        assertEq(address(hook.decisionNFT()), address(decisionNFT));
        assertEq(hook.insuranceFund(), insuranceFund);
        assertEq(hook.owner(), address(this));
    }

    function test_getHookPermissions() public view {
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertFalse(permissions.beforeInitialize);
        assertFalse(permissions.afterInitialize);
        assertFalse(permissions.beforeAddLiquidity);
        assertTrue(permissions.afterAddLiquidity);
        assertFalse(permissions.beforeRemoveLiquidity);
        assertFalse(permissions.afterRemoveLiquidity);
        assertTrue(permissions.beforeSwap);
        assertTrue(permissions.afterSwap);
        assertFalse(permissions.beforeDonate);
        assertFalse(permissions.afterDonate);
        assertFalse(permissions.beforeSwapReturnDelta);
        assertFalse(permissions.afterSwapReturnDelta);
    }

    // ---------- beforeSwap: signature & access control ----------

    function test_beforeSwap_revertsOnExpiredSignature() public {
        bytes memory hookData = encodeHookData(
            1000,
            agent,
            referrer,
            block.timestamp - 1
        );
        vm.expectRevert(AIHook.ExpiredSignature.selector);
        callBeforeSwap(poolKey, hookData);
    }

    function test_beforeSwap_revertsOnInvalidSignature() public {
        uint256 wrongPk = 0xBEEF;
        bytes32 hash = keccak256(
            abi.encode(1000, agent, referrer, block.timestamp + 1 hours)
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", hash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPk, digest);
        bytes memory hookData = abi.encode(
            abi.encodePacked(r, s, v),
            abi.encode(1000, agent, referrer, block.timestamp + 1 hours)
        );

        vm.expectRevert(AIHook.InvalidSignature.selector);
        callBeforeSwap(poolKey, hookData);
    }

    function test_beforeSwap_revertsWhenAgentReputationTooLow() public {
        registerAgent(agent);
        vm.prank(address(hook));
        registry.decreaseReputation(agent, 450);

        bytes memory hookData = encodeHookData(
            1000,
            agent,
            referrer,
            block.timestamp + 1 hours
        );
        vm.expectRevert("Agent reputation too low");
        callBeforeSwap(poolKey, hookData);
    }

    function test_beforeSwap_allowsUnregisteredAgent() public {
        bytes memory hookData = encodeHookData(
            1000,
            agent,
            referrer,
            block.timestamp + 1 hours
        );
        (bytes4 selector, , uint24 fee) = callBeforeSwap(poolKey, hookData);
        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(fee.removeOverrideFlag(), expectedDynamicFee(1000));
        assertTrue(fee.isOverride());
    }

    // ---------- beforeSwap: dynamic fee tiers ----------

    function test_beforeSwap_appliesMinFeeForLowRisk() public {
        bytes memory hookData = encodeHookData(
            1000,
            address(0),
            address(0),
            block.timestamp + 1 hours
        );
        (, , uint24 fee) = callBeforeSwap(poolKey, hookData);
        assertEq(fee.removeOverrideFlag(), expectedDynamicFee(1000));
    }

    function test_beforeSwap_appliesMaxFeeForHighRisk() public {
        bytes memory hookData = encodeHookData(
            9000,
            address(0),
            address(0),
            block.timestamp + 1 hours
        );
        (, , uint24 fee) = callBeforeSwap(poolKey, hookData);
        assertEq(fee.removeOverrideFlag(), hook.MAX_FEE());
    }

    function test_beforeSwap_interpolatesMidRiskFee() public {
        uint256 midRisk = 5000;
        bytes memory hookData = encodeHookData(
            midRisk,
            address(0),
            address(0),
            block.timestamp + 1 hours
        );
        (, , uint24 fee) = callBeforeSwap(poolKey, hookData);
        assertEq(fee.removeOverrideFlag(), expectedDynamicFee(midRisk));
        assertEq(fee.removeOverrideFlag(), 8000);
    }

    function test_beforeSwap_emitsFeeAdjusted() public {
        uint256 riskScore = 5000;
        bytes memory hookData = encodeHookData(
            riskScore,
            address(0),
            address(0),
            block.timestamp + 1 hours
        );

        vm.expectEmit(true, false, false, true, address(hook));
        emit AIHook.FeeAdjusted(
            keccak256(abi.encode(poolKey)),
            expectedDynamicFee(riskScore),
            riskScore
        );
        callBeforeSwap(poolKey, hookData);
    }

    // ---------- afterSwap: rewards, insurance, reputation ----------

    function test_afterSwap_mintsReferralReward() public {
        uint256 riskScore = 1000;
        bytes memory hookData = encodeHookData(
            riskScore,
            address(0),
            referrer,
            block.timestamp + 1 hours
        );
        BalanceDelta swapDelta = BalanceDelta.wrap(-10000 << 128);

        vm.expectEmit(true, false, false, true, address(hook));
        emit AIHook.ReferralRewarded(referrer, 15);
        callAfterSwap(poolKey, swapDelta, hookData);

        assertEq(token.balanceOf(referrer), 15);
        assertEq(decisionNFT.ownerOf(0), address(this));
        assertEq(hook.battlePoints(address(this)), 10000);
    }

    function test_afterSwap_skipsReferralWhenZeroAddress() public {
        bytes memory hookData = encodeHookData(
            1000,
            address(0),
            address(0),
            block.timestamp + 1 hours
        );
        BalanceDelta swapDelta = BalanceDelta.wrap(-10000 << 128);
        callAfterSwap(poolKey, swapDelta, hookData);
        assertEq(token.totalSupply(), 0);
    }

    function test_afterSwap_emitsInsuranceFundCharged() public {
        bytes memory hookData = encodeHookData(
            1000,
            address(0),
            address(0),
            block.timestamp + 1 hours
        );
        BalanceDelta swapDelta = BalanceDelta.wrap(-10000 << 128);

        vm.expectEmit(false, false, false, true, address(hook));
        emit AIHook.InsuranceFundCharged(20);
        callAfterSwap(poolKey, swapDelta, hookData);
    }

    function test_afterSwap_increasesReputationForLowRiskAgent() public {
        registerAgent(agent);
        bytes memory hookData = encodeHookData(
            1000,
            agent,
            address(0),
            block.timestamp + 1 hours
        );
        BalanceDelta swapDelta = BalanceDelta.wrap(-10000 << 128);

        callAfterSwap(poolKey, swapDelta, hookData);
        assertEq(registry.reputation(agent), 501);
    }

    function test_afterSwap_decreasesReputationForHighRiskAgent() public {
        registerAgent(agent);
        bytes memory hookData = encodeHookData(
            9000,
            agent,
            address(0),
            block.timestamp + 1 hours
        );
        BalanceDelta swapDelta = BalanceDelta.wrap(-10000 << 128);

        callAfterSwap(poolKey, swapDelta, hookData);
        assertEq(registry.reputation(agent), 495);
    }

    function test_afterSwap_skipsReputationForUnregisteredAgent() public {
        bytes memory hookData = encodeHookData(
            1000,
            agent,
            address(0),
            block.timestamp + 1 hours
        );
        BalanceDelta swapDelta = BalanceDelta.wrap(-10000 << 128);
        callAfterSwap(poolKey, swapDelta, hookData);
        assertEq(registry.reputation(agent), 0);
    }

    function test_afterSwap_awardsExtremeRarityPoints() public {
        bytes memory hookData = encodeHookData(
            9000,
            address(0),
            address(0),
            block.timestamp + 1 hours
        );
        BalanceDelta swapDelta = BalanceDelta.wrap(-10000 << 128);
        callAfterSwap(poolKey, swapDelta, hookData);
        // 10000 volume * 500 bps / 100 = 50000
        assertEq(hook.battlePoints(address(this)), 50000);
    }

    function test_afterSwap_mintsDecisionNFTWithMetadata() public {
        uint256 riskScore = 9000;
        bytes memory hookData = encodeHookData(
            riskScore,
            address(0),
            address(0),
            block.timestamp + 1 hours
        );
        BalanceDelta swapDelta = BalanceDelta.wrap(-10000 << 128);
        callAfterSwap(poolKey, swapDelta, hookData);

        (
            uint256 storedRisk,
            uint256 storedVolume,
            ,
            uint256 storedTime
        ) = decisionNFT.decisions(0);
        assertEq(storedRisk, riskScore);
        assertEq(storedVolume, 10000);
        assertEq(storedTime, block.timestamp);

        string memory uri = decisionNFT.tokenURI(0);
        assertTrue(bytes(uri).length > 0);
    }

    function test_afterAddLiquidity_awardsEarlyLPBonusOnce() public {
        address lp = makeAddr("earlyLP");
        vm.startPrank(address(manager));
        hook.afterAddLiquidity(
            lp, poolKey, LIQUIDITY_PARAMS, BalanceDelta.wrap(0), BalanceDelta.wrap(0), ZERO_BYTES
        );
        hook.afterAddLiquidity(
            lp, poolKey, LIQUIDITY_PARAMS, BalanceDelta.wrap(0), BalanceDelta.wrap(0), ZERO_BYTES
        );
        vm.stopPrank();
        assertEq(hook.battlePoints(lp), hook.EARLY_LP_BONUS());
    }

    function test_swap_withValidOracleSignature_succeeds() public {
        registerAgent(agent);
        bytes memory hookData = encodeHookData(
            1000,
            agent,
            referrer,
            block.timestamp + 1 hours
        );

        BalanceDelta delta = swap(poolKey, true, -10_000, hookData);
        assertLt(delta.amount0(), 0);
        assertGt(delta.amount1(), 0);
        assertEq(token.balanceOf(referrer), 15);
        assertEq(registry.reputation(agent), 501);
        assertEq(decisionNFT.balanceOf(address(swapRouter)), 1);
        assertGt(hook.battlePoints(address(swapRouter)), 0);
    }

    function test_swap_usesHookOverrideFeeInSwapEvent() public {
        uint256 riskScore = 9000;
        bytes memory hookData = encodeHookData(
            riskScore,
            address(0),
            address(0),
            block.timestamp + 1 hours
        );

        vm.recordLogs();
        swap(poolKey, true, -10_000, hookData);

        bytes32 swapTopic = keccak256(
            "Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)"
        );
        bool found;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter == address(manager) &&
                logs[i].topics[0] == swapTopic
            ) {
                (, , , , , uint24 fee) = abi.decode(
                    logs[i].data,
                    (int128, int128, uint160, uint128, int24, uint24)
                );
                assertEq(fee, expectedDynamicFee(riskScore));
                found = true;
            }
        }
        assertTrue(found, "Swap event not found");
    }

    function test_swap_revertsWithExpiredSignature() public {
        bytes memory hookData = encodeHookData(
            1000,
            address(0),
            address(0),
            block.timestamp - 1
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(AIHook.ExpiredSignature.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(poolKey, true, -100, hookData);
    }

    // ---------- admin ----------

    function test_setAIOracle_onlyOwner() public {
        address newOracle = makeAddr("newOracle");
        hook.setAIOracle(newOracle);
        assertEq(hook.aiOracle(), newOracle);
    }

    function test_setAIOracle_revertsForNonOwner() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert();
        hook.setAIOracle(makeAddr("newOracle"));
    }

    function test_setInsuranceFund_onlyOwner() public {
        address newFund = makeAddr("newFund");
        hook.setInsuranceFund(newFund);
        assertEq(hook.insuranceFund(), newFund);
    }

    function test_setInsuranceFund_revertsForNonOwner() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert();
        hook.setInsuranceFund(makeAddr("newFund"));
    }

    function test_agent_registration_and_reputation() public {
        // 注册代理
        address agent = address(0xB0B);
        vm.deal(agent, 1 ether);
        vm.prank(agent);
        registry.register{value: 0.1 ether}();

        assertTrue(registry.isRegistered(agent));
        assertEq(registry.reputation(agent), 500);

        // 模拟 Hook 增加信誉（需 Hook 为 Owner，这里简化）
        vm.prank(address(hook)); // Hook 合约地址
        registry.increaseReputation(agent, 100);
        assertEq(registry.reputation(agent), 600);
    }
}
