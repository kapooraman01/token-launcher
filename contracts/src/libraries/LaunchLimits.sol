// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/// @title LaunchLimits
/// @notice Hard caps compiled into the contracts. No admin setting can ever exceed these.
library LaunchLimits {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_TRADE_FEE_BPS = 200;
    uint256 internal constant MAX_ANTI_SNIPE_FEE_BPS = 8_000;
    uint256 internal constant MAX_ANTI_SNIPE_DURATION = 5 minutes;
    uint256 internal constant MIN_TARGET_RAISE = 0.1 ether;
    uint256 internal constant MAX_TARGET_RAISE = 1_000 ether;
    uint256 internal constant MAX_CREATOR_BUY_BPS = 1_000;

    /// @dev Uniswap v4 fee units are pips: 1_000_000 = 100%, so 30_000 = 3%.
    uint24 internal constant MAX_POOL_FEE = 30_000;
    uint256 internal constant MAX_GRADUATION_FEE_BPS_OF_RAISE = 500;
}
