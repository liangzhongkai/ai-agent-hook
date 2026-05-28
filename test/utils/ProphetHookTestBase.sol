// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Deployers} from "v4-test/utils/Deployers.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";

import {ProphetHook} from "../../src/ProphetHook.sol";
import {ProphetCard} from "../../src/ProphetCard.sol";
import {AlphaToken, IAlphaToken} from "../../src/AlphaToken.sol";
import {AlphaStaking} from "../../src/AlphaStaking.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Shared setUp + helpers for ProphetHook tests.
abstract contract ProphetHookTestBase is Test, Deployers {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;

    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    uint32 internal constant DEFAULT_EPOCH_BLOCKS = 64;
    uint16 internal constant DEFAULT_SKIM_BPS = 50; // 0.50%
    uint24 internal constant DEFAULT_LP_FEE_BPS = 2500; // 0.25%

    ProphetHook internal hook;
    AlphaToken internal alpha;
    ProphetCard internal card;
    AlphaStaking internal staking;

    address internal alice;
    address internal bob;
    address internal carol;

    function setUpProphetStack() internal {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");

        deployFreshManagerAndRouters();

        alpha = new AlphaToken();
        card = new ProphetCard();
        staking = new AlphaStaking(IAlphaToken(address(alpha)));

        address hookAddr = address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | HOOK_FLAGS));
        deployCodeTo(
            "ProphetHook.sol:ProphetHook",
            abi.encode(manager, address(alpha), address(card), address(this)),
            hookAddr
        );
        hook = ProphetHook(hookAddr);

        alpha.setMinter(hookAddr);
        card.setRecorder(hookAddr);
        staking.setNotifier(hookAddr);
        hook.setAlphaStaking(address(staking));
    }

    /// @notice Mint $ALPHA to `who` and stake it on their behalf.
    function mintAndStake(address who, uint256 amount) internal {
        alpha.mint(who, amount);
        vm.startPrank(who);
        IERC20(address(alpha)).approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();
    }

    /// @notice Configures + initializes a dynamic-fee pool keyed to ProphetHook, with seeded liquidity.
    function initProphetPool() internal returns (PoolKey memory poolKey) {
        deployMintAndApprove2Currencies();
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        hook.configurePool(poolKey, DEFAULT_EPOCH_BLOCKS, DEFAULT_SKIM_BPS, DEFAULT_LP_FEE_BPS);
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    function encodeTrader(address trader) internal pure returns (bytes memory) {
        return abi.encode(trader);
    }

    function rollPastEpoch(uint64 epochBlocks) internal {
        vm.roll(block.number + uint256(epochBlocks) + 1);
    }
}
