// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title Vesting Interface
 * @notice Interface for interacting with vesting contracts
 */
interface IVesting {
    /**
     * @notice Get the address of the vesting claim contract
     * @return The address of the vesting claim contract
     */
    function getVestingClaimContract() external view returns (address);

    /**
     * @notice Claim vested tokens for a specific vesting wallet and template
     * @param _vestingWallet The address of the vesting wallet
     * @param _templateName The name of the template used for vesting
     */
    function claimTokens(address _vestingWallet, string calldata _templateName) external;

    /**
     * @notice Claim vested tokens for a specific vesting wallet used in an ICO
     * @param _vestingWallet The address of the vesting wallet
     */
    function claimTokensForICO(address _vestingWallet) external;

    /**
     * @notice Get the amount of tokens pending for a specific template
     * @param _templateName The name of the template used for vesting
     * @return The amount of tokens pending to be claimed
     */
    function pendingClaimableTokens(string calldata _templateName) external view returns (uint256);

    /**
     * @notice Get the address of the vesting token
     * @return The address of the vesting token
     */
    function getVestingToken() external view returns (address);
}
