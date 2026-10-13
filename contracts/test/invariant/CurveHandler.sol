// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {BondingCurve} from "../../src/BondingCurve.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";

/// @notice Drives random buys, sells, claims and time jumps against one curve, and records every
/// ETH flow in ghost variables so the invariants can check them against the curve's own books.
contract CurveHandler is Test {
    BondingCurve internal immutable curve;
    LaunchToken internal immutable token;
    address internal immutable creator;

    address[] internal actors;

    uint256 public ghostEthToCurve;
    uint256 public ghostGrossEthOut;
    uint256 public ghostPlatformFees;
    uint256 public ghostCreatorFees;
    uint256 public ghostCreatorClaimed;
    uint256 public ghostGraduationToVault;
    bool public ghostCompleted;
    bool public ghostGraduated;

    uint256 public buys;
    uint256 public sells;
    uint256 public claims;
    uint256 public graduations;

    constructor(BondingCurve curve_, LaunchToken token_, address creator_) {
        curve = curve_;
        token = token_;
        creator = creator_;
        for (uint256 i = 0; i < 5; i++) {
            actors.push(makeAddr(string.concat("actor", vm.toString(i))));
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 index) external view returns (address) {
        return actors[index];
    }

    function buy(uint256 actorSeed, uint256 ethIn) external {
        if (curve.state() != BondingCurve.State.Trading) return;
        address actor = actors[actorSeed % actors.length];
        ethIn = bound(ethIn, 1 gwei, 2 ether);

        vm.roll(block.number + 1);
        BondingCurve.BuyQuote memory quote = curve.quoteBuy(ethIn);
        if (quote.tokensOut == 0) return;

        vm.deal(actor, ethIn);
        vm.prank(actor);
        curve.buy{value: ethIn}(quote.tokensOut, block.timestamp);

        ghostEthToCurve += quote.ethToCurve;
        ghostPlatformFees += quote.platformFee;
        ghostCreatorFees += quote.creatorFee;
        if (curve.state() == BondingCurve.State.Complete) ghostCompleted = true;
        buys++;
    }

    function sell(uint256 actorSeed, uint256 amount) external {
        if (curve.state() != BondingCurve.State.Trading) return;
        address actor = actors[actorSeed % actors.length];
        uint256 balance = token.balanceOf(actor);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);

        BondingCurve.SellQuote memory quote = curve.quoteSell(amount);
        if (quote.ethOut == 0) return;

        vm.startPrank(actor);
        token.approve(address(curve), amount);
        curve.sell(amount, quote.ethOut, block.timestamp);
        vm.stopPrank();

        ghostGrossEthOut += quote.grossEth;
        ghostPlatformFees += quote.platformFee;
        ghostCreatorFees += quote.creatorFee;
        sells++;
    }

    function claimCreatorFees() external {
        if (curve.creatorFeesAccrued() == 0) return;
        vm.prank(creator);
        ghostCreatorClaimed += curve.claimCreatorFees();
        claims++;
    }

    function graduate(uint256 callerSeed) external {
        if (curve.state() != BondingCurve.State.Complete) return;
        address caller = actors[callerSeed % actors.length];
        uint256 toVault = address(curve).balance - curve.creatorFeesAccrued()
            - (curve.realEthReserve() - curve.graduationFee()) - curve.graduationReward();

        vm.prank(caller);
        curve.graduate();

        ghostGraduationToVault += toVault;
        ghostGraduated = true;
        graduations++;
    }

    function passTime(uint256 seconds_) external {
        seconds_ = bound(seconds_, 1, 60);
        vm.warp(block.timestamp + seconds_);
        vm.roll(block.number + 1);
    }
}
