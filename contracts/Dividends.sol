// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// imports
import { LasmOwnable } from "./imports/LasmOwnable.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Pausable } from "@openzeppelin/contracts/security/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { Address } from "./libs/Address.sol";
import { Math } from "./libs/Math.sol";

/**
 * @title Dividends
 * @dev Dividends is a contract designed to distribute dividends to token holders based on their holdings. 
 * The contract allows users to subscribe and unsubscribe from dividends, manage epochs for distribution, 
 * and claim their rewards. The contract integrates with ERC20 tokens for dividend payments and includes 
 * features such as pausing, reentrancy protection, and validations for addresses and contracts.
 * It ensures efficient and fair distribution of dividends and maintains a record of user snapshots and 
 * epoch details.
 */

contract Dividends is LasmOwnable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;
    using Address for address;
    using Math for uint256;

    uint256 public constant ZERO = 0;
    uint256 public constant E18 = 1e18;
    uint256 public constant HOUR = 1 hours;
    uint256 public constant HUNDRED = 100;
    uint256 public constant THOUSAND = 1000;
    uint256 public constant MAX_EPOCHS_CLAIMABLE = 10;

    EnumerableSet.AddressSet private _holders;
    uint256 public minimumBalanceForDividends = HUNDRED * E18;
    uint256 public claimWaitTime = HOUR;
    uint256 public totalDividendsDistributed;

    IERC20 private _baseAsset;
    address private _operator;

    struct Snapshot {
        uint256 subscribedAt;
        uint256 epoch;
    }

    struct Epochs {
        bool mutex;
        uint256 epochStartTime;
        uint256 epochEndTime;
        uint256 epochDividends;
        uint256 epochPortions;
        uint256 epochDividendsClaimed;
    }

    uint256 public lastBalance;
    uint256 public currentEpoch;
    uint256 public minimumBalanceRequiredForPos = 1 ether;

    mapping(uint256 => uint256) public epochStartTimestamps;
    mapping(uint256 => Epochs) public epochInfo;

    mapping(address => Snapshot) public userSnapshots;

    mapping(address => bool) public isExcludedFromDividends;
    mapping(address => uint256) public lastClaimTime;
    mapping(address => uint256) public withdrawnDividends;    

    // Events
    event EpochCreated(uint256 indexed epochId, uint256 epochPortion);
    event SubscribedToTheDividends(address indexed account);
    event UnsubscribedFromTheDividends(address indexed account);
    event ClaimWaitTimeUpdated(uint256 indexed _newClaimWaitTime);
    event DividendsClaimed(address indexed _account, uint256 indexed _amount);
    event ExcludedFromDividends(address indexed _account);
    event LiquifyContractRegistered(address indexed _liquifyContract);
    event MinimumBalanceUpdated(uint256 indexed _newMinimumBalance);
    event MinimumRequiredForPosBalanceUpdated(uint256 indexed _newMinimumBalance);
    event Withdrawal(address indexed _owner, address indexed _destination, uint256 indexed _amount);    

    // Errors
    error NotPermittedSubscription();
    error AlreadySubscribedToDividends();
    error EpochNotFound();
    error UserNotFound();
    error CanNotClaimDueExcludedFromDividends();
    error DoesNotAcceptingEthers();
    error InCompleteSetup();
    error InvalidAddressInteraction();
    error InvalidContractInteraction();
    error NoDividendsToClaim();
    error NoHoldersToDistribute();
    error NotEligibleForRewards();
    error NotYetEligibleForRewards();
    error UpdatingTheSameAddress();
    error TokenAmountIsZero();
    error OnlyOperator();
    error NotPermitted();
    error FailedToSend();

    modifier onlyOperator(){
        if(_msgSender() != _operator){
            revert OnlyOperator();
        }
        _;
    }

    modifier validContract(address _address) {
        if(!Address.isContract(_address)) revert InvalidContractInteraction();
        _;
    }

    modifier validAddress(address _address) {
        if(_address.isZeroAddress()) revert InvalidAddressInteraction();
        _;
    }

    /* setup -------------------------------------------------------------------------------------- */

    /**
     * @dev Initializes the contract with the base asset token address.
     * @param _token The address of the base asset token.
     */
    constructor(address _token)  {
        if(!_token.isContract()) revert InvalidContractInteraction();
        _operator = _token;
        _baseAsset = IERC20(_token);
    }

    receive() external payable {
        revert DoesNotAcceptingEthers();
    }

    fallback() external payable {
        revert NotPermitted();
    }

    /* mechanics -----------------------------------------------------------------------------------*/
   
    /**
     * @notice Subscribes the caller to receive dividends.
     * @dev Checks if the caller is already subscribed or excluded from dividends.
     * Emits the SubscribedToTheDividends event.
     */
    function subscribeToDividends() external {
        if(currentEpoch == 0) _newEpoch();
        address account = _msgSender();
        if(_holders.contains(account)) revert AlreadySubscribedToDividends();
        if(isExcludedFromDividends[account]) revert NotPermittedSubscription();
    
        _holders.add(account);
    
        Snapshot storage _snapshotCurrent = userSnapshots[account];
        _snapshotCurrent.epoch = currentEpoch;
        _snapshotCurrent.subscribedAt = block.timestamp;

        emit SubscribedToTheDividends(account);
    }
    
    /**
     * @notice Unsubscribes the caller from receiving dividends.
     * @dev Removes the caller from the _holders set and deletes their snapshot.
     * Emits the UnsubscribedFromTheDividends event.
     */
    function unsubscribeFromDividends() external {
        address account = _msgSender();
        if(!_holders.contains(account)) revert UserNotFound();

        _holders.remove(account);
        delete userSnapshots[account];

        emit UnsubscribedFromTheDividends(account);
    }

    /**
     * @notice Creates a new epoch for dividend distribution.
     * @dev This function calculates the new epoch portion based on the effective balance.
     * It updates the epoch information and emits the EpochCreated event.
     */
    function createNewEpoch() external onlyOwner() {
        _newEpoch();
    }

    /**
     * @dev Internal function to create a new epoch for dividend distribution.
     */
    function _newEpoch() internal {
        uint256 effectiveBalance = _baseAsset.balanceOf(address(this)) + totalDividendsDistributed;
        uint256 newEpochPortion = effectiveBalance > lastBalance ? effectiveBalance - lastBalance : 0;
    
        currentEpoch += 1;

        emit EpochCreated(currentEpoch, newEpochPortion);

        Epochs storage _epoch = epochInfo[currentEpoch];
        
        /* solhint-disable */
        if(currentEpoch > 1) {
            Epochs storage _previousEpoch = epochInfo[currentEpoch - 1];
            uint256 currentTime = block.timestamp;
            _previousEpoch.epochEndTime = currentTime;
            _previousEpoch.epochPortions = _previousEpoch.epochDividends / (currentTime - _previousEpoch.epochStartTime);
            _previousEpoch.mutex = true;
        }
        /* solhint-enable */

        _epoch.epochStartTime = block.timestamp;
        _epoch.epochDividends = newEpochPortion;
        _epoch.epochEndTime = 0;
        _epoch.epochPortions = 0;
        _epoch.epochDividendsClaimed = 0;
        _epoch.mutex = false;

        lastBalance = effectiveBalance;
    }

    /**
     * @notice Retrieves the details of a specific epoch.
     * @param _epochIndex The index of the epoch to retrieve.
     * @return The epoch details as an Epochs struct.
     */
    function getEpoch(uint256 _epochIndex) external view returns(Epochs memory) {
        if(currentEpoch < _epochIndex) revert EpochNotFound();
        Epochs memory _epoch = epochInfo[_epochIndex]; 
        return _epoch;
    }

    /**
     * @notice Retrieves the most recent finalized epoch.
     * @return The most recent finalized epoch as an Epochs struct.
     */
    function getRecentFinalizedEpoch() external view returns(Epochs memory) {
        uint256 _epochIndex = currentEpoch > 1 ? currentEpoch - 1 : 0;
        Epochs memory _epoch = epochInfo[_epochIndex]; 
        return _epoch;
    }

    /**
     * @notice Retrieves the most recent epoch index.
     * @return The most recent finalized epoch index.
     */
    function getCurrentEpochIndex() external view returns(uint256) {
        uint256 _epochIndex = currentEpoch > 1 ? currentEpoch - 1 : 0;
        return _epochIndex;
    }

    /**
     * @notice Retrieves the snapshot of a specific user.
     * @param _account The address of the user.
     * @return The user's snapshot as a Snapshot struct.
     */
    function getUserSnapshot(address _account) external view returns(Snapshot memory){
        if(!_holders.contains(_account)) revert UserNotFound();
        Snapshot memory _userSnap = userSnapshots[_account];
        return _userSnap;
    }

    /**
     * @notice Calculates the claimable rewards for a specific user.
     * @param claimant The address of the claimant.
     * @return totalDividends The total claimable rewards.
     */
    function getClaimableRewards(address claimant) public view returns (uint256 totalDividends) {
        if (!_isEligibleForRewards(claimant)) revert NotEligibleForRewards();
    
        Snapshot memory userSnapshot = userSnapshots[claimant];
        totalDividends = 0;
    
        uint256 epochsProcessed = 0;
        uint256 epochIndex = userSnapshot.epoch;

        if(epochIndex == currentEpoch || epochIndex == 0) return 0;

        while(epochIndex <= currentEpoch && epochsProcessed < MAX_EPOCHS_CLAIMABLE) {
            Epochs memory epoch = epochInfo[epochIndex];

            if (
                !epoch.mutex 
                || epoch.epochDividends == 0 
                || epoch.epochPortions == 0
                || userSnapshot.subscribedAt > epoch.epochEndTime
            ) {
                epochIndex++;
                continue;
            }
 
           uint256 timeElapsed = epoch.epochEndTime - userSnapshot.subscribedAt;
           totalDividends += epoch.epochPortions * timeElapsed;
    
            epochIndex++;
            epochsProcessed++;
        }

        uint256 _safeContractBalance = _baseAsset.balanceOf(address(this));
    
        return totalDividends.min(_safeContractBalance);
    }
    
    /**
     * @notice Claims the dividends for the caller.
     * @dev Ensures the caller is eligible for rewards, updates their claim time and withdrawn dividends.
     * Emits the DividendsClaimed event.
     */
    function claimRewards() external nonReentrant() whenNotPaused() {
        address claimant = _msgSender();

        if(lastClaimTime[claimant] + claimWaitTime >= block.timestamp 
            || userSnapshots[claimant].epoch == currentEpoch 
            || userSnapshots[claimant].epoch == 0 // short circuit for scalability, instead _holders tracking
        )  revert NotYetEligibleForRewards();
        
        uint256 totalDividends = getClaimableRewards(claimant);
        if(totalDividends == 0) revert NoDividendsToClaim();
        
        lastClaimTime[claimant] = block.timestamp;
        totalDividendsDistributed += totalDividends;
        userSnapshots[claimant].epoch = currentEpoch;
        
        _baseAsset.safeTransfer(claimant, totalDividends);
        emit DividendsClaimed(claimant, totalDividends);
    }
    

    /**
     * @notice Excludes or includes an account in dividends.
     * @param account The address of the account to be excluded or included.
     * @param exclude True to exclude the account, false to include.
     */
    function excludeFromDividends(address account, bool exclude) 
    external 
    validAddress(account)
    onlyOperator() {
        isExcludedFromDividends[account] = exclude;
        if (exclude) {
            _holders.remove(account);
        } else {
            _holders.add(account);
        }
        emit ExcludedFromDividends(account);
    }

    /* setters ------------------------------------------------------------------------------------ */

    /**
     * @notice Sets a new base asset for the contract.
     * @param _newBaseAsset The address of the new base asset.
     */
    function setBaseAsset(address _newBaseAsset) external 
    validContract(_newBaseAsset)
    onlyOwner(){
        _setBaseAsset(_newBaseAsset);
    }

    /**
     * @notice Sets the claim wait time for dividends.
     * @param newClaimWaitTime The new claim wait time in seconds.
     */
    function setClaimWaitTime(uint256 newClaimWaitTime) external onlyOwner() {
        claimWaitTime = newClaimWaitTime;
        emit ClaimWaitTimeUpdated(claimWaitTime);
    }

    /**
     * @notice Sets the minimum balance required to receive dividends.
     * @param newMinimumBalance The new minimum balance.
     */
    function setMinimumBalanceForDividends(uint256 newMinimumBalance) external onlyOwner() {
        minimumBalanceForDividends = newMinimumBalance;
        emit MinimumBalanceUpdated(newMinimumBalance);
    }

    /**
     * @notice Sets the minimum balance required for PoS.
     * @param newMinimumBalance The new minimum balance for PoS.
     */
    function setMinimumRequiredTokensForPos(uint256 newMinimumBalance) external onlyOwner() {
        minimumBalanceRequiredForPos = newMinimumBalance;
        emit MinimumRequiredForPosBalanceUpdated(minimumBalanceRequiredForPos);
    }

    /* getters ------------------------------------------------------------------------------------ */

    /**
     * @notice Returns the address of the operator.
     * @return The operator's address.
     */
    function getOperator() external view returns(address) {
        return _operator;
    }

    /**
     * @notice Returns the address of the base asset.
     * @return The base asset's address.
     */
    function getBaseAsset() external view returns(address){
        return address(_baseAsset);
    }

    /**
     * @notice Returns the claim wait time for dividends.
     * @return The claim wait time in seconds.
     */
    function getClaimWait() external view returns (uint256) {
        return claimWaitTime;
    }

    /**
     * @notice Returns the current epoch.
     * @return The current epoch number.
     */
    function getCurrentEpoch() external view returns (uint256) {
        return currentEpoch;
    }
    
    /**
     * @notice Returns the total dividends distributed.
     * @return The total dividends distributed.
     */
    function getTotalDividendsDistributed() external view returns(uint256){
        return totalDividendsDistributed;
    }

    /**
     * @notice Returns the minimum balance required for claiming dividends.
     * @return The minimum balance required.
     */
    function getMinimumBalanceForDividendsClaiming() external view returns(uint256){
        return minimumBalanceForDividends;
    }

    /**
     * @notice Returns the minimum balance required for PoS.
     * @return The minimum balance required for PoS.
     */
    function getMinRequiredTokensForPos() external view returns(uint256){
        return minimumBalanceRequiredForPos;
    }

    /**
     * @notice Returns the number of token holders.
     * @return The number of token holders.
     */
    function getNumberOfTokenHolders() external view returns (uint256) {
        return _holders.length();
    }

    /**
     * @notice Returns the last claim time of a specific account.
     * @param account The address of the account.
     * @return The last claim time.
     */
    function getLastProccessTime(address account) external view returns (uint256) {
        return lastClaimTime[account];
    }

    /**
     * @notice Checks if an account is eligible for rewards.
     * @param account The address of the account to check.
     * @return True if the account is eligible, false otherwise.
     */
    function isEligibleForRewards(address account) 
    external 
    view 
    validAddress(account)
    returns (bool) {
        return _isEligibleForRewards(account);
    }
    
    /**
     * @notice Dummy function to return a constant price.
     * @return A constant price of 1 ether.
     */
    function dummyGetPrice() public pure returns (uint256) {
        return E18;
    }

    /* internals----------------------------------------------------------------------------------- */

    /**
     * @dev Internal function to set a new base asset.
     * @param _newBaseAsset The address of the new base asset.
     */
    function _setBaseAsset(address _newBaseAsset) 
    internal {
        if(_newBaseAsset == address(_baseAsset)) revert UpdatingTheSameAddress();
        _baseAsset = IERC20(_newBaseAsset);
    }

    /**
     * @dev Internal function to check if an account is eligible for rewards.
     * @param account The address of the account to check.
     * @return True if the account is eligible, false otherwise.
     */
    function _isEligibleForRewards(address account) internal view returns(bool){
        if(isExcludedFromDividends[account]){
            revert CanNotClaimDueExcludedFromDividends();
        }
        uint256 balance = _baseAsset.balanceOf(account);
        
        return balance >= minimumBalanceRequiredForPos; 
    }

    /* oracle --------------------------------------------------------------------------------------- */

  
    /* administrator -------------------------------------------------------------------------------- */

    /**
     * @notice Rescues tokens mistakenly sent to the contract.
     * @param _tokenAddress The address of the token contract.
     * @param _to The address to send the rescued tokens to.
     * @param _amount The amount of tokens to rescue.
     */
    function rescueTokens(address _tokenAddress, address _to, uint256 _amount) 
    external 
    validContract(_tokenAddress)
    validAddress(_to) 
    onlyOwner() 
    {
        if(_amount == 0) revert TokenAmountIsZero();
        SafeERC20.safeTransfer(IERC20(_tokenAddress), _to, _amount);
        emit Withdrawal(_tokenAddress, _to, _amount);
    }
       
    /**
     * @notice Withdraws native tokens from the contract.
     */
     function withdraw() external onlyOwner() {
        uint256 balance = address(this).balance;
        (bool success, ) = payable(owner()).call{value: balance}("");
        if(!success) revert FailedToSend();
    }

    /**
     * @notice Pauses the contract.
     */
    function pause() external onlyOwner() {
        _pause();
    }

    /**
     * @notice Unpauses the contract.
     */
    function unpause() external onlyOwner(){
        _unpause();
    }
}