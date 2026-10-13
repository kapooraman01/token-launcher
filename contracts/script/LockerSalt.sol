// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {GraduationLocker} from "../src/GraduationLocker.sol";
import {LaunchFactory} from "../src/LaunchFactory.sol";

/// @notice Finds the CREATE2 salt that places the factory's GraduationLocker at an address whose
/// hook-permission bits are exactly `beforeInitialize`. Uniswap v4 reads a hook's permissions from
/// its address, so the locker's constructor rejects any other address.
library LockerSalt {
    uint256 internal constant MAX_ATTEMPTS = 1_000_000;

    error SaltNotFound();

    function find(address factory, LaunchFactory.Settings memory settings)
        internal
        pure
        returns (bytes32 salt, address locker)
    {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(GraduationLocker).creationCode,
                abi.encode(
                    IPoolManager(settings.poolManager),
                    settings.feeVault,
                    settings.poolFee,
                    settings.tickSpacing,
                    settings.lockerCreatorShareBps
                )
            )
        );
        for (uint256 i = 0; i < MAX_ATTEMPTS; i++) {
            salt = bytes32(i);
            locker = address(
                uint160(
                    uint256(keccak256(abi.encodePacked(bytes1(0xff), factory, salt, initCodeHash)))
                )
            );
            if (uint160(locker) & Hooks.ALL_HOOK_MASK == Hooks.BEFORE_INITIALIZE_FLAG) {
                return (salt, locker);
            }
        }
        revert SaltNotFound();
    }
}
