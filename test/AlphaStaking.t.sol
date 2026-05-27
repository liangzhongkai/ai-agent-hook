// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {AlphaToken, IAlphaToken} from "../src/AlphaToken.sol";
import {AlphaStaking} from "../src/AlphaStaking.sol";

contract AlphaStakingTest is Test {
    AlphaToken internal alpha;
    AlphaStaking internal staking;
    MockERC20 internal rewardToken;
    Currency internal rewardCurrency;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal notifier = makeAddr("notifier");

    function setUp() public {
        alpha = new AlphaToken();
        staking = new AlphaStaking(IAlphaToken(address(alpha)));
        staking.setNotifier(notifier);
        rewardToken = new MockERC20("R", "R", 18);
        rewardCurrency = Currency.wrap(address(rewardToken));
    }

    function _stake(address who, uint256 amount) internal {
        alpha.mint(who, amount);
        vm.startPrank(who);
        IERC20(address(alpha)).approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();
    }

    function _notify(uint256 amount) internal {
        rewardToken.mint(address(staking), amount);
        vm.prank(notifier);
        staking.notifyReward(rewardCurrency, amount);
    }

    function test_stake_increasesTotal() public {
        _stake(alice, 100 ether);
        assertEq(staking.totalStaked(), 100 ether);
        assertEq(staking.stakedOf(alice), 100 ether);
    }

    function test_unstake_requiresCooldown() public {
        _stake(alice, 100 ether);
        vm.prank(alice);
        staking.requestUnstake(100 ether);

        vm.prank(alice);
        vm.expectRevert(AlphaStaking.CooldownActive.selector);
        staking.unstake();

        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        staking.unstake();

        assertEq(staking.stakedOf(alice), 0);
    }

    function test_unstake_revertsWithoutRequest() public {
        _stake(alice, 100 ether);
        vm.prank(alice);
        vm.expectRevert(AlphaStaking.NoUnstakeRequest.selector);
        staking.unstake();
    }

    function test_rewards_proRataSplit() public {
        _stake(alice, 100 ether);
        _stake(bob, 300 ether); // 1:3 split

        _notify(400 ether);

        assertEq(staking.earned(alice, rewardCurrency), 100 ether);
        assertEq(staking.earned(bob, rewardCurrency), 300 ether);
    }

    function test_rewards_claimTransfersTokens() public {
        _stake(alice, 100 ether);
        _notify(100 ether);

        vm.prank(alice);
        uint256 paid = staking.claim(rewardCurrency);
        assertEq(paid, 100 ether);
        assertEq(rewardToken.balanceOf(alice), 100 ether);
    }

    function test_rewards_doubleClaimReturnsZero() public {
        _stake(alice, 100 ether);
        _notify(100 ether);
        vm.prank(alice);
        staking.claim(rewardCurrency);
        vm.prank(alice);
        uint256 paid = staking.claim(rewardCurrency);
        assertEq(paid, 0);
    }

    function test_rewards_stakeChangeSnapshotsAccrual() public {
        _stake(alice, 100 ether);
        _notify(100 ether); // alice earns 100

        _stake(bob, 100 ether); // bob joins; alice's 100 should be preserved
        _notify(100 ether); // alice & bob each earn 50

        assertEq(staking.earned(alice, rewardCurrency), 150 ether);
        assertEq(staking.earned(bob, rewardCurrency), 50 ether);
    }

    function test_rewards_notifyBeforeAnyStaker_isLost() public {
        // No stakers yet → tokens sit untracked (covered by admin rescue or future stakers).
        _notify(50 ether); // no effect since totalStaked == 0
        _stake(alice, 100 ether);
        _notify(100 ether);
        assertEq(staking.earned(alice, rewardCurrency), 100 ether);
    }

    function test_multiplier_curveMonotonic() public {
        _stake(alice, 1 ether);
        uint256 m1 = staking.getScoreMultiplierBps(alice);
        _stake(alice, 99 ether);
        uint256 m100 = staking.getScoreMultiplierBps(alice);
        _stake(alice, 100_000 ether - 100 ether);
        uint256 mFull = staking.getScoreMultiplierBps(alice);

        assertLe(m1, m100);
        assertLe(m100, mFull);
        assertEq(mFull, 20_000); // 2.00x cap
    }

    function test_discount_curveMonotonic() public {
        _stake(alice, 50_000 ether);
        assertEq(staking.getSkimDiscountBps(alice), 2_500); // 25%
        _stake(alice, 50_000 ether);
        assertEq(staking.getSkimDiscountBps(alice), 5_000); // 50%
        _stake(alice, 100_000 ether); // beyond cap
        assertEq(staking.getSkimDiscountBps(alice), 5_000); // still 50%
    }

    function test_notify_revertsForNonNotifier() public {
        rewardToken.mint(address(staking), 1 ether);
        vm.expectRevert(AlphaStaking.NotNotifier.selector);
        staking.notifyReward(rewardCurrency, 1 ether);
    }
}
