// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/// @notice Emits events with exactly the same signatures as LaunchFactory and BondingCurve, to
/// prove the indexer only trusts events from the real factory and the curves it created.
contract ImpostorCurve {
    event CoinCreated(
        address indexed token,
        address indexed curve,
        address indexed creator,
        string name,
        string symbol,
        uint256 targetRaise,
        uint16 platformFeeBps,
        uint16 creatorFeeBps,
        uint16 antiSnipeFeeBps,
        uint32 antiSnipeDuration
    );
    event Buy(
        address indexed buyer,
        uint256 ethSpent,
        uint256 tokensOut,
        uint256 platformFee,
        uint256 creatorFee,
        uint256 virtualEthReserve,
        uint256 virtualTokenReserve
    );

    function fakeLaunch() external {
        emit CoinCreated(address(this), address(this), msg.sender, "Fake", "FAKE", 1, 0, 0, 0, 0);
    }

    function fakeBuy() external {
        emit Buy(msg.sender, 1 ether, 1, 0, 0, 1, 1);
    }
}
