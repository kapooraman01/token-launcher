// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {LaunchFactory} from "../../src/LaunchFactory.sol";
import {LockerSalt} from "../../script/LockerSalt.sol";

/// @notice Deploys a LaunchFactory from the test contract, mining the locker salt first.
abstract contract FactoryDeployer is Test {
    /// Robinhood Chain's Uniswap v4 PoolManager (same address on mainnet and testnet).
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    function _defaultSettings(address owner, address feeVault)
        internal
        pure
        returns (LaunchFactory.Settings memory)
    {
        return LaunchFactory.Settings({
            owner: owner,
            feeVault: feeVault,
            targetRaise: 4 ether,
            platformFeeBps: 95,
            creatorFeeBps: 30,
            antiSnipeFeeBps: 5_000,
            antiSnipeDuration: 30,
            maxCreatorBuyBps: 500,
            maxCreatorBuyEth: 0.5 ether,
            poolManager: POOL_MANAGER,
            lockerSalt: bytes32(0),
            poolFee: 10_000,
            tickSpacing: 200,
            lockerCreatorShareBps: 5_000,
            graduationFee: 0.02 ether,
            graduationReward: 0.001 ether
        });
    }

    function _deployFactory(LaunchFactory.Settings memory settings)
        internal
        returns (LaunchFactory)
    {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        (settings.lockerSalt,) = LockerSalt.find(predicted, settings);
        LaunchFactory factory = new LaunchFactory(settings);
        assertEq(address(factory), predicted, "factory address prediction");
        return factory;
    }
}
