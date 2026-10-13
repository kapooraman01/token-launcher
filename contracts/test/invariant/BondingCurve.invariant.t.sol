// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {BondingCurve} from "../../src/BondingCurve.sol";
import {BondingCurveMath} from "../../src/libraries/BondingCurveMath.sol";
import {CurveTestBase} from "../utils/CurveTestBase.sol";
import {CurveHandler} from "./CurveHandler.sol";

contract BondingCurveInvariantTest is CurveTestBase {
    CurveHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new CurveHandler(curve, token, creator);

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = CurveHandler.buy.selector;
        selectors[1] = CurveHandler.sell.selector;
        selectors[2] = CurveHandler.claimCreatorFees.selector;
        selectors[3] = CurveHandler.passTime.selector;
        selectors[4] = CurveHandler.graduate.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_TotalSupplyNeverChanges() public view {
        assertEq(token.totalSupply(), BondingCurveMath.TOTAL_SUPPLY);
    }

    function invariant_EveryTokenIsAccountedFor() public view {
        uint256 held = token.balanceOf(address(curve)) + token.balanceOf(address(locker))
            + token.balanceOf(curve.DEAD());
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            held += token.balanceOf(handler.actorAt(i));
        }
        assertEq(held, BondingCurveMath.TOTAL_SUPPLY);

        if (handler.ghostGraduated()) {
            assertEq(token.balanceOf(address(curve)), 0);
            assertEq(
                token.balanceOf(address(locker)) + token.balanceOf(curve.DEAD()),
                BondingCurveMath.POOL_SUPPLY
            );
        } else {
            assertEq(
                token.balanceOf(address(curve)),
                BondingCurveMath.POOL_SUPPLY + curve.tokensRemaining()
            );
        }
    }

    function invariant_NoEthIsStranded() public view {
        _assertEthAccounted();
    }

    function invariant_CurveCanPayEveryHolder() public view {
        if (handler.ghostGraduated()) return; // liquidity now lives in the Uniswap pool
        uint256 circulating =
            BondingCurveMath.INITIAL_VIRTUAL_TOKEN_RESERVE - curve.virtualTokenReserve();
        uint256 owedIfAllSell = BondingCurveMath.ethOutForTokensIn(
            curve.virtualEthReserve(), curve.virtualTokenReserve(), circulating
        );
        assertGe(curve.realEthReserve(), owedIfAllSell);
    }

    function invariant_KNeverFallsBelowStart() public view {
        if (handler.ghostGraduated()) return;
        assertGe(
            curve.virtualEthReserve() * curve.virtualTokenReserve(),
            curve.initialVirtualEth() * BondingCurveMath.INITIAL_VIRTUAL_TOKEN_RESERVE
        );
    }

    function invariant_ReservesMatchRecordedFlows() public view {
        if (handler.ghostGraduated()) {
            assertEq(curve.realEthReserve(), 0);
            assertEq(
                locker.lastEth(),
                handler.ghostEthToCurve() - handler.ghostGrossEthOut() - GRADUATION_FEE
            );
        } else {
            assertEq(curve.realEthReserve(), handler.ghostEthToCurve() - handler.ghostGrossEthOut());
        }
        assertEq(feeVault.balance, handler.ghostPlatformFees() + handler.ghostGraduationToVault());
        assertEq(
            curve.creatorFeesAccrued(), handler.ghostCreatorFees() - handler.ghostCreatorClaimed()
        );
        assertEq(creator.balance, handler.ghostCreatorClaimed());
    }

    function invariant_StateOnlyMovesForward() public view {
        if (handler.ghostGraduated()) {
            assertEq(uint256(curve.state()), uint256(BondingCurve.State.Graduated));
        } else if (handler.ghostCompleted()) {
            assertEq(uint256(curve.state()), uint256(BondingCurve.State.Complete));
            assertEq(curve.tokensRemaining(), 0);
            assertGe(curve.realEthReserve(), TARGET_RAISE);
        }
    }

    function afterInvariant() external view {
        assertGt(handler.buys(), 0, "no buys exercised");
    }
}
