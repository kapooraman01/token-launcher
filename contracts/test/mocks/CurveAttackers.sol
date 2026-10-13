// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";

/// @notice Tries to re-enter the curve from its `receive` hook and records what happened.
contract ReentrantTrader {
    BondingCurve internal immutable curve;
    bool internal reentering;
    bytes public reentryError;
    bool public reentrySucceeded;

    constructor(BondingCurve curve_) {
        curve = curve_;
    }

    function buy() external payable {
        curve.buy{value: msg.value}(0, block.timestamp);
    }

    function sellAll() external {
        IERC20 token = curve.token();
        uint256 balance = token.balanceOf(address(this));
        token.approve(address(curve), type(uint256).max);
        reentering = true;
        curve.sell(balance / 2, 0, block.timestamp);
        reentering = false;
    }

    receive() external payable {
        if (!reentering) return;
        uint256 balance = curve.token().balanceOf(address(this));
        try curve.sell(balance, 0, block.timestamp) {
            reentrySucceeded = true;
        } catch (bytes memory err) {
            reentryError = err;
        }
    }
}

/// @notice A contract that cannot receive ETH.
contract EthRejecter {
    function buy(BondingCurve curve) external payable {
        curve.buy{value: msg.value}(0, block.timestamp);
    }
}
