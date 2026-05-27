// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";

import {IAlphaToken} from "./AlphaToken.sol";

interface IAlphaStaking {
    /// @notice Score multiplier in bps (10000 = 1.00x baseline).
    function getScoreMultiplierBps(address user) external view returns (uint256);

    /// @notice Prophet skim discount in bps (out of 10000).
    function getSkimDiscountBps(address user) external view returns (uint256);

    /// @notice Called by ProphetHook (or any authorized notifier) to register a deposited reward.
    /// @dev    The reward tokens MUST already be transferred to this contract before this call.
    function notifyReward(Currency currency, uint256 amount) external;
}

/// @title Alpha Staking — Prophet Hook's vote-escrow / boost layer
/// @notice Stake $ALPHA to earn:
///         (a) up to +100% score multiplier in Prophet epochs (caps at 2.0x)
///         (b) up to 50% discount on the prophet skim fee for your own swaps
///         (c) pro-rata share of the staker channel from each epoch payout
///         (paid in whatever currencies the source pool trades).
contract AlphaStaking is IAlphaStaking, Ownable, ReentrancyGuard {
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;

    // ---------------- constants ----------------
    /// @notice Stake amount that saturates both boosts.
    uint256 public constant MAX_STAKE_FOR_BOOST = 100_000 ether;
    /// @notice Maximum *bonus* score multiplier in bps (10000 = +100% → 2.0x total).
    uint256 public constant MAX_MULT_BONUS_BPS = 10_000;
    /// @notice Maximum prophet skim discount in bps (5000 = -50%).
    uint256 public constant MAX_DISCOUNT_BPS = 5_000;
    /// @notice Hard cap on how many distinct reward currencies we track.
    ///         Protects stake/unstake from unbounded iteration.
    uint256 public constant MAX_REWARD_CURRENCIES = 16;
    /// @notice Cooldown between unstake request and actual unstake (anti-flash-stake exploit).
    uint256 public constant UNSTAKE_COOLDOWN = 1 days;
    /// @notice Per-share accumulator scale.
    uint256 internal constant ACC_SCALE = 1e30;

    // ---------------- errors ----------------
    error NotNotifier();
    error TooManyCurrencies();
    error InsufficientStake();
    error CooldownActive();
    error NoUnstakeRequest();

    // ---------------- events ----------------
    event Staked(address indexed user, uint256 amount, uint256 newTotal);
    event UnstakeRequested(address indexed user, uint256 amount, uint256 readyAt);
    event Unstaked(address indexed user, uint256 amount);
    event RewardNotified(Currency indexed currency, uint256 amount, uint256 accPerShareAfter);
    event RewardClaimed(address indexed user, Currency indexed currency, uint256 amount);
    event NotifierSet(address indexed notifier);

    // ---------------- storage ----------------
    IAlphaToken public immutable alpha;
    address public notifier;

    uint256 public totalStaked;
    mapping(address => uint256) public stakedOf;

    Currency[] public activeCurrencies;
    mapping(Currency => bool) public isActiveCurrency;
    mapping(Currency => uint256) public accPerShare; // scaled by ACC_SCALE
    mapping(address => mapping(Currency => uint256)) public userAccPaid;
    mapping(address => mapping(Currency => uint256)) public pendingOf;

    struct PendingUnstake {
        uint128 amount;
        uint128 readyAt;
    }

    mapping(address => PendingUnstake) public pendingUnstake;

    constructor(IAlphaToken _alpha) Ownable(msg.sender) {
        alpha = _alpha;
    }

    // ---------------- admin ----------------
    function setNotifier(address _notifier) external onlyOwner {
        notifier = _notifier;
        emit NotifierSet(_notifier);
    }

    // ---------------- stake / unstake ----------------
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert InsufficientStake();
        _settleAll(msg.sender);

        IERC20(address(alpha)).safeTransferFrom(msg.sender, address(this), amount);
        stakedOf[msg.sender] += amount;
        totalStaked += amount;

        _checkpointAll(msg.sender);
        emit Staked(msg.sender, amount, totalStaked);
    }

    function requestUnstake(uint256 amount) external {
        if (amount == 0 || stakedOf[msg.sender] < amount) revert InsufficientStake();
        uint256 ready = block.timestamp + UNSTAKE_COOLDOWN;
        pendingUnstake[msg.sender] = PendingUnstake({amount: uint128(amount), readyAt: uint128(ready)});
        emit UnstakeRequested(msg.sender, amount, ready);
    }

    function unstake() external nonReentrant {
        PendingUnstake memory req = pendingUnstake[msg.sender];
        if (req.amount == 0) revert NoUnstakeRequest();
        if (block.timestamp < req.readyAt) revert CooldownActive();
        if (stakedOf[msg.sender] < req.amount) revert InsufficientStake();

        _settleAll(msg.sender);

        stakedOf[msg.sender] -= req.amount;
        totalStaked -= req.amount;
        delete pendingUnstake[msg.sender];

        _checkpointAll(msg.sender);

        IERC20(address(alpha)).safeTransfer(msg.sender, req.amount);
        emit Unstaked(msg.sender, req.amount);
    }

    // ---------------- claim ----------------
    function claim(Currency currency) external nonReentrant returns (uint256 paid) {
        _settleOne(msg.sender, currency);
        paid = pendingOf[msg.sender][currency];
        if (paid == 0) return 0;
        pendingOf[msg.sender][currency] = 0;
        _transferOut(currency, msg.sender, paid);
        emit RewardClaimed(msg.sender, currency, paid);
    }

    function claimMany(Currency[] calldata currencies) external nonReentrant {
        for (uint256 i = 0; i < currencies.length; i++) {
            Currency c = currencies[i];
            _settleOne(msg.sender, c);
            uint256 amt = pendingOf[msg.sender][c];
            if (amt == 0) continue;
            pendingOf[msg.sender][c] = 0;
            _transferOut(c, msg.sender, amt);
            emit RewardClaimed(msg.sender, c, amt);
        }
    }

    // ---------------- notification (from hook) ----------------
    /// @notice Register an incoming reward. Tokens MUST already be in this contract.
    function notifyReward(Currency currency, uint256 amount) external override {
        if (msg.sender != notifier) revert NotNotifier();
        if (amount == 0) return;
        if (totalStaked == 0) {
            // No stakers yet → reward sits as untracked balance; admin can rescue or wait until stakers exist.
            return;
        }
        if (!isActiveCurrency[currency]) {
            if (activeCurrencies.length >= MAX_REWARD_CURRENCIES) revert TooManyCurrencies();
            isActiveCurrency[currency] = true;
            activeCurrencies.push(currency);
        }
        accPerShare[currency] += (amount * ACC_SCALE) / totalStaked;
        emit RewardNotified(currency, amount, accPerShare[currency]);
    }

    // ---------------- views ----------------
    function getScoreMultiplierBps(address user) external view override returns (uint256) {
        uint256 s = stakedOf[user];
        if (s == 0) return 10_000;
        if (s >= MAX_STAKE_FOR_BOOST) return 10_000 + MAX_MULT_BONUS_BPS;
        return 10_000 + (s * MAX_MULT_BONUS_BPS) / MAX_STAKE_FOR_BOOST;
    }

    function getSkimDiscountBps(address user) external view override returns (uint256) {
        uint256 s = stakedOf[user];
        if (s == 0) return 0;
        if (s >= MAX_STAKE_FOR_BOOST) return MAX_DISCOUNT_BPS;
        return (s * MAX_DISCOUNT_BPS) / MAX_STAKE_FOR_BOOST;
    }

    function earned(address user, Currency currency) external view returns (uint256) {
        uint256 stk = stakedOf[user];
        if (stk == 0) return pendingOf[user][currency];
        uint256 newlyAccrued = (stk * (accPerShare[currency] - userAccPaid[user][currency])) / ACC_SCALE;
        return pendingOf[user][currency] + newlyAccrued;
    }

    function activeCurrenciesLength() external view returns (uint256) {
        return activeCurrencies.length;
    }

    // ---------------- internal ----------------
    function _settleAll(address user) internal {
        uint256 len = activeCurrencies.length;
        for (uint256 i = 0; i < len; i++) {
            _settleOne(user, activeCurrencies[i]);
        }
    }

    function _checkpointAll(address user) internal {
        uint256 len = activeCurrencies.length;
        for (uint256 i = 0; i < len; i++) {
            userAccPaid[user][activeCurrencies[i]] = accPerShare[activeCurrencies[i]];
        }
    }

    function _settleOne(address user, Currency currency) internal {
        uint256 stk = stakedOf[user];
        if (stk > 0) {
            uint256 newlyAccrued = (stk * (accPerShare[currency] - userAccPaid[user][currency])) / ACC_SCALE;
            if (newlyAccrued > 0) pendingOf[user][currency] += newlyAccrued;
        }
        userAccPaid[user][currency] = accPerShare[currency];
    }

    function _transferOut(Currency currency, address to, uint256 amount) internal {
        if (currency.isAddressZero()) {
            (bool ok,) = to.call{value: amount}("");
            require(ok, "ETH send failed");
        } else {
            IERC20(Currency.unwrap(currency)).safeTransfer(to, amount);
        }
    }

    receive() external payable {}
}
