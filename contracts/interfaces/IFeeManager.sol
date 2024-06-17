// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title FeeManager Interface
 * @notice Interface for the FeeManager contract that manages fees related to tax, 
 * reward pool, liquidity pool, and team wallet.
 */
interface IFeeManager {
    /**
     * @notice Returns the current tax fee.
     * @return The current tax fee.
     */
    function getTaxFee() external view returns (uint256);

    /**
     * @notice Returns the current fees.
     * @return The tax fee, liquidity pool fee, reward pool fee, and team wallet fee.
     */
    function getFees() external view returns (uint256, uint256, uint256, uint256);
}
