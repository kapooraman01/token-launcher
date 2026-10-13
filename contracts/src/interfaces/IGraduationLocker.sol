// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

interface IGraduationLocker {
    function graduate(address token, address creator, uint256 tokenAmount) external payable;
}
