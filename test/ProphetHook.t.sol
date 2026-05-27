// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {ProphetHook} from "../src/ProphetHook.sol";
import {ProphetHookTestBase} from "./utils/ProphetHookTestBase.sol";

/// @notice End-to-end behavioural tests for the Prophet Hook.
contract ProphetHookTest is ProphetHookTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    PoolKey internal poolKey;
    PoolId internal poolId;

    function setUp() public {
        setUpProphetStack();
        poolKey = initProphetPool();
        poolId = poolKey.toId();
    }

    // -------- permissions --------

    function test_hookPermissions_matchExpectedFlags() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize);
        assertTrue(p.afterInitialize);
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertTrue(p.beforeSwapReturnDelta);
        assertFalse(p.afterSwapReturnDelta);
        assertFalse(p.beforeAddLiquidity);
    }

    function test_configurePool_revertsOnSecondCall() public {
        vm.expectRevert(ProphetHook.PoolAlreadyConfigured.selector);
        hook.configurePool(poolKey, DEFAULT_EPOCH_BLOCKS, DEFAULT_SKIM_BPS, DEFAULT_LP_FEE_BPS);
    }

    function test_configurePool_revertsOnTinyEpoch() public {
        PoolKey memory other = poolKey;
        other.tickSpacing = 30; // different key → different PoolId
        vm.expectRevert(ProphetHook.InvalidConfig.selector);
        hook.configurePool(other, 5, DEFAULT_SKIM_BPS, DEFAULT_LP_FEE_BPS);
    }

    function test_configurePool_revertsOnHugeSkim() public {
        PoolKey memory other = poolKey;
        other.tickSpacing = 30;
        vm.expectRevert(ProphetHook.SkimTooLarge.selector);
        hook.configurePool(other, DEFAULT_EPOCH_BLOCKS, 9999, DEFAULT_LP_FEE_BPS);
    }

    // -------- epoch 0 setup --------

    function test_afterInitialize_opensEpochZero() public view {
        (int24 openTick,, bool settled,,,,) = hook.getEpochInfo(poolKey, 0);
        assertEq(openTick, 0); // SQRT_PRICE_1_1 → tick 0
        assertFalse(settled);
        assertEq(uint256(hook.currentEpoch(poolId)), 0);
    }

    // -------- single-swap accumulator math --------

    function test_swap_recordsPredictionAndSkim() public {
        int256 amountIn = -1_000_000;
        // alice buys token1 with token0 → zeroForOne=true → sign=-1 (bet tick goes DOWN)
        swap(poolKey, true, amountIn, encodeTrader(alice));

        (int128 netSize,, uint128 absN,) = hook.getTraderEpoch(poolKey, 0, alice);
        assertEq(netSize, int128(int256(amountIn))); // -1_000_000 (sign=-1 * size=1_000_000)
        // tick at entry was very close to 0 (some movement from swap, but tested separately)
        assertGt(absN, 0);

        (,,, uint128 pot0, uint128 pot1,,) = hook.getEpochInfo(poolKey, 0);
        // skim = 1_000_000 * 50bps / 10000 = 5000
        assertEq(uint256(pot0), 5000);
        assertEq(uint256(pot1), 0);
    }

    function test_swap_oneForZero_recordsPositiveSign() public {
        int256 amountIn = -1_000_000;
        // bob buys token0 with token1 → zeroForOne=false → sign=+1
        swap(poolKey, false, amountIn, encodeTrader(bob));

        (int128 netSize,,,) = hook.getTraderEpoch(poolKey, 0, bob);
        assertGt(netSize, 0);

        (,,,, uint128 pot1,,) = hook.getEpochInfo(poolKey, 0);
        assertEq(uint256(pot1), 5000);
    }

    function test_dustSwap_isIgnored() public {
        // amount below MIN_SIZE_TO_COUNT should not record
        swap(poolKey, true, -500, encodeTrader(alice));
        (int128 netSize,, uint128 absN,) = hook.getTraderEpoch(poolKey, 0, alice);
        assertEq(netSize, 0);
        assertEq(absN, 0);
    }

    // -------- epoch lifecycle --------

    function test_swap_rollsEpochAutomatically() public {
        swap(poolKey, true, -1_000_000, encodeTrader(alice));
        assertEq(uint256(hook.currentEpoch(poolId)), 0);

        rollPastEpoch(DEFAULT_EPOCH_BLOCKS);

        swap(poolKey, true, -1_000_000, encodeTrader(bob));
        assertEq(uint256(hook.currentEpoch(poolId)), 1);
    }

    function test_settleEpoch_revertsBeforeEnd() public {
        vm.expectRevert(ProphetHook.EpochNotYetEnded.selector);
        hook.settleEpoch(poolKey, 0);
    }

    function test_settleEpoch_setsSettledTick() public {
        swap(poolKey, true, -1_000_000, encodeTrader(alice));
        rollPastEpoch(DEFAULT_EPOCH_BLOCKS);
        // force a roll
        swap(poolKey, true, -1_000_000, encodeTrader(bob));

        hook.settleEpoch(poolKey, 0);

        (, int24 settledTick, bool settled,,,,) = hook.getEpochInfo(poolKey, 0);
        assertTrue(settled);
        assertLt(settledTick, 0); // alice's zeroForOne pushed price down → tick negative
    }

    function test_settleEpoch_doublesettleReverts() public {
        rollPastEpoch(DEFAULT_EPOCH_BLOCKS);
        hook.settleEpoch(poolKey, 0);
        vm.expectRevert(ProphetHook.EpochAlreadySettled.selector);
        hook.settleEpoch(poolKey, 0);
    }

    // -------- claim --------

    function test_claim_correctDirection_yieldsPositiveScore() public {
        // alice bets price DOWN (zeroForOne = true)
        swap(poolKey, true, -1e15, encodeTrader(alice));
        // bob also bets DOWN (more size so tick moves more)
        swap(poolKey, true, -5e15, encodeTrader(bob));

        rollPastEpoch(DEFAULT_EPOCH_BLOCKS);
        hook.settleEpoch(poolKey, 0);

        int256 aliceScore = hook.claim(poolKey, 0, alice);
        assertGt(aliceScore, 0, "alice predicted DOWN, price went DOWN, should be positive");

        // bob also positive (same direction)
        int256 bobScore = hook.claim(poolKey, 0, bob);
        assertGt(bobScore, 0);
    }

    function test_claim_wrongDirection_yieldsZeroOrNegativeScore() public {
        // carol bets price UP, but other swaps push it down
        swap(poolKey, false, -100_000, encodeTrader(carol));
        swap(poolKey, true, -10_000_000, encodeTrader(bob));

        rollPastEpoch(DEFAULT_EPOCH_BLOCKS);
        hook.settleEpoch(poolKey, 0);

        int256 carolScore = hook.claim(poolKey, 0, carol);
        assertLe(carolScore, 0, "carol's UP bet vs DOWN move = non-positive score");
    }

    function test_claim_mintsAlphaForPositiveScore() public {
        swap(poolKey, true, -10_000_000, encodeTrader(alice));
        rollPastEpoch(DEFAULT_EPOCH_BLOCKS);
        hook.settleEpoch(poolKey, 0);

        uint256 before = alpha.balanceOf(alice);
        hook.claim(poolKey, 0, alice);
        assertGt(alpha.balanceOf(alice), before, "alpha minted to positive-score trader");
    }

    function test_claim_doubleClaim_reverts() public {
        swap(poolKey, true, -1_000_000, encodeTrader(alice));
        rollPastEpoch(DEFAULT_EPOCH_BLOCKS);
        hook.settleEpoch(poolKey, 0);

        hook.claim(poolKey, 0, alice);
        vm.expectRevert(ProphetHook.EpochAlreadyClaimed.selector);
        hook.claim(poolKey, 0, alice);
    }

    function test_claim_nothingToClaim_reverts() public {
        rollPastEpoch(DEFAULT_EPOCH_BLOCKS);
        hook.settleEpoch(poolKey, 0);
        vm.expectRevert(ProphetHook.NothingToClaim.selector);
        hook.claim(poolKey, 0, alice);
    }

    function test_claim_updatesProphetCard() public {
        swap(poolKey, true, -5_000_000, encodeTrader(alice));
        rollPastEpoch(DEFAULT_EPOCH_BLOCKS);
        hook.settleEpoch(poolKey, 0);

        hook.claim(poolKey, 0, alice);

        uint256 cardId = card.tokenIdOf(alice);
        assertGt(cardId, 0);
        (uint64 totalClaims, uint64 wins, uint64 champs,,,,, ) = card.statsOf(cardId);
        assertEq(totalClaims, 1);
        assertEq(wins, 1);
        assertEq(champs, 1); // alice is the only claimant → automatic top prophet
    }

    function test_claim_topProphetReplacedByHigherScore() public {
        // alice makes a small correct prediction
        swap(poolKey, true, -1e15, encodeTrader(alice));
        // bob makes a much larger correct prediction
        swap(poolKey, true, -10e15, encodeTrader(bob));

        rollPastEpoch(DEFAULT_EPOCH_BLOCKS);
        hook.settleEpoch(poolKey, 0);

        hook.claim(poolKey, 0, alice);
        (,,,,, address topAfterAlice,) = hook.getEpochInfo(poolKey, 0);
        assertEq(topAfterAlice, alice);

        hook.claim(poolKey, 0, bob);
        (,,,,, address topAfterBob,) = hook.getEpochInfo(poolKey, 0);
        assertEq(topAfterBob, bob);
    }

    // -------- payout --------

    function test_payoutPot_revertsWhilewindowOpen() public {
        swap(poolKey, true, -5_000_000, encodeTrader(alice));
        rollPastEpoch(DEFAULT_EPOCH_BLOCKS);
        hook.settleEpoch(poolKey, 0);
        hook.claim(poolKey, 0, alice);

        vm.expectRevert(ProphetHook.ClaimWindowOpen.selector);
        hook.payoutPot(poolKey, 0);
    }

    function test_payoutPot_paysOutToTopProphet() public {
        swap(poolKey, true, -5_000_000, encodeTrader(alice));
        rollPastEpoch(DEFAULT_EPOCH_BLOCKS);
        hook.settleEpoch(poolKey, 0);
        hook.claim(poolKey, 0, alice);

        // jump past the claim window
        rollPastEpoch(DEFAULT_EPOCH_BLOCKS);

        uint256 c0Before = currency0.balanceOf(alice);
        uint256 c1Before = currency1.balanceOf(alice);

        hook.payoutPot(poolKey, 0);

        // alice swapped zeroForOne, so the pot was accumulated in currency0
        assertGt(currency0.balanceOf(alice), c0Before);
        assertEq(currency1.balanceOf(alice), c1Before);
    }

    function test_payoutPot_rollsForwardWhenNoProphet() public {
        // someone swaps but never claims → no prophet emerges
        swap(poolKey, true, -5_000_000, encodeTrader(alice));
        rollPastEpoch(DEFAULT_EPOCH_BLOCKS);
        hook.settleEpoch(poolKey, 0);

        rollPastEpoch(DEFAULT_EPOCH_BLOCKS);
        hook.payoutPot(poolKey, 0);

        (,,, uint128 pot0Next,,,) = hook.getEpochInfo(poolKey, 1);
        assertGt(uint256(pot0Next), 0, "unwon pot should roll forward");
    }

    // -------- agent multiplier --------

    function test_agentMultiplier_boostsScore() public {
        // register alice as an AI agent (the registry will be owned by us in tests)
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        registry.register{value: 0.1 ether}();

        swap(poolKey, true, -1_000_000, encodeTrader(alice));
        // bob is unregistered baseline
        swap(poolKey, true, -1_000_000, encodeTrader(bob));

        rollPastEpoch(DEFAULT_EPOCH_BLOCKS);
        hook.settleEpoch(poolKey, 0);

        int256 aliceScoreBoosted = hook.claim(poolKey, 0, alice);
        int256 bobScore = hook.claim(poolKey, 0, bob);

        // alice and bob have same notional & same tick approx, but alice has rep=500 → 1.025x multiplier
        // we expect alice's score >= bob's score, with strict greater when multiplier applies
        assertGe(aliceScoreBoosted, bobScore);
    }

    // -------- preview --------

    function test_previewScore_returnsZeroBeforeSettlement() public {
        swap(poolKey, true, -1_000_000, encodeTrader(alice));
        int256 preview = hook.previewScore(poolKey, 0, alice);
        assertEq(preview, 0);
    }

    function test_previewScore_matchesClaim() public {
        swap(poolKey, true, -5_000_000, encodeTrader(alice));
        rollPastEpoch(DEFAULT_EPOCH_BLOCKS);
        hook.settleEpoch(poolKey, 0);

        int256 preview = hook.previewScore(poolKey, 0, alice);
        int256 actual = hook.claim(poolKey, 0, alice);
        assertEq(preview, actual);
    }

    // -------- admin --------

    function test_setAlphaRewardsEnabled_blocksMint() public {
        hook.setAlphaRewardsEnabled(false);

        swap(poolKey, true, -10_000_000, encodeTrader(alice));
        rollPastEpoch(DEFAULT_EPOCH_BLOCKS);
        hook.settleEpoch(poolKey, 0);

        uint256 before = alpha.balanceOf(alice);
        hook.claim(poolKey, 0, alice);
        assertEq(alpha.balanceOf(alice), before);
    }

    // -------- $ALPHA stake → score multiplier --------

    function test_stakeMultiplier_boostsScore_proportionalToStake() public {
        // alice & bob make identical predictions, but alice stakes 100k ALPHA → 2.0x multiplier
        mintAndStake(alice, 100_000 ether);

        // identical entries
        swap(poolKey, true, -1e15, encodeTrader(alice));
        swap(poolKey, true, -1e15, encodeTrader(bob));

        rollPastEpoch(DEFAULT_EPOCH_BLOCKS);
        hook.settleEpoch(poolKey, 0);

        int256 aliceScore = hook.claim(poolKey, 0, alice);
        int256 bobScore = hook.claim(poolKey, 0, bob);

        // alice should be ~2x bob (modulo tiny differences from her swap happening first)
        assertGt(aliceScore, bobScore);
        // her boost is exactly 2.00x of the raw score
        // raw_alice_score / raw_bob_score ≈ 1, so boosted alice / bob ≈ 2.0
        assertGe(aliceScore, bobScore * 19 / 10, "expected ~2.0x boost from 100k ALPHA stake");
    }

    function test_stakeMultiplier_smallStakeGivesProportionalBoost() public {
        // 50k ALPHA = +50% (1.5x)
        mintAndStake(alice, 50_000 ether);
        assertEq(staking.getScoreMultiplierBps(alice), 15_000);
    }

    function test_stakeMultiplier_zeroStakeIsNoOp() public view {
        assertEq(staking.getScoreMultiplierBps(alice), 10_000);
    }

    function test_stakeMultiplier_capsAtTwoX() public {
        mintAndStake(alice, 1_000_000 ether); // way beyond cap
        assertEq(staking.getScoreMultiplierBps(alice), 20_000);
    }

    // -------- $ALPHA stake → skim discount --------

    function test_skimDiscount_reducesPotForStaker() public {
        mintAndStake(alice, 100_000 ether); // 50% discount

        // alice swap should pay 0.25% (50% off 0.50%) instead of 0.50%
        swap(poolKey, true, -1_000_000, encodeTrader(alice));
        (,,, uint128 potAlice,,,) = hook.getEpochInfo(poolKey, 0);
        // expected skim = 1M * 50bps * 50% = 2500 (instead of 5000)
        assertEq(uint256(potAlice), 2_500);

        // bob (no stake) → full 5000
        swap(poolKey, true, -1_000_000, encodeTrader(bob));
        (,,, uint128 potAfterBob,,,) = hook.getEpochInfo(poolKey, 0);
        assertEq(uint256(potAfterBob), 2_500 + 5_000);
    }

    function test_skimDiscount_halfStakeGivesPartialDiscount() public {
        mintAndStake(alice, 50_000 ether); // 25% discount → 0.375% skim
        swap(poolKey, true, -1_000_000, encodeTrader(alice));
        (,,, uint128 pot,,,) = hook.getEpochInfo(poolKey, 0);
        // expected = 1M * 50bps * 75% = 3750
        assertEq(uint256(pot), 3_750);
    }

    // -------- 70/20/10 pot split --------

    function test_payoutPot_splits_70_20_10() public {
        // alice will be top prophet; carol stakes ALPHA to receive staker share.
        mintAndStake(carol, 10_000 ether);
        // Small swap so the tick stays inside the LP range → donate() succeeds.
        swap(poolKey, true, -5_000_000, encodeTrader(alice));
        rollPastEpoch(DEFAULT_EPOCH_BLOCKS);
        hook.settleEpoch(poolKey, 0);
        hook.claim(poolKey, 0, alice);

        (,,, uint128 pot0,,,) = hook.getEpochInfo(poolKey, 0);
        uint128 expectedProphet = uint128((uint256(pot0) * 7000) / 10_000);
        uint128 expectedLP = uint128((uint256(pot0) * 2000) / 10_000);
        uint128 expectedStaker = pot0 - expectedProphet - expectedLP;

        rollPastEpoch(DEFAULT_EPOCH_BLOCKS);

        uint256 aliceBefore = currency0.balanceOf(alice);
        uint256 stakingBefore = currency0.balanceOf(address(staking));

        vm.expectEmit(true, true, false, true, address(hook));
        emit ProphetHook.PotSplit(poolKey.toId(), 0, expectedProphet, 0, expectedLP, 0, expectedStaker, 0);
        hook.payoutPot(poolKey, 0);

        assertEq(currency0.balanceOf(alice), aliceBefore + expectedProphet, "prophet got 70%");
        assertEq(currency0.balanceOf(address(staking)), stakingBefore + expectedStaker, "stakers got 10%");
        // LP share went into the pool via donate (verified by the PotSplit event + non-reverting payout).
    }

    function test_payoutPot_stakerShareFolds_whenNoStaking() public {
        hook.setAlphaStaking(address(0));

        swap(poolKey, true, -5_000_000, encodeTrader(alice));
        rollPastEpoch(DEFAULT_EPOCH_BLOCKS);
        hook.settleEpoch(poolKey, 0);
        hook.claim(poolKey, 0, alice);

        (,,, uint128 pot0,,,) = hook.getEpochInfo(poolKey, 0);
        // staker share collapses into prophet → prophet gets 70 + 10 = 80%
        uint128 expectedProphet = uint128((uint256(pot0) * 8000) / 10_000);
        rollPastEpoch(DEFAULT_EPOCH_BLOCKS);

        uint256 aliceBefore = currency0.balanceOf(alice);
        hook.payoutPot(poolKey, 0);
        assertEq(currency0.balanceOf(alice), aliceBefore + expectedProphet);
    }

    function test_payoutPot_lpShareFolds_whenNoLiquidityInRange() public {
        // Big swap pushes tick OUT of the [-120, 120] LP range → donate is infeasible
        // → LP share (20%) folds into prophet → prophet gets 90% (70 + 20).
        swap(poolKey, true, -10e15, encodeTrader(alice));
        rollPastEpoch(DEFAULT_EPOCH_BLOCKS);
        hook.settleEpoch(poolKey, 0);
        hook.claim(poolKey, 0, alice);

        (,,, uint128 pot0,,,) = hook.getEpochInfo(poolKey, 0);
        uint128 expectedProphet = uint128((uint256(pot0) * 9000) / 10_000);
        rollPastEpoch(DEFAULT_EPOCH_BLOCKS);

        uint256 aliceBefore = currency0.balanceOf(alice);
        hook.payoutPot(poolKey, 0);
        assertEq(currency0.balanceOf(alice), aliceBefore + expectedProphet);
    }

    function test_stakers_canClaimAccruedRewards() public {
        mintAndStake(carol, 10_000 ether);

        swap(poolKey, true, -5_000_000, encodeTrader(alice));
        rollPastEpoch(DEFAULT_EPOCH_BLOCKS);
        hook.settleEpoch(poolKey, 0);
        hook.claim(poolKey, 0, alice);
        rollPastEpoch(DEFAULT_EPOCH_BLOCKS);
        hook.payoutPot(poolKey, 0);

        uint256 carolBefore = currency0.balanceOf(carol);
        vm.prank(carol);
        uint256 paid = staking.claim(currency0);
        assertGt(paid, 0, "carol receives staker share");
        assertEq(currency0.balanceOf(carol), carolBefore + paid);
    }

    function test_stake_unstakeCooldown_works() public {
        mintAndStake(alice, 1_000 ether);

        vm.prank(alice);
        staking.requestUnstake(1_000 ether);

        vm.prank(alice);
        vm.expectRevert();
        staking.unstake();

        vm.warp(block.timestamp + 1 days);

        vm.prank(alice);
        staking.unstake();

        assertEq(staking.stakedOf(alice), 0);
        assertEq(alpha.balanceOf(alice), 1_000 ether);
    }
}
