// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Records what a curve hands over at graduation, without a real Uniswap pool.
contract MockLocker {
    uint256 public calls;
    address public lastToken;
    address public lastCreator;
    uint256 public lastTokenAmount;
    uint256 public lastEth;

    function graduate(address token, address creator, uint256 tokenAmount) external payable {
        require(IERC20(token).transferFrom(msg.sender, address(this), tokenAmount), "pull");
        calls++;
        lastToken = token;
        lastCreator = creator;
        lastTokenAmount = tokenAmount;
        lastEth = msg.value;
    }
}
