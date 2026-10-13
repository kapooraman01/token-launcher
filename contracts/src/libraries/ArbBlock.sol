// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

interface IArbSys {
    function arbBlockNumber() external view returns (uint256);
}

/// @title ArbBlock
/// @notice On Arbitrum chains `block.number` is an approximate L1 block number shared by many L2
/// blocks. The real L2 block number is only available from the ArbSys precompile.
library ArbBlock {
    IArbSys internal constant ARB_SYS = IArbSys(address(100));

    function number() internal view returns (uint256) {
        return ARB_SYS.arbBlockNumber();
    }
}
