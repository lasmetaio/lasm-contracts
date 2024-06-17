// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title LASM Interface
 * @notice Interface for the LASM ERC20 token contract.
 */
interface ILasm {
    /**
     * @notice Sets a new tax fee.
     * @param _full If true, updates all fees, otherwise only the tax fee.
     */
    function setNewTaxFee(bool _full) external;

    /**
     * @notice Excludes or includes an account from dividends.
     * @param account The account to exclude or include.
     * @param exclude Whether to exclude or include the account.
     */
    function excludeFromDividends(address account, bool exclude) external;

    /**
     * @notice Adds or removes an address from the exclusion list.
     * @param _address The address to add or remove.
     * @param _isExcluded Whether to add or remove the address.
     */
    function addRemoveFromTax(address _address, bool _isExcluded) external;

    /**
     * @notice Transfers tokens safely.
     * @param to The recipient address.
     * @param amount The amount of tokens to transfer.
     */
    function safeTransfer(address to, uint256 amount) external;

    /**
     * @notice Checks if the given address is an ecosystem contract.
     * @param _address The address to check.
     * @return True if the address is an ecosystem contract, false otherwise.
     */
    function isEcoSystemContract(address _address) external view returns (bool);
}
