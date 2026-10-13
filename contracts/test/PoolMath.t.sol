// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BondingCurveMath} from "../src/libraries/BondingCurveMath.sol";
import {PoolMath} from "../src/libraries/PoolMath.sol";

contract PoolMathHarness {
    function sqrtPriceX96(uint256 amountEth, uint256 amountToken) external pure returns (uint160) {
        return PoolMath.sqrtPriceX96(amountEth, amountToken);
    }

    function liquidityForAmounts(
        uint160 sqrtPrice,
        uint160 sqrtPriceLower,
        uint160 sqrtPriceUpper,
        uint256 amountEth,
        uint256 amountToken
    ) external pure returns (uint128) {
        return PoolMath.liquidityForAmounts(
            sqrtPrice, sqrtPriceLower, sqrtPriceUpper, amountEth, amountToken
        );
    }
}

contract PoolMathTest is Test {
    int24 internal constant TICK_SPACING = 200;

    PoolMathHarness internal harness;

    function setUp() public {
        harness = new PoolMathHarness();
    }

    function _fullRangePrices() internal pure returns (uint160 lower, uint160 upper) {
        (int24 tickLower, int24 tickUpper) = PoolMath.fullRangeTicks(TICK_SPACING);
        return (TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper));
    }

    function test_SqrtPriceOfEqualAmountsIsOne() public pure {
        assertEq(PoolMath.sqrtPriceX96(1 ether, 1 ether), 2 ** 96);
        assertEq(PoolMath.sqrtPriceX96(1 ether, 4 ether), 2 * 2 ** 96);
    }

    function test_FullRangeTicksAreAlignedAndInsideBounds() public pure {
        (int24 lower, int24 upper) = PoolMath.fullRangeTicks(TICK_SPACING);
        assertEq(lower, -887200);
        assertEq(upper, 887200);
        assertEq(lower % TICK_SPACING, 0);
        assertGe(lower, TickMath.MIN_TICK);
        assertLe(upper, TickMath.MAX_TICK);
    }

    function test_RevertWhen_PriceOutOfRange() public {
        vm.expectRevert(PoolMath.PriceOutOfRange.selector);
        harness.sqrtPriceX96(type(uint128).max, 1);

        (uint160 lower, uint160 upper) = _fullRangePrices();
        vm.expectRevert(PoolMath.PriceOutOfRange.selector);
        harness.liquidityForAmounts(lower, lower, upper, 1 ether, 1 ether);
    }

    function test_DefaultGraduationAmounts() public pure {
        // 4 ETH target, 0.02 ETH graduation fee.
        uint256 virtualEth = BondingCurveMath.initialVirtualEth(4 ether) + 4 ether + 3;
        uint256 ethForPool = 4 ether + 3 - 0.02 ether;
        uint256 tokens = BondingCurveMath.poolTokensForEth(
            ethForPool, virtualEth, BondingCurveMath.FINAL_VIRTUAL_TOKEN_RESERVE
        );

        assertLt(tokens, BondingCurveMath.POOL_SUPPLY);
        uint256 burned = BondingCurveMath.POOL_SUPPLY - tokens;
        assertApproxEqRel(burned, 1_054_000 ether, 0.01e18);
    }

    function testFuzz_PoolNeverOpensBelowCurvePrice(
        uint256 ethForPool,
        uint256 virtualEth,
        uint256 virtualToken
    ) public pure {
        virtualEth = bound(virtualEth, 0.01 ether, 10_000 ether);
        virtualToken = bound(virtualToken, 1e24, BondingCurveMath.INITIAL_VIRTUAL_TOKEN_RESERVE);
        ethForPool = bound(ethForPool, 1 gwei, virtualEth);

        uint256 tokens = BondingCurveMath.poolTokensForEth(ethForPool, virtualEth, virtualToken);

        // ethForPool / tokens >= virtualEth / virtualToken, and within one token unit of exact.
        assertGe(ethForPool * virtualToken, tokens * virtualEth);
        assertLt(ethForPool * virtualToken, (tokens + 1) * virtualEth);
    }

    function testFuzz_SqrtPriceMatchesAmounts(uint256 amountEth, uint256 amountToken) public pure {
        amountEth = bound(amountEth, 0.01 ether, 10_000 ether);
        amountToken = bound(amountToken, 1e24, 1e27);

        uint256 sqrtPrice = PoolMath.sqrtPriceX96(amountEth, amountToken);

        // sqrtPrice^2 / 2^192 equals amountToken / amountEth, up to the floor of the square root.
        uint256 low = sqrtPrice * sqrtPrice;
        uint256 high = (sqrtPrice + 1) * (sqrtPrice + 1);
        uint256 target = amountToken * 2 ** 64 / amountEth;
        assertLe(low >> 128, target);
        assertGe(high >> 128, target);
    }

    function testFuzz_LiquidityNeverNeedsMoreThanProvided(uint256 amountEth, uint256 amountToken)
        public
        pure
    {
        amountEth = bound(amountEth, 0.01 ether, 10_000 ether);
        amountToken = bound(amountToken, 1e24, 1e27);
        (uint160 lower, uint160 upper) = _fullRangePrices();
        uint160 sqrtPrice = PoolMath.sqrtPriceX96(amountEth, amountToken);

        uint128 liquidity =
            PoolMath.liquidityForAmounts(sqrtPrice, lower, upper, amountEth, amountToken);

        uint256 needEth = SqrtPriceMath.getAmount0Delta(sqrtPrice, upper, liquidity, true);
        uint256 needToken = SqrtPriceMath.getAmount1Delta(lower, sqrtPrice, liquidity, true);
        assertLe(needEth, amountEth);
        assertLe(needToken, amountToken);

        // Leftover dust is negligible: under one part in a billion of either amount.
        assertLe(amountEth - needEth, amountEth / 1e9 + 1);
        assertLe(amountToken - needToken, amountToken / 1e9 + 1);
    }
}
