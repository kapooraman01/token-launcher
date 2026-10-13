// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Minimal exact-input swapper against the real PoolManager, for tests only.
contract PoolSwapper is IUnlockCallback {
    IPoolManager internal immutable poolManager;

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
    }

    receive() external payable {}

    /// @notice Swaps all of `msg.value` for tokens, sent to the caller.
    function buy(PoolKey memory key) external payable returns (uint256 tokensOut) {
        tokensOut =
            abi.decode(poolManager.unlock(abi.encode(key, true, msg.value, msg.sender)), (uint256));
    }

    /// @notice Swaps `tokensIn` (pulled from the caller) for ETH, sent to the caller.
    function sell(PoolKey memory key, uint256 tokensIn) external returns (uint256 ethOut) {
        IERC20(Currency.unwrap(key.currency1)).transferFrom(msg.sender, address(this), tokensIn);
        ethOut =
            abi.decode(poolManager.unlock(abi.encode(key, false, tokensIn, msg.sender)), (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "only pool manager");
        (PoolKey memory key, bool ethIn, uint256 amountIn, address recipient) =
            abi.decode(data, (PoolKey, bool, uint256, address));

        BalanceDelta delta = poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: ethIn,
                amountSpecified: -SafeCast.toInt256(amountIn),
                sqrtPriceLimitX96: ethIn ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        uint256 amountOut;
        if (ethIn) {
            poolManager.settle{value: SafeCast.toUint256(-int256(delta.amount0()))}();
            amountOut = SafeCast.toUint256(delta.amount1());
            poolManager.take(key.currency1, recipient, amountOut);
        } else {
            poolManager.sync(key.currency1);
            IERC20(Currency.unwrap(key.currency1))
                .transfer(address(poolManager), SafeCast.toUint256(-int256(delta.amount1())));
            poolManager.settle();
            amountOut = SafeCast.toUint256(delta.amount0());
            poolManager.take(key.currency0, recipient, amountOut);
        }
        return abi.encode(amountOut);
    }
}
