// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {BondingCurveMath} from "../src/libraries/BondingCurveMath.sol";

contract BondingCurveMathHarness {
    function tokensOutForEthIn(uint256 virtualEth, uint256 virtualToken, uint256 ethIn)
        external
        pure
        returns (uint256)
    {
        return BondingCurveMath.tokensOutForEthIn(virtualEth, virtualToken, ethIn);
    }

    function ethInForTokensOut(uint256 virtualEth, uint256 virtualToken, uint256 tokensOut)
        external
        pure
        returns (uint256)
    {
        return BondingCurveMath.ethInForTokensOut(virtualEth, virtualToken, tokensOut);
    }

    function ethOutForTokensIn(uint256 virtualEth, uint256 virtualToken, uint256 tokensIn)
        external
        pure
        returns (uint256)
    {
        return BondingCurveMath.ethOutForTokensIn(virtualEth, virtualToken, tokensIn);
    }
}

contract BondingCurveMathTest is Test {
    uint256 internal constant V0 = BondingCurveMath.INITIAL_VIRTUAL_TOKEN_RESERVE;
    uint256 internal constant CURVE_SUPPLY = BondingCurveMath.CURVE_SUPPLY;

    BondingCurveMathHarness internal harness;

    function setUp() public {
        harness = new BondingCurveMathHarness();
    }

    // ---------------------------------------------------------------------
    // Hand-calculated values (independently computed with arbitrary precision)
    // ---------------------------------------------------------------------

    function test_SupplySplitAddsUpToTotalSupply() public pure {
        assertEq(
            BondingCurveMath.CURVE_SUPPLY + BondingCurveMath.POOL_SUPPLY,
            BondingCurveMath.TOTAL_SUPPLY
        );
        assertEq(BondingCurveMath.TOTAL_SUPPLY, 1_000_000_000 ether);
        assertEq(BondingCurveMath.FINAL_VIRTUAL_TOKEN_RESERVE, 279_900_000 ether);
    }

    function test_InitialVirtualEthForFourEthRaise() public pure {
        assertEq(BondingCurveMath.initialVirtualEth(4 ether), 1_411_675_702_937_838_861);
    }

    function test_TokensOutForOneEth() public pure {
        uint256 out = BondingCurveMath.tokensOutForEthIn(30 ether, V0, 1 ether);
        assertEq(out, 34_612_903_225_806_451_612_903_225);
    }

    function test_EthInForTokensOutRoundsUp() public pure {
        uint256 ethIn =
            BondingCurveMath.ethInForTokensOut(30 ether, V0, 34_612_903_225_806_451_612_903_225);
        assertEq(ethIn, 1 ether);
    }

    function test_SellingBackReturnsSlightlyLessThanPaid() public pure {
        uint256 out = 34_612_903_225_806_451_612_903_225;
        uint256 ethOut = BondingCurveMath.ethOutForTokensIn(31 ether, V0 - out, out);
        assertEq(ethOut, 1 ether - 1);
    }

    function test_BuyingWholeCurveCostsTargetRaisePlusRounding() public pure {
        uint256 virtualEth = BondingCurveMath.initialVirtualEth(4 ether);
        uint256 cost = BondingCurveMath.ethInForTokensOut(virtualEth, V0, CURVE_SUPPLY);
        assertEq(cost, 4 ether + 3);
    }

    function test_ZeroInputsGiveZeroOutputs() public pure {
        assertEq(BondingCurveMath.tokensOutForEthIn(30 ether, V0, 0), 0);
        assertEq(BondingCurveMath.ethInForTokensOut(30 ether, V0, 0), 0);
        assertEq(BondingCurveMath.ethOutForTokensIn(30 ether, V0, 0), 0);
    }

    function test_DustBuyGivesNoFreeTokens() public pure {
        // One token unit is worth a fraction of a wei here; rounding up still charges 1 wei.
        assertEq(BondingCurveMath.ethInForTokensOut(30 ether, V0, 1), 1);
    }

    // ---------------------------------------------------------------------
    // Reverts
    // ---------------------------------------------------------------------

    function test_RevertWhen_ReservesAreEmpty() public {
        vm.expectRevert(BondingCurveMath.EmptyReserves.selector);
        harness.tokensOutForEthIn(0, V0, 1 ether);

        vm.expectRevert(BondingCurveMath.EmptyReserves.selector);
        harness.ethInForTokensOut(30 ether, 0, 1);

        vm.expectRevert(BondingCurveMath.EmptyReserves.selector);
        harness.ethOutForTokensIn(0, 0, 1);
    }

    function test_RevertWhen_BuyingEntireTokenReserve() public {
        vm.expectRevert(BondingCurveMath.InsufficientTokenReserve.selector);
        harness.ethInForTokensOut(30 ether, V0, V0);

        vm.expectRevert(BondingCurveMath.InsufficientTokenReserve.selector);
        harness.ethInForTokensOut(30 ether, V0, V0 + 1);
    }

    // ---------------------------------------------------------------------
    // Fuzz properties
    // ---------------------------------------------------------------------

    function _boundReserves(uint256 virtualEth, uint256 virtualToken)
        internal
        pure
        returns (uint256, uint256)
    {
        return (bound(virtualEth, 1e12, 1e24), bound(virtualToken, 1e18, V0));
    }

    function testFuzz_BuyNeverDecreasesK(uint256 virtualEth, uint256 virtualToken, uint256 ethIn)
        public
        pure
    {
        (virtualEth, virtualToken) = _boundReserves(virtualEth, virtualToken);
        ethIn = bound(ethIn, 0, 1e24);

        uint256 out = BondingCurveMath.tokensOutForEthIn(virtualEth, virtualToken, ethIn);

        assertLt(out, virtualToken);
        assertGe((virtualEth + ethIn) * (virtualToken - out), virtualEth * virtualToken);
    }

    function testFuzz_SellNeverDecreasesK(
        uint256 virtualEth,
        uint256 virtualToken,
        uint256 tokensIn
    ) public pure {
        (virtualEth, virtualToken) = _boundReserves(virtualEth, virtualToken);
        tokensIn = bound(tokensIn, 0, V0);

        uint256 ethOut = BondingCurveMath.ethOutForTokensIn(virtualEth, virtualToken, tokensIn);

        assertLt(ethOut, virtualEth);
        assertGe((virtualEth - ethOut) * (virtualToken + tokensIn), virtualEth * virtualToken);
    }

    function testFuzz_ExactOutBuyNeverDecreasesK(
        uint256 virtualEth,
        uint256 virtualToken,
        uint256 tokensOut
    ) public pure {
        (virtualEth, virtualToken) = _boundReserves(virtualEth, virtualToken);
        tokensOut = bound(tokensOut, 0, virtualToken - 1);

        uint256 ethIn = BondingCurveMath.ethInForTokensOut(virtualEth, virtualToken, tokensOut);

        assertGe((virtualEth + ethIn) * (virtualToken - tokensOut), virtualEth * virtualToken);
    }

    function testFuzz_BuyThenSellNeverProfits(
        uint256 virtualEth,
        uint256 virtualToken,
        uint256 ethIn
    ) public pure {
        (virtualEth, virtualToken) = _boundReserves(virtualEth, virtualToken);
        ethIn = bound(ethIn, 0, 1e24);

        uint256 out = BondingCurveMath.tokensOutForEthIn(virtualEth, virtualToken, ethIn);
        uint256 ethBack =
            BondingCurveMath.ethOutForTokensIn(virtualEth + ethIn, virtualToken - out, out);

        assertLe(ethBack, ethIn);
    }

    function testFuzz_SplitBuyNeverBeatsSingleBuy(
        uint256 virtualEth,
        uint256 virtualToken,
        uint256 first,
        uint256 second
    ) public pure {
        (virtualEth, virtualToken) = _boundReserves(virtualEth, virtualToken);
        first = bound(first, 0, 1e24);
        second = bound(second, 0, 1e24);

        uint256 outA = BondingCurveMath.tokensOutForEthIn(virtualEth, virtualToken, first);
        uint256 outB =
            BondingCurveMath.tokensOutForEthIn(virtualEth + first, virtualToken - outA, second);
        uint256 single =
            BondingCurveMath.tokensOutForEthIn(virtualEth, virtualToken, first + second);

        assertLe(outA + outB, single);
    }

    function testFuzz_SplitSellNeverBeatsSingleSell(
        uint256 virtualEth,
        uint256 virtualToken,
        uint256 first,
        uint256 second
    ) public pure {
        (virtualEth, virtualToken) = _boundReserves(virtualEth, virtualToken);
        first = bound(first, 0, V0);
        second = bound(second, 0, V0);

        uint256 ethA = BondingCurveMath.ethOutForTokensIn(virtualEth, virtualToken, first);
        uint256 ethB =
            BondingCurveMath.ethOutForTokensIn(virtualEth - ethA, virtualToken + first, second);
        uint256 single =
            BondingCurveMath.ethOutForTokensIn(virtualEth, virtualToken, first + second);

        assertLe(ethA + ethB, single);
    }

    function testFuzz_MoreEthNeverBuysFewerTokens(
        uint256 virtualEth,
        uint256 virtualToken,
        uint256 small,
        uint256 large
    ) public pure {
        (virtualEth, virtualToken) = _boundReserves(virtualEth, virtualToken);
        small = bound(small, 0, 1e24);
        large = bound(large, small, 1e24);

        assertLe(
            BondingCurveMath.tokensOutForEthIn(virtualEth, virtualToken, small),
            BondingCurveMath.tokensOutForEthIn(virtualEth, virtualToken, large)
        );
    }

    function testFuzz_PriceRisesOnBuy(uint256 virtualEth, uint256 virtualToken, uint256 ethIn)
        public
        pure
    {
        (virtualEth, virtualToken) = _boundReserves(virtualEth, virtualToken);
        ethIn = bound(ethIn, 1, 1e24);

        uint256 out = BondingCurveMath.tokensOutForEthIn(virtualEth, virtualToken, ethIn);

        // newEth / newToken >= oldEth / oldToken, compared by cross-multiplication.
        assertGe((virtualEth + ethIn) * virtualToken, virtualEth * (virtualToken - out));
    }

    function testFuzz_ExactOutQuoteDeliversAtLeastRequestedTokens(
        uint256 virtualEth,
        uint256 virtualToken,
        uint256 tokensOut
    ) public pure {
        (virtualEth, virtualToken) = _boundReserves(virtualEth, virtualToken);
        tokensOut = bound(tokensOut, 0, virtualToken - 1);

        uint256 ethIn = BondingCurveMath.ethInForTokensOut(virtualEth, virtualToken, tokensOut);
        vm.assume(ethIn <= type(uint128).max);

        assertGe(BondingCurveMath.tokensOutForEthIn(virtualEth, virtualToken, ethIn), tokensOut);
    }

    function testFuzz_FullCurveRaisesAtLeastTarget(uint256 targetRaise) public pure {
        targetRaise = bound(targetRaise, 0.01 ether, 10_000 ether);

        uint256 virtualEth = BondingCurveMath.initialVirtualEth(targetRaise);
        uint256 cost = BondingCurveMath.ethInForTokensOut(virtualEth, V0, CURVE_SUPPLY);

        assertGe(cost, targetRaise);
        assertLe(cost - targetRaise, 3);
    }
}
