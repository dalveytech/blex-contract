// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;
pragma experimental ABIEncoderV2;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "../ac/Ac.sol";
import {Calc} from "../utils/Calc.sol";
import "../order/interface/IOrderBook.sol";
import {IPositionBook} from "../position/interfaces/IPositionBook.sol";
import {IMarket} from "./interfaces/IMarket.sol";
import {MarketLib} from "./MarketLib.sol";
import {IFeeRouter} from "../fee/interfaces/IFeeRouter.sol";
import {IMarketValid, IMarketValidFuncs} from "./interfaces/IMarketValid.sol";

import "../oracle/interfaces/IPrice.sol";
import {MarketConfigStruct} from "./MarketConfigStruct.sol";

import {Position} from "../position/PositionStruct.sol";
import "./MarketDataTypes.sol";
import "./../utils/TransferHelper.sol";

/*
error CollateralValidErr();
error SizeValidErr();
error SlippageValidErr();
error TpValidErr();
error SlValidErr();
error PriceValidErr();
error MarketOfflineErr();
*/
contract MarketValid is Ac, IMarketValidFuncs {
    using Calc for uint256;
    using Calc for int256;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;
    using Order for Order.Props;
    using MarketLib for uint256;
    using MarketConfigStruct for IMarketValid.Props;
    using MarketDataTypes for int256[];

    using MarketDataTypes for MarketDataTypes.UpdateOrderInputs;
    using MarketDataTypes for MarketDataTypes.UpdatePositionInputs;

    IMarketValid.Props public conf;
    uint256 private constant DECIMALS = 10000;

    constructor(address _f) Ac(_f) {}

    /**
     * @dev Called by `Market`.Validates a position based on the provided inputs.
     * @param _params The UpdatePositionInputs struct containing various parameters.
     * @param _position The Props struct representing the position.
     * @param _fees The array of fees associated with the position.
     * @dev This function is view-only and does not modify the contract state.
     */
    function validPosition(
        MarketDataTypes.UpdatePositionInputs memory _params,
        Position.Props memory _position,
        int256[] memory _fees
    ) external view {
        validSize(_position.size, _params._sizeDelta, _params.isOpen);
        if (_params.isOpen) {
            validPay(_params.collateralDelta);
            validCollateralDelta(
                _params.collateralDelta > 0 ? 1 : 2,
                _position.collateral,
                _params.collateralDelta,
                _position.size,
                _params._sizeDelta,
                _fees.totoalFees()
            );
        } else {
            if (_params._sizeDelta != _position.size) {
                validCollateralDelta(
                    _params.collateralDelta > 0 ? 3 : 4,
                    _position.collateral,
                    _params.collateralDelta,
                    _position.size,
                    _params._sizeDelta,
                    _fees.totoalFees()
                );
            }
        }
        if (_params._sizeDelta > 0 && _params.liqState == 0) {
            require(_params._oraclePrice > 0, "invalid oracle price");
            validSlippagePrice(_params);
        }
    }

    /**
     * @dev Called by `Market`.Validates the collateral delta based on the specified parameters.
     * @param busType The type of business operation:
     *   - 1: Increase collateral
     *   - 2: Increase collateral and size
     *   - 3: Decrease collateral
     *   - 4: Decrease collateral and size
     * @param _collateral The current collateral amount.
     * @param _collateralDelta The change in collateral.
     * @param _size The current size of the position.
     * @param _sizeDelta The change in size of the position.
     * @param _fees The fees associated with the position.
     * @dev This function is a public view function and is part of the IMarketValid interface.
     */
    function validCollateralDelta(
        uint256 busType,
        uint256 _collateral,
        uint256 _collateralDelta,
        uint256 _size,
        uint256 _sizeDelta,
        int256 _fees
    ) public view override {
        IMarketValid.Props memory _conf = conf;

        // Check if the market allows opening or closing of positions based on the busType
        if (
            (!_conf.getAllowOpen() && busType <= 2) ||
            (!_conf.getAllowClose() && busType > 2)
        ) revert("MarketOfflineErr");

        // If the busType indicates a decrease in collateral and the size is not changing, return without further validation
        if (busType > 2 && _sizeDelta == _size) return;

        // Calculate the new collateral based on the busType
        uint256 newCollateral = (
            busType < 3
                ? (_collateral + _collateralDelta)
                : (_collateral - _collateralDelta)
        );
        if (busType == 3 && newCollateral == 0) return;

        // Adjust the new collateral based on the fees
        if (_fees > 0) {
            newCollateral -= uint256(_fees);
        } else {
            newCollateral += uint256(-_fees);
        }

        // Validate the collateral and size based on the configured minimum values
        if (
            (_collateral == 0 &&
                busType == 1 &&
                _collateralDelta < _conf.getMinPay()) ||
            (busType > 2 && newCollateral < uint256(_conf.getMinCollateral()))
        ) {
            revert("CollateralValidErr");
        }

        uint256 newSize = _size;

        // Update the newSize based on the busType
        if (busType == 1) newSize += _sizeDelta;
        else if (busType == 3) newSize -= _sizeDelta;

        // Calculate the leverage and validate it against the configured maximum and minimum values
        uint256 lev = newSize / newCollateral;
        if (lev > _conf.getMaxLev() || lev < _conf.getMinLev())
            revert("Lev exceed");
    }

    /**
     * @dev Validates the take profit and stop loss prices for a position.
     * @param _triggerPrice The trigger price of the position.
     * @param _tpPrice The take profit price.
     * @param _slPrice The stop loss price.
     * @param _isLong Boolean flag indicating whether the position is long.
     * @dev This function is private and should not be called directly from outside the contract.
     */
    function validTPSL(
        uint256 _triggerPrice,
        uint256 _tpPrice,
        uint256 _slPrice,
        bool _isLong
    ) private pure {
        if (_tpPrice > 0) {
            if (
                _tpPrice > _triggerPrice != _isLong || _tpPrice == _triggerPrice
            ) {
                revert("TpValidErr");
            }
        }
        if (_slPrice > 0) {
            if (
                _isLong != _triggerPrice > _slPrice || _slPrice == _triggerPrice
            ) {
                revert("SlValidErr");
            }
        }
    }

    /**
     * @dev Called by `Market`.Validates an increase order based on the provided inputs.
     * @param _vars The UpdateOrderInputs struct containing various parameters.
     * @param fees The fees associated with the order.
     * @dev This function is a view-only function.
     */
    function validIncreaseOrder(
        MarketDataTypes.UpdateOrderInputs memory _vars,
        int256 fees
    ) external view {
        // Validate the take profit and stop loss prices of the order
        validTPSL(
            _vars._order.price,
            _vars._order.getTakeprofit(),
            _vars._order.getStoploss(),
            _vars._isLong
        );
        // Validate the size of the order
        validSize(0, _vars._order.size, true);

        // Validate the collateral delta for an increase order
        validCollateralDelta(1, 0, _vars.pay(), 0, _vars._order.size, fees);
    }

    /**
     * @dev Called by `Market`.Validates the size of a position.
     * @param _size The current size of the position.
     * @param _sizeDelta The change in size of the position.
     * @param _isIncrease Boolean flag indicating whether the size is increasing.
     * @dev This function is a public view function and is part of the IMarketValid interface.
     */
    function validSize(
        uint256 _size,
        uint256 _sizeDelta,
        bool _isIncrease
    ) public pure override {
        // Require that the size is greater than or equal to the size delta for a decrease in size
        if (false == _isIncrease) require(_size >= _sizeDelta, "SizeValidErr");
    }

    /**
     * @dev Called by `Market`.Validates the payment amount for a transaction.
     * @param _pay The payment amount to be validated.
     * @dev This function is a public view function.
     */
    function validPay(uint256 _pay) public view {
        // Check if the payment amount exceeds the maximum trade amount
        if (_pay > conf.getMaxTradeAmount()) {
            revert("pay>MaxTradeAmount");
        }
    }

    /**
     * @dev Retrieves the validation status for a decrease order count.
     * @param decrOrderCount The current count of decrease orders.
     * @return isValid Boolean value indicating whether the decrease order count is valid.
     * @dev This function is a view function and is part of the IMarketValid interface.
     */
    function getDecreaseOrderValidation(
        uint256 decrOrderCount
    ) external view override returns (bool isValid) {
        // Check if the decrease order count is within the limit defined by the configuration
        return conf.getDecrOrderLmt() >= decrOrderCount + 1;
    }

    /**
     * @dev Called by `Market`.Validates a decrease order based on the provided inputs.
     * @param _collateral The current collateral amount.
     * @param _collateralDelta The change in collateral amount.
     * @param _size The current size of the position.
     * @param _sizeDelta The change in size of the position.
     * @param fees The fees associated with the order.
     * @param decrOrderCount The count of decrease orders.
     * @dev This function is a view function.
     */
    function validDecreaseOrder(
        uint256 _collateral,
        uint256 _collateralDelta,
        uint256 _size,
        uint256 _sizeDelta,
        int256 fees,
        uint256 decrOrderCount
    ) external view {
        // Check if the decrease order count is within the limit defined by the configuration
        require(conf.getDecrOrderLmt() >= decrOrderCount + 1, "trigger>10");

        // Validate the size of the position for a decrease order
        validSize(_size, _sizeDelta, false);

        // If enabled, validate the collateral delta for a decrease order
        if (conf.getEnableValidDecrease())
            validCollateralDelta(
                3,
                _collateral,
                _collateralDelta,
                _size,
                _sizeDelta,
                fees
            );
    }

    /**
     * @dev Called by `Market`.Retrieves the range of collateral delta values based on the specified inputs.
     * @param _isIncrease Boolean flag indicating whether the size is increasing.
     * @param _oldCollertal The current collateral amount.
     * @param _oldSize The current size of the position.
     * @param _sizeDelta The change in size of the position.
     * @return maxCollateralDelta The maximum collateral delta value.
     * @return minCollateralDelta The minimum collateral delta value.
     * @dev This function is a public view function and is part of the IMarketValid interface.
     */
    function getCollateralRange(
        bool _isIncrease,
        uint256 _oldCollertal,
        uint256 _oldSize,
        uint256 _sizeDelta
    )
        public
        view
        override
        returns (uint256 maxCollateralDelta, uint256 minCollateralDelta)
    {
        if (_isIncrease) {
            minCollateralDelta =
                (_sizeDelta + _oldSize) /
                conf.getMinLev() -
                _oldCollertal;
            maxCollateralDelta =
                (_sizeDelta + _oldSize) /
                conf.getMaxLev() -
                _oldCollertal;
        } else {
            uint256 right = (_oldSize - _sizeDelta) / conf.getMinLev();
            minCollateralDelta = _oldCollertal > right
                ? _oldCollertal - right
                : 0;
            maxCollateralDelta =
                _oldCollertal -
                (_oldSize - _sizeDelta) /
                conf.getMaxLev();
        }
    }

    /**
     * @dev Called by `Market`.Validates the mark price based on the specified inputs.
     * @param _isLong Boolean flag indicating whether the position is long.
     * @param _price The current price of the position.
     * @param _isIncrease Boolean flag indicating whether the size is increasing.
     * @param _isExec Boolean flag indicating whether the execution is internal or external.
     * @param _markPrice The mark price of the position.
     * @dev This function is a public view function and is part of the IMarketValid interface.
     */
    function validMarkPrice(
        bool _isLong,
        uint256 _price,
        bool _isIncrease,
        bool _isExec,
        uint256 _markPrice
    ) public pure override {
        require(_price > 0, "input price zero");
        require(_markPrice > 0, "price zero");

        if (!_isExec) {
            require(
                (_isLong == _isIncrease) == (_price > _markPrice),
                "invalid front-end price"
            );
        }
    }

    /**
     * @dev Called by `Market`.Validates the slippage price based on the provided inputs.
     * @param _inputs The UpdatePositionInputs struct containing various parameters.
     * @dev This function is a view function and is part of the IMarketValid interface.
     */
    function validSlippagePrice(
        MarketDataTypes.UpdatePositionInputs memory _inputs
    ) public view override {
        if (_inputs._slippage > conf.getMaxSlippage()) {
            _inputs._slippage = conf.getMaxSlippage();
        }

        uint256 _slippagePrice;
        if (_inputs._isLong == _inputs.isOpen) {
            _slippagePrice =
                _inputs._price +
                (_inputs._price * _inputs._slippage) /
                MarketConfigStruct.DENOMINATOR_SLIPPAGE;
        } else {
            _slippagePrice =
                _inputs._price -
                (_inputs._price * _inputs._slippage) /
                MarketConfigStruct.DENOMINATOR_SLIPPAGE;
        }

        validMarkPrice(
            _inputs._isLong,
            _slippagePrice,
            _inputs.isOpen,
            _inputs._isExec,
            _inputs._oraclePrice
        );
    }

    function setConf(
        uint256 _minSlippage,
        uint256 _maxSlippage,
        uint256 _minLeverage,
        uint256 _maxLeverage,
        uint256 _maxTradeAmount,
        uint256 _minPay,
        uint256 _minCollateral,
        bool _allowOpen,
        bool _allowClose,
        uint256
    ) external override onlyRole(MARKET_MGR_ROLE) {
        IMarketValid.Props memory _conf = conf;
        _conf.setMaxLev(_maxLeverage);

        _conf.setMinLev(_minLeverage);
        _conf.setMinSlippage(_minSlippage);
        _conf.setMaxSlippage(_maxSlippage);
        _conf.setMaxTradeAmount(_maxTradeAmount);
        _conf.setMinPay(_minPay);
        _conf.setMinCollateral(_minCollateral);
        _conf.setAllowOpen(_allowOpen);
        _conf.setAllowClose(_allowClose);

        _conf.setDecimals(uint256(TransferHelper.getUSDDecimals()));
        conf = _conf;
    }

    function setConfData(uint256 _data) external onlyRole(MARKET_MGR_ROLE) {
        IMarketValid.Props memory _conf = conf;
        _conf.data = _data;
        conf = _conf;
    }

    /**
     * @dev Called by `MarketValid`.Validates the liquidation conditions based on the provided inputs.
     * @param pnl The profit and loss value.
     * @param fees The fees associated with the position.
     * @param liquidateFee The liquidation fee.
     * @param collateral The current collateral amount.
     * @param size The current size of the position.
     * @param _raise Boolean flag indicating whether to revert on validation failure.
     * @return _state The state indicating the result of the liquidation validation:
     *   - 0: Liquidation conditions are not met.
     *   - 1: Losses or fees exceed collateral.
     *   - 2: Maximum leverage exceeded.
     * @dev This function is a public view function and is part of the IVault interface.
     */
    function validateLiquidation(
        int256 pnl,
        int256 fees,
        int256 liquidateFee,
        int256 collateral,
        uint256 size,
        bool _raise
    ) public view override returns (uint8) {
        if (pnl < 0 && collateral + pnl < 0) {
            if (_raise) {
                revert("Vault: losses exceed collateral");
            }
            return 1;
        }

        int256 remainingCollateral = collateral;
        if (pnl < 0) {
            remainingCollateral = collateral + pnl;
        }

        if (remainingCollateral < fees) {
            if (_raise) {
                revert("Vault: fees exceed collateral");
            }
            return 1;
        }

        if (remainingCollateral < fees + liquidateFee) {
            if (_raise) {
                revert("Vault: liquidation fees exceed collateral");
            }
            return 1;
        }

        if (
            uint256(remainingCollateral) * conf.getMaxLev() * DECIMALS <
            size * DECIMALS
        ) {
            if (_raise) {
                revert("Vault: maxLeverage exceeded");
            }
            return 2;
        }

        return 0;
    }

    struct isLiquidateVars {
        uint256 _size;
        uint256 _collateral;
        uint256 _realisedPnl;
        int256 _entryFundingRate;
        bool _hasProfit;
        address _account;
        int256 _totoalFees;
        int256 _liqFee;
    }

    /**
     * @dev Called by `Market` and `MarketReader`.Determines the state of liquidation for a given account and market.
     * @param _account The address of the account.
     * @param _market The address of the market.
     * @param _isLong Boolean flag indicating whether the position is long.
     * @param positionBook The instance of the position book.
     * @param feeRouter The instance of the fee router.
     * @param markPrice The mark price of the position.
     * @return _state The state indicating the result of the liquidation check:
     *   - 0: Position is not liquidatable.
     *   - 1: Position is liquidatable.
     * @dev This function is a public view function and is part of the IValid interface.
     */
    function isLiquidate(
        address _account,
        address _market,
        bool _isLong,
        IPositionBook positionBook,
        IFeeRouter feeRouter,
        uint256 markPrice
    ) public view override returns (uint256 _state) {
        Position.Props memory _position = positionBook.getPosition(
            _account,
            markPrice,
            _isLong
        );

        // If the position size is 0, it is not liquidatable
        if (_position.size == 0) {
            return 0;
        }

        MarketDataTypes.UpdatePositionInputs memory _vars;
        _vars.initialize(false);
        _vars._oraclePrice = markPrice;
        _vars._account = _account;
        _vars._isExec = true;
        _vars._isLong = _isLong;
        _vars._sizeDelta = _position.size;
        _vars.collateralDelta = _position.collateral;
        _vars._market = _market;
        _vars.liqState = 1;
        int256[] memory fees = feeRouter.getFees(_vars, _position);

        // Validate the liquidation based on the position details and fees
        _state = validateLiquidation(
            _position.realisedPnl,
            fees[1] + fees[2],
            fees[4],
            int256(_position.collateral),
            _position.size,
            false
        );
    }
}

contract MarketValidReader {
    using MarketConfigStruct for IMarketValid.Props;

    address public marketValid;

    constructor(address _addr) {
        marketValid = _addr;
    }

    function getConf() external view returns (uint256) {
        return IMarketValid(marketValid).conf().data;
    }

    function getMinLev() external view returns (uint) {
        IMarketValid.Props memory _confg = IMarketValid(marketValid).conf();
        return _confg.getMinLev();
    }

    function minSlippage() external view returns (uint) {
        IMarketValid.Props memory _confg = IMarketValid(marketValid).conf();
        return _confg.getMinSlippage();
    }

    function maxSlippage() external view returns (uint) {
        IMarketValid.Props memory _confg = IMarketValid(marketValid).conf();
        return _confg.getMaxSlippage();
    }

    function getMaxLev() external view returns (uint) {
        return IMarketValid(marketValid).conf().getMaxLev();
    }
}
