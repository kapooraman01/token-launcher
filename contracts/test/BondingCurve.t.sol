// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {BondingCurve} from "../src/BondingCurve.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {BondingCurveMath} from "../src/libraries/BondingCurveMath.sol";
import {CurveTestBase} from "./utils/CurveTestBase.sol";
import {EthRejecter, ReentrantTrader} from "./mocks/CurveAttackers.sol";

contract BondingCurveTest is CurveTestBase {
    uint256 internal constant TRADE_FEE_BPS = PLATFORM_FEE_BPS + CREATOR_FEE_BPS;
    uint256 internal constant V0 = BondingCurveMath.INITIAL_VIRTUAL_TOKEN_RESERVE;

    // ---------------------------------------------------------------------
    // Initialisation
    // ---------------------------------------------------------------------

    function test_InitialState() public view {
        assertEq(curve.factory(), address(this));
        assertEq(address(curve.token()), address(token));
        assertEq(curve.creator(), creator);
        assertEq(curve.feeVault(), feeVault);
        assertEq(uint256(curve.state()), uint256(BondingCurve.State.Trading));
        assertEq(curve.launchedAt(), block.timestamp);
        assertEq(curve.initialVirtualEth(), BondingCurveMath.initialVirtualEth(TARGET_RAISE));
        assertEq(curve.virtualTokenReserve(), V0);
        assertEq(curve.realEthReserve(), 0);
        assertEq(curve.tokensRemaining(), BondingCurveMath.CURVE_SUPPLY);
        assertEq(token.balanceOf(address(curve)), BondingCurveMath.TOTAL_SUPPLY);
    }

    function test_RevertWhen_InitialisedTwice() public {
        BondingCurve.Config memory config = _defaultConfig();
        config.token = address(token);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        curve.initialize(config);
    }

    function test_RevertWhen_ImplementationInitialised() public {
        BondingCurve.Config memory config = _defaultConfig();
        config.token = address(token);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(config);
    }

    function test_RevertWhen_NonFactoryInitialises() public {
        BondingCurve fresh = BondingCurve(Clones.clone(address(implementation)));
        BondingCurve.Config memory config = _defaultConfig();
        config.token = address(new LaunchToken("X", "X", address(fresh)));

        vm.prank(alice);
        vm.expectRevert(BondingCurve.OnlyFactory.selector);
        fresh.initialize(config);
    }

    function test_RevertWhen_ConfigIsInvalid() public {
        BondingCurve.Config memory config;

        config = _defaultConfig();
        config.creator = address(0);
        _expectLaunchRevert(config, BondingCurve.ZeroAddress.selector);

        config = _defaultConfig();
        config.feeVault = address(0);
        _expectLaunchRevert(config, BondingCurve.ZeroAddress.selector);

        config = _defaultConfig();
        config.targetRaise = 0.1 ether - 1;
        _expectLaunchRevert(config, BondingCurve.InvalidTargetRaise.selector);

        config = _defaultConfig();
        config.targetRaise = 1_000 ether + 1;
        _expectLaunchRevert(config, BondingCurve.InvalidTargetRaise.selector);

        config = _defaultConfig();
        config.platformFeeBps = 150;
        config.creatorFeeBps = 51;
        _expectLaunchRevert(config, BondingCurve.FeeTooHigh.selector);

        config = _defaultConfig();
        config.antiSnipeFeeBps = 8_001;
        _expectLaunchRevert(config, BondingCurve.InvalidAntiSnipe.selector);

        config = _defaultConfig();
        config.antiSnipeDuration = 5 minutes + 1;
        _expectLaunchRevert(config, BondingCurve.InvalidAntiSnipe.selector);
    }

    function test_RevertWhen_TokenSupplyNotHeldByCurve() public {
        BondingCurve fresh = BondingCurve(Clones.clone(address(implementation)));
        BondingCurve.Config memory config = _defaultConfig();
        config.token = address(new LaunchToken("X", "X", alice));

        vm.expectRevert(BondingCurve.InvalidToken.selector);
        fresh.initialize(config);
    }

    function test_RevertWhen_TokenIsZeroAddress() public {
        BondingCurve fresh = BondingCurve(Clones.clone(address(implementation)));
        vm.expectRevert(BondingCurve.ZeroAddress.selector);
        fresh.initialize(_defaultConfig());
    }

    function _expectLaunchRevert(BondingCurve.Config memory config, bytes4 selector) internal {
        BondingCurve fresh = BondingCurve(Clones.clone(address(implementation)));
        config.token = address(new LaunchToken("X", "X", address(fresh)));
        vm.expectRevert(selector);
        fresh.initialize(config);
    }

    // ---------------------------------------------------------------------
    // Buy
    // ---------------------------------------------------------------------

    function test_BuyAfterAntiSnipeWindow() public {
        _skipAntiSnipe();
        uint256 ethIn = 0.1 ether;
        uint256 fee = ethIn * TRADE_FEE_BPS / 10_000;
        uint256 creatorFee = fee * CREATOR_FEE_BPS / TRADE_FEE_BPS;
        uint256 expectedOut =
            BondingCurveMath.tokensOutForEthIn(curve.initialVirtualEth(), V0, ethIn - fee);

        vm.expectEmit(address(curve));
        emit BondingCurve.Buy(
            alice,
            ethIn,
            expectedOut,
            fee - creatorFee,
            creatorFee,
            curve.initialVirtualEth() + ethIn - fee,
            V0 - expectedOut
        );
        uint256 out = _buy(alice, ethIn);

        assertEq(out, expectedOut);
        assertEq(token.balanceOf(alice), expectedOut);
        assertEq(feeVault.balance, fee - creatorFee);
        assertEq(curve.creatorFeesAccrued(), creatorFee);
        assertEq(curve.realEthReserve(), ethIn - fee);
        assertEq(curve.virtualTokenReserve(), V0 - expectedOut);
        assertEq(alice.balance, 0);
        _assertEthAccounted();
    }

    function test_QuoteBuyMatchesBuy() public {
        _skipAntiSnipe();
        BondingCurve.BuyQuote memory quote = curve.quoteBuy(1 ether);
        uint256 out = _buy(alice, 1 ether);
        assertEq(out, quote.tokensOut);
        assertEq(feeVault.balance, quote.platformFee);
        assertEq(curve.creatorFeesAccrued(), quote.creatorFee);
    }

    function test_RevertWhen_BuyDeadlinePassed() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(BondingCurve.DeadlineExpired.selector);
        curve.buy{value: 1 ether}(0, block.timestamp - 1);
    }

    function test_RevertWhen_BuyWithZeroEth() public {
        vm.prank(alice);
        vm.expectRevert(BondingCurve.ZeroAmount.selector);
        curve.buy(0, block.timestamp);
    }

    function test_RevertWhen_BuySlippageExceeded() public {
        _skipAntiSnipe();
        uint256 quoted = curve.quoteBuy(1 ether).tokensOut;
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(BondingCurve.SlippageExceeded.selector);
        curve.buy{value: 1 ether}(quoted + 1, block.timestamp);
    }

    function test_RevertWhen_SecondBuyInSameL2Block() public {
        _buy(alice, 0.01 ether);

        vm.deal(alice, 0.01 ether);
        vm.prank(alice);
        vm.expectRevert(BondingCurve.OneBuyPerBlock.selector);
        curve.buy{value: 0.01 ether}(0, block.timestamp);

        _nextBlock();
        _buy(alice, 0.01 ether);
    }

    function test_DifferentWalletsCanBuyInSameBlock() public {
        _buy(alice, 0.01 ether);
        _buy(bob, 0.01 ether);
        assertGt(token.balanceOf(bob), 0);
    }

    function test_RevertWhen_DustBuyWouldGiveNoTokens() public {
        _skipAntiSnipe();
        vm.deal(alice, 1);
        vm.prank(alice);
        vm.expectRevert(BondingCurve.ZeroAmount.selector);
        curve.buy{value: 1}(0, block.timestamp);
    }

    function test_ZeroFeeCoinChargesNothing() public {
        BondingCurve.Config memory config = _defaultConfig();
        config.platformFeeBps = 0;
        config.creatorFeeBps = 0;
        config.antiSnipeFeeBps = 0;
        (curve, token) = _launch(config);

        uint256 bought = _buy(alice, 1 ether);
        assertEq(curve.realEthReserve(), 1 ether);
        _sell(alice, bought);

        assertEq(feeVault.balance, 0);
        assertEq(curve.creatorFeesAccrued(), 0);
        assertEq(alice.balance + curve.realEthReserve(), 1 ether);
    }

    function test_RevertWhen_PlainEthSent() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool success,) = address(curve).call{value: 1 ether}("");
        assertFalse(success);
    }

    // ---------------------------------------------------------------------
    // Anti-snipe fee
    // ---------------------------------------------------------------------

    function test_AntiSnipeFeeDecaysLinearly() public {
        assertEq(curve.currentAntiSnipeFeeBps(), ANTI_SNIPE_FEE_BPS);
        assertEq(curve.currentBuyFeeBps(), TRADE_FEE_BPS + ANTI_SNIPE_FEE_BPS);

        vm.warp(block.timestamp + ANTI_SNIPE_DURATION / 2);
        assertEq(curve.currentAntiSnipeFeeBps(), ANTI_SNIPE_FEE_BPS / 2);

        vm.warp(block.timestamp + ANTI_SNIPE_DURATION / 2);
        assertEq(curve.currentAntiSnipeFeeBps(), 0);
        assertEq(curve.currentBuyFeeBps(), TRADE_FEE_BPS);
    }

    function test_SniperPaysSurchargeToPlatform() public {
        uint256 ethIn = 1 ether;
        uint256 feeBps = TRADE_FEE_BPS + ANTI_SNIPE_FEE_BPS;
        uint256 fee = ethIn * feeBps / 10_000;
        uint256 creatorFee = fee * CREATOR_FEE_BPS / feeBps;

        _buy(alice, ethIn);

        assertEq(curve.realEthReserve(), ethIn - fee);
        assertEq(curve.creatorFeesAccrued(), creatorFee);
        assertEq(feeVault.balance, fee - creatorFee);
        assertApproxEqAbs(creatorFee, ethIn * CREATOR_FEE_BPS / 10_000, 1);
    }

    function test_NoAntiSnipeFeeWhenDurationIsZero() public {
        BondingCurve.Config memory config = _defaultConfig();
        config.antiSnipeDuration = 0;
        (BondingCurve fresh,) = _launch(config);
        assertEq(fresh.currentAntiSnipeFeeBps(), 0);
    }

    // ---------------------------------------------------------------------
    // Sell
    // ---------------------------------------------------------------------

    function test_Sell() public {
        _skipAntiSnipe();
        uint256 bought = _buy(alice, 1 ether);
        _nextBlock();

        uint256 sellAmount = bought / 2;
        uint256 gross = BondingCurveMath.ethOutForTokensIn(
            curve.virtualEthReserve(), curve.virtualTokenReserve(), sellAmount
        );
        uint256 fee = gross * TRADE_FEE_BPS / 10_000;
        uint256 creatorFee = fee * CREATOR_FEE_BPS / TRADE_FEE_BPS;
        uint256 vaultBefore = feeVault.balance;
        uint256 creatorBefore = curve.creatorFeesAccrued();
        uint256 reserveBefore = curve.realEthReserve();

        uint256 ethOut = _sell(alice, sellAmount);

        assertEq(ethOut, gross - fee);
        assertEq(alice.balance, gross - fee);
        assertEq(token.balanceOf(alice), bought - sellAmount);
        assertEq(feeVault.balance - vaultBefore, fee - creatorFee);
        assertEq(curve.creatorFeesAccrued() - creatorBefore, creatorFee);
        assertEq(reserveBefore - curve.realEthReserve(), gross);
        _assertEthAccounted();
    }

    function test_QuoteSellMatchesSell() public {
        _skipAntiSnipe();
        uint256 bought = _buy(alice, 1 ether);
        BondingCurve.SellQuote memory quote = curve.quoteSell(bought);
        assertEq(_sell(alice, bought), quote.ethOut);
    }

    function test_BuyThenSellEverythingLosesOnlyFees() public {
        _skipAntiSnipe();
        uint256 bought = _buy(alice, 1 ether);
        uint256 ethOut = _sell(alice, bought);

        assertLt(ethOut, 1 ether);
        assertEq(curve.virtualTokenReserve(), V0);
        assertLe(curve.realEthReserve(), 1);
        _assertEthAccounted();
    }

    function test_RevertWhen_SellZero() public {
        vm.prank(alice);
        vm.expectRevert(BondingCurve.ZeroAmount.selector);
        curve.sell(0, 0, block.timestamp);
    }

    function test_RevertWhen_DustSellWouldGiveNoEth() public {
        _buy(alice, 1 ether);
        vm.startPrank(alice);
        token.approve(address(curve), 1);
        vm.expectRevert(BondingCurve.ZeroAmount.selector);
        curve.sell(1, 0, block.timestamp);
        vm.stopPrank();
    }

    function test_RevertWhen_SellSlippageExceeded() public {
        _skipAntiSnipe();
        uint256 bought = _buy(alice, 1 ether);
        uint256 quoted = curve.quoteSell(bought).ethOut;

        vm.startPrank(alice);
        token.approve(address(curve), bought);
        vm.expectRevert(BondingCurve.SlippageExceeded.selector);
        curve.sell(bought, quoted + 1, block.timestamp);
        vm.stopPrank();
    }

    function test_RevertWhen_SellDeadlinePassed() public {
        uint256 bought = _buy(alice, 1 ether);
        vm.startPrank(alice);
        token.approve(address(curve), bought);
        vm.expectRevert(BondingCurve.DeadlineExpired.selector);
        curve.sell(bought, 0, block.timestamp - 1);
        vm.stopPrank();
    }

    function test_RevertWhen_SellWithoutApproval() public {
        uint256 bought = _buy(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert();
        curve.sell(bought, 0, block.timestamp);
    }

    function test_RevertWhen_SellMoreThanHeld() public {
        uint256 bought = _buy(alice, 1 ether);
        vm.startPrank(alice);
        token.approve(address(curve), bought + 1);
        vm.expectRevert();
        curve.sell(bought + 1, 0, block.timestamp);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // Completion
    // ---------------------------------------------------------------------

    function test_FinalBuyIsPartiallyFilledAndRefunded() public {
        _skipAntiSnipe();
        uint256 ethToCurve = BondingCurveMath.ethInForTokensOut(
            curve.initialVirtualEth(), V0, BondingCurveMath.CURVE_SUPPLY
        );
        uint256 ethSpent = _ceilDiv(ethToCurve * 10_000, 10_000 - TRADE_FEE_BPS);

        vm.expectEmit(address(curve));
        emit BondingCurve.CurveCompleted(ethToCurve);
        uint256 out = _buy(alice, 10 ether);

        assertEq(out, BondingCurveMath.CURVE_SUPPLY);
        assertEq(alice.balance, 10 ether - ethSpent);
        assertEq(uint256(curve.state()), uint256(BondingCurve.State.Complete));
        assertEq(curve.tokensRemaining(), 0);
        assertEq(curve.realEthReserve(), ethToCurve);
        assertGe(curve.realEthReserve(), TARGET_RAISE);
        assertEq(token.balanceOf(address(curve)), BondingCurveMath.POOL_SUPPLY);
        _assertEthAccounted();
    }

    function test_ExactBuyCompletesWithoutRefund() public {
        _skipAntiSnipe();
        uint256 ethToCurve = BondingCurveMath.ethInForTokensOut(
            curve.initialVirtualEth(), V0, BondingCurveMath.CURVE_SUPPLY
        );
        uint256 ethSpent = _ceilDiv(ethToCurve * 10_000, 10_000 - TRADE_FEE_BPS);

        _buy(alice, ethSpent);

        assertEq(uint256(curve.state()), uint256(BondingCurve.State.Complete));
        assertEq(alice.balance, 0);
        _assertEthAccounted();
    }

    function test_RevertWhen_TradingAfterCompletion() public {
        _skipAntiSnipe();
        uint256 bought = _buy(alice, 10 ether);
        _nextBlock();

        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(BondingCurve.NotTrading.selector);
        curve.buy{value: 1 ether}(0, block.timestamp);

        vm.startPrank(alice);
        token.approve(address(curve), bought);
        vm.expectRevert(BondingCurve.NotTrading.selector);
        curve.sell(bought, 0, block.timestamp);
        vm.stopPrank();

        vm.expectRevert(BondingCurve.NotTrading.selector);
        curve.quoteBuy(1 ether);
    }

    function test_RevertWhen_RefundRecipientRejectsEth() public {
        _skipAntiSnipe();
        EthRejecter rejecter = new EthRejecter();
        vm.deal(address(this), 10 ether);
        vm.expectRevert(BondingCurve.EthTransferFailed.selector);
        rejecter.buy{value: 10 ether}(curve);
        assertEq(uint256(curve.state()), uint256(BondingCurve.State.Trading));
    }

    // ---------------------------------------------------------------------
    // Graduation (locker mocked; the real Uniswap path is in test/fork)
    // ---------------------------------------------------------------------

    function test_GraduateHandsPriceMatchedLiquidityToLocker() public {
        _skipAntiSnipe();
        _buy(alice, 10 ether);
        uint256 raised = curve.realEthReserve();
        uint256 expectedTokens = BondingCurveMath.poolTokensForEth(
            raised - GRADUATION_FEE, curve.virtualEthReserve(), curve.virtualTokenReserve()
        );
        uint256 vaultBefore = feeVault.balance;

        vm.expectEmit(address(curve));
        emit BondingCurve.CurveGraduated(
            bob,
            raised - GRADUATION_FEE,
            expectedTokens,
            BondingCurveMath.POOL_SUPPLY - expectedTokens
        );
        vm.prank(bob);
        curve.graduate();

        assertEq(uint256(curve.state()), uint256(BondingCurve.State.Graduated));
        assertEq(locker.calls(), 1);
        assertEq(locker.lastToken(), address(token));
        assertEq(locker.lastCreator(), creator);
        assertEq(locker.lastEth(), raised - GRADUATION_FEE);
        assertEq(locker.lastTokenAmount(), expectedTokens);
        assertEq(token.balanceOf(address(locker)), expectedTokens);
        assertEq(token.balanceOf(curve.DEAD()), BondingCurveMath.POOL_SUPPLY - expectedTokens);
        assertEq(token.balanceOf(address(curve)), 0);
        assertEq(bob.balance, GRADUATION_REWARD);
        assertEq(feeVault.balance - vaultBefore, GRADUATION_FEE - GRADUATION_REWARD);
        assertEq(address(curve).balance, curve.creatorFeesAccrued());
        assertEq(curve.realEthReserve(), 0);
    }

    function test_RevertWhen_GraduatingWhileTrading() public {
        vm.expectRevert(BondingCurve.NotComplete.selector);
        curve.graduate();
    }

    function test_RevertWhen_GraduationFeeConfigInvalid() public {
        BondingCurve.Config memory config = _defaultConfig();
        config.graduationFee = TARGET_RAISE * 500 / 10_000 + 1;
        _expectLaunchRevert(config, BondingCurve.InvalidGraduationFee.selector);

        config = _defaultConfig();
        config.graduationReward = GRADUATION_FEE + 1;
        _expectLaunchRevert(config, BondingCurve.InvalidGraduationFee.selector);

        config = _defaultConfig();
        config.locker = address(0);
        _expectLaunchRevert(config, BondingCurve.ZeroAddress.selector);
    }

    function testFuzz_GraduationNeverOpensBelowCurvePriceOrStrandsFunds(
        uint256 targetRaise,
        uint256 feeBps,
        uint256 rewardBps
    ) public {
        targetRaise = bound(targetRaise, 0.1 ether, 1_000 ether);
        uint256 fee = targetRaise * bound(feeBps, 0, 500) / 10_000;
        uint256 reward = fee * bound(rewardBps, 0, 10_000) / 10_000;
        BondingCurve.Config memory config = _defaultConfig();
        config.targetRaise = targetRaise;
        config.graduationFee = fee;
        config.graduationReward = reward;
        (curve, token) = _launch(config);
        _skipAntiSnipe();
        _buy(alice, targetRaise * 2);

        uint256 virtualEth = curve.virtualEthReserve();
        uint256 virtualToken = curve.virtualTokenReserve();
        vm.prank(bob);
        curve.graduate();

        uint256 poolEth = locker.lastEth();
        uint256 poolTokens = locker.lastTokenAmount();
        assertGe(poolEth * virtualToken, poolTokens * virtualEth, "pool price >= curve price");
        assertEq(poolTokens + token.balanceOf(curve.DEAD()), BondingCurveMath.POOL_SUPPLY);
        assertEq(address(curve).balance, curve.creatorFeesAccrued());
        assertEq(bob.balance, reward);
    }

    // ---------------------------------------------------------------------
    // Creator buy and fees
    // ---------------------------------------------------------------------

    function test_CreatorBuyPaysNoAntiSnipeFee() public {
        uint256 ethIn = 0.05 ether;
        uint256 fee = ethIn * TRADE_FEE_BPS / 10_000;
        uint256 expectedOut =
            BondingCurveMath.tokensOutForEthIn(curve.initialVirtualEth(), V0, ethIn - fee);

        uint256 out = curve.creatorBuy{value: ethIn}(0, type(uint256).max);

        assertEq(out, expectedOut);
        assertEq(token.balanceOf(creator), expectedOut);
        assertEq(curve.realEthReserve(), ethIn - fee);
    }

    function test_RevertWhen_CreatorBuyNotFromFactory() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(BondingCurve.OnlyFactory.selector);
        curve.creatorBuy{value: 1 ether}(0, type(uint256).max);
    }

    function test_RevertWhen_CreatorBuyIsNotFirst() public {
        _buy(alice, 0.01 ether);
        vm.expectRevert(BondingCurve.CreatorBuyNotFirst.selector);
        curve.creatorBuy{value: 0.01 ether}(0, type(uint256).max);
    }

    function test_RevertWhen_CreatorBuyExceedsCap() public {
        vm.expectRevert(BondingCurve.CreatorBuyTooLarge.selector);
        curve.creatorBuy{value: 1 ether}(0, 1_000_000 ether);
    }

    function test_CreatorClaimsAccruedFees() public {
        _skipAntiSnipe();
        _buy(alice, 1 ether);
        _buy(bob, 1 ether);
        uint256 accrued = curve.creatorFeesAccrued();
        assertGt(accrued, 0);

        vm.expectEmit(address(curve));
        emit BondingCurve.CreatorFeesClaimed(creator, accrued);
        vm.prank(creator);
        uint256 claimed = curve.claimCreatorFees();

        assertEq(claimed, accrued);
        assertEq(creator.balance, accrued);
        assertEq(curve.creatorFeesAccrued(), 0);
        _assertEthAccounted();
    }

    function test_CreatorCanClaimAfterCompletion() public {
        _skipAntiSnipe();
        _buy(alice, 10 ether);
        vm.prank(creator);
        assertGt(curve.claimCreatorFees(), 0);
    }

    function test_RevertWhen_NonCreatorClaims() public {
        _buy(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(BondingCurve.OnlyCreator.selector);
        curve.claimCreatorFees();
    }

    function test_RevertWhen_NothingToClaim() public {
        vm.prank(creator);
        vm.expectRevert(BondingCurve.NothingToClaim.selector);
        curve.claimCreatorFees();
    }

    // ---------------------------------------------------------------------
    // Manipulation and reentrancy
    // ---------------------------------------------------------------------

    function test_DonatedTokensAndEthDoNotMovePrice() public {
        _skipAntiSnipe();
        uint256 bought = _buy(alice, 1 ether);
        _nextBlock();
        BondingCurve.BuyQuote memory before = curve.quoteBuy(1 ether);

        vm.prank(alice);
        assertTrue(token.transfer(address(curve), bought));
        vm.deal(address(curve), address(curve).balance + 5 ether);

        BondingCurve.BuyQuote memory afterDonation = curve.quoteBuy(1 ether);
        assertEq(afterDonation.tokensOut, before.tokensOut);
        assertEq(curve.virtualEthReserve(), curve.initialVirtualEth() + curve.realEthReserve());
    }

    function test_ReentrancyFromSellIsBlocked() public {
        _skipAntiSnipe();
        ReentrantTrader attacker = new ReentrantTrader(curve);
        vm.deal(address(attacker), 1 ether);
        vm.prank(address(attacker));
        attacker.buy{value: 1 ether}();

        attacker.sellAll();

        assertFalse(attacker.reentrySucceeded());
        assertEq(
            attacker.reentryError(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        _assertEthAccounted();
    }

    // ---------------------------------------------------------------------
    // Fuzz
    // ---------------------------------------------------------------------

    function testFuzz_BuyAccounting(uint256 ethIn, uint256 secondsAfterLaunch) public {
        ethIn = bound(ethIn, 1 gwei, 20 ether);
        secondsAfterLaunch = bound(secondsAfterLaunch, 0, 2 * ANTI_SNIPE_DURATION);
        vm.warp(block.timestamp + secondsAfterLaunch);

        BondingCurve.BuyQuote memory quote = curve.quoteBuy(ethIn);
        vm.assume(quote.tokensOut > 0);
        uint256 out = _buy(alice, ethIn);

        assertEq(out, quote.tokensOut);
        assertLe(quote.ethSpent, ethIn);
        assertEq(alice.balance, ethIn - quote.ethSpent);
        assertEq(quote.ethSpent, quote.ethToCurve + quote.platformFee + quote.creatorFee);
        assertEq(token.balanceOf(alice) + token.balanceOf(address(curve)), token.totalSupply());
        _assertEthAccounted();
    }

    function testFuzz_RoundTripNeverProfits(uint256 ethIn, uint256 sellPart) public {
        _skipAntiSnipe();
        ethIn = bound(ethIn, 1 gwei, 3 ether);
        uint256 bought = _buy(alice, ethIn);
        sellPart = bound(sellPart, 1, bought);

        uint256 ethBack = curve.quoteSell(sellPart).ethOut;
        vm.assume(ethBack > 0);
        _sell(alice, sellPart);

        assertLe(alice.balance, ethIn);
        _assertEthAccounted();
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }
}
