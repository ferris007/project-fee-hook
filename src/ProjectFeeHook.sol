// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { BaseHook } from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { BeforeSwapDelta, toBeforeSwapDelta } from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title ProjectFeeHook
/// @notice Charges one disclosed, immutable project fee on the specified leg of every swap and accrues it as
///         ERC-6909 claims for two immutable recipients.
/// @dev UNAUDITED, UNDEPLOYED custom source. Local tests are implementation evidence, never an audit or approval.
///
///      Fee model (single rule, disclosed once, collected exactly once):
///        fee = |amountSpecified| * TOTAL_FEE_HUNDREDTHS_OF_BIP / RATE_DENOMINATOR
///
///      The fee is charged on the swap's *specified* currency, which is the leg the trader pins:
///        - exact input  (amountSpecified < 0): specified is the input currency. The trader spends exactly
///          |amountSpecified| and the AMM receives |amountSpecified| - fee, so the output shrinks by the fee.
///        - exact output (amountSpecified > 0): specified is the output currency. The trader receives exactly
///          amountSpecified and the AMM must produce amountSpecified + fee, so the input grows by the fee.
///
///      In both quadrants the returned specified delta is +fee (hook is owed), so one uniform sign rule covers all
///      four direction/exactness quadrants with no hookData witness and no partial-fill dependency. Because the fee
///      rate is bounded strictly below 100%, the residual AMM leg never crosses zero and exact-input/exact-output
///      semantics are never inverted.
///
///      The fee basis is the EXECUTED specified amount. Because a partially filled swap would otherwise pay the
///      full fee on an unfilled notional, `_afterSwap` re-derives the residual AMM leg and reverts the whole swap
///      with `PartialFillUnsupported` unless it filled exactly. Full fill therefore makes requested == executed.
///
///      The total fee is INCLUSIVE, never additive: PROTOCOL_FEE_HUNDREDTHS_OF_BIP is carved out of
///      TOTAL_FEE_HUNDREDTHS_OF_BIP rather than added to it. A trader is never charged more than the disclosed total.
contract ProjectFeeHook is BaseHook {
    using SafeCast for *;

    /// @notice Denominator for every rate in this contract. Rates are hundredths of a basis point.
    uint256 public constant RATE_DENOMINATOR = 1_000_000;

    /// @notice Disclosed total fee: 10_000 / 1_000_000 = 1.00% of the specified leg.
    uint256 public constant TOTAL_FEE_HUNDREDTHS_OF_BIP = 10_000;

    /// @notice Inclusive protocol share carved out of the total: 1_000 / 1_000_000 = 0.10% (10 bps).
    uint256 public constant PROTOCOL_FEE_HUNDREDTHS_OF_BIP = 1_000;

    /// @notice Immutable beneficiary of the project share (total minus protocol share).
    address public immutable treasury;

    /// @notice Immutable beneficiary of the inclusive protocol share.
    address public immutable protocolFeeRecipient;

    /// @notice Cumulative fee accrued per currency, in that currency's smallest unit.
    mapping(Currency currency => uint256 amount) public totalFeesAccrued;

    /// @dev Expected residual AMM leg on the specified currency for the swap currently in flight, offset by one so
    ///      that zero means "no swap in flight". Written in `_beforeSwap` and consumed by `_afterSwap`.
    int256 private _pendingResidualPlusOne;

    error InvalidRecipient(address recipient);
    error FeeAmountOutOfRange(uint256 amount);
    error PartialFillUnsupported(int256 expectedResidual, int256 executedResidual);
    error PendingSwapInProgress();

    event ProjectFeeCharged(
        PoolId indexed poolId,
        Currency indexed specifiedCurrency,
        address indexed sender,
        uint256 specifiedAmount,
        uint256 treasuryAmount,
        uint256 protocolAmount
    );

    constructor(IPoolManager poolManager_, address treasury_, address protocolFeeRecipient_) BaseHook(poolManager_) {
        if (treasury_ == address(0)) revert InvalidRecipient(treasury_);
        if (protocolFeeRecipient_ == address(0)) revert InvalidRecipient(protocolFeeRecipient_);
        treasury = treasury_;
        protocolFeeRecipient = protocolFeeRecipient_;
    }

    /// @inheritdoc BaseHook
    /// @dev Every permission starts disabled; only the two required by the confirmed behavior are enabled.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
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
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Quote the fee for a specified amount without touching state.
    /// @dev Exposed so every trading surface can disclose the exact charge before a swap is signed.
    function quoteFee(uint256 specifiedAmount)
        public
        pure
        returns (uint256 totalFee, uint256 treasuryAmount, uint256 protocolAmount)
    {
        totalFee = FullMath.mulDiv(specifiedAmount, TOTAL_FEE_HUNDREDTHS_OF_BIP, RATE_DENOMINATOR);
        protocolAmount = FullMath.mulDiv(specifiedAmount, PROTOCOL_FEE_HUNDREDTHS_OF_BIP, RATE_DENOMINATOR);
        treasuryAmount = totalFee - protocolAmount;
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bool exactInput = params.amountSpecified < 0;
        uint256 specifiedAmount =
            exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);

        if (_pendingResidualPlusOne != 0) revert PendingSwapInProgress();

        (uint256 totalFee, uint256 treasuryAmount, uint256 protocolAmount) = quoteFee(specifiedAmount);
        if (totalFee == 0) return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        if (totalFee > uint256(uint128(type(int128).max))) revert FeeAmountOutOfRange(totalFee);

        // zeroForOne means currency0 in / currency1 out. The specified leg is currency0 exactly when the trader
        // pinned the input side of a zeroForOne swap, or the output side of a oneForZero swap.
        Currency specified = (params.zeroForOne == exactInput) ? key.currency0 : key.currency1;

        // Accrue as ERC-6909 claims directly to each immutable recipient. The hook never takes custody, so it holds
        // no balance to rescue, and no recipient can redirect another recipient's share.
        if (treasuryAmount != 0) poolManager.mint(treasury, specified.toId(), treasuryAmount);
        if (protocolAmount != 0) poolManager.mint(protocolFeeRecipient, specified.toId(), protocolAmount);
        totalFeesAccrued[specified] += totalFee;

        emit ProjectFeeCharged(
            key.toId(), specified, sender, specifiedAmount, treasuryAmount, protocolAmount
        );

        // Positive specified delta: the hook is owed `totalFee` of the specified currency. Core subtracts it from
        // the caller and leaves the AMM with `amountSpecified + totalFee` as the residual leg.
        int256 residual = params.amountSpecified + totalFee.toInt256();
        _pendingResidualPlusOne = residual + 1;
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(totalFee.toInt256().toInt128(), 0), 0);
    }

    /// @dev Enforces exact fill. No delta is returned here; `afterSwapReturnDelta` stays disabled.
    function _afterSwap(address, PoolKey calldata, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        int256 pending = _pendingResidualPlusOne;
        _pendingResidualPlusOne = 0;
        if (pending == 0) return (IHooks.afterSwap.selector, 0);

        bool exactInput = params.amountSpecified < 0;
        bool specifiedIsCurrency0 = (params.zeroForOne == exactInput);
        int128 executed = specifiedIsCurrency0 ? delta.amount0() : delta.amount1();

        // `delta` is the caller-side delta of the residual AMM swap, so the executed specified leg carries the
        // same sign as the residual we asked the pool for: negative when the caller pays an exact input, positive
        // when the caller receives an exact output.
        int256 expected = pending - 1;
        if (int256(executed) != expected) revert PartialFillUnsupported(expected, int256(executed));

        return (IHooks.afterSwap.selector, 0);
    }
}
