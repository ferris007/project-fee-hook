// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { CustomRevert } from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { BeforeSwapDelta } from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";

import { ProjectFeeHook } from "../src/ProjectFeeHook.sol";

/// @notice Bounded swap driver for invariant runs. It only ever performs fully fillable swaps so the invariant
///         exercises accrual rather than the partial-fill guard.
contract SwapHandler {
    PoolSwapTest internal immutable router;
    PoolKey internal key;
    uint256 public swapCount;

    PoolSwapTest.TestSettings internal settings =
        PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false });

    constructor(PoolSwapTest router_, PoolKey memory key_) {
        router = router_;
        key = key_;
    }

    function swapExactIn(uint96 rawAmount, bool zeroForOne) external {
        uint256 amount = uint256(rawAmount) % 0.002 ether;
        if (amount == 0) return;
        try router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            settings,
            ""
        ) {
            swapCount++;
        } catch { }
    }
}


contract ProjectFeeHookTest is Deployers {
    ProjectFeeHook internal hook;
    SwapHandler internal handler;
    PoolKey internal feeKey;

    address internal constant TREASURY = address(0xdEAD01);
    address internal constant PROTOCOL = address(0xF0F0);

    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60; // what Deployers.initPool derives from a 3000 fee

    /// @dev The permission set the hook declares, and therefore the flag bits its address must carry.
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    uint256 internal constant DENOM = 1_000_000;
    uint256 internal constant TOTAL_RATE = 10_000; // 1.00%
    uint256 internal constant PROTOCOL_RATE = 1_000; // 0.10%

    PoolSwapTest.TestSettings internal settings =
        PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false });

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        address hookAddress = address(HOOK_FLAGS);
        // The designated pool is bound at deploy time. No circularity: the key's four bound fields are known
        // before the hook exists, and the fifth field is the hook address itself.
        deployCodeTo(
            "ProjectFeeHook.sol:ProjectFeeHook",
            abi.encode(manager, TREASURY, PROTOCOL, currency0, currency1, FEE, TICK_SPACING),
            hookAddress
        );
        hook = ProjectFeeHook(hookAddress);

        (feeKey,) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(hookAddress), FEE, SQRT_PRICE_1_1
        );

        handler = new SwapHandler(swapRouter, feeKey);
        MockERC20(Currency.unwrap(currency0)).mint(address(handler), 100 ether);
        MockERC20(Currency.unwrap(currency1)).mint(address(handler), 100 ether);
        vm.startPrank(address(handler));
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
        targetContract(address(handler));
    }

    // --- disclosure ---------------------------------------------------------

    function test_permissionsEnableOnlyTheInitializeGateSwapAndItsDelta() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeSwap, "beforeSwap");
        assertTrue(p.beforeSwapReturnDelta, "beforeSwapReturnDelta");
        assertTrue(p.beforeInitialize, "beforeInitialize gates pool attachment");
        assertFalse(p.afterInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertTrue(p.afterSwap, "afterSwap enforces exact fill");
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.afterSwapReturnDelta);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
    }

    function test_disclosedRateIsOnePercentInclusiveOfTenBps() public view {
        assertEq(hook.TOTAL_FEE_HUNDREDTHS_OF_BIP(), TOTAL_RATE);
        assertEq(hook.PROTOCOL_FEE_HUNDREDTHS_OF_BIP(), PROTOCOL_RATE);
        assertEq(hook.RATE_DENOMINATOR(), DENOM);
        // Inclusive, never additive: the protocol share is carved out of the disclosed total.
        assertLt(hook.PROTOCOL_FEE_HUNDREDTHS_OF_BIP(), hook.TOTAL_FEE_HUNDREDTHS_OF_BIP());

        (uint256 total, uint256 treasuryAmount, uint256 protocolAmount) = hook.quoteFee(1 ether);
        assertEq(total, 0.01 ether, "1% of specified");
        assertEq(protocolAmount, 0.001 ether, "10 bps");
        assertEq(treasuryAmount, total - protocolAmount, "treasury is the remainder");
        assertEq(treasuryAmount + protocolAmount, total, "shares conserve the total exactly once");
    }

    // --- the four direction/exactness quadrants -----------------------------

    function test_exactInputZeroForOne_chargesSpecifiedInputCurrency() public {
        uint256 amountIn = 0.001 ether;
        (, uint256 treasuryAmount, uint256 protocolAmount) = hook.quoteFee(amountIn);

        swapRouter.swap(
            feeKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );

        assertEq(manager.balanceOf(TREASURY, currency0.toId()), treasuryAmount, "treasury claims currency0");
        assertEq(manager.balanceOf(PROTOCOL, currency0.toId()), protocolAmount, "protocol claims currency0");
        assertEq(manager.balanceOf(TREASURY, currency1.toId()), 0, "no unrelated currency accrual");
    }

    function test_exactInputOneForZero_chargesSpecifiedInputCurrency() public {
        uint256 amountIn = 0.001 ether;
        (, uint256 treasuryAmount,) = hook.quoteFee(amountIn);

        swapRouter.swap(
            feeKey,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            settings,
            ZERO_BYTES
        );

        assertEq(manager.balanceOf(TREASURY, currency1.toId()), treasuryAmount, "treasury claims currency1");
        assertEq(manager.balanceOf(TREASURY, currency0.toId()), 0, "no unrelated currency accrual");
    }

    function test_exactOutputZeroForOne_chargesSpecifiedOutputCurrency() public {
        uint256 amountOut = 0.001 ether;
        (, uint256 treasuryAmount,) = hook.quoteFee(amountOut);

        swapRouter.swap(
            feeKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: int256(amountOut),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );

        // Specified leg of an exact-output zeroForOne swap is the output currency, currency1.
        assertEq(manager.balanceOf(TREASURY, currency1.toId()), treasuryAmount, "treasury claims currency1");
        assertEq(manager.balanceOf(TREASURY, currency0.toId()), 0, "no unrelated currency accrual");
    }

    function test_exactOutputOneForZero_chargesSpecifiedOutputCurrency() public {
        uint256 amountOut = 0.001 ether;
        (, uint256 treasuryAmount,) = hook.quoteFee(amountOut);

        swapRouter.swap(
            feeKey,
            SwapParams({
                zeroForOne: false,
                amountSpecified: int256(amountOut),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            settings,
            ZERO_BYTES
        );

        assertEq(manager.balanceOf(TREASURY, currency0.toId()), treasuryAmount, "treasury claims currency0");
        assertEq(manager.balanceOf(TREASURY, currency1.toId()), 0, "no unrelated currency accrual");
    }

    function test_exactInputTraderSpendsExactlySpecifiedAmount() public {
        uint256 amountIn = 0.001 ether;
        uint256 before0 = currency0.balanceOf(address(this));

        swapRouter.swap(
            feeKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );

        // Exact-input semantics are preserved: the fee reduces the output, it never increases the input.
        assertEq(before0 - currency0.balanceOf(address(this)), amountIn, "spent exactly the specified input");
    }

    function test_exactOutputTraderReceivesExactlySpecifiedAmount() public {
        uint256 amountOut = 0.001 ether;
        uint256 before1 = currency1.balanceOf(address(this));

        swapRouter.swap(
            feeKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: int256(amountOut),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );

        // Exact-output semantics are preserved: the fee increases the input, it never reduces the output.
        assertEq(currency1.balanceOf(address(this)) - before1, amountOut, "received exactly the specified output");
    }

    // --- rate boundaries and rounding ---------------------------------------

    function test_zeroFeeBelowRoundingThresholdDoesNotRevert() public {
        // 99 units * 10_000 / 1_000_000 rounds down to zero; the swap must still succeed with no accrual.
        (uint256 total,,) = hook.quoteFee(99);
        assertEq(total, 0, "sub-threshold amount rounds to a zero fee");

        swapRouter.swap(
            feeKey,
            SwapParams({ zeroForOne: true, amountSpecified: -99, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 }),
            settings,
            ZERO_BYTES
        );

        assertEq(manager.balanceOf(TREASURY, currency0.toId()), 0, "no accrual below the rounding threshold");
    }

    function test_minimumChargeableAmountAccruesToProtocolOnly() public view {
        // 100 units yields a 1-unit total fee; the 10 bps protocol share rounds to zero, so the treasury takes it.
        (uint256 total, uint256 treasuryAmount, uint256 protocolAmount) = hook.quoteFee(100);
        assertEq(total, 1, "minimum chargeable total");
        assertEq(protocolAmount, 0, "protocol share rounds down");
        assertEq(treasuryAmount, 1, "remainder goes to the treasury");
        assertEq(treasuryAmount + protocolAmount, total, "no unit is created or lost");
    }

    function test_largeAmountKeepsSharesConserved() public view {
        (uint256 total, uint256 treasuryAmount, uint256 protocolAmount) = hook.quoteFee(1_000_000 ether);
        assertEq(total, 10_000 ether, "1% of a large specified amount");
        assertEq(protocolAmount, 1_000 ether, "10 bps of a large specified amount");
        assertEq(treasuryAmount + protocolAmount, total, "shares conserve the total");
    }

    function testFuzz_sharesAlwaysConserveTheTotalAndNeverExceedIt(uint128 specifiedAmount) public view {
        (uint256 total, uint256 treasuryAmount, uint256 protocolAmount) = hook.quoteFee(specifiedAmount);
        assertEq(treasuryAmount + protocolAmount, total, "split is exactly conservative");
        assertLe(total, uint256(specifiedAmount) / 100, "never charges more than the disclosed 1%");
        assertLe(protocolAmount, total, "protocol share is inclusive, never additive");
    }

    // --- authority and isolation --------------------------------------------

    function test_recipientsAreImmutableAndDistinct() public view {
        assertEq(hook.treasury(), TREASURY);
        assertEq(hook.protocolFeeRecipient(), PROTOCOL);
        // No setter exists for either recipient; both are `immutable`, so neither beneficiary can be redirected
        // and neither can capture the other's share.
    }

    function test_directCallbackFromNonManagerReverts() public {
        vm.expectRevert();
        IHooks(address(hook)).beforeSwap(
            address(this),
            feeKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ZERO_BYTES
        );
    }

    function test_poolIsolation_unhookedPoolAccruesNothing() public {
        (PoolKey memory plainKey,) =
            initPoolAndAddLiquidity(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);

        swapRouter.swap(
            plainKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );

        assertEq(manager.balanceOf(TREASURY, currency0.toId()), 0, "a pool without this hook is never charged");
    }

    function test_feeIsCollectedExactlyOncePerSwap() public {
        uint256 amountIn = 0.001 ether;
        (, uint256 treasuryAmount,) = hook.quoteFee(amountIn);

        for (uint256 i = 0; i < 3; i++) {
            swapRouter.swap(
                feeKey,
                SwapParams({
                    zeroForOne: true,
                    amountSpecified: -int256(amountIn),
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                settings,
                ZERO_BYTES
            );
        }

        assertEq(
            manager.balanceOf(TREASURY, currency0.toId()),
            treasuryAmount * 3,
            "three swaps accrue exactly three fees, never double-collected"
        );
        (uint256 totalPerSwap,,) = hook.quoteFee(amountIn);
        assertEq(hook.totalFeesAccrued(currency0), totalPerSwap * 3, "accounting mirrors the minted claims");
    }

    // --- pool binding --------------------------------------------------------

    /// @dev Builds the exact revert payload core produces when a hook reverts: the hook's own error, wrapped by
    ///      `CustomRevert.WrappedError`. Asserting the whole envelope proves the gate fired, not merely that
    ///      initialization failed for some other reason.
    function _expectUndesignatedPool(PoolKey memory badKey) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(ProjectFeeHook.UndesignatedPool.selector, badKey.toId()),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    function test_designatedPoolIsExactlyTheOneBoundAtDeploy() public view {
        // setUp initialized this pool, so the gate admits the designated key.
        assertTrue(feeKey.currency0 == hook.designatedCurrency0(), "designated currency0");
        assertTrue(feeKey.currency1 == hook.designatedCurrency1(), "designated currency1");
        assertEq(feeKey.fee, hook.designatedFee(), "designated fee");
        assertEq(feeKey.tickSpacing, hook.designatedTickSpacing(), "designated tick spacing");
        assertEq(address(feeKey.hooks), address(hook), "the key names this hook");
    }

    /// @notice v4 initialization is permissionless, so a third party may name this hook in any key. Every key but
    ///         the designated one is rejected before the pool exists.
    function test_undesignatedFeeTierCannotAttach() public {
        PoolKey memory badKey = PoolKey(currency0, currency1, 500, 10, IHooks(address(hook)));
        _expectUndesignatedPool(badKey);
        manager.initialize(badKey, SQRT_PRICE_1_1);
    }

    function test_undesignatedTickSpacingCannotAttach() public {
        PoolKey memory badKey = PoolKey(currency0, currency1, FEE, 30, IHooks(address(hook)));
        _expectUndesignatedPool(badKey);
        manager.initialize(badKey, SQRT_PRICE_1_1);
    }

    function test_undesignatedCurrencyPairCannotAttach() public {
        Currency foreign = deployMintAndApproveCurrency();
        (Currency a, Currency b) = foreign < currency0 ? (foreign, currency0) : (currency0, foreign);

        PoolKey memory badKey = PoolKey(a, b, FEE, TICK_SPACING, IHooks(address(hook)));
        _expectUndesignatedPool(badKey);
        manager.initialize(badKey, SQRT_PRICE_1_1);
    }

    /// @notice The designated pool cannot be re-initialized to reset its price, and the gate is not what stops it:
    ///         core rejects the duplicate first. Recorded so the two rejections are not confused.
    function test_designatedPoolCannotBeReinitialized() public {
        vm.expectRevert();
        manager.initialize(feeKey, SQRT_PRICE_1_1);
    }

    /// @dev Deploys the hook's creation code directly. `deployCodeTo` swallows a constructor revert behind its own
    ///      require string, so the constructor's own error would be invisible through it.
    function _tryDeployHook(bytes memory args, address where) internal returns (bool ok, bytes memory ret) {
        vm.etch(where, abi.encodePacked(vm.getCode("ProjectFeeHook.sol:ProjectFeeHook"), args));
        (ok, ret) = where.call("");
    }

    /// @notice The designated key is immutable, so a key core could never accept would brick the hook forever.
    ///         Both such keys are rejected at deploy time instead.
    function test_constructorRejectsUnsortedDesignatedCurrencies() public {
        (bool ok, bytes memory ret) = _tryDeployHook(
            abi.encode(manager, TREASURY, PROTOCOL, currency1, currency0, FEE, TICK_SPACING),
            address(HOOK_FLAGS | uint160(0x1111 << 20))
        );

        assertFalse(ok, "an unsortable designated pair must not deploy");
        assertEq(bytes4(ret), ProjectFeeHook.CurrenciesOutOfOrder.selector, "rejected as out of order");
    }

    function test_constructorRejectsInvalidDesignatedTickSpacing() public {
        (bool ok, bytes memory ret) = _tryDeployHook(
            abi.encode(manager, TREASURY, PROTOCOL, currency0, currency1, FEE, int24(0)),
            address(HOOK_FLAGS | uint160(0x2222 << 20))
        );

        assertFalse(ok, "an uninitializable tick spacing must not deploy");
        assertEq(bytes4(ret), ProjectFeeHook.InvalidTickSpacing.selector, "rejected as invalid tick spacing");
    }

    // --- solvency and claims ------------------------------------------------

    function test_hookHoldsNoCustodyAndRecipientsCanRedeemClaims() public {
        uint256 amountIn = 0.001 ether;
        (, uint256 treasuryAmount,) = hook.quoteFee(amountIn);

        swapRouter.swap(
            feeKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );

        // The hook never takes custody: it mints claims straight to the immutable recipients.
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 0, "hook holds no claims");
        assertEq(currency0.balanceOf(address(hook)), 0, "hook holds no tokens");
        assertEq(manager.balanceOf(TREASURY, currency0.toId()), treasuryAmount, "treasury holds its claims");

        // Claims are backed: the PoolManager's token balance covers every outstanding claim.
        assertGe(
            currency0.balanceOf(address(manager)),
            manager.balanceOf(TREASURY, currency0.toId()) + manager.balanceOf(PROTOCOL, currency0.toId()),
            "outstanding claims are fully backed"
        );
    }

    /// @notice A swap too large for the pool's liquidity partially fills. Charging 1% of the *requested* notional
    ///         would overcharge the trader for volume that never executed, so the hook reverts the whole swap.
    function test_partialFillRevertsRatherThanOverchargingRequestedNotional() public {
        vm.expectRevert();
        swapRouter.swap(
            feeKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1_000 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );

        assertEq(manager.balanceOf(TREASURY, currency0.toId()), 0, "a reverted swap accrues nothing");
    }

    // --- gate tests required by the tradable authoring contract ---------------

    /// @notice End-to-end simulation: a mixed trading session accrues the disclosed fee and nothing more.
    function testSimulation_mixedTradingSessionAccruesOnlyTheDisclosedFee() public {
        uint256 amount = 0.001 ether;
        (uint256 total, uint256 treasuryAmount, uint256 protocolAmount) = hook.quoteFee(amount);

        // Two exact-input swaps in each direction, then one exact-output swap in each direction.
        for (uint256 i = 0; i < 2; i++) {
            swapRouter.swap(
                feeKey,
                SwapParams({
                    zeroForOne: true,
                    amountSpecified: -int256(amount),
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                settings,
                ZERO_BYTES
            );
            swapRouter.swap(
                feeKey,
                SwapParams({
                    zeroForOne: false,
                    amountSpecified: -int256(amount),
                    sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
                }),
                settings,
                ZERO_BYTES
            );
        }

        // currency0 was the specified leg of the two exact-input zeroForOne swaps only.
        assertEq(hook.totalFeesAccrued(currency0), total * 2, "currency0 accrual matches two charged swaps");
        assertEq(hook.totalFeesAccrued(currency1), total * 2, "currency1 accrual matches two charged swaps");
        assertEq(manager.balanceOf(TREASURY, currency0.toId()), treasuryAmount * 2, "treasury share");
        assertEq(manager.balanceOf(PROTOCOL, currency0.toId()), protocolAmount * 2, "protocol share");
        assertEq(
            manager.balanceOf(TREASURY, currency0.toId()) + manager.balanceOf(PROTOCOL, currency0.toId()),
            hook.totalFeesAccrued(currency0),
            "claims reconcile with accounting, so the fee is collected exactly once"
        );
    }

    /// @notice The deployed hook address must encode exactly the permissions it declares, and no others.
    function testDeployment_hookAddressEncodesExactlyTheDeclaredPermissions() public view {
        uint160 encoded = uint160(address(hook)) & uint160(Hooks.ALL_HOOK_MASK);
        assertEq(encoded, HOOK_FLAGS, "address flags equal the declared permission set exactly");

        // Constructor arguments are bound and immutable.
        assertEq(address(hook.poolManager()), address(manager), "bound PoolManager");
        assertEq(hook.treasury(), TREASURY, "bound treasury");
        assertEq(hook.protocolFeeRecipient(), PROTOCOL, "bound protocol recipient");
        assertTrue(hook.designatedCurrency0() == currency0, "bound currency0");
        assertTrue(hook.designatedCurrency1() == currency1, "bound currency1");
        assertEq(hook.designatedFee(), FEE, "bound fee");
        assertEq(hook.designatedTickSpacing(), TICK_SPACING, "bound tick spacing");
    }

    /// @notice Outstanding recipient claims always reconcile exactly with the hook's own accounting, and the hook
    ///         never accumulates custody of its own.
    function invariant_claimsReconcileWithAccountingAndHookHoldsNoCustody() public view {
        assertEq(
            manager.balanceOf(TREASURY, currency0.toId()) + manager.balanceOf(PROTOCOL, currency0.toId()),
            hook.totalFeesAccrued(currency0),
            "currency0 claims reconcile"
        );
        assertEq(
            manager.balanceOf(TREASURY, currency1.toId()) + manager.balanceOf(PROTOCOL, currency1.toId()),
            hook.totalFeesAccrued(currency1),
            "currency1 claims reconcile"
        );
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 0, "hook holds no currency0 claims");
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0, "hook holds no currency1 claims");
    }
}
