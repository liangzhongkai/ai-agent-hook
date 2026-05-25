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

    // AI 预言机地址（可更新）
    address public aiOracle;

    // 代理注册中心
    IAgentRegistry public agentRegistry;

    // 治理代币
    IVxHookToken public rewardToken;

    // 互保基金接收地址
    address public insuranceFund;

    event FeeAdjusted(bytes32 indexed poolId, uint24 fee, uint256 riskScore);
    event ReferralRewarded(address indexed referrer, uint256 amount);
    event InsuranceFundCharged(uint256 amount);

    constructor(
        IPoolManager _poolManager,
        address _aiOracle,
        address _agentRegistry,
        address _rewardToken,
        address _insuranceFund
    ) BaseHook(_poolManager) Ownable(msg.sender) {
        aiOracle = _aiOracle;
        agentRegistry = IAgentRegistry(_agentRegistry);
        rewardToken = IVxHookToken(_rewardToken);
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
                afterAddLiquidity: false,
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
        // 解析传入的 hookData：签名 + 编码参数
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

        // 检查签名是否过期
        if (block.timestamp > deadline) revert ExpiredSignature();

        // 验证 AI 预言机签名
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                keccak256(abi.encode(riskScore, agent, referrer, deadline))
            )
        );
        address signer = digest.recover(signature);
        if (signer != aiOracle) revert InvalidSignature();

        // 若发起交易的 agent 已注册，检查其信誉是否过低（可选拦截）
        if (agent != address(0) && agentRegistry.isRegistered(agent)) {
            if (agentRegistry.reputation(agent) < 100) {
                // 信誉极低，可拒绝交易（实际可设更低门槛）
                revert("Agent reputation too low");
            }
        }

        // 根据风险评分计算动态费率
        uint24 dynamicFee;
        if (riskScore <= LOW_RISK_THRESHOLD) {
            dynamicFee = MIN_FEE;
        } else if (riskScore >= HIGH_RISK_THRESHOLD) {
            dynamicFee = MAX_FEE;
        } else {
            // 线性插值计算费率（1000 - 15000 之间）
            dynamicFee = uint24(
                MIN_FEE +
                    ((riskScore - LOW_RISK_THRESHOLD) * (MAX_FEE - MIN_FEE)) /
                    (HIGH_RISK_THRESHOLD - LOW_RISK_THRESHOLD)
            );
        }

        emit FeeAdjusted(keccak256(abi.encode(key)), dynamicFee, riskScore);

        // 返回覆盖后的费率（需带 OVERRIDE_FEE_FLAG 才能在动态费率池中生效）
        return (
            IHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            dynamicFee | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    // ---------- 交易后分润与信誉更新 ----------
    function _afterSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        BalanceDelta swapDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        // 从 hookData 中恢复 beforeSwap 时保存的数据（此处通过传入的 hookData 再次获取）
        // 注：Uniswap v4 中 afterSwap 的 hookData 与 beforeSwap 相同，由用户传入
        (, bytes memory data) = abi.decode(hookData, (bytes, bytes));
        (
            uint256 riskScore,
            address agent,
            address referrer,
            uint256 deadline
        ) = abi.decode(data, (uint256, address, address, uint256));

        // 计算此笔交易产生的手续费总额（以 token0 或 token1 计？需根据 pool 实际 fee 量）
        // 简化处理：假定手续费用池子的某种计价方式，这里直接从 delta 中提取
        // 实际应更精确计算，但此处仅为演示核心机制
        int128 delta0 = swapDelta.amount0();
        uint256 feeAmount = delta0 < 0 ? uint256(uint128(-delta0)) / 100 : 0; // 模拟：取负值部分的 1% 作为费用贡献

        // 1. 互保基金扣留（风险溢价部分）
        uint256 insuranceCut = (feeAmount * INSURANCE_FUND_BIPS) / 10000;
        if (insuranceCut > 0) {
            // 从池子中提取对应代币并转入保险库（需实现复杂转账逻辑，此处简化说明）
            // 实际需调用 poolManager.take 等，暂略
            emit InsuranceFundCharged(insuranceCut);
        }

        // 2. 推荐人奖励（铸造治理代币）
        if (referrer != address(0) && feeAmount > 0) {
            uint256 rewardAmount = (feeAmount * REFERRAL_SHARE_BIPS) / 10000;
            rewardToken.mint(referrer, rewardAmount);
            emit ReferralRewarded(referrer, rewardAmount);
        }

        // 3. 更新 agent 信誉（若 agent 已注册）
        if (agent != address(0) && agentRegistry.isRegistered(agent)) {
            // 根据风险评分调整信誉：低风险订单流提升信誉，反之降低
            if (riskScore <= LOW_RISK_THRESHOLD) {
                agentRegistry.increaseReputation(agent, 1);
            } else if (riskScore >= HIGH_RISK_THRESHOLD) {
                agentRegistry.decreaseReputation(agent, 5);
            }
        }

        return (IHooks.afterSwap.selector, 0);
    }

    // ---------- 管理函数 ----------
    function setAIOracle(address _newOracle) external onlyOwner {
        aiOracle = _newOracle;
    }

    function setInsuranceFund(address _newFund) external onlyOwner {
        insuranceFund = _newFund;
    }
}
