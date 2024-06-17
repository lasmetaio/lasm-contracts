// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// imports
import { LasmOwnable } from "./imports/LasmOwnable.sol";
import { ERC20, ERC20Burnable } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Pausable } from "@openzeppelin/contracts/security/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { Address } from "./libs/Address.sol";
import { ILiquify } from "./interfaces/ILiquify.sol";
import { IDividends } from "./interfaces/IDividends.sol";
import { IFeeManager } from "./interfaces/IFeeManager.sol";
import { IVesting } from "./interfaces/IVesting.sol";

/**
 * @title LASM Token
 * @dev LASM is an ERC20 token with burning, pausing, and reentrancy protection capabilities.
 * The contract supports an ecosystem of modular components, enabling flexibility and separation of concerns.
 * It integrates with external contracts for liquidity management, dividends distribution, fee management, and vesting.
 * The contract includes mechanisms to exclude addresses from taxes and dividends, manage ecosystem contracts, 
 * and enforce modular interactions with other contracts for maintaining a robust and scalable architecture.
 */

contract LASM is ERC20Burnable, LasmOwnable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Address for address;

    uint256 public constant ZERO = 0;
    uint256 public constant HALFDIV = 2;
    uint256 public constant HUNDRED = 100;
    uint256 public constant THOUSAND = 1000;
    uint256 public constant E18 = 1e18;
    uint256 public constant MILLION = 1e6;
    uint256 public constant INITIAL_SUPPLY = 500 * MILLION * E18;

    uint256 public swapTokensAtAmount = E18 * 1000;
    uint256 public maxAllowenceForVestingContract = E18 * 100_000;

    bool private _inSwapAndLiquify = false;
    bool private _swapAndLiquifyEnabled = true;

    address public uniswapV2Pair;
    address public uniswapRouter;
    address public teamDevWalletAddress;
    address public buyBackWalletAddress;

    uint256 public taxFee;
    uint256 public rewardPoolFee = 40;
    uint256 public liquidityPoolFee = 40;
    uint256 public teamWalletFee = 20;
    uint256 public lastFeeUpdate;

    ILiquify public liquify;
    IDividends public dividend;
    IVesting public vesting;
    IFeeManager public feeManager;

    address public vestingClaimContract;

    mapping(address => bool) public excludeFromTax;
    mapping(address => bool) private _ecosytemContracts;

    // Events
    event LiquifyContractUpdated(address indexed previousAddress, address indexed newAddress);
    event LiquidityRouterAddressUpdated(address indexed _uniswapRouter, address indexed _uniswapPair);
    event DividendContractUpdated(address indexed previousAddress, address indexed newAddress);
    event FeeManagerContractUpdated(address indexed previousAddress, address indexed newAddress);
    event VestingContractUpdated(address indexed previousAddress, address indexed newAddress);
    event TeamDevWalletUpdated(address indexed previousAddress, address indexed newAddress);
    event BuyBackWalletUpdated(address indexed previousAddress, address indexed newAddress);
    event SwapTokensAtAmountHasChanged(uint256 indexed _amount);
    event AddressTaxExclusionChanged(address indexed _address, bool indexed _isExcluded);
    event AddressDividendExclusionChanged(address indexed previousAddress, bool indexed _isExcluded);
    event EcosytemAddressListUpdated(address indexed _account, bool indexed _isAdded);
    event FeesUpdated(
        uint256 indexed _teamWalletFee,
        uint256 indexed _rewardPoolFee, 
        uint256 indexed _liquidityPoolFee
    );
    event FeeUpdateFailed(string indexed _reason);
    event NewTaxFeeReceivedFromFeeManager(uint256 indexed taxFee);
    event Withdrawal(address indexed owner, address indexed destination, uint256 indexed amount);

    // Errors
    error InvalidContractInteraction();
    error InvalidAddressInteraction();
    error SameAddressProvided();
    error TeamAndBuyBackWalletsNotSettled();
    error InvalidFeeUpdatingInterval();
    error TokenAmountIsZero();
    error DoesNotAcceptingEthers();
    error NotPermitted();

    // Modifiers
    modifier validContract(address _address) {
        if(!Address.isContract(_address)) revert InvalidContractInteraction();
        _;
    }

    modifier validAddress(address _address) {
        if(_address.isZeroAddress()) revert InvalidAddressInteraction();
        _;
    }

    modifier onlyEcoSystemContracts(){
        if(!_ecosytemContracts[_msgSender()]) revert NotPermitted();
        _;
    }

    /* setup ------------------------------------------------------------------------------------- */

    /**
     * @dev Sets up the initial supply, mints the tokens 
     * and adds necessary addresses to the ecosystem and exclusion lists.
     */
    constructor() ERC20("LASM TOKEN", "LASM") {
        _mint(_msgSender(), INITIAL_SUPPLY);

        _addRemoveFromEcoSystem(address(this),true);
        _addRemoveFromEcoSystem(_msgSender(),true);
        _addRemoveFromExclusion(_msgSender(), true);
        _addRemoveFromExclusion(address(this), true);
        
    }

    receive() external payable {
        revert DoesNotAcceptingEthers();
    }

    fallback() external payable {
        revert NotPermitted();
    }

    /* mechanics -------------------------------------------------------------------------------- */

    /**
     * @dev Checks if the given address is excluded from tax.
     * @param _wallet Address to check.
     * @return bool True if the address is excluded, false otherwise.
     */
    function isExcludedFromTax(address _wallet) external view validAddress(_wallet) returns(bool) {
        return excludeFromTax[_wallet];
    }

    /**
     * @dev Adds or removes an address from the exclusion list.
     * @param _address The address to be added or removed.
     * @param _isExcluded True if the address should be excluded, false otherwise.
     */
    function addRemoveFromTax(address _address, bool _isExcluded) 
    external 
    validAddress(_address)
    onlyEcoSystemContracts() 
    {
        _addRemoveFromExclusion(_address, _isExcluded);
    }

    /**
     * @dev Excludes or includes an address in dividends.
     * @param _address The address to be added or removed from dividends.
     * @param _isExcluded True if the address should be excluded, false otherwise.
     */
    function excludeFromDividends(address _address, bool _isExcluded) 
    external 
    validAddress(_address)
    onlyEcoSystemContracts() 
    {
        _addRemoveFromDividends(_address, _isExcluded);
    }

    /**
     * @dev Sets a new tax fee. Updates fees from the Fee Manager contract.
     * @param _full If true, updates all fees, otherwise only the tax fee.
     */
    function setNewTaxFee(bool _full) external onlyEcoSystemContracts() {
        if(_full) {
            _updateFees();
        } else {
            taxFee  = feeManager.getTaxFee();
            emit NewTaxFeeReceivedFromFeeManager(taxFee);
        }
    }

    /**
     * @dev Sends the team and buy back fees to their respective addresses.
     * @param _tokens Amount of tokens to be sent.
     */
    function _sendToTeamDevAndBuyBackFee(uint256 _tokens) 
        private
        {
            if(teamDevWalletAddress == address(0) || buyBackWalletAddress == address(0)){
                revert TeamAndBuyBackWalletsNotSettled();
            }

            uint256 amount = _tokens / HALFDIV;
            super._transfer(address(this),teamDevWalletAddress, amount);

            amount = _tokens - amount;
            super._transfer(address(this), buyBackWalletAddress, amount);
    }

    /**
     * @dev Distributes dividends to the Dividend contract.
     * @param amount Amount of tokens to distribute.
     */
    function _distributeDividends(uint256 amount) 
        private 
        validAddress(address(dividend)) {
            super._transfer(address(this), address(dividend), amount);
    }

    /* setters ---------------------------------------------------------------------------------- */

    /**
     * @dev Sets a new team development wallet address.
     * @param _wallet The new team development wallet address.
     */
    function setTeamDevWalletAddress(address _wallet) 
        external 
        validAddress(_wallet)
        onlyOwner()
        {
            emit TeamDevWalletUpdated(teamDevWalletAddress, _wallet);
            teamDevWalletAddress = _wallet;
            _addRemoveFromExclusion(teamDevWalletAddress, true);
        }

    /**
     * @dev Sets a new buy back wallet address.
     * @param _wallet The new buy back wallet address.
     */
    function setBuyBackWalletAddress(address _wallet) 
    external 
    validAddress(_wallet)
    onlyOwner()
        {
            emit BuyBackWalletUpdated(buyBackWalletAddress, _wallet);
            buyBackWalletAddress = _wallet;
            _addRemoveFromExclusion(buyBackWalletAddress, true);
        }

    /**
     * @dev Sets a new liquify contract address.
     * @param newLiquifyContract The new liquify contract address.
     */
    function setLiquifyContract(address newLiquifyContract)
        external 
        validContract(newLiquifyContract)
        onlyOwner()
        {
            if(newLiquifyContract == address(liquify)) revert SameAddressProvided();
        
            if(address(liquify) != address(0)) _addRemoveFromEcoSystem(address(liquify),false);

            emit LiquifyContractUpdated(address(liquify), newLiquifyContract);

            liquify = ILiquify(newLiquifyContract);

            uniswapV2Pair = liquify.getPair();
            uniswapRouter = liquify.getRouter();

            _addRemoveFromEcoSystem(address(liquify),true);
            _addRemoveFromExclusion(address(liquify), true);
        }

    /**
     * @dev Sets a new liquify swap router address.
     * @param _newLiquifySwapRouter The new liquify swap router address.
     */
    function setLiquifySwapRouter(address _newLiquifySwapRouter)
        external 
        validContract(_newLiquifySwapRouter)
        onlyOwner()
        {
            if(address(liquify) == address(0)) revert InvalidContractInteraction();
            if(uniswapV2Pair == _newLiquifySwapRouter) revert SameAddressProvided();
            (uniswapV2Pair, uniswapRouter) = liquify.setupMechanics(_newLiquifySwapRouter, address(this));
            emit LiquidityRouterAddressUpdated(uniswapRouter, uniswapV2Pair);
        }

    /**
     * @dev Sets a new dividend contract address.
     * @param _newDividendContract The new dividend contract address.
     */
    function setDividendContract(address _newDividendContract)
        external 
        validContract(_newDividendContract) 
        onlyOwner()
        {
            if(_newDividendContract == address(dividend)) revert SameAddressProvided();
            if(address(dividend) != address(0)) _addRemoveFromEcoSystem(address(dividend),false);

            emit DividendContractUpdated(address(dividend), _newDividendContract);
        
            dividend = IDividends(_newDividendContract);
        
            _addRemoveFromEcoSystem(address(dividend),true);
            _addRemoveFromExclusion(address(dividend), true);
        }    

    /**
     * @dev Sets a new vesting contract address.
     * @param newVestingContract The new vesting contract address.
     */
    function setVestingContract(address newVestingContract)
        external 
        validContract(newVestingContract) 
        onlyOwner()
        {
            if(newVestingContract == address(vesting)) revert SameAddressProvided();
            if(address(vesting) != address(0)) _addRemoveFromEcoSystem(address(vesting),false);

            emit VestingContractUpdated(address(vesting), newVestingContract);

            vesting = IVesting(newVestingContract);

            vestingClaimContract = vesting.getVestingClaimContract();

            _addRemoveFromEcoSystem(address(vesting),true);
            _addRemoveFromExclusion(address(vesting), true);

        }    

    /**
     * @dev Sets a new fee manager contract address.
     * @param _newFeeManagerContract The new fee manager contract address.
     */
    function setFeeManagerContract(address _newFeeManagerContract) 
        external 
        validContract(_newFeeManagerContract)
        onlyOwner()         
        {
            if(_newFeeManagerContract == address(feeManager)) revert SameAddressProvided();
            if(address(feeManager) != address(0) )_addRemoveFromEcoSystem(address(feeManager),false);

            emit FeeManagerContractUpdated(address(feeManager), _newFeeManagerContract);

            feeManager = IFeeManager(_newFeeManagerContract);
            _updateFees();

            _addRemoveFromEcoSystem(address(feeManager),true);
            _addRemoveFromExclusion(address(feeManager), true);

        }   

    /**
     * @dev Adds or removes an address from the ecosystem contract list.
     * @param _address The address to be added or removed.
     * @param _isAdded True if the address should be added, false otherwise.
     */
    function addRemoveEcoSystemContract(address _address, bool _isAdded) 
        external 
        validAddress(_address) 
        onlyOwner()
        {
            _addRemoveFromEcoSystem(_address,_isAdded);
            _addRemoveFromExclusion(_address, _isAdded);
            emit EcosytemAddressListUpdated(_address, _isAdded);
        } 
    
    /**
     * @dev Forces fee updates from the Fee Manager contract.
     */
    function enforceFeeUpdates() external onlyOwner {
        _updateFees();
    }

    /* getters ---------------------------------------------------------------------------------- */

    /**
     * @dev Returns the team development wallet address.
     * @return address The team development wallet address.
     */
    function getTeamDevWalletAddress() external view returns(address) {
        return teamDevWalletAddress;
    }

    /**
     * @dev Returns the buy back wallet address.
     * @return address The buy back wallet address.
     */
    function getBuyBackWalletAddress() external view returns(address) {
        return buyBackWalletAddress;
    }

    /**
     * @dev Checks if the given address is an ecosystem contract.
     * @param _address The address to check.
     * @return bool True if the address is an ecosystem contract, false otherwise.
     */
    function isEcoSystemContract(address _address) external view validAddress(_address) returns(bool) {
        return _ecosytemContracts[_address];
    }

    /* internals ---- --------------------------------------------------------------------------- */

    /**
     * @dev Updates fees from the Fee Manager contract.
     */
    function _updateFees() internal {
        (taxFee, liquidityPoolFee, rewardPoolFee, teamWalletFee) = feeManager.getFees();
        
        uint256 totalFees = liquidityPoolFee + rewardPoolFee + teamWalletFee;
        
        if (totalFees != HUNDRED && (liquidityPoolFee != ZERO || rewardPoolFee != ZERO || teamWalletFee != ZERO)) {
            emit FeeUpdateFailed("Total fee percentages must equal 100% or all be zero.");
            return;
        }
        
        lastFeeUpdate = block.number;
        emit FeesUpdated(teamWalletFee, rewardPoolFee, liquidityPoolFee);
        emit NewTaxFeeReceivedFromFeeManager(taxFee);
    }
    

    /**
     * @dev Distributes fees to the respective pools and wallets.
     * @param _balance The balance of tokens to distribute.
     */
    function _distributeFees(uint256 _balance) internal {    
        uint256 toLiquify = (_balance * liquidityPoolFee) / HUNDRED;
        uint256 toRewards = (_balance * rewardPoolFee) / HUNDRED;
        uint256 toTeam = (_balance * teamWalletFee) / HUNDRED;

        uint256 totalCalculatedFees = toLiquify + toRewards + toTeam;

        if (totalCalculatedFees > _balance) return;

        liquify.swapAndLiquify(toLiquify);
        _sendToTeamDevAndBuyBackFee(toTeam);
        _distributeDividends(toRewards);
    }    

    /**
     * @dev Transfers tokens from one address to another with fee handling.
     * @param _from The address to transfer from.
     * @param _to The address to transfer to.
     * @param _amount The amount of tokens to transfer.
     */
    function _transfer(address _from, address _to, uint256 _amount)
    internal override
    nonReentrant()
    whenNotPaused()
    validAddress(_from)
    validAddress(_to)
    {
        bool isNotEcosystemContract = !_ecosytemContracts[_from] && !_ecosytemContracts[_to];
        bool isNotUniswapPair = _from != uniswapV2Pair && _to != uniswapV2Pair;

        if (_inSwapAndLiquify == false && taxFee != ZERO && isNotEcosystemContract && isNotUniswapPair) {
            if (!_isExcludedFromTax(_from, _to)) {
                uint256 fees = (_amount * taxFee) / THOUSAND;
                _amount -= fees;
                super._transfer(_from, address(this), fees);
            }

            uint256 balance = balanceOf(address(this));

            if (_from != uniswapV2Pair && _swapAndLiquifyEnabled && balance >= swapTokensAtAmount) {
                _inSwapAndLiquify = true;
                _distributeFees(balance);
                _inSwapAndLiquify = false;
            }
        }

        if (_amount > 0) {
            super._transfer(_from, _to, _amount);
        }
    }

    /**
     * @dev Adds or removes an address from the ecosystem list.
     * @param _address The address to be added or removed.
     * @param _isAdded True if the address should be added, false otherwise.
     */
    function _addRemoveFromEcoSystem(address _address, bool _isAdded) internal {
        if(_address == address(0)) revert InvalidContractInteraction();
        _ecosytemContracts[_address] = _isAdded;
        emit EcosytemAddressListUpdated(_address, _isAdded);
    }

    /**
     * @dev Adds or removes an address from the tax exclusion list.
     * @param _address The address to be added or removed.
     * @param _isExcluded True if the address should be excluded, false otherwise.
     */
    function _addRemoveFromExclusion(address _address, bool _isExcluded) internal {
        if(_address == address(0)) revert InvalidContractInteraction();
        excludeFromTax[_address] = _isExcluded;
        emit AddressTaxExclusionChanged(_address, _isExcluded);
    }

    /**
     * @dev Adds or removes an address from the dividends exclusion list.
     * @param _address The address to be added or removed.
     * @param _isExcluded True if the address should be excluded, false otherwise.
     */
    function _addRemoveFromDividends(address _address, bool _isExcluded) internal {
        if(_address == address(0)) revert InvalidContractInteraction();
        dividend.excludeFromDividends(_address, _isExcluded);
        emit AddressDividendExclusionChanged(_address, _isExcluded);
    }

    /**
     * @dev Checks if the given addresses are excluded from tax.
     * @param _from The address to check.
     * @param _to The address to check.
     * @return bool True if either address is excluded, false otherwise.
     */
    function _isExcludedFromTax(address _from, address _to) internal view returns(bool){
        return (excludeFromTax[_from] || excludeFromTax[_to]);
    }

    /**
     * @dev Sets the amount of tokens to trigger swap and liquify.
     * @param _amount The new amount.
     */
    function setSwapTokensAtAmount(uint256 _amount) external onlyOwner() {
        swapTokensAtAmount = _amount;
        emit SwapTokensAtAmountHasChanged(_amount);
    }

    /* administration --------------------------------------------------------------------------- */
 
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
        if(_amount == ZERO) revert TokenAmountIsZero();
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
    function unpause() external onlyOwner(){
        _unpause();
    }
}