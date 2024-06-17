// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title Liquify Interface
 * @notice Interface for the Liquify contract that manages liquidity on Uniswap V2.
 */
interface ILiquify {
    /**
     * @notice Initializes the Liquify contract with the specified operator address.
     * @param _operator The address of the operator.
     */
    function initialize(address _operator) external;

    /**
     * @notice Swaps tokens and adds liquidity to Uniswap V2.
     * @param _amount The amount of tokens to swap and add to liquidity.
     */
    function swapAndLiquify(uint256 _amount) external;

    /**
     * @notice Returns the address of the Uniswap V2 pair.
     * @return The address of the Uniswap V2 pair.
     */
    function getPair() external returns (address);

    /**
     * @notice Returns the address of the Uniswap V2 router.
     * @return The address of the Uniswap V2 router.
     */
    function getRouter() external returns (address);

    /**
     * @notice Sets up the mechanics with the new router and base asset addresses.
     * @param _newRouterAddress The new router address.
     * @param _newBaseAsset The new base asset address.
     * @return The addresses of the new router and the new Uniswap V2 pair.
     */
    function setupMechanics(
        address _newRouterAddress, 
        address _newBaseAsset
    ) external returns (address, address);
}
