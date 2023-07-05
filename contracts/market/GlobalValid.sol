// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";

import "./GlobalDataTypes.sol";
import "../ac/Ac.sol";

contract GlobalValid is Ac {
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;

    uint256 public maxSizeLimit = 10000;
    uint256 public maxNetSizeLimit = 10000;
    uint256 public maxUserNetSizeLimit = 10000;

    mapping(address => uint256) public maxMarketSizeLimit;

    constructor() Ac(msg.sender) {}

    function setMaxSizeLimit(uint256 limit) external onlyRole(GLOBAL_MGR_ROLE) {
        require(
            limit > 0 && limit <= BASIS_POINTS_DIVISOR,
            "globalValid: invalid params"
        );
        maxSizeLimit = limit;
    }

    function setMaxNetSizeLimit(
        uint256 limit
    ) external onlyRole(GLOBAL_MGR_ROLE) {
        require(
            limit > 0 && limit <= BASIS_POINTS_DIVISOR,
            "globalValid: invalid params"
        );
        maxNetSizeLimit = limit;
    }

    function setMaxUserNetSizeLimit(
        uint256 limit
    ) external onlyRole(GLOBAL_MGR_ROLE) {
        require(
            limit > 0 && limit <= BASIS_POINTS_DIVISOR,
            "globalValid: invalid params"
        );
        maxUserNetSizeLimit = limit;
    }

    function setMaxMarketSizeLimit(
        address market,
        uint256 limit
    ) external onlyRole(GLOBAL_MGR_ROLE) {
        require(market != address(0), "globalValid: invalid market");
        require(limit > 0, "globalValid: invalid size limit");

        maxMarketSizeLimit[market] = limit;
    }

    /**
     * @dev Checks if the position should be increased.
     * @param params The ValidParams struct containing the valid parameters.
     * @return A boolean indicating whether the position should be increased.
     */
    function isIncreasePosition(
        GlobalDataTypes.ValidParams memory params
    ) external view returns (bool) {
        if (params.sizeDelta == 0) {
            return true;
        }

        uint256 _max = _getMaxIncreasePositionSize(params);

        /**
         * @dev Checks if the maximum increase in position size is greater than or equal to sizeDelta.
         * @return A boolean indicating whether the maximum increase in position size is satisfied.
         */
        return (_max >= params.sizeDelta);
    }

    /**
     * @dev Retrieves the maximum increase in position size.
     * @param params The ValidParams struct containing the valid parameters.
     * @return The maximum increase in position size as a uint256 value.
     */
    function getMaxIncreasePositionSize(
        GlobalDataTypes.ValidParams memory params
    ) external view returns (uint256) {
        return _getMaxIncreasePositionSize(params);
    }

    /**
     * @dev Retrieves the maximum increase in position size based on the provided parameters.
     * @param params The ValidParams struct containing the valid parameters.
     * @return The maximum increase in position size as a uint256 value.
     */
    function _getMaxIncreasePositionSize(
        GlobalDataTypes.ValidParams memory params
    ) private view returns (uint256) {
        uint256 _min = _getMaxUseableGlobalSize(
            params.globalLongSizes,
            params.globalShortSizes,
            params.usdBalance,
            params.isLong
        );
        if (_min == 0) return 0;

        uint256 _tmp = _getMaxUseableNetSize(
            params.globalLongSizes,
            params.globalShortSizes,
            params.usdBalance
        );
        if (_tmp == 0) return 0;

        if (_tmp < _min) _min = _tmp;

        _tmp = _getMaxUseableUserNetSize(
            params.userLongSizes,
            params.userShortSizes,
            params.usdBalance
        );
        if (_tmp == 0) return 0;

        if (_tmp < _min) _min = _tmp;

        _tmp = _getMaxUseableMarketSize(
            params.market,
            params.isLong,
            params.marketLongSizes,
            params.marketShortSizes
        );
        if (_tmp < _min) _min = _tmp;

        return _min;
    }

    /**
     * @dev Calculates the maximum usable global position size based on the provided parameters.
     * @param longSize The current long position size.
     * @param shortSize The current short position size.
     * @param usdBalance The USD balance of the account.
     * @param isLong A boolean indicating whether the position is long (true) or short (false).
     * @return The maximum usable global position size as a uint256 value.
     */
    function _getMaxUseableGlobalSize(
        uint256 longSize,
        uint256 shortSize,
        uint256 usdBalance,
        bool isLong
    ) private view returns (uint256) {
        uint256 _size = isLong ? longSize : shortSize;
        uint256 _limit = (usdBalance * maxSizeLimit) / BASIS_POINTS_DIVISOR;
        if (_size >= _limit) return 0;
        return (_limit - _size);
    }

    /**
     * @dev Calculates the maximum usable net position size based on the provided parameters.
     * @param longSize The current long position size.
     * @param shortSize The current short position size.
     * @param usdBalance The USD balance of the account.
     * @return The maximum usable net position size as a uint256 value.
     */
    function _getMaxUseableNetSize(
        uint256 longSize,
        uint256 shortSize,
        uint256 usdBalance
    ) private view returns (uint256) {
        uint256 _size = longSize > shortSize
            ? longSize - shortSize
            : shortSize - longSize;
        uint256 _limit = (usdBalance * maxNetSizeLimit) / BASIS_POINTS_DIVISOR;
        if (_size >= _limit) return 0;
        return (_limit - _size);
    }

    /**
     * @dev Calculates the maximum usable net position size for the user based on the provided parameters.
     * @param longSize The user's current long position size.
     * @param shortSize The user's current short position size.
     * @param usdBalance The USD balance of the user's account.
     * @return The maximum usable net position size for the user as a uint256 value.
     */
    function _getMaxUseableUserNetSize(
        uint256 longSize,
        uint256 shortSize,
        uint256 usdBalance
    ) private view returns (uint256) {
        uint256 _size = longSize > shortSize
            ? longSize - shortSize
            : shortSize - longSize;

        uint256 _limit = (usdBalance * maxUserNetSizeLimit) /
            BASIS_POINTS_DIVISOR;
        if (_size >= _limit) return 0;
        return (_limit - _size);
    }

    /**
     * @dev Calculates the maximum usable market position size based on the provided parameters.
     * @param market The address of the market.
     * @param isLong A boolean indicating whether the position is long (true) or short (false).
     * @param longSize The current long position size.
     * @param shortSize The current short position size.
     * @return The maximum usable market position size as a uint256 value.
     */
    function _getMaxUseableMarketSize(
        address market,
        bool isLong,
        uint256 longSize,
        uint256 shortSize
    ) private view returns (uint256) {
        uint256 _limit = maxMarketSizeLimit[market];
        uint256 _size = isLong ? longSize : shortSize;

        if (_size >= _limit) return 0;

        return (_limit - _size);
    }
}
