// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.17;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IERC20Decimals is IERC20 {
    function decimals() external view returns (uint8);
}

library Precision {
    uint256 public constant BASIS_POINTS_DIVISOR = 100000000;
    uint256 public constant FEE_RATE_PRECISION_DECIMALS = 8;
    uint256 public constant FEE_RATE_PRECISION =
        10 ** FEE_RATE_PRECISION_DECIMALS;
}

library TransferHelper {
    uint8 public constant usdDecimals = 18;

    using SafeERC20 for IERC20;

    /**
     * @dev Retrieves the number of decimal places for USD.
     * @return The number of decimal places for USD.
     */
    function getUSDDecimals() internal pure returns (uint8) {
        return usdDecimals;
    }

    /**
     * @dev Formats the collateral amount by adjusting the number of decimal places.
     * @param amount The original collateral amount.
     * @param collateralTokenDigits The number of decimal places for the collateral token.
     * @return The formatted collateral amount.
     */
    function formatCollateral(
        uint256 amount,
        uint8 collateralTokenDigits
    ) internal pure returns (uint256) {
        return
            (amount * (10 ** uint256(collateralTokenDigits))) /
            (10 ** usdDecimals);
    }

    /**
     * @dev Parses the vault asset amount by adjusting the number of decimal places.
     * @param amount The original asset amount in vault.
     * @param originDigits The number of decimal places for the original asset.
     * @return The parsed vault asset amount.
     */
    function parseVaultAsset(
        uint256 amount,
        uint8 originDigits
    ) internal pure returns (uint256) {
        return (amount * (10 ** uint256(usdDecimals))) / (10 ** originDigits);
    }

    /**
     * @dev This library contains utility functions for transferring assets.
     * @param amount The amount of assets to transfer in integer format with decimal precision.
     * @param collateralTokenDigits The decimal precision of the collateral token.
     * @return The transferred asset amount converted to integer with decimal precision for the USD stablecoin.
     * This function is internal and can only be accessed within the current contract or library.
     */
    function parseVaultAssetSigned(
        int256 amount,
        uint8 collateralTokenDigits
    ) internal pure returns (int256) {
        return
            (amount * int256(10 ** uint256(collateralTokenDigits))) /
            int256(10 ** uint256(usdDecimals));
    }

    /**
     * @dev Transfers a specified amount of tokens from a given address to another address.
     * @param tokenAddress The address of the token.
     * @param _from The address from which the tokens will be transferred.
     * @param _to The address to which the tokens will be transferred.
     * @param _tokenAmount The amount of tokens to be transferred.
     */
    function transferIn(
        address tokenAddress,
        address _from,
        address _to,
        uint256 _tokenAmount
    ) internal {
        // If the token amount is 0, return.
        if (_tokenAmount == 0) return;
        // Retrieve the token contract.
        IERC20 coll = IERC20(tokenAddress);
        // Format the collateral amount based on the token's decimals and transfer the tokens.
        coll.safeTransferFrom(
            _from,
            _to,
            formatCollateral(
                _tokenAmount,
                IERC20Decimals(tokenAddress).decimals()
            )
        );
    }

    /**
     * @dev Transfers a specified amount of tokens to a given address.
     * @param tokenAddress The address of the token.
     * @param _to The address to which the tokens will be transferred.
     * @param _tokenAmount The amount of tokens to be transferred.
     */
    function transferOut(
        address tokenAddress,
        address _to,
        uint256 _tokenAmount
    ) internal {
        // If the token amount is 0, return.
        if (_tokenAmount == 0) return;
        // Retrieve the token contract.
        IERC20 coll = IERC20(tokenAddress);
        // Format the collateral amount based on the token's decimals.
        _tokenAmount = formatCollateral(
            _tokenAmount,
            IERC20Decimals(tokenAddress).decimals()
        );
        // Transfer the tokens to the specified address.
        coll.safeTransfer(_to, _tokenAmount);
    }
}
