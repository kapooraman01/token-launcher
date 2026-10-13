// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {FeeVault} from "../src/FeeVault.sol";
import {LaunchFactory} from "../src/LaunchFactory.sol";
import {LockerSalt} from "./LockerSalt.sol";

/// @notice Deploys the FeeVault and LaunchFactory (which deploys the GraduationLocker). `OWNER` is
/// required; every other setting falls back to the agreed proposals and can be overridden
/// through the environment.
contract Deploy is Script {
    /// Uniswap v4 PoolManager on Robinhood Chain mainnet and testnet.
    address internal constant ROBINHOOD_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    function run() external returns (FeeVault vault, LaunchFactory factory) {
        LaunchFactory.Settings memory settings = LaunchFactory.Settings({
            owner: vm.envAddress("OWNER"),
            feeVault: address(0),
            targetRaise: vm.envOr("TARGET_RAISE_WEI", uint256(4 ether)),
            platformFeeBps: uint16(vm.envOr("PLATFORM_FEE_BPS", uint256(95))),
            creatorFeeBps: uint16(vm.envOr("CREATOR_FEE_BPS", uint256(30))),
            antiSnipeFeeBps: uint16(vm.envOr("ANTI_SNIPE_FEE_BPS", uint256(5_000))),
            antiSnipeDuration: uint32(vm.envOr("ANTI_SNIPE_DURATION_SECONDS", uint256(30))),
            maxCreatorBuyBps: uint16(vm.envOr("MAX_CREATOR_BUY_BPS", uint256(500))),
            maxCreatorBuyEth: vm.envOr("MAX_CREATOR_BUY_WEI", uint256(0.5 ether)),
            poolManager: vm.envOr("POOL_MANAGER", ROBINHOOD_POOL_MANAGER),
            lockerSalt: bytes32(0),
            poolFee: uint24(vm.envOr("POOL_FEE_PIPS", uint256(10_000))),
            tickSpacing: int24(int256(vm.envOr("TICK_SPACING", uint256(200)))),
            lockerCreatorShareBps: uint16(vm.envOr("POOL_CREATOR_SHARE_BPS", uint256(5_000))),
            graduationFee: vm.envOr("GRADUATION_FEE_WEI", uint256(0.02 ether)),
            graduationReward: vm.envOr("GRADUATION_REWARD_WEI", uint256(0.001 ether))
        });

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();

        vault = new FeeVault(settings.owner);
        settings.feeVault = address(vault);

        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
        (settings.lockerSalt,) = LockerSalt.find(predicted, settings);
        factory = new LaunchFactory(settings);
        require(address(factory) == predicted, "factory address prediction failed");
        vm.stopBroadcast();

        console.log("FeeVault:         ", address(vault));
        console.log("LaunchFactory:    ", address(factory));
        console.log("GraduationLocker: ", factory.locker());
        console.log("Implementation:   ", factory.implementation());
    }
}
