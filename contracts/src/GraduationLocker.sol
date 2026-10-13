// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IGraduationLocker} from "./interfaces/IGraduationLocker.sol";
import {LaunchLimits} from "./libraries/LaunchLimits.sol";
import {PoolMath} from "./libraries/PoolMath.sol";

interface ICurveRegistry {
    function curveOf(address token) external view returns (address);
}

/// @title GraduationLocker
/// @notice Moves a completed curve's liquidity into a Uniswap v4 ETH/token pool and holds the
/// position forever. It is also the pools' hook: its only hook function blocks anyone but itself
/// from creating a pool, so a pool can never be pre-created at a manipulated price. The contract
/// has no code path that removes liquidity; it can only collect swap fees, sending the platform's
/// share to the FeeVault and accruing the creator's share for them to claim.
contract GraduationLocker is IGraduationLocker, IUnlockCallback, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    enum Action {
        Graduate,
        Collect
    }

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    Currency internal constant ETH = Currency.wrap(address(0));

    IPoolManager public immutable poolManager;
    ICurveRegistry public immutable factory;
    address public immutable feeVault;
    uint24 public immutable poolFee;
    int24 public immutable tickSpacing;
    uint16 public immutable creatorShareBps;

    mapping(address token => address creator) public creatorOf;
    mapping(address account => mapping(address currency => uint256 amount)) public claimable;

    event Graduated(
        address indexed token,
        PoolId indexed poolId,
        address indexed creator,
        uint256 ethAdded,
        uint256 tokensAdded,
        uint128 liquidity
    );
    event FeesCollected(
        address indexed token,
        uint256 ethFees,
        uint256 tokenFees,
        uint256 creatorEth,
        uint256 creatorTokens
    );
    event Claimed(address indexed account, address indexed currency, uint256 amount);

    error ZeroAddress();
    error InvalidPoolConfig();
    error OnlyCurve();
    error OnlyPoolManager();
    error AlreadyGraduated();
    error NotGraduated();
    error NothingToClaim();
    error PoolCreationNotAllowed();
    error EthTransferFailed();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    /// @dev Deployed by the factory with CREATE2 at an address whose low bits grant exactly the
    /// beforeInitialize hook permission; the constructor reverts at any other address.
    constructor(
        IPoolManager poolManager_,
        address feeVault_,
        uint24 poolFee_,
        int24 tickSpacing_,
        uint16 creatorShareBps_
    ) {
        if (address(poolManager_) == address(0) || feeVault_ == address(0)) {
            revert ZeroAddress();
        }
        if (
            poolFee_ > LaunchLimits.MAX_POOL_FEE || tickSpacing_ < TickMath.MIN_TICK_SPACING
                || tickSpacing_ > TickMath.MAX_TICK_SPACING || creatorShareBps_ > LaunchLimits.BPS
        ) revert InvalidPoolConfig();

        Hooks.validateHookPermissions(
            IHooks(address(this)),
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );

        poolManager = poolManager_;
        factory = ICurveRegistry(msg.sender);
        feeVault = feeVault_;
        poolFee = poolFee_;
        tickSpacing = tickSpacing_;
        creatorShareBps = creatorShareBps_;
    }

    /// @dev Only accepts ETH from the PoolManager (fee collection and graduation dust).
    receive() external payable onlyPoolManager {}

    // ---------------------------------------------------------------------
    // Hook
    // ---------------------------------------------------------------------

    /// @notice Uniswap calls this before creating any pool that uses this contract as its hook.
    function beforeInitialize(address sender, PoolKey calldata, uint160)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != address(this)) revert PoolCreationNotAllowed();
        return IHooks.beforeInitialize.selector;
    }

    // ---------------------------------------------------------------------
    // Graduation and fees
    // ---------------------------------------------------------------------

    function poolKey(address token) public view returns (PoolKey memory) {
        return PoolKey({
            currency0: ETH,
            currency1: Currency.wrap(token),
            fee: poolFee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(this))
        });
    }

    function poolId(address token) external view returns (PoolId) {
        return poolKey(token).toId();
    }

    /// @notice Creates the coin's pool priced at `msg.value : tokenAmount` and adds all of it as
    /// one full-range position owned by this contract. Callable once per coin, by its own curve.
    function graduate(address token, address creator, uint256 tokenAmount)
        external
        payable
        nonReentrant
    {
        if (msg.sender == address(0) || factory.curveOf(token) != msg.sender) {
            revert OnlyCurve();
        }
        if (creator == address(0)) revert ZeroAddress();
        if (creatorOf[token] != address(0)) revert AlreadyGraduated();
        creatorOf[token] = creator;

        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);
        (uint256 ethAdded, uint256 tokensAdded, uint128 liquidity) = abi.decode(
            poolManager.unlock(abi.encode(Action.Graduate, token, msg.value, tokenAmount)),
            (uint256, uint256, uint128)
        );

        // Rounding leaves a few wei unspent; ETH goes to the platform, tokens are burned.
        _sendEth(feeVault, msg.value - ethAdded);
        if (tokenAmount > tokensAdded) IERC20(token).safeTransfer(DEAD, tokenAmount - tokensAdded);

        emit Graduated(token, poolKey(token).toId(), creator, ethAdded, tokensAdded, liquidity);
    }

    /// @notice Collects the swap fees earned by a coin's position. Anyone may call it; fees only
    /// ever go to the coin's creator (claimable) and the FeeVault.
    function collectFees(address token)
        external
        nonReentrant
        returns (uint256 ethFees, uint256 tokenFees)
    {
        address creator = creatorOf[token];
        if (creator == address(0)) revert NotGraduated();

        (ethFees, tokenFees) = abi.decode(
            poolManager.unlock(abi.encode(Action.Collect, token, 0, 0)), (uint256, uint256)
        );

        uint256 creatorEth = Math.mulDiv(ethFees, creatorShareBps, LaunchLimits.BPS);
        uint256 creatorTokens = Math.mulDiv(tokenFees, creatorShareBps, LaunchLimits.BPS);
        claimable[creator][address(0)] += creatorEth;
        claimable[creator][token] += creatorTokens;
        emit FeesCollected(token, ethFees, tokenFees, creatorEth, creatorTokens);

        _sendEth(feeVault, ethFees - creatorEth);
        if (tokenFees > creatorTokens) {
            IERC20(token).safeTransfer(feeVault, tokenFees - creatorTokens);
        }
    }

    /// @notice Withdraws fees owed to the caller. `currency` is address(0) for ETH.
    function claim(address currency) external nonReentrant returns (uint256 amount) {
        amount = claimable[msg.sender][currency];
        if (amount == 0) revert NothingToClaim();
        claimable[msg.sender][currency] = 0;
        emit Claimed(msg.sender, currency, amount);

        if (currency == address(0)) {
            _sendEth(msg.sender, amount);
        } else {
            IERC20(currency).safeTransfer(msg.sender, amount);
        }
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (Action action, address token, uint256 amountEth, uint256 amountToken) =
            abi.decode(data, (Action, address, uint256, uint256));
        PoolKey memory key = poolKey(token);
        (int24 tickLower, int24 tickUpper) = PoolMath.fullRangeTicks(tickSpacing);

        if (action == Action.Graduate) {
            return _addLiquidity(key, tickLower, tickUpper, amountEth, amountToken);
        }
        return _collect(key, tickLower, tickUpper);
    }

    // ---------------------------------------------------------------------
    // Internals (run inside the PoolManager's unlock callback)
    // ---------------------------------------------------------------------

    function _addLiquidity(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint256 amountEth,
        uint256 amountToken
    ) private returns (bytes memory) {
        uint160 sqrtPrice = PoolMath.sqrtPriceX96(amountEth, amountToken);
        poolManager.initialize(key, sqrtPrice);

        uint128 liquidity = PoolMath.liquidityForAmounts(
            sqrtPrice,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amountEth,
            amountToken
        );
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        );

        uint256 ethOwed = _owed(delta.amount0());
        uint256 tokensOwed = _owed(delta.amount1());
        poolManager.settle{value: ethOwed}();
        poolManager.sync(key.currency1);
        IERC20(Currency.unwrap(key.currency1)).safeTransfer(address(poolManager), tokensOwed);
        poolManager.settle();

        return abi.encode(ethOwed, tokensOwed, liquidity);
    }

    function _collect(PoolKey memory key, int24 tickLower, int24 tickUpper)
        private
        returns (bytes memory)
    {
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 0, salt: bytes32(0)
            }),
            ""
        );

        uint256 ethFees = SafeCast.toUint256(delta.amount0());
        uint256 tokenFees = SafeCast.toUint256(delta.amount1());
        if (ethFees > 0) poolManager.take(key.currency0, address(this), ethFees);
        if (tokenFees > 0) poolManager.take(key.currency1, address(this), tokenFees);

        return abi.encode(ethFees, tokenFees);
    }

    /// @dev Amount this contract must pay for a negative delta; reverts on a positive one rather
    /// than letting a signed-to-unsigned conversion wrap.
    function _owed(int128 amount) private pure returns (uint256) {
        return SafeCast.toUint256(-int256(amount));
    }

    function _sendEth(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool success,) = to.call{value: amount}("");
        if (!success) revert EthTransferFailed();
    }
}
