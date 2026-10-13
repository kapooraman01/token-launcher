// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title BondingCurveMath
/// @notice Constant-product (x * y = k) pricing against virtual reserves. Every function rounds in
/// favour of the curve, so `virtualEth * virtualToken` can never decrease across a trade.
library BondingCurveMath {
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 internal constant CURVE_SUPPLY = 793_100_000 ether;
    uint256 internal constant POOL_SUPPLY = 206_900_000 ether;
    uint256 internal constant INITIAL_VIRTUAL_TOKEN_RESERVE = 1_073_000_000 ether;
    uint256 internal constant FINAL_VIRTUAL_TOKEN_RESERVE =
        INITIAL_VIRTUAL_TOKEN_RESERVE - CURVE_SUPPLY;

    error EmptyReserves();
    error InsufficientTokenReserve();

    /// @notice Starting virtual ETH reserve for a curve that raises at least `targetRaise` real ETH
    /// (and at most a few wei more) once all of `CURVE_SUPPLY` has been sold.
    function initialVirtualEth(uint256 targetRaise) internal pure returns (uint256) {
        return
            Math.mulDiv(targetRaise, FINAL_VIRTUAL_TOKEN_RESERVE, CURVE_SUPPLY, Math.Rounding.Ceil);
    }

    /// @notice Tokens received for exactly `ethIn`, rounded down.
    function tokensOutForEthIn(uint256 virtualEth, uint256 virtualToken, uint256 ethIn)
        internal
        pure
        returns (uint256)
    {
        _requireReserves(virtualEth, virtualToken);
        return Math.mulDiv(virtualToken, ethIn, virtualEth + ethIn);
    }

    /// @notice ETH required to receive exactly `tokensOut`, rounded up.
    function ethInForTokensOut(uint256 virtualEth, uint256 virtualToken, uint256 tokensOut)
        internal
        pure
        returns (uint256)
    {
        _requireReserves(virtualEth, virtualToken);
        if (tokensOut >= virtualToken) revert InsufficientTokenReserve();
        return Math.mulDiv(virtualEth, tokensOut, virtualToken - tokensOut, Math.Rounding.Ceil);
    }

    /// @notice ETH received for selling exactly `tokensIn`, rounded down.
    function ethOutForTokensIn(uint256 virtualEth, uint256 virtualToken, uint256 tokensIn)
        internal
        pure
        returns (uint256)
    {
        _requireReserves(virtualEth, virtualToken);
        return Math.mulDiv(virtualEth, tokensIn, virtualToken + tokensIn);
    }

    /// @notice Tokens to pair with `ethForPool` so the pool opens at the curve's current price
    /// `virtualEth / virtualToken`. Rounds down, so the pool never opens below the curve's price.
    function poolTokensForEth(uint256 ethForPool, uint256 virtualEth, uint256 virtualToken)
        internal
        pure
        returns (uint256)
    {
        _requireReserves(virtualEth, virtualToken);
        return Math.mulDiv(ethForPool, virtualToken, virtualEth);
    }

    function _requireReserves(uint256 virtualEth, uint256 virtualToken) private pure {
        if (virtualEth == 0 || virtualToken == 0) revert EmptyReserves();
    }
}
