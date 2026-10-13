// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {BondingCurve} from "../src/BondingCurve.sol";
import {FeeVault} from "../src/FeeVault.sol";
import {LaunchFactory} from "../src/LaunchFactory.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {BondingCurveMath} from "../src/libraries/BondingCurveMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {GraduationLocker} from "../src/GraduationLocker.sol";
import {MockArbSys} from "./mocks/MockArbSys.sol";
import {FactoryDeployer} from "./utils/FactoryDeployer.sol";

contract LaunchFactoryTest is FactoryDeployer {
    uint256 internal constant V0 = BondingCurveMath.INITIAL_VIRTUAL_TOKEN_RESERVE;

    FeeVault internal vault;
    LaunchFactory internal factory;

    address internal owner = makeAddr("owner");
    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");

    function setUp() public {
        vm.etch(address(100), address(new MockArbSys()).code);
        vm.warp(1_700_000_000);
        vm.roll(100);

        vault = new FeeVault(owner);
        factory = _deployFactory(_settings());
    }

    function _settings() internal view returns (LaunchFactory.Settings memory) {
        return _defaultSettings(owner, address(vault));
    }

    function _create(uint256 value) internal returns (LaunchToken token, BondingCurve curve) {
        vm.deal(creator, creator.balance + value);
        vm.prank(creator);
        (address token_, address curve_) =
            factory.createCoin{value: value}("Test Coin", "TEST", 0, block.timestamp);
        return (LaunchToken(token_), BondingCurve(curve_));
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    function test_ConstructorStoresSettings() public view {
        assertEq(factory.owner(), owner);
        assertEq(factory.feeVault(), address(vault));
        assertEq(factory.targetRaise(), 4 ether);
        assertEq(factory.platformFeeBps(), 95);
        assertEq(factory.creatorFeeBps(), 30);
        assertEq(factory.antiSnipeFeeBps(), 5_000);
        assertEq(factory.antiSnipeDuration(), 30);
        assertEq(factory.maxCreatorBuyTokens(), BondingCurveMath.CURVE_SUPPLY * 500 / 10_000);
        assertEq(factory.maxCreatorBuyEth(), 0.5 ether);
        assertEq(BondingCurve(factory.implementation()).factory(), address(factory));
        assertEq(factory.graduationFee(), 0.02 ether);
        assertEq(factory.graduationReward(), 0.001 ether);
    }

    function test_LockerIsAValidBeforeInitializeHook() public view {
        GraduationLocker locker = GraduationLocker(payable(factory.locker()));
        assertEq(uint160(address(locker)) & Hooks.ALL_HOOK_MASK, Hooks.BEFORE_INITIALIZE_FLAG);
        assertEq(address(locker.factory()), address(factory));
        assertEq(address(locker.poolManager()), POOL_MANAGER);
        assertEq(locker.feeVault(), address(vault));
        assertEq(locker.poolFee(), 10_000);
        assertEq(locker.tickSpacing(), 200);
        assertEq(locker.creatorShareBps(), 5_000);
    }

    function test_RevertWhen_LockerSaltDoesNotGiveAHookAddress() public {
        LaunchFactory.Settings memory settings = _settings();
        settings.lockerSalt = keccak256("not mined");
        vm.expectRevert();
        new LaunchFactory(settings);
    }

    function test_RevertWhen_ConstructorSettingsInvalid() public {
        LaunchFactory.Settings memory settings;

        settings = _settings();
        settings.feeVault = address(0);
        vm.expectRevert(LaunchFactory.ZeroAddress.selector);
        new LaunchFactory(settings);

        settings = _settings();
        settings.owner = address(0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new LaunchFactory(settings);

        settings = _settings();
        settings.targetRaise = 0.01 ether;
        vm.expectRevert(LaunchFactory.InvalidTargetRaise.selector);
        new LaunchFactory(settings);

        settings = _settings();
        settings.platformFeeBps = 200;
        settings.creatorFeeBps = 1;
        vm.expectRevert(LaunchFactory.FeeTooHigh.selector);
        new LaunchFactory(settings);

        settings = _settings();
        settings.antiSnipeFeeBps = 9_000;
        vm.expectRevert(LaunchFactory.InvalidAntiSnipe.selector);
        new LaunchFactory(settings);

        settings = _settings();
        settings.maxCreatorBuyBps = 1_001;
        vm.expectRevert(LaunchFactory.InvalidCreatorBuyCap.selector);
        new LaunchFactory(settings);

        settings = _settings();
        settings.graduationFee = 0.2 ether + 1;
        vm.expectRevert(LaunchFactory.InvalidGraduationFee.selector);
        new LaunchFactory(settings);

        settings = _settings();
        settings.graduationReward = settings.graduationFee + 1;
        vm.expectRevert(LaunchFactory.InvalidGraduationFee.selector);
        new LaunchFactory(settings);
    }

    // ---------------------------------------------------------------------
    // createCoin
    // ---------------------------------------------------------------------

    function test_CreateCoinWithoutCreatorBuy() public {
        vm.expectEmit(false, false, true, true, address(factory));
        emit LaunchFactory.CoinCreated(
            address(0), address(0), creator, "Test Coin", "TEST", 4 ether, 95, 30, 5_000, 30
        );
        (LaunchToken token, BondingCurve curve) = _create(0);

        assertEq(token.name(), "Test Coin");
        assertEq(token.symbol(), "TEST");
        assertEq(token.balanceOf(address(curve)), BondingCurveMath.TOTAL_SUPPLY);
        assertEq(address(curve.token()), address(token));
        assertEq(curve.creator(), creator);
        assertEq(curve.feeVault(), address(vault));
        assertEq(curve.factory(), address(factory));
        assertEq(curve.platformFeeBps(), 95);
        assertEq(curve.creatorFeeBps(), 30);
        assertEq(curve.virtualTokenReserve(), V0);
        assertEq(curve.locker(), factory.locker());
        assertEq(curve.graduationFee(), 0.02 ether);
        assertEq(curve.graduationReward(), 0.001 ether);

        assertEq(factory.coinCount(), 1);
        assertEq(factory.curveOf(address(token)), address(curve));
        assertTrue(factory.isCurve(address(curve)));
        assertEq(address(factory).balance, 0);
    }

    function test_CreateCoinWithCreatorBuy() public {
        uint256 value = 0.05 ether;
        uint256 fee = value * 125 / 10_000;
        uint256 expectedOut = BondingCurveMath.tokensOutForEthIn(
            BondingCurveMath.initialVirtualEth(4 ether), V0, value - fee
        );

        (LaunchToken token, BondingCurve curve) = _create(value);

        assertEq(token.balanceOf(creator), expectedOut);
        assertEq(curve.realEthReserve(), value - fee);
        assertEq(curve.creatorFeesAccrued(), fee * 30 / 125);
        assertEq(address(vault).balance, fee - fee * 30 / 125);
        assertEq(address(factory).balance, 0);
        assertEq(creator.balance, 0);
    }

    function test_CreatorBuyHappensBeforeAnyoneElse() public {
        (LaunchToken token, BondingCurve curve) = _create(0.05 ether);
        uint256 creatorTokens = token.balanceOf(creator);

        vm.deal(alice, 0.05 ether);
        vm.prank(alice);
        curve.buy{value: 0.05 ether}(0, block.timestamp);

        assertLt(token.balanceOf(alice), creatorTokens);
    }

    function test_RevertWhen_CreatorBuyExceedsEthCap() public {
        vm.deal(creator, 0.5 ether + 1);
        vm.prank(creator);
        vm.expectRevert(LaunchFactory.CreatorBuyTooLarge.selector);
        factory.createCoin{value: 0.5 ether + 1}("Test Coin", "TEST", 0, block.timestamp);
    }

    function test_RevertWhen_CreatorBuyExceedsTokenCap() public {
        // 0.5 ETH is within the ETH cap but buys far more than 5% of the curve supply.
        vm.deal(creator, 0.5 ether);
        vm.prank(creator);
        vm.expectRevert(BondingCurve.CreatorBuyTooLarge.selector);
        factory.createCoin{value: 0.5 ether}("Test Coin", "TEST", 0, block.timestamp);
    }

    function test_RevertWhen_CreatorBuySlippageExceeded() public {
        vm.deal(creator, 0.05 ether);
        vm.prank(creator);
        vm.expectRevert(BondingCurve.SlippageExceeded.selector);
        factory.createCoin{value: 0.05 ether}(
            "Test Coin", "TEST", type(uint256).max, block.timestamp
        );
    }

    function test_RevertWhen_CreateCoinInputsInvalid() public {
        vm.startPrank(creator);

        vm.expectRevert(LaunchFactory.DeadlineExpired.selector);
        factory.createCoin("Test Coin", "TEST", 0, block.timestamp - 1);

        vm.expectRevert(LaunchFactory.InvalidName.selector);
        factory.createCoin("", "TEST", 0, block.timestamp);

        vm.expectRevert(LaunchFactory.InvalidName.selector);
        factory.createCoin(string(new bytes(33)), "TEST", 0, block.timestamp);

        vm.expectRevert(LaunchFactory.InvalidSymbol.selector);
        factory.createCoin("Test Coin", "", 0, block.timestamp);

        vm.expectRevert(LaunchFactory.InvalidSymbol.selector);
        factory.createCoin("Test Coin", "ELEVENCHARS", 0, block.timestamp);

        vm.stopPrank();
    }

    function test_EachCoinGetsItsOwnCurve() public {
        (LaunchToken tokenA, BondingCurve curveA) = _create(0);
        (LaunchToken tokenB, BondingCurve curveB) = _create(0);

        assertTrue(address(tokenA) != address(tokenB));
        assertTrue(address(curveA) != address(curveB));
        assertEq(factory.coinCount(), 2);
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    function test_PauseBlocksNewLaunchesButNotTrading() public {
        (, BondingCurve curve) = _create(0);

        vm.prank(owner);
        factory.pause();

        vm.prank(creator);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        factory.createCoin("Test Coin", "TEST", 0, block.timestamp);

        vm.deal(alice, 0.1 ether);
        vm.prank(alice);
        assertGt(curve.buy{value: 0.1 ether}(0, block.timestamp), 0);

        vm.prank(owner);
        factory.unpause();
        _create(0);
    }

    function test_FeeChangesOnlyAffectNewCoins() public {
        (, BondingCurve oldCurve) = _create(0);

        vm.startPrank(owner);
        factory.setTradeFees(150, 50);
        factory.setAntiSnipe(1_000, 10);
        vm.stopPrank();

        (, BondingCurve newCurve) = _create(0);

        assertEq(oldCurve.platformFeeBps(), 95);
        assertEq(oldCurve.creatorFeeBps(), 30);
        assertEq(oldCurve.antiSnipeFeeBps(), 5_000);
        assertEq(newCurve.platformFeeBps(), 150);
        assertEq(newCurve.creatorFeeBps(), 50);
        assertEq(newCurve.antiSnipeFeeBps(), 1_000);
        assertEq(newCurve.antiSnipeDuration(), 10);
    }

    function test_RevertWhen_FeesExceedHardCaps() public {
        vm.startPrank(owner);
        vm.expectRevert(LaunchFactory.FeeTooHigh.selector);
        factory.setTradeFees(150, 51);

        vm.expectRevert(LaunchFactory.InvalidAntiSnipe.selector);
        factory.setAntiSnipe(8_001, 30);

        vm.expectRevert(LaunchFactory.InvalidAntiSnipe.selector);
        factory.setAntiSnipe(5_000, 5 minutes + 1);
        vm.stopPrank();
    }

    function test_RevertWhen_NonOwnerCallsAdmin() public {
        bytes memory unauthorized =
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice);
        vm.startPrank(alice);

        vm.expectRevert(unauthorized);
        factory.setTradeFees(0, 0);

        vm.expectRevert(unauthorized);
        factory.setAntiSnipe(0, 0);

        vm.expectRevert(unauthorized);
        factory.pause();

        vm.expectRevert(unauthorized);
        factory.unpause();

        vm.stopPrank();
    }

    function test_OwnershipTransferIsTwoStep() public {
        vm.prank(owner);
        factory.transferOwnership(alice);
        assertEq(factory.owner(), owner);

        vm.prank(alice);
        factory.acceptOwnership();
        assertEq(factory.owner(), alice);
    }

    function test_FactoryCannotReconfigureOrRebuyExistingCurves() public {
        (LaunchToken token, BondingCurve curve) = _create(0);
        BondingCurve.Config memory hijack = BondingCurve.Config({
            token: address(token),
            creator: alice,
            feeVault: alice,
            targetRaise: 4 ether,
            platformFeeBps: 0,
            creatorFeeBps: 0,
            antiSnipeFeeBps: 0,
            antiSnipeDuration: 0,
            locker: alice,
            graduationFee: 0,
            graduationReward: 0
        });

        vm.prank(address(factory));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        curve.initialize(hijack);

        vm.deal(alice, 0.01 ether);
        vm.prank(alice);
        curve.buy{value: 0.01 ether}(0, block.timestamp);

        vm.deal(address(factory), 0.01 ether);
        vm.prank(address(factory));
        vm.expectRevert(BondingCurve.CreatorBuyNotFirst.selector);
        curve.creatorBuy{value: 0.01 ether}(0, type(uint256).max);
    }
}
