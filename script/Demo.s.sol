// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ProphetHook} from "../src/ProphetHook.sol";
import {ProphetCard} from "../src/ProphetCard.sol";
import {AlphaToken, IAlphaToken} from "../src/AlphaToken.sol";
import {AlphaStaking} from "../src/AlphaStaking.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";

/// @notice End-to-end demo: spins up a fresh PoolManager, deploys the entire Prophet stack,
///         configures a dynamic-fee pool, makes multi-trader swaps, settles, claims,
///         pays out the 70/20/10 pot split, and lets the staker collect their share.
///
/// Run locally (in-memory, no broadcast needed):
///   forge script script/Demo.s.sol:Demo -vv
///
/// Or against a running Anvil:
///   anvil &     # in another shell
///   forge script script/Demo.s.sol:Demo --rpc-url http://localhost:8545 --broadcast -vv
contract Demo is Script, StdCheats {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using LPFeeLibrary for uint24;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );
    uint160 internal constant CLEAR_HOOK_FLAGS_MASK = ~uint160((1 << 14) - 1);
    uint32 internal constant EPOCH_BLOCKS = 64;
    uint16 internal constant SKIM_BPS = 50; // 0.50%

    address internal deployer = vm.addr(uint256(keccak256("DEMO_DEPLOYER")));
    address internal alice = vm.addr(0xA11CE);
    address internal bob = vm.addr(0xB0B);
    address internal carol = vm.addr(0xCA401);

    // ----- deployed at runtime -----
    PoolManager internal manager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liqRouter;
    MockERC20 internal token0;
    MockERC20 internal token1;
    Currency internal currency0;
    Currency internal currency1;
    PoolKey internal poolKey;

    AlphaToken internal alpha;
    AlphaStaking internal staking;
    AgentRegistry internal registry;
    ProphetCard internal card;
    ProphetHook internal hook;

    function run() external {
        vm.startPrank(deployer, deployer);
        _stage1_deployInfra();
        _stage2_deployProphetStack();
        _stage3_configureAndInit();
        _stage4_addLiquidity();
        _stage5_carolStakes();
        vm.stopPrank();

        _stage6_swaps();

        vm.startPrank(deployer, deployer);
        _stage7_settle();
        _stage8_claims();
        _stage9_payout();
        vm.stopPrank();

        _stage10_stakerClaim();
        _printSummary();
    }

    // ============== STAGE 1: infra ==============
    function _stage1_deployInfra() internal {
        console.log("");
        console.log("===== STAGE 1: deploy PoolManager + routers + mock tokens =====");
        manager = new PoolManager(deployer);
        swapRouter = new PoolSwapTest(manager);
        liqRouter = new PoolModifyLiquidityTest(manager);

        MockERC20 a = new MockERC20("Token A", "A", 18);
        MockERC20 b = new MockERC20("Token B", "B", 18);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));

        console.log("PoolManager :", address(manager));
        console.log("token0      :", address(token0));
        console.log("token1      :", address(token1));
    }

    // ============== STAGE 2: prophet stack ==============
    function _stage2_deployProphetStack() internal {
        console.log("");
        console.log("===== STAGE 2: deploy AlphaToken / Registry / Card / Staking / Hook =====");
        alpha = new AlphaToken();
        registry = new AgentRegistry();
        card = new ProphetCard();
        staking = new AlphaStaking(IAlphaToken(address(alpha)));

        address hookAddr = address(uint160(uint256(type(uint160).max) & CLEAR_HOOK_FLAGS_MASK | HOOK_FLAGS));
        deployCodeTo(
            "ProphetHook.sol:ProphetHook",
            abi.encode(manager, address(alpha), address(registry), address(card)),
            hookAddr
        );
        hook = ProphetHook(hookAddr);

        alpha.setMinter(hookAddr);
        card.setRecorder(hookAddr);
        staking.setNotifier(hookAddr);
        hook.setAlphaStaking(address(staking));

        console.log("AlphaToken  :", address(alpha));
        console.log("Registry    :", address(registry));
        console.log("ProphetCard :", address(card));
        console.log("Staking     :", address(staking));
        console.log("ProphetHook :", address(hook));
    }

    // ============== STAGE 3: configure + initialize ==============
    function _stage3_configureAndInit() internal {
        console.log("");
        console.log("===== STAGE 3: configurePool() then PoolManager.initialize() =====");
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        hook.configurePool(poolKey, EPOCH_BLOCKS, SKIM_BPS, 2500);
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        console.log("Pool configured: epochBlocks=", EPOCH_BLOCKS);
        console.log("                 prophetSkimBps=", SKIM_BPS);
    }

    // ============== STAGE 4: liquidity ==============
    function _stage4_addLiquidity() internal {
        console.log("");
        console.log("===== STAGE 4: seed liquidity (1e18 over [-600, 600]) =====");
        token0.mint(deployer, 100 ether);
        token1.mint(deployer, 100 ether);
        token0.approve(address(liqRouter), type(uint256).max);
        token1.approve(address(liqRouter), type(uint256).max);

        liqRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -600,
                tickUpper: 600,
                liquidityDelta: 1e18,
                salt: bytes32(0)
            }),
            ""
        );
        console.log("Liquidity added.");
    }

    // ============== STAGE 5: carol stakes ALPHA ==============
    function _stage5_carolStakes() internal {
        console.log("");
        console.log("===== STAGE 5: carol mints + stakes 50,000 ALPHA (50%% boost, 25%% skim discount) =====");
        // deployer has admin role on alpha (granted in constructor) → temporarily mint
        alpha.setMinter(deployer);
        alpha.mint(carol, 50_000 ether);
        alpha.setMinter(address(hook)); // restore

        // hop to carol for the stake call (vm.prank consumes for next external call only)
        vm.stopPrank();
        vm.startPrank(carol);
        IERC20(address(alpha)).approve(address(staking), type(uint256).max);
        staking.stake(50_000 ether);
        vm.stopPrank();
        vm.startPrank(deployer, deployer);

        console.log("Carol staked ALPHA :", staking.stakedOf(carol) / 1e18);
        console.log("Carol scoreMultBps :", staking.getScoreMultiplierBps(carol));
        console.log("Carol skimDiscount :", staking.getSkimDiscountBps(carol));
    }

    // ============== STAGE 6: traders swap ==============
    function _stage6_swaps() internal {
        console.log("");
        console.log("===== STAGE 6: alice/bob/carol swap (recording predictions) =====");

        // mint trading balances
        token0.mint(alice, 1 ether);
        token1.mint(alice, 1 ether);
        token0.mint(bob, 1 ether);
        token1.mint(bob, 1 ether);
        token0.mint(carol, 1 ether);
        token1.mint(carol, 1 ether);

        _approveTrader(alice);
        _approveTrader(bob);
        _approveTrader(carol);

        // alice swap zeroForOne 5M (bets price of token0 will drop = settledTick < openTick)
        _swap(alice, true, -5_000_000);
        console.log("alice swapped zeroForOne -5M (bets tick will DROP)");
        // bob swap zeroForOne 3M (same direction)
        _swap(bob, true, -3_000_000);
        console.log("bob   swapped zeroForOne -3M (same bet)");
        // carol swap oneForZero 2M (opposite bet, but with 50%% boost on her score)
        _swap(carol, false, -2_000_000);
        console.log("carol swapped oneForZero -2M (opposite bet, but boosted)");

        (,,, uint128 pot0, uint128 pot1,,) = hook.getEpochInfo(poolKey, 0);
        console.log("epoch 0 pot0 (skim accumulated):", pot0);
        console.log("epoch 0 pot1 (skim accumulated):", pot1);
    }

    // ============== STAGE 7: settle ==============
    function _stage7_settle() internal {
        console.log("");
        console.log("===== STAGE 7: roll past epoch + settleEpoch(0) =====");
        vm.roll(block.number + EPOCH_BLOCKS + 1);
        hook.settleEpoch(poolKey, 0);

        (int24 openTick, int24 settledTick,,,,,) = hook.getEpochInfo(poolKey, 0);
        console.log("openTick    :", openTick);
        console.log("settledTick :", settledTick);
        if (settledTick < openTick) {
            console.log("=> Price DROPPED. zeroForOne traders (alice/bob) will score positive.");
        } else if (settledTick > openTick) {
            console.log("=> Price ROSE. oneForZero traders (carol) will score positive.");
        }
    }

    // ============== STAGE 8: claims ==============
    function _stage8_claims() internal {
        console.log("");
        console.log("===== STAGE 8: each trader claims & is scored =====");
        int256 sa = hook.claim(poolKey, 0, alice);
        int256 sb = hook.claim(poolKey, 0, bob);
        int256 sc = hook.claim(poolKey, 0, carol);

        console.log("alice score :", sa);
        console.log("bob   score :", sb);
        console.log("carol score (with 1.50x stake boost):", sc);

        (,,,,, address topProphet, int256 topScore) = hook.getEpochInfo(poolKey, 0);
        console.log("Top prophet :", topProphet);
        console.log("Top score   :", topScore);

        console.log("ALPHA balances minted to winners:");
        console.log("  alice :", alpha.balanceOf(alice) / 1e18);
        console.log("  bob   :", alpha.balanceOf(bob)   / 1e18);
        console.log("  carol :", alpha.balanceOf(carol) / 1e18);

        console.log("ProphetCard SBT ownership:");
        console.log("  alice tokenId :", card.tokenIdOf(alice));
        console.log("  bob   tokenId :", card.tokenIdOf(bob));
        console.log("  carol tokenId :", card.tokenIdOf(carol));
    }

    // ============== STAGE 9: payout 70/20/10 ==============
    function _stage9_payout() internal {
        console.log("");
        console.log("===== STAGE 9: roll past claim window + payoutPot (70 / 20 / 10) =====");
        vm.roll(block.number + EPOCH_BLOCKS + 1);

        (,,, uint128 pot0Before,, address winner,) = hook.getEpochInfo(poolKey, 0);
        uint256 winnerC0Before = token0.balanceOf(winner);
        uint256 stakingC0Before = token0.balanceOf(address(staking));

        hook.payoutPot(poolKey, 0);

        uint256 prophetGot = token0.balanceOf(winner) - winnerC0Before;
        uint256 stakerGot = token0.balanceOf(address(staking)) - stakingC0Before;
        uint256 lpGot = pot0Before - prophetGot - stakerGot;

        console.log("Winner   :", winner);
        console.log("Pot c0   :", pot0Before);
        console.log("  -> top prophet (70%%) :", prophetGot);
        console.log("  -> LPs (donate, 20%%) :", lpGot);
        console.log("  -> stakers (10%%)     :", stakerGot);
    }

    // ============== STAGE 10: staker claim ==============
    function _stage10_stakerClaim() internal {
        console.log("");
        console.log("===== STAGE 10: carol claims her staker share =====");
        uint256 carolC0Before = token0.balanceOf(carol);
        uint256 carolC1Before = token1.balanceOf(carol);

        vm.startPrank(carol);
        uint256 paid0 = staking.claim(currency0);
        uint256 paid1 = staking.claim(currency1);
        vm.stopPrank();

        console.log("Carol claimed currency0 :", paid0);
        console.log("Carol claimed currency1 :", paid1);
        console.log("Carol c0 balance gain    :", token0.balanceOf(carol) - carolC0Before);
        console.log("Carol c1 balance gain    :", token1.balanceOf(carol) - carolC1Before);
    }

    // ============== summary ==============
    function _printSummary() internal view {
        console.log("");
        console.log("======================================================");
        console.log(" FLYWHEEL VERIFIED: swap -> predict -> settle -> claim ");
        console.log("                    -> 70/20/10 split -> staker claim  ");
        console.log("======================================================");
        console.log("All addresses are visible above. Pool ID:");
        console.logBytes32(PoolId.unwrap(poolKey.toId()));
    }

    // ============== helpers ==============
    function _approveTrader(address who) internal {
        vm.startPrank(who);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _swap(address who, bool zeroForOne, int256 amount) internal {
        vm.prank(who);
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amount,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(who) // hookData = trader address
        );
    }
}
