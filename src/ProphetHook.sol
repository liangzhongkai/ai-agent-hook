// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseHook} from "./base/BaseHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IAlphaToken} from "./AlphaToken.sol";
import {IAlphaStaking} from "./AlphaStaking.sol";
import {IProphetCard} from "./ProphetCard.sol";

/// @title PROPHET HOOK / 先知池
/// @notice A Uniswap v4 hook that turns every swap into an implicit directional prediction.
///         Traders whose swap direction is later confirmed by the pool's own tick movement
///         earn a share of a "Prophet Pot" skimmed from swap fees, plus $ALPHA emissions
///         and an evolving on-chain SVG Prophet Card (SBT).
///
/// @dev    Mechanism (O(1) per swap):
///         beforeSwap:  accumulate (sign * size, sign * size * tick) into per-(trader, epoch)
///                      and skim `prophetSkimBps` of the specified amount into an ERC-6909
///                      claim held by this hook.
///         epoch close: `settleEpoch` snapshots the current tick as the truth.
///         claim:       score = settledTick * netSize - weightedEntry.
///                      Positive scores mint $ALPHA and update the trader's ProphetCard.
///         payout:      after the claim window, the recorded top prophet takes the entire pot.
contract ProphetHook is BaseHook, Ownable, IUnlockCallback {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    // ---------------- errors ----------------
    error EpochAlreadySettled();
    error EpochNotYetEnded();
    error EpochAlreadyClaimed();
    error PoolNotConfigured();
    error InvalidConfig();
    error SkimTooLarge();
    error NothingToClaim();
    error ClaimWindowOpen();
    error PoolAlreadyConfigured();
    error PotAlreadyPaid();
    error UnauthorizedUnlocker();

    // ---------------- events ----------------
    event PoolConfigured(PoolId indexed poolId, uint32 epochBlocks, uint16 prophetSkimBps, uint24 baseLpFeeBps);
    event EpochOpened(PoolId indexed poolId, uint64 indexed epoch, int24 openTick, uint64 startBlock);
    event EpochSettled(
        PoolId indexed poolId, uint64 indexed epoch, int24 settledTick, uint128 pot0, uint128 pot1
    );
    event PredictionRecorded(
        PoolId indexed poolId, uint64 indexed epoch, address indexed trader, int24 entryTick, int256 signedSize
    );
    event Claimed(
        PoolId indexed poolId,
        uint64 indexed epoch,
        address indexed trader,
        int256 score,
        uint256 alphaMinted,
        bool isNewTopProphet
    );
    event PotPaidOut(
        PoolId indexed poolId, uint64 indexed epoch, address indexed topProphet, uint128 amount0, uint128 amount1
    );
    event PotSplit(
        PoolId indexed poolId,
        uint64 indexed epoch,
        uint128 prophet0,
        uint128 prophet1,
        uint128 lp0,
        uint128 lp1,
        uint128 staker0,
        uint128 staker1
    );

    // ---------------- constants ----------------
    /// @notice Maximum per-trader notional that can count toward score in one epoch.
    uint128 public constant PER_EPOCH_NOTIONAL_CAP = type(uint96).max;
    /// @notice $ALPHA emitted per epoch (cap, distributed via log-scaling).
    uint256 public constant ALPHA_PER_EPOCH = 1_000 ether;
    /// @notice Minimum swap input to be counted as a prophecy (filter dust).
    uint128 public constant MIN_SIZE_TO_COUNT = 1_000;
    /// @notice Epochs after settlement during which the leader can still be dethroned.
    uint64 public constant CLAIM_WINDOW_EPOCHS = 1;
    /// @notice Hard cap on prophet skim (in bps) configurable per pool.
    uint16 public constant MAX_PROPHET_SKIM_BPS = 100; // 1.00%
    /// @notice Soft minimum on epoch length (blocks). Stops trivially short epochs.
    uint32 public constant MIN_EPOCH_BLOCKS = 32;

    /// @notice Top prophet's share of the pot in bps (out of 10000).
    uint16 public constant TOP_PROPHET_BPS = 7000;
    /// @notice LPs' share of the pot in bps — donated back to in-range LPs via PoolManager.donate.
    uint16 public constant LP_DONATE_BPS = 2000;
    /// @notice $ALPHA stakers' share of the pot in bps — sent to AlphaStaking + notified for pro-rata distribution.
    uint16 public constant STAKER_BPS = 1000;

    // ---------------- types ----------------
    struct PoolConfig {
        uint32 epochBlocks;
        uint16 prophetSkimBps;
        uint24 baseLpFeeBps;
        uint64 firstEpochStartBlock;
        bool configured;
    }

    struct EpochState {
        int24 openTick;
        int24 settledTick;
        uint64 settledAtBlock;
        bool settled;
        uint128 pot0;
        uint128 pot1;
        address topProphet;
        int256 topScore;
        bool potPaid;
    }

    struct TraderEpoch {
        int128 netSize;
        int128 weightedEntry;
        uint128 absNotional;
        bool claimed;
    }

    // ---------------- storage ----------------
    mapping(PoolId => PoolConfig) public poolConfig;
    mapping(PoolId => uint64) public currentEpoch;
    mapping(PoolId => mapping(uint64 => EpochState)) public epochs;
    mapping(PoolId => mapping(uint64 => mapping(address => TraderEpoch))) public positions;

    IAlphaToken public alphaToken;
    IProphetCard public prophetCard;
    /// @notice Optional. If set & has stakers, drives skim discount, score multiplier, and pot share.
    IAlphaStaking public alphaStaking;

    bool public alphaRewardsEnabled = true;

    constructor(IPoolManager _poolManager, address _alphaToken, address _prophetCard, address owner_)
        BaseHook(_poolManager)
        Ownable(owner_)
    {
        alphaToken = IAlphaToken(_alphaToken);
        prophetCard = IProphetCard(_prophetCard);
    }

    // ---------------- permissions ----------------
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------- pool init ----------------
    /// @dev We require dynamic-fee pools so we can override the LP fee on every swap.
    ///      Pool creators MUST call `configurePool` BEFORE `initialize`.
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal pure override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert InvalidConfig();
        return IHooks.beforeInitialize.selector;
    }

    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        PoolId pid = key.toId();
        PoolConfig storage cfg = poolConfig[pid];
        if (cfg.configured) {
            // Anchor epoch numbering at this block; open epoch 0 with the initial tick.
            cfg.firstEpochStartBlock = uint64(block.number);
            EpochState storage e = epochs[pid][0];
            e.openTick = tick;
            emit EpochOpened(pid, 0, tick, uint64(block.number));
        }
        return IHooks.afterInitialize.selector;
    }

    /// @notice Pool creator registers epoch length + skim rate BEFORE pool initialization.
    ///         First-writer-wins; cannot be reconfigured (immutability for trust).
    function configurePool(PoolKey calldata key, uint32 epochBlocks, uint16 prophetSkimBps, uint24 baseLpFeeBps)
        external
    {
        if (!key.fee.isDynamicFee()) revert InvalidConfig();
        if (epochBlocks < MIN_EPOCH_BLOCKS) revert InvalidConfig();
        if (prophetSkimBps > MAX_PROPHET_SKIM_BPS) revert SkimTooLarge();
        if (baseLpFeeBps > LPFeeLibrary.MAX_LP_FEE) revert InvalidConfig();

        PoolId pid = key.toId();
        PoolConfig storage cfg = poolConfig[pid];
        if (cfg.configured) revert PoolAlreadyConfigured();

        cfg.epochBlocks = epochBlocks;
        cfg.prophetSkimBps = prophetSkimBps;
        cfg.baseLpFeeBps = baseLpFeeBps;
        cfg.configured = true;

        emit PoolConfigured(pid, epochBlocks, prophetSkimBps, baseLpFeeBps);
    }

    // ---------------- swap path ----------------
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        SwapCtx memory ctx = _prepareCtx(key, params, hookData, sender);
        if (ctx.absAmount >= MIN_SIZE_TO_COUNT) {
            _recordPrediction(ctx.pid, ctx.epoch, ctx.trader, ctx.tick, ctx.absAmount, ctx.sign);
        }
        BeforeSwapDelta delta = _takeProphetSkim(ctx, key, params);
        return (IHooks.beforeSwap.selector, delta, uint24(ctx.baseLpFeeBps) | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @dev Bundled context to keep `_beforeSwap`'s stack shallow.
    struct SwapCtx {
        PoolId pid;
        uint64 epoch;
        int24 tick;
        uint256 absAmount;
        int256 sign;
        address trader;
        uint16 skimBps;
        uint24 baseLpFeeBps;
    }

    function _prepareCtx(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData,
        address sender
    ) internal returns (SwapCtx memory ctx) {
        ctx.pid = key.toId();
        PoolConfig memory cfg = poolConfig[ctx.pid];
        if (!cfg.configured) revert PoolNotConfigured();
        ctx.skimBps = cfg.prophetSkimBps;
        ctx.baseLpFeeBps = cfg.baseLpFeeBps;
        ctx.epoch = _maybeRollEpoch(ctx.pid, cfg);
        (, ctx.tick,,) = poolManager.getSlot0(ctx.pid);
        ctx.absAmount =
            params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        ctx.sign = params.zeroForOne ? int256(-1) : int256(1);
        ctx.trader = _decodeTrader(hookData, sender);
    }

    function _takeProphetSkim(SwapCtx memory ctx, PoolKey calldata key, IPoolManager.SwapParams calldata params)
        internal
        returns (BeforeSwapDelta)
    {
        uint128 skim = _computeEffectiveSkim(ctx.absAmount, ctx.skimBps, ctx.trader);
        if (skim == 0) return BeforeSwapDeltaLibrary.ZERO_DELTA;

        Currency specified = _specifiedCurrency(key, params);
        // Convert the credit into an ERC-6909 claim held by this hook so it persists.
        // `mint` debits the hook (-skim); the BeforeSwapDelta we return credits the hook (+skim).
        // Net hook delta is zero; the user pays `skim` of the specified currency.
        poolManager.mint(address(this), specified.toId(), skim);

        EpochState storage e = epochs[ctx.pid][ctx.epoch];
        if (Currency.unwrap(specified) == Currency.unwrap(key.currency0)) {
            e.pot0 += skim;
        } else {
            e.pot1 += skim;
        }
        return toBeforeSwapDelta(int128(skim), int128(0));
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        PoolId pid = key.toId();
        PoolConfig memory cfg = poolConfig[pid];
        if (cfg.configured) _maybeRollEpoch(pid, cfg);
        return (IHooks.afterSwap.selector, 0);
    }

    // ---------------- epoch lifecycle ----------------
    function _maybeRollEpoch(PoolId pid, PoolConfig memory cfg) internal returns (uint64 epoch) {
        epoch = currentEpoch[pid];
        uint64 epochEnd = cfg.firstEpochStartBlock + uint64(cfg.epochBlocks) * (epoch + 1);
        if (uint64(block.number) >= epochEnd) {
            uint64 newEpoch;
            unchecked {
                newEpoch = epoch + 1;
            }
            (, int24 tick,,) = poolManager.getSlot0(pid);
            EpochState storage ne = epochs[pid][newEpoch];
            ne.openTick = tick;
            currentEpoch[pid] = newEpoch;
            emit EpochOpened(pid, newEpoch, tick, uint64(block.number));
            epoch = newEpoch;
        }
    }

    /// @notice Anyone can settle a finished epoch. Settled tick = current tick at settlement time.
    ///         (TWAP upgrade path is left as a hook config knob for v2; MVP uses spot.)
    function settleEpoch(PoolKey calldata key, uint64 epoch) external {
        PoolId pid = key.toId();
        PoolConfig memory cfg = poolConfig[pid];
        if (!cfg.configured) revert PoolNotConfigured();
        uint64 epochEnd = cfg.firstEpochStartBlock + uint64(cfg.epochBlocks) * (epoch + 1);
        if (uint64(block.number) < epochEnd) revert EpochNotYetEnded();

        EpochState storage e = epochs[pid][epoch];
        if (e.settled) revert EpochAlreadySettled();

        (, int24 tick,,) = poolManager.getSlot0(pid);
        e.settledTick = tick;
        e.settled = true;
        e.settledAtBlock = uint64(block.number);

        emit EpochSettled(pid, epoch, tick, e.pot0, e.pot1);
    }

    // ---------------- claim ----------------
    function claim(PoolKey calldata key, uint64 epoch, address trader) external returns (int256 score) {
        PoolId pid = key.toId();
        EpochState storage e = epochs[pid][epoch];
        if (!e.settled) revert EpochNotYetEnded();

        TraderEpoch storage pos = positions[pid][epoch][trader];
        if (pos.claimed) revert EpochAlreadyClaimed();
        if (pos.absNotional == 0) revert NothingToClaim();

        score = _computeScore(e.settledTick, pos.netSize, pos.weightedEntry);

        // optional $ALPHA stake multiplier (in [1.00x, 2.00x])
        if (address(alphaStaking) != address(0)) {
            uint256 stakeMultBps = alphaStaking.getScoreMultiplierBps(trader); // 10000..20000
            if (stakeMultBps != 10_000) {
                score = (score * int256(stakeMultBps)) / 10_000;
            }
        }

        pos.claimed = true;

        bool isNewTop;
        if (score > e.topScore) {
            e.topScore = score;
            e.topProphet = trader;
            isNewTop = true;
        }

        uint256 alphaMinted;
        if (score > 0 && alphaRewardsEnabled && address(alphaToken) != address(0)) {
            uint256 raw = uint256(score) / 1e6;
            alphaMinted = raw > ALPHA_PER_EPOCH ? ALPHA_PER_EPOCH : raw;
            if (alphaMinted > 0) {
                alphaToken.mint(trader, alphaMinted);
            }
        }

        if (address(prophetCard) != address(0)) {
            prophetCard.recordClaim(trader, pid, epoch, score, isNewTop);
        }

        emit Claimed(pid, epoch, trader, score, alphaMinted, isNewTop);
    }

    /// @notice After the claim window, distributes the pot in a 70/20/10 split:
    ///         70% → top prophet · 20% → LPs (donate) · 10% → $ALPHA stakers (pro-rata)
    ///         If no prophet emerged, the entire pot rolls forward to the next epoch.
    ///         If LP donate is infeasible (no in-range liquidity) or staking is unset,
    ///         that share folds back into the prophet's share — pot never gets stranded.
    function payoutPot(PoolKey calldata key, uint64 epoch) external {
        PoolId pid = key.toId();
        PoolConfig memory cfg = poolConfig[pid];
        EpochState storage e = epochs[pid][epoch];
        if (!e.settled) revert EpochNotYetEnded();
        if (e.potPaid) revert PotAlreadyPaid();

        uint64 windowEnd = e.settledAtBlock + uint64(cfg.epochBlocks) * CLAIM_WINDOW_EPOCHS;
        if (uint64(block.number) < windowEnd) revert ClaimWindowOpen();

        address winner = e.topProphet;
        uint128 amt0 = e.pot0;
        uint128 amt1 = e.pot1;

        if (winner == address(0)) {
            EpochState storage next = epochs[pid][epoch + 1];
            next.pot0 += amt0;
            next.pot1 += amt1;
        } else if (amt0 > 0 || amt1 > 0) {
            PayoutSplit memory s = _splitPot(amt0, amt1);
            emit PotSplit(pid, epoch, s.prophet0, s.prophet1, s.lp0, s.lp1, s.staker0, s.staker1);
            poolManager.unlock(abi.encode(key, winner, s));
        }

        e.potPaid = true;
        emit PotPaidOut(pid, epoch, winner, amt0, amt1);
    }

    struct PayoutSplit {
        uint128 prophet0;
        uint128 prophet1;
        uint128 lp0;
        uint128 lp1;
        uint128 staker0;
        uint128 staker1;
    }

    function _splitPot(uint128 amt0, uint128 amt1) internal pure returns (PayoutSplit memory s) {
        s.lp0 = uint128((uint256(amt0) * LP_DONATE_BPS) / 10_000);
        s.staker0 = uint128((uint256(amt0) * STAKER_BPS) / 10_000);
        s.prophet0 = amt0 - s.lp0 - s.staker0;
        s.lp1 = uint128((uint256(amt1) * LP_DONATE_BPS) / 10_000);
        s.staker1 = uint128((uint256(amt1) * STAKER_BPS) / 10_000);
        s.prophet1 = amt1 - s.lp1 - s.staker1;
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert UnauthorizedUnlocker();
        (PoolKey memory key, address winner, PayoutSplit memory s) =
            abi.decode(data, (PoolKey, address, PayoutSplit));

        address staking = address(alphaStaking);
        bool hasStaking = staking != address(0);
        // Donate requires at least one in-range LP; if liquidity == 0, fold LP share into prophet's.
        bool canDonate = (s.lp0 > 0 || s.lp1 > 0) && poolManager.getLiquidity(key.toId()) > 0;

        if (!canDonate) {
            s.prophet0 += s.lp0;
            s.prophet1 += s.lp1;
            s.lp0 = 0;
            s.lp1 = 0;
        }
        if (!hasStaking) {
            s.prophet0 += s.staker0;
            s.prophet1 += s.staker1;
            s.staker0 = 0;
            s.staker1 = 0;
        }

        _payProphet(key, winner, s.prophet0, s.prophet1);
        if (canDonate) _donateToLPs(key, s.lp0, s.lp1);
        if (hasStaking) _payStakers(key, staking, s.staker0, s.staker1);

        return "";
    }

    function _payProphet(PoolKey memory key, address winner, uint128 amt0, uint128 amt1) internal {
        if (amt0 > 0) {
            poolManager.burn(address(this), key.currency0.toId(), amt0);
            poolManager.take(key.currency0, winner, amt0);
        }
        if (amt1 > 0) {
            poolManager.burn(address(this), key.currency1.toId(), amt1);
            poolManager.take(key.currency1, winner, amt1);
        }
    }

    function _donateToLPs(PoolKey memory key, uint128 amt0, uint128 amt1) internal {
        if (amt0 > 0) poolManager.burn(address(this), key.currency0.toId(), amt0);
        if (amt1 > 0) poolManager.burn(address(this), key.currency1.toId(), amt1);
        poolManager.donate(key, uint256(amt0), uint256(amt1), "");
    }

    function _payStakers(PoolKey memory key, address staking, uint128 amt0, uint128 amt1) internal {
        if (amt0 > 0) {
            poolManager.burn(address(this), key.currency0.toId(), amt0);
            poolManager.take(key.currency0, staking, amt0);
            IAlphaStaking(staking).notifyReward(key.currency0, amt0);
        }
        if (amt1 > 0) {
            poolManager.burn(address(this), key.currency1.toId(), amt1);
            poolManager.take(key.currency1, staking, amt1);
            IAlphaStaking(staking).notifyReward(key.currency1, amt1);
        }
    }

    // ---------------- views ----------------
    function previewScore(PoolKey calldata key, uint64 epoch, address trader) external view returns (int256) {
        PoolId pid = key.toId();
        EpochState storage e = epochs[pid][epoch];
        if (!e.settled) return 0;
        TraderEpoch storage pos = positions[pid][epoch][trader];
        return _computeScore(e.settledTick, pos.netSize, pos.weightedEntry);
    }

    function getEpochInfo(PoolKey calldata key, uint64 epoch)
        external
        view
        returns (
            int24 openTick,
            int24 settledTick,
            bool settled,
            uint128 pot0,
            uint128 pot1,
            address topProphet,
            int256 topScore
        )
    {
        PoolId pid = key.toId();
        EpochState storage e = epochs[pid][epoch];
        return (e.openTick, e.settledTick, e.settled, e.pot0, e.pot1, e.topProphet, e.topScore);
    }

    function getTraderEpoch(PoolKey calldata key, uint64 epoch, address trader)
        external
        view
        returns (int128 netSize, int128 weightedEntry, uint128 absNotional, bool claimed)
    {
        PoolId pid = key.toId();
        TraderEpoch storage pos = positions[pid][epoch][trader];
        return (pos.netSize, pos.weightedEntry, pos.absNotional, pos.claimed);
    }

    // ---------------- admin ----------------
    function setAlphaRewardsEnabled(bool enabled) external onlyOwner {
        alphaRewardsEnabled = enabled;
    }

    function setProphetCard(address card) external onlyOwner {
        prophetCard = IProphetCard(card);
    }

    function setAlphaToken(address tok) external onlyOwner {
        alphaToken = IAlphaToken(tok);
    }

    function setAlphaStaking(address staking) external onlyOwner {
        alphaStaking = IAlphaStaking(staking);
    }

    // ---------------- internal helpers ----------------
    function _recordPrediction(
        PoolId pid,
        uint64 epoch,
        address trader,
        int24 tick,
        uint256 absAmount,
        int256 sign
    ) internal {
        TraderEpoch storage pos = positions[pid][epoch][trader];
        uint128 boundedAdd = absAmount > type(uint128).max ? type(uint128).max : uint128(absAmount);
        uint128 newAbs = pos.absNotional + boundedAdd;

        uint128 effective;
        if (newAbs > PER_EPOCH_NOTIONAL_CAP) {
            if (pos.absNotional >= PER_EPOCH_NOTIONAL_CAP) {
                effective = 0;
            } else {
                effective = PER_EPOCH_NOTIONAL_CAP - pos.absNotional;
            }
            pos.absNotional = PER_EPOCH_NOTIONAL_CAP;
        } else {
            effective = boundedAdd;
            pos.absNotional = newAbs;
        }
        if (effective == 0) return;

        int128 signedSize = int128(uint128(effective)) * int128(sign);
        pos.netSize = _addClamp128(pos.netSize, signedSize);
        int128 weighted = int128(int256(tick)) * signedSize;
        pos.weightedEntry = _addClamp128(pos.weightedEntry, weighted);

        emit PredictionRecorded(pid, epoch, trader, tick, signedSize);
    }

    /// @notice Computes the actual skim, applying the trader's $ALPHA stake-based discount with full
    ///         precision (avoids the rounding loss of pre-collapsing to a uint16 bps value).
    function _computeEffectiveSkim(uint256 absAmount, uint16 baseBps, address trader)
        internal
        view
        returns (uint128)
    {
        if (baseBps == 0 || absAmount == 0) return 0;
        uint256 numerator = absAmount * uint256(baseBps);
        if (address(alphaStaking) != address(0)) {
            uint256 discount = alphaStaking.getSkimDiscountBps(trader);
            if (discount >= 10_000) return 0;
            if (discount > 0) numerator = (numerator * (10_000 - discount)) / 10_000;
        }
        uint256 s = numerator / 10_000;
        if (s == 0) return 0;
        if (s > uint256(uint128(type(int128).max))) return uint128(int128(type(int128).max));
        return uint128(s);
    }

    function _decodeTrader(bytes calldata hookData, address fallbackTrader) internal pure returns (address trader) {
        if (hookData.length >= 32) {
            trader = abi.decode(hookData[:32], (address));
            if (trader != address(0)) return trader;
        }
        return fallbackTrader;
    }

    function _specifiedCurrency(PoolKey calldata key, IPoolManager.SwapParams calldata params)
        internal
        pure
        returns (Currency)
    {
        bool isExactInput = params.amountSpecified < 0;
        if (isExactInput) {
            return params.zeroForOne ? key.currency0 : key.currency1;
        } else {
            return params.zeroForOne ? key.currency1 : key.currency0;
        }
    }

    function _computeScore(int24 settledTick, int128 netSize, int128 weightedEntry) internal pure returns (int256) {
        return int256(settledTick) * int256(netSize) - int256(weightedEntry);
    }

    function _addClamp128(int128 a, int128 b) internal pure returns (int128) {
        int256 s = int256(a) + int256(b);
        if (s > int256(type(int128).max)) return type(int128).max;
        if (s < int256(type(int128).min)) return type(int128).min;
        return int128(s);
    }
}
