// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BondingCurve} from "../src/BondingCurve.sol";
import {FeeVault} from "../src/FeeVault.sol";
import {GraduationLocker} from "../src/GraduationLocker.sol";
import {LaunchFactory} from "../src/LaunchFactory.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {PoolSwapper} from "../test/utils/PoolSwapper.sol";
import {LockerSalt} from "./LockerSalt.sol";

contract SmokeTrader {
    receive() external payable {}

    function buyThenSellHalf(BondingCurve curve) external payable {
        curve.buy{value: msg.value}(0, block.timestamp);
        LaunchToken token = LaunchToken(address(curve.token()));
        uint256 half = token.balanceOf(address(this)) / 2;
        token.approve(address(curve), half);
        curve.sell(half, 0, block.timestamp);
    }

    function buy(BondingCurve curve) external payable {
        curve.buy{value: msg.value}(0, block.timestamp);
    }
}

/// @notice Gas-free end-to-end check against a live chain. Run its creation code with
/// `cast call --create` (an eth_call, nothing is broadcast) and enough overridden balance:
/// the constructor deploys everything, launches a coin, trades it, fills the curve, graduates it
/// into the chain's real Uniswap v4 PoolManager, swaps on the new pool and collects the fees.
/// It reverts with a reason if any step misbehaves.
contract TestnetSmoke {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager internal constant POOL_MANAGER =
        IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);

    constructor() payable {
        FeeVault vault = new FeeVault(address(this));
        LaunchFactory.Settings memory settings = LaunchFactory.Settings({
            owner: address(this),
            feeVault: address(vault),
            targetRaise: 4 ether,
            platformFeeBps: 95,
            creatorFeeBps: 30,
            antiSnipeFeeBps: 5_000,
            antiSnipeDuration: 30,
            maxCreatorBuyBps: 500,
            maxCreatorBuyEth: 0.5 ether,
            poolManager: address(POOL_MANAGER),
            lockerSalt: bytes32(0),
            poolFee: 10_000,
            tickSpacing: 200,
            lockerCreatorShareBps: 5_000,
            graduationFee: 0.02 ether,
            graduationReward: 0.001 ether
        });

        // The vault used this contract's nonce 1, so the factory will be created with nonce 2.
        address predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(hex"d694", address(this), hex"02"))))
        );
        (settings.lockerSalt,) = LockerSalt.find(predicted, settings);
        LaunchFactory factory = new LaunchFactory(settings);
        require(address(factory) == predicted, "factory address");
        GraduationLocker locker = GraduationLocker(payable(factory.locker()));

        (address tokenAddress, address curveAddress) =
            factory.createCoin{value: 0.01 ether}("Smoke", "SMOKE", 1, block.timestamp);
        BondingCurve curve = BondingCurve(curveAddress);
        LaunchToken token = LaunchToken(tokenAddress);
        require(token.balanceOf(address(this)) > 0, "creator buy failed");

        SmokeTrader trader = new SmokeTrader();
        trader.buyThenSellHalf{value: 0.1 ether}(curve);
        require(address(trader).balance > 0, "sell paid nothing");

        new SmokeTrader().buy{value: 20 ether}(curve);
        require(curve.state() == BondingCurve.State.Complete, "curve not complete");

        curve.graduate();
        require(curve.state() == BondingCurve.State.Graduated, "not graduated");
        require(address(curve).balance == curve.creatorFeesAccrued(), "curve eth left over");
        require(token.balanceOf(address(curve)) == 0, "curve tokens left over");

        PoolKey memory key = locker.poolKey(tokenAddress);
        require(POOL_MANAGER.getLiquidity(key.toId()) > 0, "pool has no liquidity");

        PoolSwapper swapper = new PoolSwapper(POOL_MANAGER);
        require(swapper.buy{value: 0.5 ether}(key) > 0, "pool swap failed");

        (uint256 ethFees,) = locker.collectFees(tokenAddress);
        require(ethFees > 0, "no swap fees");
        require(locker.claim(address(0)) > 0, "creator fee claim failed");
        require(curve.claimCreatorFees() > 0, "curve creator fees");
        require(address(vault).balance > 0, "no platform fees");
    }
}
