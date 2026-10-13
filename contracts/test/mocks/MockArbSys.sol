// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/// @notice Stand-in for the ArbSys precompile at address 100, which does not exist on a local chain.
/// Returns `block.number`, so tests advance the "L2 block" with `vm.roll`.
contract MockArbSys {
    function arbBlockNumber() external view returns (uint256) {
        return block.number;
    }
}
