// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// imports
import { LasmOwnable } from "./imports/LasmOwnable.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Address } from "./libs/Address.sol";
import { ILasm } from "./interfaces/ILasm.sol";

/**
 * @title FeeManager
 * @dev This contract manages various fees related to tax, reward pool, liquidity pool, and team wallet.
 * It allows the owner to set and update fees, ensuring that they do not exceed predefined limits.
 * The contract also includes mechanisms for handling fee distribution 
 * and allows the operator to perform specific actions.
 */

contract FeeManager is LasmOwnable {
    using SafeERC20 for IERC20;
    using Address for address;

    ILasm private _baseAsset;
    /**  
    *  @dev This is for following the same pattern on all contracts 
    *  and further guarding for accepting commands from _operator
    */
    address private _operator; 

    uint256 public constant ZERO = 0;
    uint256 public constant HUNDRED = 100;
    uint256 public constant MAX_TOLERANCE = 1000;
    uint256 public taxFee = 50;
    uint256 public rewardPoolFee = 40;
    uint256 public liquidityPoolFee = 40;
    uint256 public teamWalletFee = 20;

    // Events
    /**
     * @dev Emitted when the tax fee is updated.
     * @param _newTaxFee The new tax fee.
     */
    event TaxFeeUpdated(uint256 indexed _newTaxFee);

    /**
     * @dev Emitted when the fees are updated.
     * @param _teamWalletFee The new team wallet fee.
     * @param _rewardPoolFee The new reward pool fee.
     * @param _liquidityPoolFee The new liquidity pool fee.
     */
    event FeesUpdated(
        uint256 indexed _teamWalletFee,
        uint256 indexed _rewardPoolFee, 
        uint256 indexed _liquidityPoolFee
    );

    /**
     * @dev Emitted when tokens are withdrawn from the contract.
     * @param owner The address of the owner initiating the withdrawal.
     * @param destination The address receiving the tokens.
     * @param amount The amount of tokens withdrawn.
     */
    event Withdrawal(address indexed owner, address indexed destination, uint256 indexed amount);

    // Errors
    error OnlyOperator();
    error InvalidAddressInteraction();
    error InvalidContractInteraction();
    error UpdatingTheSameAddress();
    error TokenAmountIsZero();
    error InvalidRates();
    error DoesNotAcceptingEthers();
    error NotPermitted();

    // Modifiers
    /**
     * @dev Modifier to make a function callable only by the operator.
     */
    modifier onlyOperator() {
        if (_msgSender() != _operator) {
            revert OnlyOperator();
        }
        _;
    }

    /**
     * @dev Modifier to validate if an address is a contract.
     * @param _address The address to validate.
     */
    modifier validContract(address _address) {
        if (!_address.isContract()) {
            revert InvalidContractInteraction();
        }
        _;
    }

    /**
     * @dev Modifier to validate if an address is non-zero.
     * @param _address The address to validate.
     */
    modifier validAddress(address _address) {
        if (_address == address(0)) {
            revert InvalidAddressInteraction();
        }
        _;
    }

    // Constructor
    /**
     * @dev Initializes the contract with the specified token address.
     * @param _token The address of the token.
     */
    constructor(address _token) {
        if (!_token.isContract()) revert InvalidContractInteraction();
        _operator = _token;
        _baseAsset = ILasm(_token);
    }

    // Fallback functions
    /**
     * @dev Disallow direct ether transfers.
     */
    receive() external payable {
        revert DoesNotAcceptingEthers();
    }

    /**
     * @dev Disallow direct ether transfers.
     */
    fallback() external payable {
        revert NotPermitted();
    }

    // Functions
    /**
     * @dev Sets the tax fee.
     * @param _taxFee The new tax fee.
     */
    function setTaxFee(uint256 _taxFee) external onlyOwner {
        if (_taxFee > MAX_TOLERANCE) revert InvalidRates();
        taxFee = _taxFee;
        _baseAsset.setNewTaxFee(false);
        emit TaxFeeUpdated(taxFee);
    }
    
    /**
     * @dev Returns the current fees.
     * @return The tax fee, liquidity pool fee, reward pool fee, and team wallet fee.
     */
    function getFees() external view returns (uint256, uint256, uint256, uint256) {
        return (taxFee, liquidityPoolFee, rewardPoolFee, teamWalletFee);
    }

    /**
     * @dev Sets the fees for team wallet, reward pool, and liquidity pool.
     * @param _teamWalletFee The new team wallet fee.
     * @param _rewardPoolFee The new reward pool fee.
     * @param _liquidityPoolFee The new liquidity pool fee.
     */
    function setFees(
        uint256 _teamWalletFee,
        uint256 _rewardPoolFee, 
        uint256 _liquidityPoolFee
    ) external onlyOwner {
        uint256 totalFee = _teamWalletFee + _rewardPoolFee + _liquidityPoolFee;
        if (
            !(totalFee == HUNDRED || 
            (_teamWalletFee == ZERO && 
            _rewardPoolFee == ZERO && 
            _liquidityPoolFee == ZERO))
        ) {
            revert InvalidRates();
        }
    
        teamWalletFee = _teamWalletFee;
        rewardPoolFee = _rewardPoolFee;
        liquidityPoolFee = _liquidityPoolFee;
        _baseAsset.setNewTaxFee(true);
        emit FeesUpdated(_teamWalletFee, _rewardPoolFee, _liquidityPoolFee);
    }
    
    // Getters
    /**
     * @dev Returns the operator address.
     * @return The operator address.
     */
    function getOperator() external view returns (address) {
        return _operator;
    }

    /**
     * @dev Returns the base asset address.
     * @return The base asset address.
     */
    function getBaseAsset() external view returns (address) {
        return address(_baseAsset);
    }

    /**
     * @dev Returns the current tax fee.
     * @return The current tax fee.
     */
    function getTaxFee() external view returns (uint256) {
        return taxFee;
    }
    
    /**
     * @dev Returns the current reward pool fee.
     * @return The current reward pool fee.
     */
    function getRewardPoolFee() external view returns (uint256) {
        return rewardPoolFee;
    }
    
    /**
     * @dev Returns the current liquidity pool fee.
     * @return The current liquidity pool fee.
     */
    function getLiquidityPoolFee() external view returns (uint256) {
        return liquidityPoolFee;
    }
    
    /**
     * @dev Returns the current team wallet fee.
     * @return The current team wallet fee.
     */
    function getTeamWalletFee() external view returns (uint256) {
        return teamWalletFee;
    }

    // Internal functions
    /**
     * @dev Sets the base asset address internally.
     * @param _newBaseAsset The new base asset address.
     */
    function _setBaseAsset(address _newBaseAsset) 
        internal 
    {
        if (_newBaseAsset == address(_baseAsset)) revert UpdatingTheSameAddress();
        _baseAsset = ILasm(_newBaseAsset);
    }

    // Administrator functions
    /**
     * @dev Rescues tokens from the contract.
     * @param _tokenAddress The address of the token to rescue.
     * @param _to The address to send the rescued tokens to.
     * @param _amount The amount of tokens to rescue.
     */
    function rescueTokens(address _tokenAddress, address _to, uint256 _amount) 
        external 
        validContract(_tokenAddress)
        validAddress(_to) 
        onlyOwner 
    {
        if (_amount == 0) revert TokenAmountIsZero();
        SafeERC20.safeTransfer(IERC20(_tokenAddress), _to, _amount);
        emit Withdrawal(_tokenAddress, _to, _amount);
    }
}