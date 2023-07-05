// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "../ac/Ac.sol";
import {IFeeVault} from "./interfaces/IFeeVault.sol";

contract FundFee is Ownable, Ac {
    address public feeVault;

    uint256 public constant MIN_FUNDING_INTERVAL = 1 hours;
    uint256 public constant FEE_RATE_PRECISION = 100000000;
    uint256 public constant BASIS_INTERVAL_HOU = 24;
    uint256 public constant DEFAILT_RATE_DIVISOR = 100;

    uint256 public minRateLimit = 2083;
    uint256 public minorityFRate = 0;

    // market's funding rate update interval
    mapping(address => uint256) public fundingIntervals;

    struct SkipTime {
        uint256 start;
        uint256 end;
    }

    SkipTime[] public skipTimes;

    event UpdateMinRateLimit(uint256 indexed oldLimit, uint256 newLimit);
    event UpdateFundInterval(address indexed market, uint256 interval);
    event UpdateMinorityFRate(uint256 oldFRate, uint256 newFRate);
    event AddSkipTime(uint256 indexed startTime, uint256 indexed endTime);

    constructor(address vault) Ac(msg.sender) {
        require(vault != address(0), "invalid feeVault");
        feeVault = vault;

        _grantRole(MANAGER_ROLE, msg.sender);
    }

    function setMinRateLimit(uint256 limit) external onlyAdmin {
        require(limit > 0, "invalid limit");

        uint256 _oldLimit = minRateLimit;
        minRateLimit = limit;

        emit UpdateMinRateLimit(_oldLimit, limit);
    }

    function setMinorityFRate(uint256 rate) external onlyAdmin {
        uint256 _old = minorityFRate;
        minorityFRate = rate;

        emit UpdateMinorityFRate(_old, rate);
    }

    function setFundingInterval(
        address[] memory markets,
        uint256[] memory intervals
    ) external onlyAdmin {
        require(markets.length == intervals.length, "invalid params");

        uint256 interval;

        for (uint256 i = 0; i < markets.length; i++) {
            require(markets[i] != address(0));
            require(intervals[i] >= MIN_FUNDING_INTERVAL);

            interval =
                (intervals[i] / MIN_FUNDING_INTERVAL) *
                MIN_FUNDING_INTERVAL;
            fundingIntervals[markets[i]] = interval;

            emit UpdateFundInterval(markets[i], interval);
        }
    }

    /**
     * @dev Adds a skip time interval during which certain operations are skipped.
     * @param start The start timestamp of the skip time interval.
     * @param end The end timestamp of the skip time interval.
     */
    function addSkipTime(uint256 start, uint256 end) external onlyAdmin {
        require(end >= start, "invalid params");

        SkipTime memory _skipTime;
        _skipTime.start = start;
        _skipTime.end = end;
        skipTimes.push(_skipTime);

        emit AddSkipTime(start, end);
    }

    /**
     * @dev Retrieves the current timestamp.
     * @return The current timestamp.
     */
    function _getTimeStamp() private view returns (uint256) {
        return block.timestamp;
    }

    /**
     * @dev Updates the cumulative funding rate for a market based on the sizes of long and short positions.
     * @param market The address of the market.
     * @param longSize The size of the long position.
     * @param shortSize The size of the short position.
     */
    function updateCumulativeFundingRate(
        address market,
        uint256 longSize,
        uint256 shortSize
    ) external onlyController {
        uint256 _fundingInterval = _getFundingInterval(market);
        uint256 _lastTime = _getLastFundingTimes(market);

        if (_lastTime == 0) {
            _lastTime = (_getTimeStamp() / _fundingInterval) * _fundingInterval;
            _updateGlobalFundingRate(market, 0, 0, 0, 0, _lastTime);
            return;
        }

        if ((_lastTime + _fundingInterval) > _getTimeStamp()) {
            return;
        }

        (int256 _longRate, int256 _shortRate) = _getFundingRate(
            longSize,
            shortSize
        );
        (int256 _longRates, int256 _shortRates) = _getNextFundingRate(
            market,
            _longRate,
            _shortRate
        );

        _lastTime = (_getTimeStamp() / _fundingInterval) * _fundingInterval;

        _updateGlobalFundingRate(
            market,
            _longRate,
            _shortRate,
            _longRates,
            _shortRates,
            _lastTime
        );
    }

    /**
     * @dev Retrieves the funding rate for a market based on the sizes of long and short positions.
     * @param market The address of the market.
     * @param longSize The size of the long position.
     * @param shortSize The size of the short position.
     * @param isLong Flag indicating whether the position is long.
     * @return The funding rate.
     */
    function getFundingRate(
        address market,
        uint256 longSize,
        uint256 shortSize,
        bool isLong
    ) external view returns (int256) {
        int256 _rate = IFeeVault(feeVault).fundingRates(market, isLong);
        if (_rate != 0) {
            return _rate;
        }

        (int256 _longRate, int256 _shortRate) = _getFundingRate(
            longSize,
            shortSize
        );
        if (isLong) {
            return _longRate;
        }
        return _shortRate;
    }

    /**
     * @dev Retrieves the funding fee for a market based on the size, entry funding rate, and position type.
     * @param market The address of the market.
     * @param size The size of the position.
     * @param entryFundingRate The entry funding rate of the position.
     * @param isLong Flag indicating whether the position is long.
     * @return The funding fee.
     */
    function getFundingFee(
        address market,
        uint256 size,
        int256 entryFundingRate,
        bool isLong
    ) external view returns (int256) {
        if (size == 0) {
            return 0;
        }

        int256 _cumRates = IFeeVault(feeVault).cumulativeFundingRates(
            market,
            isLong
        );
        int256 _divisor = int256(FEE_RATE_PRECISION);

        return _getFundingFee(size, entryFundingRate, _cumRates) / _divisor;
    }

    /**
     * @dev Retrieves the next funding rates for a market based on the sizes of long and short positions.
     * @param market The address of the market.
     * @param longSize The size of the long position.
     * @param shortSize The size of the short position.
     * @return The next funding rates for long and short positions.
     */
    function getNextFundingRate(
        address market,
        uint256 longSize,
        uint256 shortSize
    ) external view returns (int256, int256) {
        (int256 _longRate, int256 _shortRate) = _getFundingRate(
            longSize,
            shortSize
        );

        (int256 _longRates, int256 _shortRates) = _getNextFundingRate(
            market,
            _longRate,
            _shortRate
        );
        return (_longRates, _shortRates);
    }

    /**
     * @dev Retrieves the funding rate for a market based on the sizes of long and short positions.
     * @param longSize The size of the long position.
     * @param shortSize The size of the short position.
     * @return The funding rates for long and short positions.
     */
    function _getFundingRate(
        uint256 longSize,
        uint256 shortSize
    ) private view returns (int256, int256) {
        uint256 _rate = _calFeeRate(longSize, shortSize);
        int256 _sRate = int256(_rate);

        if (_rate == minRateLimit) {
            return (_sRate, _sRate);
        }
        if (longSize >= shortSize) {
            return (_sRate, int256(minorityFRate));
        }
        return (int256(minorityFRate), _sRate);
    }

    /**
     * @dev Calculates the fee rate based on the long and short positions' sizes.
     * @param _longSize The size of the long position.
     * @param _shortSize The size of the short position.
     * @return The fee rate calculated based on the position sizes.
     */
    function _calFeeRate(
        uint256 _longSize,
        uint256 _shortSize
    ) private view returns (uint256) {
        // If both long and short positions have size 0, return the minimum rate limit.
        if (_longSize == 0 && _shortSize == 0) {
            return minRateLimit;
        }

        uint256 _size;
        // Calculate the absolute difference between longSize and shortSize.
        if (_longSize >= _shortSize) _size = _longSize - _shortSize;
        else _size = _shortSize - _longSize;

        uint256 _rate;
        if (_size != 0) {
            // Calculate the divisor by summing longSize and shortSize.
            uint256 _divisor = _longSize + _shortSize;

            // Calculate the fee rate.
            _rate = (_size * FEE_RATE_PRECISION) / _divisor;
            // Square the rate and divide by constants to adjust the rate.
            _rate =
                (_rate ** 2) /
                FEE_RATE_PRECISION /
                DEFAILT_RATE_DIVISOR /
                BASIS_INTERVAL_HOU;
        }

        // If the calculated rate is less than the minimum rate limit, return the minimum rate limit.
        if (_rate < minRateLimit) {
            return minRateLimit;
        }

        return _rate;
    }

    /**
     * @dev Calculates the funding fee based on the position size, entry funding rate, and cumulative rates.
     * @param size The size of the position.
     * @param entryFundingRate The entry funding rate of the position.
     * @param cumRates The cumulative rates.
     * @return The funding fee calculated based on the position parameters.
     */
    function _getFundingFee(
        uint256 size,
        int256 entryFundingRate,
        int256 cumRates
    ) private pure returns (int256) {
        int256 _rate = cumRates - entryFundingRate;
        // If the rate is 0, return 0 as the funding fee.
        if (_rate == 0) {
            return 0;
        }
        // Calculate the funding fee by multiplying the position size with the rate.
        return int256(size) * _rate;
    }

    /**
     * @dev Retrieves the funding interval for a given market.
     * @param market The address of the market.
     * @return The funding interval for the specified market, or the minimum funding interval if not set.
     */
    function _getFundingInterval(
        address market
    ) private view returns (uint256) {
        uint256 _interval = fundingIntervals[market];
        // If the funding interval is set for the market, return it.
        if (_interval != 0) {
            return _interval;
        }

        // If the funding interval is not set, return the minimum funding interval.
        return MIN_FUNDING_INTERVAL;
    }

    /**
     * @dev Retrieves the last funding time for a given market from the FeeVault contract.
     * @param market The address of the market.
     * @return The last funding time for the specified market.
     */
    function _getLastFundingTimes(
        address market
    ) private view returns (uint256) {
        return IFeeVault(feeVault).lastFundingTimes(market);
    }

    /**
     * @dev Calculates the next funding rate for a given market based on the current rates and funding interval.
     * @param _market The address of the market.
     * @param _longRate The current long rate.
     * @param _shortRate The current short rate.
     * @return The next long rate and short rate after the funding interval has passed.
     */
    function _getNextFundingRate(
        address _market,
        int256 _longRate,
        int256 _shortRate
    ) private view returns (int256, int256) {
        uint256 _fundingInterval = _getFundingInterval(_market);
        uint256 _lastTime = _getLastFundingTimes(_market);

        // If the next funding time is not reached yet, return (0, 0) as the next rates.
        if ((_lastTime + _fundingInterval) > _getTimeStamp()) {
            return (0, 0);
        }

        uint256 _skipTimes = _getSkipTimes();
        int256 _intervals = int256(
            (_getTimeStamp() - _lastTime - _skipTimes) / MIN_FUNDING_INTERVAL
        );

        // Calculate the next long and short rates based on the intervals.
        int256 _longRates = _longRate * _intervals;
        int256 _shortRates = _shortRate * _intervals;

        return (_longRates, _shortRates);
    }

    /**
     * @dev Updates the global funding rate for a specific market in the FeeVault contract.
     * @param market The address of the market.
     * @param longRate The current long rate.
     * @param shortRate The current short rate.
     * @param nextLongRate The next long rate after the funding interval.
     * @param nextShortRate The next short rate after the funding interval.
     * @param timestamp The current timestamp.
     */
    function _updateGlobalFundingRate(
        address market,
        int256 longRate,
        int256 shortRate,
        int256 nextLongRate,
        int256 nextShortRate,
        uint256 timestamp
    ) private {
        IFeeVault(feeVault).updateGlobalFundingRate(
            market,
            longRate,
            shortRate,
            nextLongRate,
            nextShortRate,
            timestamp
        );
    }

    /**
     * @dev Retrieves the total skip times accumulated based on the current timestamp and skip times array.
     * @return totalSkip The total skip times accumulated.
     */
    function _getSkipTimes() private view returns (uint256 totalSkip) {
        // If there are no skip times defined, return the total skip as 0.
        if (skipTimes.length == 0) {
            return totalSkip;
        }

        // Iterate through the skip times array and calculate the total skip times.
        for (uint256 i = 0; i < skipTimes.length; i++) {
            if (block.timestamp > skipTimes[i].end) {
                totalSkip += (skipTimes[i].end - skipTimes[i].start);
            }
        }
        // Return the total skip times accumulated.
        return totalSkip;
    }
}
