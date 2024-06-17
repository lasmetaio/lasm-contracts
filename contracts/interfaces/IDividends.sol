// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title Dividends Interface
 * @notice Interface for the Dividends contract.
 */
interface IDividends {
    /**
     * @notice Excludes or includes an address from receiving dividends.
     * @param _address The address to exclude or include.
     * @param _isExcluded True to exclude the address, false to include.
     */
    function excludeFromDividends(address _address, bool _isExcluded) external;
}
