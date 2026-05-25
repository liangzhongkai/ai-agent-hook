// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IAgentRegistry {
    function isRegistered(address agent) external view returns (bool);

    function reputation(address agent) external view returns (uint256);

    function increaseReputation(address agent, uint256 amount) external;

    function decreaseReputation(address agent, uint256 amount) external;
}

contract AgentRegistry is IAgentRegistry, Ownable, ReentrancyGuard {
    struct AgentInfo {
        bool registered;
        uint256 stakedAmount;
        uint256 reputation; // 0 - 10000 分值
        uint256 lastUpdate;
    }

    mapping(address => AgentInfo) public agents;
    mapping(address => uint256) public pendingUnstake; // 提款锁定

    uint256 public constant MIN_STAKE = 0.1 ether;
    uint256 public constant UNSTAKE_DELAY = 7 days;

    event AgentRegistered(address indexed agent, uint256 stake);
    event ReputationUpdated(
        address indexed agent,
        uint256 newRep,
        int256 delta
    );
    event Slashed(address indexed agent, uint256 amount);

    constructor() Ownable(msg.sender) {}

    modifier onlyRegistered(address agent) {
        require(agents[agent].registered, "Not registered");
        _;
    }

    function register() external payable {
        require(msg.value >= MIN_STAKE, "Insufficient stake");
        require(!agents[msg.sender].registered, "Already registered");

        agents[msg.sender] = AgentInfo({
            registered: true,
            stakedAmount: msg.value,
            reputation: 500, // 初始信誉分
            lastUpdate: block.timestamp
        });

        emit AgentRegistered(msg.sender, msg.value);
    }

    function requestUnstake() external onlyRegistered(msg.sender) {
        pendingUnstake[msg.sender] = block.timestamp + UNSTAKE_DELAY;
    }

    function unstake() external nonReentrant onlyRegistered(msg.sender) {
        require(
            pendingUnstake[msg.sender] != 0 &&
                block.timestamp >= pendingUnstake[msg.sender],
            "Too early"
        );
        uint256 amount = agents[msg.sender].stakedAmount;
        agents[msg.sender].stakedAmount = 0;
        agents[msg.sender].registered = false;
        pendingUnstake[msg.sender] = 0;
        payable(msg.sender).transfer(amount);
    }

    // 仅 Hook 合约可调用
    function increaseReputation(address agent, uint256 amount) external {
        require(
            msg.sender == owner() || agents[agent].registered,
            "Unauthorized"
        );
        agents[agent].reputation += amount;
        if (agents[agent].reputation > 10000) agents[agent].reputation = 10000;
        emit ReputationUpdated(agent, agents[agent].reputation, int256(amount));
    }

    function decreaseReputation(address agent, uint256 amount) external {
        require(
            msg.sender == owner() || agents[agent].registered,
            "Unauthorized"
        );
        if (amount >= agents[agent].reputation) {
            agents[agent].reputation = 0;
        } else {
            agents[agent].reputation -= amount;
        }
        emit ReputationUpdated(
            agent,
            agents[agent].reputation,
            -int256(amount)
        );
    }

    // 罚没：由 Owner 或 Hook 在验证恶意行为后调用
    function slash(address agent, uint256 amount) external onlyOwner {
        require(agents[agent].registered, "Not registered");
        if (amount > agents[agent].stakedAmount) {
            amount = agents[agent].stakedAmount;
        }
        agents[agent].stakedAmount -= amount;
        // 罚金转入互保基金（也可配置）
        payable(owner()).transfer(amount);
        emit Slashed(agent, amount);
    }

    function isRegistered(address agent) external view returns (bool) {
        return agents[agent].registered;
    }

    function reputation(address agent) external view returns (uint256) {
        return agents[agent].reputation;
    }
}
