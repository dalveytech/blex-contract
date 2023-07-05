// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../ac/Ac.sol";

import {IFundFee} from "./interfaces/IFundFee.sol";
import {IFeeVault} from "./interfaces/IFeeVault.sol";
import {MarketDataTypes} from "../market/MarketDataTypes.sol";
import {Position} from "../position/PositionStruct.sol";
import {TransferHelper} from "./../utils/TransferHelper.sol";

import "./interfaces/IFeeRouter.sol";
import {Precision} from "../utils/TransferHelper.sol";

contract FeeRouter is Ac, IFeeRouter {
    using SafeERC20 for IERC20;

    address public feeVault;
    address public fundFee;

    uint256 public constant FEE_RATE_PRECISION = Precision.FEE_RATE_PRECISION;

    // market's feeRate and fee
    mapping(address => mapping(uint8 => uint256)) public feeAndRates;

    event UpdateFee(
        address indexed account,
        address indexed market,
        int256[] fees,
        uint256 amount
    );
    event UpdateFeeAndRates(
        address indexed market,
        uint8 kind,
        uint256 oldFeeOrRate,
        uint256 feeOrRate
    );

    constructor(address factory) Ac(factory) {
        _grantRole(MANAGER_ROLE, msg.sender);
    }

    function initialize(
        address vault,
        address fundingFee
    ) external initializer {
        require(vault != address(0), "invalid fee vault");
        require(fundingFee != address(0), "invalid fundFee");

        feeVault = vault;
        fundFee = fundingFee;
    }

    function setFeeVault(address vault) external onlyAdmin {
        require(vault != address(0), "invalid fee vault");
        feeVault = vault;
    }

    function setFundFee(address fundingFee) external onlyAdmin {
        require(fundFee != address(0), "invalid fundFee");
        fundFee = fundingFee;
    }

    function setFeeAndRates(
        address market,
        uint256[] memory rates
    ) external onlyRole(MARKET_MGR_ROLE) {
        require(rates.length > 0, "invalid params");

        for (uint8 i = 0; i < rates.length; i++) {
            uint256 _old = rates[i];
            feeAndRates[market][i] = rates[i];
            emit UpdateFeeAndRates(market, i, _old, rates[i]);
        }
    }

    function getGlobalFees() external view returns (int256 total) {
        return IFeeVault(feeVault).getGlobalFees();
    }

    /**
     * @dev Withdraws tokens from the fee vault contract and transfers them to the specified account.
     * Only the withdraw role can call this function.
     * @param token The address of the token to withdraw.
     * @param to The address to transfer the tokens to.
     * @param amount The amount of tokens to withdraw.
     */
    function withdraw(
        address token,
        address to,
        uint256 amount
    ) external onlyRole(WITHDRAW_ROLE) {
        IFeeVault(feeVault).withdraw(token, to, amount);
    }

    /**
     * @dev Updates the cumulative funding rate for a specific market.
     * Only the controller can call this function.
     * @param market The address of the market.
     * @param longSize The size of the long position.
     * @param shortSize The size of the short position.
     */
    function updateCumulativeFundingRate(
        address market,
        uint256 longSize,
        uint256 shortSize
    ) external onlyController {
        IFundFee(fundFee).updateCumulativeFundingRate(
            market,
            longSize,
            shortSize
        );
    }

    /**
     * @dev Collects fees from the sender and increases the fees in the fee vault for the specified account.
     * Only the controller can call this function.
     * @param account The account to increase fees for.
     * @param token The address of the token to collect fees in.
     * @param fees The array of fee amounts.
     */
    function collectFees(
        address account,
        address token,
        int256[] memory fees
    ) external onlyController {
        uint256 _amount = IERC20(token).allowance(msg.sender, address(this));
        if (_amount == 0) {
            return;
        }

        IERC20(token).safeTransferFrom(msg.sender, feeVault, _amount);
        IFeeVault(feeVault).increaseFees(msg.sender, account, fees);

        emit UpdateFee(account, msg.sender, fees, _amount);
    }

    /**
     * @dev Retrieves the execution fee for a specific market.
     * @param market The address of the market.
     * @return The execution fee for the market.
     */
    function getExecFee(address market) external view returns (uint256) {
        return feeAndRates[market][uint8(FeeType.ExecFee)];
    }

    /**
     * @dev Retrieves the total fees for an account by subtracting the buy and sell LP fees from the account's total fees.
     * @param account The address of the account.
     * @return The total fees for the account.
     */
    function getAccountFees(address account) external view returns (uint256) {
        uint256 _fees = uint256(IFeeVault(feeVault).accountFees(account));
        uint256 _buyFee = uint256(
            IFeeVault(feeVault).accountKindFees(
                account,
                uint8(FeeType.BuyLpFee)
            )
        );
        uint256 _sellFee = uint256(
            IFeeVault(feeVault).accountKindFees(
                account,
                uint8(FeeType.SellLpFee)
            )
        );

        return (_fees - _buyFee - _sellFee);
    }

    /**
     * @dev Retrieves the funding rate for a specific market and position.
     * @param market The address of the market.
     * @param longSize The size of the long position.
     * @param shortSize The size of the short position.
     * @param isLong A flag indicating whether the position is long (true) or short (false).
     * @return The funding rate for the market and position.
     */
    function getFundingRate(
        address market,
        uint256 longSize,
        uint256 shortSize,
        bool isLong
    ) external view returns (int256) {
        return
            IFundFee(fundFee).getFundingRate(
                market,
                longSize,
                shortSize,
                isLong
            );
    }

    /**
     * @dev Retrieves the cumulative funding rates for a specific market and position.
     * @param market The address of the market.
     * @param isLong A flag indicating whether the position is long (true) or short (false).
     * @return The cumulative funding rates for the market and position.
     */
    function cumulativeFundingRates(
        address market,
        bool isLong
    ) external view returns (int256) {
        return IFeeVault(feeVault).cumulativeFundingRates(market, isLong);
    }

    /**
     * @dev Retrieves the total fees for an order by calculating the trade fee and adding it to the execution fee.
     * @param params The parameters of the order.
     * @return fees The total fees for the order.
     */
    function getOrderFees(
        MarketDataTypes.UpdateOrderInputs memory params
    ) external view returns (int256 fees) {
        uint8 _kind;

        if (params.isOpen) {
            _kind = uint8(FeeType.OpenFee);
        } else {
            _kind = uint8(FeeType.CloseFee);
        }

        uint256 _tradeFee = _getFee(params._market, params._order.size, _kind);
        uint256 _execFee = feeAndRates[params._market][uint8(FeeType.ExecFee)];
        return int256(_tradeFee + _execFee);
    }

    /**
     * @dev Retrieves the fees associated with updating a position.
     * @param params The parameters of the position update.
     * @param position The properties of the position.
     * @return fees An array of fees for each fee type.
     */
    function getFees(
        MarketDataTypes.UpdatePositionInputs memory params,
        Position.Props memory position
    ) external view returns (int256[] memory fees) {
        fees = new int256[](uint8(FeeType.Counter));
        address _market = params._market;

        int256 _fundFee = _getFundingFee(
            _market,
            params._isLong,
            position.size,
            position.entryFundingRate
        );
        fees[uint8(FeeType.FundFee)] = _fundFee;

        if (params._sizeDelta == 0 && params.collateralDelta != 0) {
            return fees;
        }

        // open position
        if (params.isOpen) {
            fees[uint8(FeeType.OpenFee)] = int256(
                _getFee(_market, params._sizeDelta, uint8(FeeType.OpenFee))
            );
        } else {
            // close position
            fees[uint8(FeeType.CloseFee)] = int256(
                _getFee(_market, params._sizeDelta, uint8(FeeType.CloseFee))
            );

            // liquidate position
            if (params.liqState == 1) {
                uint256 _fee = feeAndRates[_market][uint8(FeeType.LiqFee)];
                fees[uint8(FeeType.LiqFee)] = int256(_fee);
            }
        }
        if (params.execNum > 0) {
            // exec fee
            uint256 _fee = feeAndRates[_market][uint8(FeeType.ExecFee)];
            _fee = _fee * params.execNum;

            fees[uint8(FeeType.ExecFee)] = int256(_fee);
        }
        return fees;
    }

    /**
     * @dev Calculates the funding fee for a given position update.
     * @param market The address of the market.
     * @param isLong A flag indicating whether the position is long (true) or short (false).
     * @param sizeDelta The change in position size.
     * @param entryFundingRate The funding rate at the entry of the position.
     * @return The funding fee for the position update.
     */
    function _getFundingFee(
        address market,
        bool isLong,
        uint256 sizeDelta,
        int256 entryFundingRate
    ) private view returns (int256) {
        if (sizeDelta == 0) {
            return 0;
        }

        return
            IFundFee(fundFee).getFundingFee(
                market,
                sizeDelta,
                entryFundingRate,
                isLong
            );
    }

    /**
     * @dev Calculates the fee for a given size delta and fee kind.
     * @param market The address of the market.
     * @param sizeDelta The change in position size.
     * @param kind The fee kind.
     * @return The fee amount.
     */

    function _getFee(
        address market,
        uint256 sizeDelta,
        uint8 kind
    ) private view returns (uint256) {
        if (sizeDelta == 0) {
            return 0;
        }

        uint256 _point = feeAndRates[market][kind];
        if (_point == 0) {
            _point = 100000;
        }

        uint256 _size = (sizeDelta * (FEE_RATE_PRECISION - _point)) /
            FEE_RATE_PRECISION;
        return sizeDelta - _size;
    }
}
