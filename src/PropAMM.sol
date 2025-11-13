// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

interface IGlobalStorage {
    function set(bytes32 key, bytes32 value) external;
    function setBatch(bytes32[] calldata keys, bytes32[] calldata values) external;
    function get(address owner, bytes32 key) external view returns (bytes32 value);
    function getWithTimestamp(address owner, bytes32 key)
        external
        view
        returns (bytes32 value, uint64 blockTimestamp, uint64 blockNumber);
}

/**
 * @title PropAMM
 * @notice A Proprietary Automated Market Maker where only the market maker can provide liquidity
 * @dev Integrates with GlobalStorage to prevent frontrunning of price updates
 */
contract PropAMM is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Structures ============

    struct TradingPair {
        IERC20 tokenX;
        IERC20 tokenY;
        uint256 reserveX;
        uint256 reserveY;
        uint256 targetX; // Target amount of X for the curve
        uint8 xRetainDecimals; // Decimals to retain for X price normalization
        uint8 yRetainDecimals; // Decimals to retain for Y price normalization
        bool targetYBasedLock; // Emergency lock flag
        uint256 targetYReference; // Reference value for lock mechanism
        bool exists; // Whether this pair exists
    }

    struct PairParameters {
        uint256 concentration; // Concentration parameter for the curve (scaled by 1e6)
        uint256 multX; // Price multiplier for token X (scaled by 1e18)
        uint256 multY; // Price multiplier for token Y (scaled by 1e18)
        uint256 baseInvariant; // Baseline invariant constant for the curve
        uint256 feeRate; // Fee charged on each trade (scaled by 1e6)
        uint256 spread; // Additional spread applied to trades (scaled by 1e6)
    }

    // ============ State Variables ============

    address public marketMaker;
    IGlobalStorage public immutable globalStorage;

    mapping(bytes32 => TradingPair) public pairs;
    bytes32[] public pairIds;
    bool public tradingPaused;

    // ============ Mathematical Constants ============

    uint256 private constant MULTIPLIER_SCALE = 1e18;
    uint256 private constant CONCENTRATION_BASE = 1e6;
    uint256 private constant FEE_BASE = 1e6;

    // ============ Constants for GlobalStorage Keys ============

    // Key prefixes for different parameters in GlobalStorage
    bytes32 private constant CONCENTRATION_PREFIX = keccak256("CONCENTRATION");
    bytes32 private constant MULT_X_PREFIX = keccak256("MULT_X");
    bytes32 private constant MULT_Y_PREFIX = keccak256("MULT_Y");
    bytes32 private constant BASE_INVARIANT_PREFIX = keccak256("BASE_INVARIANT");
    bytes32 private constant FEE_PREFIX = keccak256("FEE_RATE");
    bytes32 private constant SPREAD_PREFIX = keccak256("SPREAD");

    // ============ Events ============

    event PairCreated(bytes32 indexed pairId, address indexed tokenX, address indexed tokenY, uint256 concentration);

    event Deposited(bytes32 indexed pairId, uint256 amountX, uint256 amountY);

    event Withdrawn(bytes32 indexed pairId, uint256 amountX, uint256 amountY);

    event Swapped(
        bytes32 indexed pairId,
        address indexed trader,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    event ParametersUpdated(
        bytes32 indexed pairId,
        uint256 concentration,
        uint256 multX,
        uint256 multY,
        uint256 baseInvariant,
        uint256 feeRate,
        uint256 spread
    );

    event CurveParametersUpdated(
        bytes32 indexed pairId,
        uint256 oldConcentration,
        uint256 oldMultX,
        uint256 oldMultY,
        uint256 newConcentration,
        uint256 newMultX,
        uint256 newMultY
    );

    event SpreadUpdated(bytes32 indexed pairId, uint256 oldSpread, uint256 newSpread);

    event LiquidityRebalanced(
        bytes32 indexed pairId,
        uint256 newTargetX,
        uint256 newTargetY,
        address indexed caller
    );

    event TradingPaused(address indexed account);
    event TradingResumed(address indexed account);

    event PairUnlocked(bytes32 indexed pairId);

    // ============ Errors ============

    error OnlyMarketMaker();
    error PairAlreadyExists();
    error PairDoesNotExist();
    error InvalidConcentration();
    error InvalidAmount();
    error InsufficientLiquidity();
    error PairLocked();
    error SlippageExceeded();
    error InvalidDecimalConfiguration();
    error StaleParameters();
    error TradingHalted();
    error TradingAlreadyPaused();
    error TradingNotPaused();

    // ============ Modifiers ============

    modifier onlyMarketMaker() {
        if (msg.sender != marketMaker) revert OnlyMarketMaker();
        _;
    }

    modifier pairExists(bytes32 pairId) {
        if (!pairs[pairId].exists) revert PairDoesNotExist();
        _;
    }

    // ============ Constructor ============

    constructor(address _marketMaker, address _globalStorage) Ownable(msg.sender) {
        marketMaker = _marketMaker;
        globalStorage = IGlobalStorage(_globalStorage);
    }

    // ============ Market Maker Functions ============

    /**
     * @notice Create a new trading pair
     * @param tokenX Address of token X
     * @param tokenY Address of token Y
     * @param initialConcentration Initial concentration parameter for the curve (1-2000)
     * @param xRetainDecimals Decimals to retain for X
     * @param yRetainDecimals Decimals to retain for Y
     */
    function createPair(
        address tokenX,
        address tokenY,
        uint256 initialConcentration,
        uint8 xRetainDecimals,
        uint8 yRetainDecimals
    ) external onlyMarketMaker returns (bytes32) {
        bytes32 pairId = keccak256(abi.encodePacked(tokenX, tokenY));

        if (pairs[pairId].exists) revert PairAlreadyExists();
        if (initialConcentration < CONCENTRATION_BASE || initialConcentration > CONCENTRATION_BASE * 100) {
            revert InvalidConcentration();
        }

        // Verify decimal configuration
        uint8 decimalsX = IERC20Metadata(tokenX).decimals();
        uint8 decimalsY = IERC20Metadata(tokenY).decimals();
        if (decimalsX + xRetainDecimals != decimalsY + yRetainDecimals) {
            revert InvalidDecimalConfiguration();
        }

        pairs[pairId] = TradingPair({
            tokenX: IERC20(tokenX),
            tokenY: IERC20(tokenY),
            reserveX: 0,
            reserveY: 0,
            targetX: 0,
            xRetainDecimals: xRetainDecimals,
            yRetainDecimals: yRetainDecimals,
            targetYBasedLock: false,
            targetYReference: 0,
            exists: true
        });

        pairIds.push(pairId);

        // Initialize parameters in GlobalStorage
        _updateParametersInGlobalStorage(
            pairId,
            initialConcentration,
            MULTIPLIER_SCALE,
            MULTIPLIER_SCALE,
            0,
            0,
            0
        );

        emit PairCreated(pairId, tokenX, tokenY, initialConcentration);
        return pairId;
    }

    /**
     * @notice Update all pricing parameters in GlobalStorage atomically
     * @dev This should be called by market maker. Updates are placed at top of block.
     * @param pairId The pair identifier
     * @param concentration New concentration parameter
     * @param multX New X multiplier
     * @param multY New Y multiplier
     */
    function updateParameters(
        bytes32 pairId,
        uint256 concentration,
        uint256 multX,
        uint256 multY,
        uint256 baseInvariant,
        uint256 feeRate,
        uint256 spread
    )
        external
        onlyMarketMaker
        pairExists(pairId)
    {
        if (concentration < CONCENTRATION_BASE || concentration > CONCENTRATION_BASE * 100) {
            revert InvalidConcentration();
        }

        if (multX == 0 || multY == 0) revert InvalidAmount();
        if (feeRate > FEE_BASE || spread > FEE_BASE) revert InvalidAmount();
        if (feeRate + spread > FEE_BASE) revert InvalidAmount();

        _updateParametersInGlobalStorage(pairId, concentration, multX, multY, baseInvariant, feeRate, spread);

        emit ParametersUpdated(pairId, concentration, multX, multY, baseInvariant, feeRate, spread);
    }

    /**
     * @notice Update the core curve parameters while retaining other configuration values
     * @dev Designed to be the primary hook for off-chain automation reacting to price changes
     * @param pairId The pair identifier
     * @param newMultX New multiplier for token X
     * @param newMultY New multiplier for token Y
     * @param newConcentration New concentration parameter
     */
    function updateCurveParams(
        bytes32 pairId,
        uint256 newMultX,
        uint256 newMultY,
        uint256 newConcentration
    ) external onlyMarketMaker pairExists(pairId) {
        if (newConcentration < CONCENTRATION_BASE || newConcentration > CONCENTRATION_BASE * 100) {
            revert InvalidConcentration();
        }

        if (newMultX == 0 || newMultY == 0) revert InvalidAmount();

        PairParameters memory current = _readParametersFromGlobalStorage(pairId);

        _updateParametersInGlobalStorage(
            pairId,
            newConcentration,
            newMultX,
            newMultY,
            current.baseInvariant,
            current.feeRate,
            current.spread
        );

        emit CurveParametersUpdated(
            pairId,
            current.concentration,
            current.multX,
            current.multY,
            newConcentration,
            newMultX,
            newMultY
        );
    }

    /**
     * @notice Update only the spread parameter, keeping other parameters unchanged
     * @param pairId The pair identifier
     * @param newSpread New spread value (scaled by 1e6)
     */
    function setSpread(bytes32 pairId, uint256 newSpread) external onlyMarketMaker pairExists(pairId) {
        if (newSpread > FEE_BASE) revert InvalidAmount();

        PairParameters memory current = _readParametersFromGlobalStorage(pairId);
        if (current.feeRate + newSpread > FEE_BASE) revert InvalidAmount();

        _updateParametersInGlobalStorage(
            pairId,
            current.concentration,
            current.multX,
            current.multY,
            current.baseInvariant,
            current.feeRate,
            newSpread
        );

        emit SpreadUpdated(pairId, current.spread, newSpread);
    }

    /**
     * @notice Rebalance the target inventory tracked by the AMM
     * @param pairId The pair identifier
     * @param newTargetX Desired target amount of token X
     * @param newTargetY Desired target amount of token Y used as reference for locking logic
     */
    function rebalanceLiquidity(
        bytes32 pairId,
        uint256 newTargetX,
        uint256 newTargetY
    ) external onlyMarketMaker pairExists(pairId) {
        TradingPair storage pair = pairs[pairId];

        if (newTargetX > pair.reserveX) revert InvalidAmount();
        if (newTargetY > pair.reserveY) revert InvalidAmount();

        pair.targetX = newTargetX;
        pair.targetYReference = newTargetY;
        pair.targetYBasedLock = false;

        emit LiquidityRebalanced(pairId, newTargetX, newTargetY, msg.sender);
    }

    /**
     * @notice Deposit liquidity into a pair
     */
    function deposit(bytes32 pairId, uint256 amountX, uint256 amountY)
        external
        onlyMarketMaker
        pairExists(pairId)
        nonReentrant
    {
        TradingPair storage pair = pairs[pairId];

        if (amountX > 0) {
            pair.tokenX.safeTransferFrom(msg.sender, address(this), amountX);
            pair.reserveX += amountX;
            pair.targetX += amountX;
        }

        if (amountY > 0) {
            pair.tokenY.safeTransferFrom(msg.sender, address(this), amountY);
            pair.reserveY += amountY;
        }

        emit Deposited(pairId, amountX, amountY);
    }

    /**
     * @notice Withdraw liquidity from a pair
     */
    function withdraw(bytes32 pairId, uint256 amountX, uint256 amountY)
        external
        onlyMarketMaker
        pairExists(pairId)
        nonReentrant
    {
        TradingPair storage pair = pairs[pairId];

        if (amountX > pair.reserveX || amountY > pair.reserveY) {
            revert InsufficientLiquidity();
        }

        if (amountX > 0) {
            pair.reserveX -= amountX;
            pair.targetX -= amountX;
            pair.tokenX.safeTransfer(msg.sender, amountX);
        }

        if (amountY > 0) {
            pair.reserveY -= amountY;
            pair.tokenY.safeTransfer(msg.sender, amountY);
        }

        emit Withdrawn(pairId, amountX, amountY);
    }

    /**
     * @notice Unlock a locked pair
     */
    function unlock(bytes32 pairId) external onlyMarketMaker pairExists(pairId) {
        pairs[pairId].targetYBasedLock = false;
        pairs[pairId].targetYReference = 0;
        emit PairUnlocked(pairId);
    }

    // ============ Public Trading Functions ============

    /**
     * @notice Swap token X for token Y
     * @dev Reads latest parameters from GlobalStorage (top-of-block values)
     * @param pairId The pair identifier
     * @param amountXIn Amount of token X to swap
     * @param minAmountYOut Minimum amount of token Y expected (slippage protection)
     */
    function swapXtoY(bytes32 pairId, uint256 amountXIn, uint256 minAmountYOut)
        external
        pairExists(pairId)
        nonReentrant
        returns (uint256 amountYOut)
    {
        if (tradingPaused) revert TradingHalted();

        TradingPair storage pair = pairs[pairId];

        // Read latest parameters from GlobalStorage
        PairParameters memory params = _readParametersFromGlobalStorage(pairId);

        // Check if pair is locked
        if (_isTargetYLocked(pairId, params)) revert PairLocked();

        // Get quote using GlobalStorage parameters
        if (amountXIn == 0) revert InvalidAmount();

        uint256 amountOut = _quoteXtoY(pairId, amountXIn, params);

        if (amountOut < minAmountYOut) revert SlippageExceeded();
        if (amountOut >= pair.reserveY) revert InsufficientLiquidity();

        // Transfer tokens
        pair.tokenX.safeTransferFrom(msg.sender, address(this), amountXIn);
        pair.reserveX += amountXIn;

        pair.reserveY -= amountOut;
        pair.tokenY.safeTransfer(msg.sender, amountOut);

        emit Swapped(pairId, msg.sender, address(pair.tokenX), address(pair.tokenY), amountXIn, amountOut);

        return amountOut;
    }

    /**
     * @notice Swap token Y for token X
     * @dev Reads latest parameters from GlobalStorage (top-of-block values)
     * @param pairId The pair identifier
     * @param amountYIn Amount of token Y to swap
     * @param minAmountXOut Minimum amount of token X expected (slippage protection)
     */
    function swapYtoX(bytes32 pairId, uint256 amountYIn, uint256 minAmountXOut)
        external
        pairExists(pairId)
        nonReentrant
        returns (uint256 amountXOut)
    {
        if (tradingPaused) revert TradingHalted();

        TradingPair storage pair = pairs[pairId];

        // Read latest parameters from GlobalStorage
        PairParameters memory params = _readParametersFromGlobalStorage(pairId);

        // Check if pair is locked
        if (_isTargetYLocked(pairId, params)) revert PairLocked();

        // Get quote using GlobalStorage parameters
        if (amountYIn == 0) revert InvalidAmount();

        uint256 amountOut = _quoteYtoX(pairId, amountYIn, params);

        if (amountOut < minAmountXOut) revert SlippageExceeded();
        if (amountOut >= pair.reserveX) revert InsufficientLiquidity();

        // Transfer tokens
        pair.tokenY.safeTransferFrom(msg.sender, address(this), amountYIn);
        pair.reserveY += amountYIn;

        pair.reserveX -= amountOut;
        pair.tokenX.safeTransfer(msg.sender, amountOut);

        emit Swapped(pairId, msg.sender, address(pair.tokenY), address(pair.tokenX), amountYIn, amountOut);

        return amountOut;
    }

    // ============ View Functions ============

    /**
     * @notice Get quote for swapping X to Y using current GlobalStorage parameters
     */
    function quoteXtoY(bytes32 pairId, uint256 amountXIn)
        external
        view
        pairExists(pairId)
        returns (uint256 amountOut)
    {
        PairParameters memory params = _readParametersFromGlobalStorage(pairId);
        return _quoteXtoY(pairId, amountXIn, params);
    }

    /**
     * @notice Get quote for swapping Y to X using current GlobalStorage parameters
     */
    function quoteYtoX(bytes32 pairId, uint256 amountYIn)
        external
        view
        pairExists(pairId)
        returns (uint256 amountOut)
    {
        PairParameters memory params = _readParametersFromGlobalStorage(pairId);
        return _quoteYtoX(pairId, amountYIn, params);
    }

    /**
     * @notice Get current parameters from GlobalStorage with metadata
     * @return params The current pricing parameters
     * @return blockTimestamp When parameters were last updated
     * @return blockNumber Block number of last update
     */
    function getParametersWithTimestamp(bytes32 pairId)
        external
        view
        returns (PairParameters memory params, uint64 blockTimestamp, uint64 blockNumber)
    {
        // Read one parameter with timestamp (they all update together)
        bytes32 key = _getStorageKey(pairId, CONCENTRATION_PREFIX);
        (, blockTimestamp, blockNumber) = globalStorage.getWithTimestamp(address(this), key);

        params = _readParametersFromGlobalStorage(pairId);
        return (params, blockTimestamp, blockNumber);
    }

    /**
     * @notice Get pair information
     */
    function getPair(bytes32 pairId) external view returns (TradingPair memory) {
        return pairs[pairId];
    }

    /**
     * @notice Get all pair IDs
     */
    function getAllPairIds() external view returns (bytes32[] memory) {
        return pairIds;
    }

    /**
     * @notice Helper to generate pairId from token addresses
     */
    function getPairId(address tokenX, address tokenY) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(tokenX, tokenY));
    }

    // ============ Internal Functions ============

    /**
     * @notice Read parameters from GlobalStorage
     */
    function _readParametersFromGlobalStorage(bytes32 pairId) internal view returns (PairParameters memory params) {
        params.concentration = uint256(globalStorage.get(address(this), _getStorageKey(pairId, CONCENTRATION_PREFIX)));
        params.multX = uint256(globalStorage.get(address(this), _getStorageKey(pairId, MULT_X_PREFIX)));
        params.multY = uint256(globalStorage.get(address(this), _getStorageKey(pairId, MULT_Y_PREFIX)));
        params.baseInvariant = uint256(globalStorage.get(address(this), _getStorageKey(pairId, BASE_INVARIANT_PREFIX)));
        params.feeRate = uint256(globalStorage.get(address(this), _getStorageKey(pairId, FEE_PREFIX)));
        params.spread = uint256(globalStorage.get(address(this), _getStorageKey(pairId, SPREAD_PREFIX)));

        return params;
    }

    /**
     * @notice Update parameters in GlobalStorage atomically
     */
    function _updateParametersInGlobalStorage(
        bytes32 pairId,
        uint256 concentration,
        uint256 multX,
        uint256 multY,
        uint256 baseInvariant,
        uint256 feeRate,
        uint256 spread
    ) internal {
        bytes32[] memory keys = new bytes32[](6);
        bytes32[] memory values = new bytes32[](6);

        keys[0] = _getStorageKey(pairId, CONCENTRATION_PREFIX);
        values[0] = bytes32(concentration);

        keys[1] = _getStorageKey(pairId, MULT_X_PREFIX);
        values[1] = bytes32(multX);

        keys[2] = _getStorageKey(pairId, MULT_Y_PREFIX);
        values[2] = bytes32(multY);

        keys[3] = _getStorageKey(pairId, BASE_INVARIANT_PREFIX);
        values[3] = bytes32(baseInvariant);

        keys[4] = _getStorageKey(pairId, FEE_PREFIX);
        values[4] = bytes32(feeRate);

        keys[5] = _getStorageKey(pairId, SPREAD_PREFIX);
        values[5] = bytes32(spread);

        globalStorage.setBatch(keys, values);
    }

    /**
     * @notice Generate storage key for a parameter
     */
    function _getStorageKey(bytes32 pairId, bytes32 prefix) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prefix, pairId));
    }

    /**
     * @notice Calculate quote for X to Y swap
     */
    function _quoteXtoY(bytes32 pairId, uint256 amountXIn, PairParameters memory params)
        internal
        view
        returns (uint256 amountOut)
    {
        TradingPair storage pair = pairs[pairId];
        if (params.concentration < CONCENTRATION_BASE) revert StaleParameters();
        if (params.multX == 0 || params.multY == 0) revert StaleParameters();

        uint256 effectiveXBefore = _effectiveAmount(pair.reserveX, params.multX);
        uint256 effectiveYBefore = _effectiveAmount(pair.reserveY, params.multY);
        if (effectiveYBefore == 0) revert InsufficientLiquidity();

        uint256 invariant = params.baseInvariant;
        if (invariant == 0) {
            invariant = Math.mulDiv(effectiveXBefore, effectiveYBefore, 1);
        }

        uint256 adjustedIn = _adjustInputForConcentration(
            _effectiveAmount(amountXIn, params.multX),
            params.concentration
        );

        uint256 newEffectiveX = effectiveXBefore + adjustedIn;
        if (newEffectiveX == 0) revert InvalidAmount();

        uint256 newEffectiveY = invariant / newEffectiveX;
        if (newEffectiveY >= effectiveYBefore) revert InsufficientLiquidity();

        uint256 rawEffectiveOut = effectiveYBefore - newEffectiveY;
        uint256 adjustedEffectiveOut = _adjustOutputForConcentration(rawEffectiveOut, params.concentration);

        amountOut = _reverseEffectiveAmount(adjustedEffectiveOut, params.multY);
        amountOut = _applyFees(amountOut, params.feeRate, params.spread);
    }

    /**
     * @notice Calculate quote for Y to X swap
     */
    function _quoteYtoX(bytes32 pairId, uint256 amountYIn, PairParameters memory params)
        internal
        view
        returns (uint256 amountOut)
    {
        TradingPair storage pair = pairs[pairId];
        if (params.concentration < CONCENTRATION_BASE) revert StaleParameters();
        if (params.multX == 0 || params.multY == 0) revert StaleParameters();

        uint256 effectiveXBefore = _effectiveAmount(pair.reserveX, params.multX);
        uint256 effectiveYBefore = _effectiveAmount(pair.reserveY, params.multY);
        if (effectiveXBefore == 0) revert InsufficientLiquidity();

        uint256 invariant = params.baseInvariant;
        if (invariant == 0) {
            invariant = Math.mulDiv(effectiveXBefore, effectiveYBefore, 1);
        }

        uint256 adjustedIn = _adjustInputForConcentration(
            _effectiveAmount(amountYIn, params.multY),
            params.concentration
        );

        uint256 newEffectiveY = effectiveYBefore + adjustedIn;
        if (newEffectiveY == 0) revert InvalidAmount();

        uint256 newEffectiveX = invariant / newEffectiveY;
        if (newEffectiveX >= effectiveXBefore) revert InsufficientLiquidity();

        uint256 rawEffectiveOut = effectiveXBefore - newEffectiveX;
        uint256 adjustedEffectiveOut = _adjustOutputForConcentration(rawEffectiveOut, params.concentration);

        amountOut = _reverseEffectiveAmount(adjustedEffectiveOut, params.multX);
        amountOut = _applyFees(amountOut, params.feeRate, params.spread);
    }

    /**
     * @notice Check if pair should be locked based on target Y deviation
     */
    function _isTargetYLocked(bytes32 pairId, PairParameters memory params) internal returns (bool) {
        TradingPair storage pair = pairs[pairId];

        uint256 targetY = _getTargetY(pairId, params);
        uint256 maxRef = targetY > pair.targetYReference ? targetY : pair.targetYReference;
        pair.targetYReference = maxRef;

        if (pair.targetYReference == 0) {
            return false;
        }

        // Lock if deviation exceeds 5%
        if (((pair.targetYReference - targetY) * 10000) / pair.targetYReference > 500) {
            pair.targetYBasedLock = true;
        }

        return pair.targetYBasedLock;
    }

    /**
     * @notice Calculate target Y based on reserves
     */
    function _getTargetY(bytes32 pairId, PairParameters memory params) internal view returns (uint256) {
        TradingPair storage pair = pairs[pairId];
        if (params.multY == 0) revert StaleParameters();

        uint256 effectiveReserveX = _effectiveAmount(pair.reserveX, params.multX);
        uint256 effectiveReserveY = _effectiveAmount(pair.reserveY, params.multY);
        uint256 effectiveTargetX = _effectiveAmount(pair.targetX, params.multX);

        if (effectiveReserveX + effectiveReserveY <= effectiveTargetX) {
            return 0;
        }

        uint256 effectiveTargetY = effectiveReserveX + effectiveReserveY - effectiveTargetX;
        return _reverseEffectiveAmount(effectiveTargetY, params.multY);
    }

    /**
     * @notice Normalize price to target decimals
     */
    function _normalizePrice(uint256 price, uint8 priceDecimals, uint8 targetDecimals)
        internal
        pure
        returns (uint256)
    {
        if (priceDecimals >= targetDecimals) {
            return price / (10 ** (priceDecimals - targetDecimals));
        } else {
            return price * (10 ** (targetDecimals - priceDecimals));
        }
    }

    function _effectiveAmount(uint256 amount, uint256 multiplier) internal pure returns (uint256) {
        return Math.mulDiv(amount, multiplier, MULTIPLIER_SCALE);
    }

    function _reverseEffectiveAmount(uint256 amount, uint256 multiplier) internal pure returns (uint256) {
        if (multiplier == 0) revert InvalidAmount();
        return Math.mulDiv(amount, MULTIPLIER_SCALE, multiplier);
    }

    function _adjustInputForConcentration(uint256 amount, uint256 concentration) internal pure returns (uint256) {
        if (concentration < CONCENTRATION_BASE) revert InvalidConcentration();
        return Math.mulDiv(amount, CONCENTRATION_BASE, concentration);
    }

    function _adjustOutputForConcentration(uint256 amount, uint256 concentration) internal pure returns (uint256) {
        if (concentration < CONCENTRATION_BASE) revert InvalidConcentration();
        return Math.mulDiv(amount, concentration, CONCENTRATION_BASE);
    }

    function _applyFees(uint256 amount, uint256 feeRate, uint256 spread) internal pure returns (uint256) {
        if (feeRate == 0 && spread == 0) return amount;

        uint256 totalRate = feeRate + spread;
        if (totalRate > FEE_BASE) revert InvalidAmount();

        uint256 feeAmount = Math.mulDiv(amount, totalRate, FEE_BASE);
        return amount - feeAmount;
    }

    // ============ Admin Functions ============

    /**
     * @notice Pause trading across all pairs
     */
    function pauseTrading() external onlyOwner {
        if (tradingPaused) revert TradingAlreadyPaused();
        tradingPaused = true;
        emit TradingPaused(msg.sender);
    }

    /**
     * @notice Resume trading across all pairs
     */
    function resumeTrading() external onlyOwner {
        if (!tradingPaused) revert TradingNotPaused();
        tradingPaused = false;
        emit TradingResumed(msg.sender);
    }

    /**
     * @notice Update market maker address
     */
    function setMarketMaker(address newMarketMaker) external onlyOwner {
        marketMaker = newMarketMaker;
    }
}

// ============ Interfaces ============

interface IERC20Metadata is IERC20 {
    function decimals() external view returns (uint8);
}
