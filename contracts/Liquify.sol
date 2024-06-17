// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// imports
import { LasmOwnable } from "./imports/LasmOwnable.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Pausable } from "@openzeppelin/contracts/security/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { Address } from "./libs/Address.sol";
import { ILasm } from "./interfaces/ILasm.sol";
import { IUniswapV2Router02, IUniswapV2Factory } from "./interfaces/IUniswap.sol";

/**
 * @title Liquify
 * @dev Liquify contract to manage liquidity on Uniswap V2. 
 * This contract allows swapping tokens for ETH and adding liquidity to Uniswap V2 pools. 
 * It supports AMM pairs and ensures that liquidity is added to Uniswap in a secure and non-reentrant manner. 
 * The contract includes mechanisms for swapping tokens, managing liquidity pairs, 
 * and handling dividend and tax exclusions.
 */

contract Liquify is LasmOwnable, Pausable, ReentrancyGuard {
    using Address for address;
    
    IUniswapV2Router02 public uniswapV2Router;
    address public uniswapV2Pair;
    IERC20 private _baseAsset;

    address private _operator;
    uint256 public constant HALFDIV = 2;
    uint256 public constant THIRTY = 30;
    uint256 public constant MINUTE = 60;
    uint256 public constant E18 = 10 ** 18;
    uint256 public constant MILLION = 10 ** 6;
    uint256 public swapTokensAtAmount = 50 * MILLION * E18; 
    bool public swapAndLiquifyEnabled = true;

    mapping(address => bool) public automatedMarketMakerPairs;

    // Events
    /**
     * @dev Emitted when an automated market maker pair is set.
     * @param pair The address of the pair.
     * @param value The value indicating if the pair is set.
     */
    event SetAutomatedMarketMakerPair(address indexed pair, bool indexed value);

    /**
     * @dev Emitted when tokens are swapped and liquified.
     * @param tokensSwapped The amount of tokens swapped.
     * @param ethReceived The amount of ETH received.
     * @param tokensIntoLiquidity The amount of tokens added to liquidity.
     */
    event SwapAndLiquify(
        uint256 indexed tokensSwapped,
        uint256 indexed ethReceived,
        uint256 indexed tokensIntoLiquidity
    );

    /**
     * @dev Emitted when dividends are sent.
     * @param tokensSwapped The amount of tokens swapped.
     * @param amount The amount of dividends sent.
     */
    event SendDividends(
        uint256 indexed tokensSwapped,
        uint256 indexed amount
    );

    /**
     * @dev Emitted when dividend exclusions are applied.
     * @param _protocol The address of the protocol.
     * @param _isExcluded The value indicating if the protocol is excluded.
     */
    event DividendExclusionsApplied(address indexed _protocol, bool indexed _isExcluded);

    /**
     * @dev Emitted when tax exclusions are applied.
     * @param _protocol The address of the protocol.
     * @param _isExcluded The value indicating if the protocol is excluded.
     */
    event TaxExclusionsApplied(address indexed _protocol, bool indexed _isExcluded);

    /**
     * @dev Emitted when the Uniswap router is updated.
     * @param _oldUniswapV2Router The old Uniswap router address.
     * @param _uniswapV2Router The new Uniswap router address.
     */
    event UniswapRouterUpdated(address indexed _oldUniswapV2Router, address indexed _uniswapV2Router);

    /**
     * @dev Emitted when the base asset is updated.
     * @param _oldAddress The old base asset address.
     * @param __baseAsset The new base asset address.
     * @param _uniswapV2Pair The Uniswap V2 pair address.
     */
    event BaseAssetUpdated(
        address indexed _oldAddress,
        address indexed __baseAsset, 
        address indexed _uniswapV2Pair
    );

    /**
     * @dev Emitted when native tokens are received.
     * @param _sender The address of the sender.
     * @param _amount The amount of native tokens received.
     */
    event NativeTokenReceived(address indexed _sender, uint256 indexed _amount);

    /**
     * @dev Emitted when tokens are withdrawn.
     * @param owner The address of the owner.
     * @param destination The address of the destination.
     * @param amount The amount of tokens withdrawn.
     */
    event Withdrawal(address indexed owner, address indexed destination, uint256 indexed amount);

    // Errors
    error OnlyOperator();
    error InvalidAddressInteraction();
    error InvalidContractInteraction();
    error TokenAmountIsZero();
    error AMMPairAlreadySettled();
    error SwapDeadlinePassed();
    error UpdatingTheSameAddress();
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

    /* setup -------------------------------------------------------------------------------------- */

    /**
     * @dev Initializes the contract with the specified token address.
     * @param _token The address of the token.
     */
    constructor(address _token) {
        if (!_token.isContract()) revert InvalidContractInteraction();
        _transferOwnership(_msgSender());
        _operator = _token;
        _baseAsset = IERC20(_token);
    }

    /**
     * @dev Fallback function to receive native tokens.
     */
    receive() external payable {
        emit NativeTokenReceived(msg.sender, msg.value);
    }

    fallback() external payable {
        revert NotPermitted();
    }

    /* mechanics -----------------------------------------------------------------------------------*/

    /**
     * @dev Sets up the mechanics with the new router and base asset addresses.
     * @param _newRouterAddress The new router address.
     * @param _newBaseAsset The new base asset address.
     * @return The addresses of the new router and the new Uniswap V2 pair.
     */
    function setupMechanics(
        address _newRouterAddress, 
        address _newBaseAsset
    ) 
        external 
        nonReentrant()
        validContract(_newRouterAddress)
        validContract(_newBaseAsset)
        onlyOperator() 
        whenNotPaused()
        returns (address, address)
    {
        address _uniswapV2Router = _setRouter(_newRouterAddress);
        address _uniswapV2Pair = _setBaseAsset(_newBaseAsset);
        return (_uniswapV2Router, _uniswapV2Pair);
    }

    /* setters ------------------------------------------------------------------------------------ */

    /**
     * @dev Sets the router address.
     * @param newRouterAddress The new router address.
     * @return The address of the new router.
     */
    function _setRouter(address newRouterAddress) internal returns (address) {
        if (newRouterAddress == address(uniswapV2Router)) revert UpdatingTheSameAddress();

        emit UniswapRouterUpdated(address(uniswapV2Router), newRouterAddress);

        uniswapV2Router = IUniswapV2Router02(newRouterAddress);
        _setTaxExclusions((address(uniswapV2Router)), true);
        _setDividendExclusions(address(uniswapV2Router), true);

        return address(uniswapV2Router);
    }

    /**
     * @dev Sets the base asset address.
     * @param _newBaseAsset The new base asset address.
     * @return The address of the new Uniswap V2 pair.
     */
    function _setBaseAsset(address _newBaseAsset) internal returns (address) {
        emit BaseAssetUpdated(address(_baseAsset), _newBaseAsset, uniswapV2Pair);
        _baseAsset = IERC20(_newBaseAsset);
        uniswapV2Pair = IUniswapV2Factory(uniswapV2Router.factory())
            .createPair(address(_baseAsset), uniswapV2Router.WETH());
        
        _setDividendExclusions(address(uniswapV2Pair), true);
        _setAutomatedMarketMakerPair(uniswapV2Pair, true);

        return address(uniswapV2Pair);
    }

    /**
     * @dev Sets dividend exclusions for a protocol.
     * @param _protocol The address of the protocol.
     * @param _isExcluded The value indicating if the protocol is excluded.
     */
    function _setDividendExclusions(address _protocol, bool _isExcluded) internal {
        ILasm(address(_baseAsset)).excludeFromDividends(address(_protocol), _isExcluded);
        emit DividendExclusionsApplied(_protocol, _isExcluded);
    }

    /**
     * @dev Sets tax exclusions for a protocol.
     * @param _protocol The address of the protocol.
     * @param _isExcluded The value indicating if the protocol is excluded.
     */
    function _setTaxExclusions(address _protocol, bool _isExcluded) internal {
        ILasm(address(_baseAsset)).addRemoveFromTax(address(_protocol), _isExcluded);
        emit TaxExclusionsApplied(_protocol, _isExcluded);
    }

    /* getters ------------------------------------------------------------------------------------ */

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
     * @dev Returns the router address.
     * @return The router address.
     */
    function getRouter() external view returns (address) {
        return address(uniswapV2Router);
    }

    /**
     * @dev Returns the Uniswap V2 pair address.
     * @return The Uniswap V2 pair address.
     */
    function getPair() external view returns (address) {
        return uniswapV2Pair;
    }

    /* internals ---------------------------------------------------------------------------------- */

    /**
     * @dev Sets an automated market maker pair.
     * @param pair The address of the pair.
     * @param value The value indicating if the pair is set.
     */
    function _setAutomatedMarketMakerPair(address pair, bool value) private {
        if (automatedMarketMakerPairs[pair] == value) revert AMMPairAlreadySettled();
        automatedMarketMakerPairs[pair] = value;
        if (value) {
            _setDividendExclusions(address(uniswapV2Pair), true);
        }
        emit SetAutomatedMarketMakerPair(pair, value);
    }

    /**
     * @dev Swaps tokens and adds liquidity.
     * @param _tokenAmount The amount of tokens to swap and add to liquidity.
     */
    function swapAndLiquify(uint256 _tokenAmount) public nonReentrant() onlyOperator() {
        
        uint256 half = _tokenAmount / HALFDIV;

        uint256 otherHalf = _tokenAmount - half;
    
        uint256 initialBalance = address(this).balance;
    
        uint256 deadline = block.timestamp;
        deadline = deadline + THIRTY * MINUTE;

        _swapTokensForEth(half, deadline);
    
        uint256 newBalance = address(this).balance;
        newBalance -= initialBalance;

        _addLiquidity(otherHalf, newBalance);
    
        emit SwapAndLiquify(half, newBalance, otherHalf);
    }   

    /**
     * @dev Swaps tokens for ETH.
     * @param _tokenAmount The amount of tokens to swap.
     * @param _deadline The deadline for the swap.
     */
    function _swapTokensForEth(uint256 _tokenAmount, uint256 _deadline) private {
        if (_deadline < block.timestamp) revert SwapDeadlinePassed();
    
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();
    
        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            _tokenAmount,
            0,
            path,
            address(this),
            _deadline
        );
    }
      
    /**
     * @dev Adds liquidity to the Uniswap pool.
     * @param _tokenAmount The amount of tokens to add to the liquidity pool.
     * @param _ethAmount The amount of ETH to add to the liquidity pool.
     */
    function _addLiquidity(uint256 _tokenAmount, uint256 _ethAmount) private {    
        uniswapV2Router.addLiquidityETH{value: _ethAmount}(
            address(this),
            _tokenAmount,
            0,
            0,
            address(_baseAsset),
            block.timestamp
        );
    }

    /* administrator ----------------------------------------------------------------------------------- */

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
        onlyOwner() 
    {
        if (_amount == 0) revert TokenAmountIsZero();
        SafeERC20.safeTransfer(IERC20(_tokenAddress), _to, _amount);
        emit Withdrawal(_tokenAddress, _to, _amount);
    }

    /**
     * @dev Pauses the contract.
     */
    function pause() external onlyOwner() {
        _pause();
    }

    /**
     * @dev Unpauses the contract.
     */
    function unpause() external onlyOwner() {
        _unpause();
    }
}
