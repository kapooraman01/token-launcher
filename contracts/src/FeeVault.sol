// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title FeeVault
/// @notice Collects platform fees from every bonding curve. Curves push fees here on each trade,
/// so `receive` must never revert; it does nothing. Only platform revenue lives here, never user
/// funds. After graduation it also receives the platform's share of Uniswap swap fees, which are
/// paid in both ETH and the coin's token.
contract FeeVault is Ownable2Step {
    using SafeERC20 for IERC20;

    event Withdrawn(address indexed to, uint256 amount);
    event TokenWithdrawn(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error EthTransferFailed();

    constructor(address initialOwner) Ownable(initialOwner) {}

    receive() external payable {}

    function withdraw(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        emit Withdrawn(to, amount);
        (bool success,) = to.call{value: amount}("");
        if (!success) revert EthTransferFailed();
    }

    function withdrawToken(IERC20 token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        emit TokenWithdrawn(address(token), to, amount);
        token.safeTransfer(to, amount);
    }
}
