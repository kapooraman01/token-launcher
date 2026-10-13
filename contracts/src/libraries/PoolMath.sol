// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @title PoolMath
/// @notice Price and liquidity helpers for opening a full-range Uniswap v4 position.
/// Currency0 is native ETH and currency1 is the coin, so the pool price is tokens per ETH.
library PoolMath {
    uint256 internal constant Q96 = 2 ** 96;

    error PriceOutOfRange();

    /// @notice sqrt(amountToken / amountEth) as a Q64.96, the price at which these amounts form a
    /// balanced full-range position.
    function sqrtPriceX96(uint256 amountEth, uint256 amountToken) internal pure returns (uint160) {
        uint256 ratioX192 = Math.mulDiv(amountToken, 2 ** 192, amountEth);
        uint256 sqrtPrice = Math.sqrt(ratioX192);
        if (sqrtPrice < TickMath.MIN_SQRT_PRICE || sqrtPrice >= TickMath.MAX_SQRT_PRICE) {
            revert PriceOutOfRange();
        }
        return uint160(sqrtPrice);
    }

    function fullRangeTicks(int24 tickSpacing)
        internal
        pure
        returns (int24 tickLower, int24 tickUpper)
    {
        return (TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing));
    }

    /// @notice Largest liquidity that `amountEth` and `amountToken` can fund for a position between
    /// `sqrtPriceLower` and `sqrtPriceUpper` when the pool price is `sqrtPrice`, rounded down.
    function liquidityForAmounts(
        uint160 sqrtPrice,
        uint160 sqrtPriceLower,
        uint160 sqrtPriceUpper,
        uint256 amountEth,
        uint256 amountToken
    ) internal pure returns (uint128) {
        if (sqrtPrice <= sqrtPriceLower || sqrtPrice >= sqrtPriceUpper) {
            revert PriceOutOfRange();
        }

        uint256 fromEth = Math.mulDiv(
            amountEth, Math.mulDiv(sqrtPrice, sqrtPriceUpper, Q96), sqrtPriceUpper - sqrtPrice
        );
        uint256 fromToken = Math.mulDiv(amountToken, Q96, sqrtPrice - sqrtPriceLower);
        return SafeCast.toUint128(Math.min(fromEth, fromToken));
    }
}
