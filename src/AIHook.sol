// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseHook} from "./base/BaseHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {IAgentRegistry} from "./AgentRegistry.sol";
import {IVxHookToken} from "./VxHookToken.sol";
import {IAgentDecisionNFT} from "./AgentDecisionNFT.sol";

contract AIHook is BaseHook, Ownable {
    using ECDSA for bytes32;
    using LPFeeLibrary for uint24;

    error InvalidSignature();
    error ExpiredSignature();
    error AgentNotRegistered();
    error SlashingFailed();

    // 费率调整常量
    uint24 public constant BASE_FEE = 3000; // 0.3%
    uint24 public constant MIN_FEE = 1000; // 0.1%
    uint24 public constant MAX_FEE = 15000; // 1.5%

    // 风险评分阈值
    uint256 public constant LOW_RISK_THRESHOLD = 2000;
    uint256 public constant HIGH_RISK_THRESHOLD = 8000;

    // 分润比例（以基点计，10000 = 100%）
    uint256 public constant REFERRAL_SHARE_BIPS = 1500; // 15%
    uint256 public constant INSURANCE_FUND_BIPS = 2000; // 20%

    // 战绩积分稀有度系数（100 = 1x）
    uint256 public constant RARITY_CALM_BPS = 100;
    uint256 public constant RARITY_EXTREME_BPS = 500;
    uint256 public constant EARLY_LP_BONUS = 10_000;

    // AI 预言机地址（可更新）
    address public aiOracle;

    // 代理注册中心
    IAgentRegistry public agentRegistry;

    // 治理代币
    IVxHookToken public rewardToken;

    // AI 决策 NFT
    IAgentDecisionNFT public decisionNFT;

    // 互保基金接收地址
    address public insuranceFund;

    // 用户战绩积分
    mapping(address => uint256) public battlePoints;

    // 早期 LP 加成是否已领取
    mapping(address => bool) public lpBonusClaimed;

    event FeeAdjusted(bytes32 indexed poolId, uint24 fee, uint256 riskScore);
    event ReferralRewarded(address indexed referrer, uint256 amount);
    event InsuranceFundCharged(uint256 amount);
    event DecisionNFTMinted(address indexed trader, uint256 tokenId, uint256 riskScore);
    event BattlePointsAwarded(address indexed trader, uint256 points, uint256 total);
    event EarlyLPBonusAwarded(address indexed lp, uint256 bonus, uint256 total);

    constructor(
        IPoolManager _poolManager,
        address _aiOracle,
        address _agentRegistry,
        address _rewardToken,
        address _decisionNFT,
        address _insuranceFund
    ) BaseHook(_poolManager) Ownable(msg.sender) {
        aiOracle = _aiOracle;
        agentRegistry = IAgentRegistry(_agentRegistry);
        rewardToken = IVxHookToken(_rewardToken);
        decisionNFT = IAgentDecisionNFT(_decisionNFT);
        insuranceFund = _insuranceFund;
    }

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: true,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    // ---------- 动态费率核心逻辑 ----------
    function _beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        (bytes memory signature, bytes memory data) = abi.decode(
            hookData,
            (bytes, bytes)
        );
        (
            uint256 riskScore,
            address agent,
            address referrer,
            uint256 deadline
        ) = abi.decode(data, (uint256, address, address, uint256));

        if (block.timestamp > deadline) revert ExpiredSignature();

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                keccak256(abi.encode(riskScore, agent, referrer, deadline))
            )
        );
        address signer = digest.recover(signature);
        if (signer != aiOracle) revert InvalidSignature();

        if (agent != address(0) && agentRegistry.isRegistered(agent)) {
            if (agentRegistry.reputation(agent) < 100) {
                revert("Agent reputation too low");
            }
        }

        uint24 dynamicFee;
        if (riskScore <= LOW_RISK_THRESHOLD) {
            dynamicFee = MIN_FEE;
        } else if (riskScore >= HIGH_RISK_THRESHOLD) {
            dynamicFee = MAX_FEE;
        } else {
            dynamicFee = uint24(
                MIN_FEE +
                    ((riskScore - LOW_RISK_THRESHOLD) * (MAX_FEE - MIN_FEE)) /
                    (HIGH_RISK_THRESHOLD - LOW_RISK_THRESHOLD)
            );
        }

        emit FeeAdjusted(keccak256(abi.encode(key)), dynamicFee, riskScore);

        return (
            IHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            dynamicFee | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    // ---------- 交易后：NFT 铸造 + 积分 + 分润 ----------
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta swapDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        (uint256 riskScore, address agent, address referrer) = _decodeHookData(hookData);

        uint256 swapVolume = _swapVolume(swapDelta);
        _handleFeeRewards(referrer, swapVolume);
        _updateAgentReputation(agent, riskScore);
        _mintDecisionAndPoints(sender, key, riskScore, swapVolume);

        return (IHooks.afterSwap.selector, 0);
    }

    function _decodeHookData(bytes calldata hookData)
        internal
        pure
        returns (uint256 riskScore, address agent, address referrer)
    {
        (, bytes memory data) = abi.decode(hookData, (bytes, bytes));
        uint256 deadline;
        (riskScore, agent, referrer, deadline) = abi.decode(data, (uint256, address, address, uint256));
        deadline;
    }

    function _swapVolume(BalanceDelta swapDelta) internal pure returns (uint256) {
        uint256 vol0 = _abs128(swapDelta.amount0());
        uint256 vol1 = _abs128(swapDelta.amount1());
        return vol0 > vol1 ? vol0 : vol1;
    }

    function _handleFeeRewards(address referrer, uint256 swapVolume) internal {
        uint256 feeAmount = swapVolume / 100;
        if (feeAmount == 0) return;

        uint256 insuranceCut = (feeAmount * INSURANCE_FUND_BIPS) / 10000;
        if (insuranceCut > 0) {
            emit InsuranceFundCharged(insuranceCut);
        }

        if (referrer != address(0)) {
            uint256 rewardAmount = (feeAmount * REFERRAL_SHARE_BIPS) / 10000;
            rewardToken.mint(referrer, rewardAmount);
            emit ReferralRewarded(referrer, rewardAmount);
        }
    }

    function _updateAgentReputation(address agent, uint256 riskScore) internal {
        if (agent == address(0) || !agentRegistry.isRegistered(agent)) return;
        if (riskScore <= LOW_RISK_THRESHOLD) {
            agentRegistry.increaseReputation(agent, 1);
        } else if (riskScore >= HIGH_RISK_THRESHOLD) {
            agentRegistry.decreaseReputation(agent, 5);
        }
    }

    function _mintDecisionAndPoints(
        address trader,
        PoolKey calldata key,
        uint256 riskScore,
        uint256 swapVolume
    ) internal {
        uint256 tokenId = decisionNFT.mintDecision(
            trader, riskScore, swapVolume, keccak256(abi.encode(key))
        );
        emit DecisionNFTMinted(trader, tokenId, riskScore);

        uint256 points = (swapVolume * _rarityMultiplier(riskScore)) / 100;
        if (points > 0) {
            battlePoints[trader] += points;
            emit BattlePointsAwarded(trader, points, battlePoints[trader]);
        }
    }

    // ---------- 早期 LP 加成积分 ----------
    function _afterAddLiquidity(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        if (!lpBonusClaimed[sender]) {
            lpBonusClaimed[sender] = true;
            battlePoints[sender] += EARLY_LP_BONUS;
            emit EarlyLPBonusAwarded(sender, EARLY_LP_BONUS, battlePoints[sender]);
        }
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function _rarityMultiplier(uint256 riskScore) internal pure returns (uint256) {
        if (riskScore <= LOW_RISK_THRESHOLD) {
            return RARITY_CALM_BPS;
        }
        if (riskScore >= HIGH_RISK_THRESHOLD) {
            return RARITY_EXTREME_BPS;
        }
        return RARITY_CALM_BPS +
            ((riskScore - LOW_RISK_THRESHOLD) * (RARITY_EXTREME_BPS - RARITY_CALM_BPS)) /
            (HIGH_RISK_THRESHOLD - LOW_RISK_THRESHOLD);
    }

    function _abs128(int128 x) internal pure returns (uint256) {
        return x < 0 ? uint256(uint128(-x)) : uint256(uint128(x));
    }

    // ---------- 管理函数 ----------
    function setAIOracle(address _newOracle) external onlyOwner {
        aiOracle = _newOracle;
    }

    function setInsuranceFund(address _newFund) external onlyOwner {
        insuranceFund = _newFund;
    }
}
