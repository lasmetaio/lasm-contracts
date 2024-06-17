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
import { VestingClaimingContract } from "./VestingClaim.sol";
import { ILasm } from "./interfaces/ILasm.sol";
import { IVestingClaimingContract } from "./interfaces/IVestingClaimingContract.sol";

/**
 * @title Vesting
 * @notice Manages token vesting schedules, supporting different vesting types like linear, twisted, and ICO.
 * @dev The contract allows creating, starting, and canceling vesting schedules, and claims tokens based on the 
 * vesting schedule lifecycle. It integrates with ERC-20 tokens and validates contract interactions. The contract 
 * ensures secure token transfers, supports multiple vesting schedules, and allows pausing/unpausing by the owner. 
 * It includes functionalities to register/unregister trusted vesting claim contracts and rescue tokens if needed.
 */

contract Vesting is LasmOwnable, ReentrancyGuard, Pausable {
    using Address for address;
    using Math for uint256;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    enum VestingScheduleType {
        LINEAR,
        TWISTED,
        ICO
    }

    struct ScheduleLifeCycle {
        bool started;
        bool cancelled;
        uint256 startTime;
        uint256 endTime;
        uint256 cliff;
        uint256 lastClaimed;
    }

    struct ScheduleBalance {
        uint256 tgePortion;
        uint256 monthlyPortions;
        uint256[5] yearsOfAllocations;
    }

    struct ScheduleBase {
        address vestingWallet;
        uint256 allocation;
        bool isTgeClaimed;
        uint256 tge;
        uint256 installments;
        uint256 claimedTokens;
    }

    struct Schedule {
        ScheduleBase base;
        ScheduleBalance balance;
        ScheduleLifeCycle lifeCycle;
        VestingScheduleType vestingType;
    }

    struct VestingInfo {
        address vestingWallet;
        string templateName;
    }

    IERC20 private _baseAsset;
    address private _operator;
    IVestingClaimingContract public vestingClaimVaultContract;

    EnumerableSet.Bytes32Set private _templateNames;
    uint256 public constant ZERO = 0;
    uint256 public constant ONE = 1;
    uint256 public constant TWO = 2;
    uint256 public constant FIVE = 5;
    uint256 public constant HUNDRED = 100;

    uint256 public constant MONTH = 30 * 24 * 60 * 60;
    uint256 public constant YEAR = 366 * 24 * 60 * 60;
    uint256 public constant MONTHS_IN_YEAR = 12;

    mapping(string => Schedule) public schedules;
    mapping(address => uint256) private _walletsOngoingVestingSchedules;
    VestingInfo[] public vestingInfos;

    // Events
    event VestingClaimVaultContractInited(address indexed vestingClaimVaultContract);
    event VestingClaimVaultContractChanged(address indexed vestingClaimVaultContract);
    event VestingClaimVaultContractRegistered(address indexed vestingClaimVaultContract);
    event VestingClaimVaultContractUnRegistered(address indexed vestingClaimVaultContract);
    event ScheduleTemplateCreated(string templateName, address indexed wallet, uint256 indexed allocation);
    event ScheduleTemplateUpdated(string templateName, address indexed wallet, uint256 indexed allocation);
    event ScheduleTemplateCancelled(string templateName, address indexed wallet, uint256 indexed allocation);
    event TrustedWalletAdded(address indexed vestingWallet);
    event TrustedWalletRemoved(address indexed vestingWallet);
    event ScheduleForICOHasStarted(string templateName, address indexed managerAddress);
    event ScheduleHasStarted(string templateName);
    event TokensLocked(string templateName, uint256 indexed amount, uint256 indexed releaseTime);
    event TokensTransferredToICOManager(address indexed wallet, uint256 indexed amount);
    event TokensClaimed(string templateName, address indexed wallet, uint256 indexed amount);
    event Withdrawal(address indexed owner, address indexed destination, uint256 indexed amount);

    // Errors
    error TemplateNameDoesNotExist();
    error InvalidAddressInteraction();
    error InvalidContractInteraction();
    error TemplateNameNotUnique();
    error ScheduleAlreadyCancelled();
    error ScheduleAlreadyStarted();
    error ScheduleNotStartedOrCompletedAlready();
    error InsufficientContractBalance();
    error TokenTransferFailed();
    error TokenResetApprovalFailed();
    error TokenApprovalFailed();
    error DurationOfYearsNotCompatible();
    error TokensAreStillLocked();
    error UnauthorizedClaiming();
    error ThisIsNotICOSchedule();
    error NoVestedTokens();
    error UnkownScheduleType();
    error SameContractAddress();
    error TrustedWalletIsOutOfBounds();
    error DoesNotAcceptingEthers();
    error InvalidVestingType();
    error ZeroAllocationNotAllowed();
    error TGEPercentageOutOfRange();
    error InstallmentsRequiredForCliff();
    error InvalidInstallmentCount();
    error SumOfTotalPercentageFailed();
    error TokenAmountIsZero();
    error NoICOSchedulesFound();
    error NotInTrustedEcoSystem();
    error NotPermitted();

    // Modifiers
    modifier validContract(address _address) {
        if(!_address.isContract()) {
            revert InvalidContractInteraction();
        }
        _;
    }

    modifier validAddress(address _address) {
        if(_address == address(0)){
            revert InvalidAddressInteraction();
        }
        _;
    }

    modifier trustedEcoSystem(address _vestingWallet) {
        bool isTrusted = _isTrustedWallet(_vestingWallet);
        if(!isTrusted) {
            revert NotInTrustedEcoSystem();
        }
        _;
    }

    modifier templateExist(string memory templateName) {    
        bytes32 encodedTemplateName = keccak256(abi.encodePacked(templateName));
        if (!_templateNames.contains(encodedTemplateName)) {
            revert TemplateNameDoesNotExist();
        }
        _;
    }

    modifier onlyUniqueTemplateNames(string memory templateName) {    
        bytes32 encodedTemplateName = keccak256(abi.encodePacked(templateName));
        if (_templateNames.contains(encodedTemplateName)) revert TemplateNameNotUnique();
        _;
    }

    modifier onlyVestingClaimContract() {
        if(address(vestingClaimVaultContract) == address(0)) revert InvalidAddressInteraction();
        if(address(vestingClaimVaultContract)  != _msgSender()) revert InvalidAddressInteraction();
        _;
    }

    /* setup -------------------------------------------------------------------------------------- */

    /**
     * @dev Initializes the contract with the given token address.
     * @param _token The address of the ERC20 token.
     */
    constructor(address _token) {
        if(!_token.isContract()) revert InvalidContractInteraction();
        _transferOwnership(_msgSender());
        _baseAsset = IERC20(_token);
        _operator = _token;
        _initVestingClaimVaultContract();
    }
    
    receive() external payable {
        revert DoesNotAcceptingEthers();
    }

    fallback() external payable {
        revert NotPermitted();
    }

    /* Linear mechanics -------------------------------------------------------------------------------*/

    /**
     * @notice Creates a vesting schedule.
     * @param templateName The name of the template.
     * @param vestingType The type of vesting schedule.
     * @param vestingWallet The address of the vesting wallet.
     * @param allocation The allocation amount.
     * @param cliff The cliff period.
     * @param tge The TGE percentage.
     * @param installments The number of installments.
     * @param yearsOfAllocations The yearly allocations.
     */
    function createSchedule(
        string calldata templateName,
        uint256 vestingType,
        address vestingWallet,
        uint256 allocation,
        uint256 cliff,
        uint256 tge,
        uint256 installments,
        uint256[5] calldata yearsOfAllocations
    ) external 
    validAddress(vestingWallet) 
    onlyOwner() 
    onlyUniqueTemplateNames(templateName) 
    {
        Schedule memory _schedule = _scheduleBase(
            vestingType, 
            vestingWallet, 
            allocation, 
            cliff, 
            tge, 
            installments, 
            yearsOfAllocations
        );
        _createSchedule(templateName, _schedule);
    }

    /**
     * @dev Initializes the base structure of a schedule.
     * @param vestingType The type of vesting schedule.
     * @param vestingWallet The address of the vesting wallet.
     * @param allocation The allocation amount.
     * @param cliff The cliff period.
     * @param tge The TGE percentage.
     * @param installments The number of installments.
     * @param yearsOfAllocations The yearly allocations.
     * @return The initialized schedule.
     */
    function _scheduleBase(
        uint256 vestingType,
        address vestingWallet,
        uint256 allocation,
        uint256 cliff, 
        uint256 tge,
        uint256 installments,
        uint256[5] memory yearsOfAllocations
    ) internal returns(Schedule memory) {
        VestingScheduleType _vestingType;

        _sanitizeInputs(vestingType, allocation, tge, cliff, installments);

        if(vestingType == ONE) _vestingType = VestingScheduleType.LINEAR;
        else if(vestingType == TWO) _vestingType = VestingScheduleType.TWISTED;
        else _vestingType = VestingScheduleType.ICO;

        if(!_isTrustedWallet(vestingWallet)) revert NotInTrustedEcoSystem();
        _computeOngoingVestingWallets(vestingWallet, true);

        uint256 _remainingAllocation = allocation - allocation * tge / HUNDRED;     
        uint256 _endTime;
        uint256 _monthlyPortions;

        if(_vestingType == VestingScheduleType.ICO) {
            installments    = ONE;
            tge             = HUNDRED;
            cliff           = ZERO;
        }

        if(_vestingType != VestingScheduleType.TWISTED) {
            _endTime = installments * MONTH;
            _monthlyPortions = _remainingAllocation / installments;
            _vestingType = vestingType == ONE ? VestingScheduleType.LINEAR : VestingScheduleType.ICO;
        } else {
            _endTime = FIVE * YEAR;
            _monthlyPortions = ZERO;
            yearsOfAllocations = _sanitizeAndComputeTwistedAllocations(yearsOfAllocations, _remainingAllocation);
            _vestingType = VestingScheduleType.TWISTED;
        }

        ScheduleLifeCycle memory _lifeCycle = _initLifeCycle(_endTime, cliff);

        ScheduleBalance memory _balance = ScheduleBalance({
            tgePortion: allocation * tge / HUNDRED,
            monthlyPortions:_monthlyPortions,
            yearsOfAllocations: yearsOfAllocations
        });

        ScheduleBase memory _base = _initScheduleBase(vestingWallet, allocation, tge, installments);

        Schedule memory _schedule = Schedule({
            vestingType: _vestingType,
            lifeCycle: _lifeCycle,
            balance: _balance,
            base: _base
        });

        return _schedule;
    }

    /**
     * @dev Sanitizes the input parameters.
     * @param vestingType The type of vesting schedule.
     * @param allocation The allocation amount.
     * @param tge The TGE percentage.
     * @param cliff The cliff period.
     * @param installments The number of installments.
     */
    function _sanitizeInputs(
        uint256 vestingType,
        uint256 allocation,
        uint256 tge,
        uint256 cliff,
        uint256 installments
    ) internal pure {
        if (vestingType < ONE || vestingType > ONE + TWO) revert InvalidVestingType();
        if (allocation == ZERO) revert ZeroAllocationNotAllowed();
        if (tge < ZERO || tge > HUNDRED) revert TGEPercentageOutOfRange();
        if (cliff > ZERO && installments == ZERO) revert InstallmentsRequiredForCliff();
        if (installments < ZERO || installments > FIVE * MONTHS_IN_YEAR) revert InvalidInstallmentCount();
    }
    
    /**
     * @dev Initializes the lifecycle of a schedule.
     * @param _endTime The end time of the schedule.
     * @param _cliff The cliff period.
     * @return The initialized lifecycle.
     */
    function _initLifeCycle(uint256 _endTime, uint256 _cliff) internal pure returns(ScheduleLifeCycle memory) {
        ScheduleLifeCycle memory _lifeCycle = ScheduleLifeCycle({
            started: false,
            cancelled: false,
            startTime: ZERO,
            endTime: _endTime,
            cliff: _cliff,
            lastClaimed: ZERO
        });

        return _lifeCycle;
    }

    /**
     * @dev Initializes the base structure of a schedule.
     * @param vestingWallet The address of the vesting wallet.
     * @param allocation The allocation amount.
     * @param tge The TGE percentage.
     * @param installments The number of installments.
     * @return The initialized base structure.
     */
    function _initScheduleBase(        
        address vestingWallet,
        uint256 allocation,
        uint256 tge,
        uint256 installments) internal pure returns(ScheduleBase memory) {
        ScheduleBase memory _base = ScheduleBase({
            vestingWallet: vestingWallet,
            allocation: allocation,
            tge: tge,
            installments: installments,
            claimedTokens: ZERO,
            isTgeClaimed: false
        });

        return _base;
    }

    /**
     * @notice Starts a vesting schedule.
     * @param _templateName The name of the template.
     */
    function startSchedule(string calldata _templateName) 
        external onlyOwner() 
        templateExist(_templateName)
    {
        Schedule storage _schedule = schedules[_templateName];
        _checkScheduleLifecycle(_schedule.lifeCycle);
        _schedule.lifeCycle.started = true;
        _schedule.lifeCycle.startTime = block.timestamp;
        _schedule.lifeCycle.endTime += block.timestamp;
        _schedule.lifeCycle.cliff += block.timestamp;
        _schedule.lifeCycle.lastClaimed = block.timestamp;

        ILasm(address(_baseAsset)).addRemoveFromTax(_schedule.base.vestingWallet, true);

        VestingInfo memory newVestingInfo = VestingInfo({
            vestingWallet: _schedule.base.vestingWallet,
            templateName: _templateName
        });

        vestingInfos.push(newVestingInfo);

        emit ScheduleHasStarted(_templateName);
    }

    /**
     * @notice Cancels a vesting schedule.
     * @param _templateName The name of the template.
     */
    function cancelSchedule(string calldata _templateName) 
        external onlyOwner() 
        templateExist(_templateName)
    {
        _cancelSchedule(_templateName);
        emit ScheduleHasStarted(_templateName);
    }

    /* ICO mechanics --------------------------------------------------------------------------------*/
    
    /**
     * @notice Registers or unregisters a vesting claim vault contract.
     * @param _vestingClaimContract The address of the vesting claim contract.
     * @param _isRegistering True if registering, false if unregistering.
     */
    function registerVestingClaimVaultContract(address _vestingClaimContract, bool _isRegistering) 
    public
    validContract(_vestingClaimContract) 
    onlyOwner() 
    {
        ILasm(address(_baseAsset)).addRemoveFromTax(_vestingClaimContract, _isRegistering);
        if (_isRegistering) emit VestingClaimVaultContractRegistered(_vestingClaimContract);
        else emit VestingClaimVaultContractUnRegistered(_vestingClaimContract);
    }

    /* internals -----------------------------------------------------------------------------------*/

    /**
     * @dev Computes the ongoing vesting wallets.
     * @param _vestingWallet The address of the vesting wallet.
     * @param _added True if added, false if removed.
     */
    function _computeOngoingVestingWallets(address _vestingWallet, bool _added) internal {
        if(_added) {
            _walletsOngoingVestingSchedules[_vestingWallet] += ONE;
        } else {
            uint256 delta = _walletsOngoingVestingSchedules[_vestingWallet] > ZERO ? ONE : ZERO;
            _walletsOngoingVestingSchedules[_vestingWallet] -= delta;
        }
    }

    /**
     * @dev Initializes the vesting claim vault contract.
     */
    function _initVestingClaimVaultContract() internal {
        VestingClaimingContract _vestingClaimVaultContractInit = new VestingClaimingContract(address(this));
        vestingClaimVaultContract = IVestingClaimingContract(address(_vestingClaimVaultContractInit));
        vestingClaimVaultContract.setWorking(true);
        emit VestingClaimVaultContractInited(address(vestingClaimVaultContract));
    }
    
    /**
     * @dev Creates a vesting schedule.
     * @param _vestingTemplate The name of the template.
     * @param _schedule The schedule to create.
     */
    function _createSchedule(string memory _vestingTemplate, Schedule memory _schedule) internal {
        schedules[_vestingTemplate] = _schedule;
        _emitScheduleCreate(_vestingTemplate, _schedule.base.vestingWallet, _schedule.base.allocation);
    }

    /**
     * @dev Cancels a vesting schedule.
     * @param _vestingTemplate The name of the template.
     */
     function _cancelSchedule(string memory _vestingTemplate) internal { 
        Schedule storage _schedule = schedules[_vestingTemplate];
    
        // For ICO schedules, decrement the ongoing vesting schedules count
        if(_schedule.vestingType == VestingScheduleType.ICO) {
            uint256 delta = _walletsOngoingVestingSchedules[_schedule.base.vestingWallet] > ZERO ? ONE : ZERO;
            _walletsOngoingVestingSchedules[_schedule.base.vestingWallet] -= delta;
        }
    
        // Ensure the schedule has not already started or been cancelled
        _checkScheduleLifecycle(_schedule.lifeCycle);
    
        // Mark the schedule as cancelled
        _schedule.lifeCycle.cancelled = true;
    
        // Update exclusion list and ongoing vesting schedules
        ILasm(address(_baseAsset)).addRemoveFromTax(_schedule.base.vestingWallet, true);
        _computeOngoingVestingWallets(_schedule.base.vestingWallet, false);
    
        // Emit the cancellation event
        _emitScheduleCancel(_vestingTemplate, _schedule.base.vestingWallet, _schedule.base.allocation);
    }

    /**
     * @dev Checks the lifecycle of a schedule.
     * @param _lifeCycle The lifecycle to check.
     */
    function _checkScheduleLifecycle(ScheduleLifeCycle memory _lifeCycle) internal pure {
        if(_lifeCycle.cancelled) revert ScheduleAlreadyCancelled();
        else if (_lifeCycle.started) revert ScheduleAlreadyStarted();
    }

    /**
     * @dev Emits the schedule creation event.
     * @param _vestingTemplate The name of the template.
     * @param _vestingWallet The address of the vesting wallet.
     * @param _allocation The allocation amount.
     */
    function _emitScheduleCreate(string memory _vestingTemplate, address _vestingWallet, uint256 _allocation) internal {
        _templateNames.add(keccak256(abi.encodePacked(_vestingTemplate)));
        _walletsOngoingVestingSchedules[_vestingWallet] += 1;
        emit ScheduleTemplateCreated(_vestingTemplate, _vestingWallet, _allocation);
    } 

    /**
     * @dev Emits the schedule cancellation event.
     * @param _vestingTemplate The name of the template.
     * @param _vestingWallet The address of the vesting wallet.
     * @param _allocation The allocation amount.
     */
    function _emitScheduleCancel(string memory _vestingTemplate, address _vestingWallet, uint256 _allocation) internal {
        uint256 _ongoingDeltaConfirm = _walletsOngoingVestingSchedules[_vestingWallet] == ZERO ? ZERO : ONE;
        _walletsOngoingVestingSchedules[_vestingWallet] -= _ongoingDeltaConfirm;
        _templateNames.remove(keccak256(abi.encodePacked(_vestingTemplate)));
        emit ScheduleTemplateCancelled(_vestingTemplate, _vestingWallet, _allocation);
    }

    /**
     * @dev Checks if a wallet is trusted.
     * @param _vestingWallet The address of the vesting wallet.
     * @return True if trusted, false otherwise.
     */
    function _isTrustedWallet(address _vestingWallet) internal view returns(bool){
       return ILasm(address(_baseAsset)).isEcoSystemContract(_vestingWallet);
    }

    /**
     * @dev Calculates the claimable amount.
     * @param _templateName The name of the template.
     * @return The claimable amount and whether TGE is added.
     */
    function _calculateClaimableAmount(string memory _templateName) internal view returns(uint256, bool) {
        Schedule storage schedule = schedules[_templateName];
        
        if (!schedule.lifeCycle.started || schedule.lifeCycle.cancelled) {
            revert ScheduleNotStartedOrCompletedAlready();
        }
        
        uint256 totalClaimable = ZERO;
        bool isTgeAdded = false;
        uint256 delta;

        if (!schedule.base.isTgeClaimed && block.timestamp >= schedule.lifeCycle.cliff) {
            totalClaimable += schedule.balance.tgePortion;
            isTgeAdded = true;
        } else if(schedule.lifeCycle.cliff > block.timestamp) {
            revert TokensAreStillLocked();
        }
        
        if(block.timestamp >= schedule.lifeCycle.endTime) {
            delta = schedule.base.claimedTokens >= schedule.base.allocation ?
                ZERO : schedule.base.allocation - schedule.base.claimedTokens;
            return (delta, isTgeAdded);
        }

        uint256 monthsPassedSinceCliff = (block.timestamp - schedule.lifeCycle.cliff) / MONTH;
        uint256 monthsPassedSinceLastClaim = (
            block.timestamp - schedule.lifeCycle.cliff.max(schedule.lifeCycle.lastClaimed)) / MONTH;

        if (monthsPassedSinceLastClaim > ZERO) {
            if(schedule.vestingType != VestingScheduleType.TWISTED) {
                totalClaimable += monthsPassedSinceLastClaim * schedule.balance.monthlyPortions;
            } else {
                uint256 currentYearIndex = ZERO;
                if (monthsPassedSinceCliff >= MONTHS_IN_YEAR) {
                    currentYearIndex = (monthsPassedSinceCliff / MONTHS_IN_YEAR) - ONE;
                }

                uint256 diff = monthsPassedSinceCliff.min(monthsPassedSinceLastClaim);
                for(uint256 i = ZERO; i < diff; i++) {
                    if(i % MONTHS_IN_YEAR == ZERO && i!=ZERO) {
                        if (currentYearIndex > ZERO) {
                            currentYearIndex -= ONE;
                        }
                    }
                    uint256 thisYearsAllocationIs = schedule.balance.yearsOfAllocations[currentYearIndex];
                    totalClaimable += thisYearsAllocationIs / MONTHS_IN_YEAR;
                }
            }        
        }

        return (totalClaimable.min(schedule.base.allocation), isTgeAdded);
    }

    /* settlers -----------------------------------------------------------------------------------*/

    /**
     * @notice Sets the vesting claim vault contract.
     * @param _newClaimingContractAddress The address of the new claiming contract.
     */
    function setVestingClaimVaultContract(address _newClaimingContractAddress) 
    external 
    validContract(_newClaimingContractAddress)
    onlyOwner() 
    {
        if(address(vestingClaimVaultContract) == _newClaimingContractAddress) revert SameContractAddress();
        vestingClaimVaultContract.setWorking(false);
        registerVestingClaimVaultContract(address(vestingClaimVaultContract), false);
        vestingClaimVaultContract = IVestingClaimingContract(_newClaimingContractAddress);
        registerVestingClaimVaultContract(address(_newClaimingContractAddress), true);
        emit VestingClaimVaultContractChanged(_newClaimingContractAddress);
    }
    
    /* getters -----------------------------------------------------------------------------------*/

    /**
     * @notice Returns the address of the operator.
     * @return The operator address.
     */
    function getOperator() external view returns(address) {
        return _operator;
    }

    /**
     * @notice Returns the address of the base asset.
     * @return The base asset address.
     */
    function getBaseAsset() external view returns(address) {
        return address(_baseAsset);
    }

    /**
     * @notice Returns the address of the vesting claim contract.
     * @return The vesting claim contract address.
     */
    function getVestingClaimContract() external view returns(address) {
        return address(vestingClaimVaultContract);
    }

    /**
     * @notice Returns the schedule details by template name.
     * @param _templateName The name of the template.
     * @return The schedule details.
     */
    function getScheduleByName(string calldata _templateName) 
    external 
    view 
    templateExist(_templateName) returns(Schedule memory) {
        Schedule memory _schedule = schedules[_templateName];
        return _schedule;
    }

    /**
     * @notice Returns the count of schedules related to a trusted wallet.
     * @param _vestingWallet The address of the vesting wallet.
     * @return The count of related schedules.
     */
    function getCountOfTrustedWalletRelatedSchedules(address _vestingWallet) 
    external 
    view 
    validAddress(_vestingWallet) 
    returns (uint256) {
        return _walletsOngoingVestingSchedules[_vestingWallet];
    }
    
    /**
     * @notice Checks if a wallet is trusted.
     * @param _vestingWallet The address of the vesting wallet.
     * @return True if trusted, false otherwise.
     */
    function isTrustedWallet(address _vestingWallet) external view validAddress(_vestingWallet) returns(bool) {
        return _isTrustedWallet(_vestingWallet);
    }
    
    /**
     * @notice Returns the pending claimable tokens.
     * @param _templateName The name of the template.
     * @return The pending claimable tokens.
     */
    function pendingClaimableTokens(string memory _templateName) 
    public 
    view 
    templateExist(_templateName) 
    returns (uint256) {
        uint256 _pendingTokens;
        (_pendingTokens, ) = _calculateClaimableAmount(_templateName);
        return _pendingTokens;
    }

    /**
     * @dev Counts the non-zero elements in an array.
     * @param _data The array of data.
     * @return The count of non-zero elements.
     */
    function _countNonZeroVars(uint256[5] memory _data) internal pure returns (uint256) {
        uint256 count = ZERO;
        uint256 length = _data.length;

        for (uint256 i = ZERO; i < length; i++) {
            if (_data[i] != ZERO) {
                count++;
            }
        }
        return count;
    }

    /**
     * @dev Sanitizes and computes the twisted allocations.
     * @param yearsOfAllocations The yearly allocations.
     * @param totalAllocation The total allocation amount.
     * @return computedAllocations
     */
    function _sanitizeAndComputeTwistedAllocations(uint256[5] memory yearsOfAllocations, uint256 totalAllocation) 
        internal pure returns (uint256[5] memory computedAllocations) {
        
        uint256 totalPercentage = ZERO;
        uint256 length = yearsOfAllocations.length;

        for (uint256 i = ZERO; i < length; i++) {
            totalPercentage += yearsOfAllocations[i];
        }

        if (totalPercentage != HUNDRED) revert SumOfTotalPercentageFailed(); 

        uint256 lenthY = yearsOfAllocations.length;

        for (uint256 i = ZERO; i < lenthY; i++) {
            computedAllocations[i] = (totalAllocation * yearsOfAllocations[i]) / HUNDRED;
        }

        return computedAllocations;
    }

    /**
     * @dev Claims tokens.
     * @param _templateName The name of the template.
     * @param _destination The address of the destination.
     * @param _amount The amount of tokens to claim.
     */
    function _claimTokens(string memory _templateName, address _destination, uint256 _amount) internal {
        uint256 contractBalance = _baseAsset.balanceOf(address(this));
        if(contractBalance < _amount) revert InsufficientContractBalance();
        _baseAsset.safeTransfer(_destination, _amount);
        emit TokensClaimed(_templateName, _destination, _amount);
    }
        
    /**
     * @dev Claims tokens on behalf of ICO contracts.
     * @param _templateName The name of the template.
     * @param _vestingWallet The address of the vesting wallet.
     */
    function _claimOnBehalfOfICOContracts(string memory _templateName, address _vestingWallet) internal {
        uint256 claimableAmount;
        Schedule storage schedule = schedules[_templateName];

        if(schedule.vestingType != VestingScheduleType.ICO) revert ThisIsNotICOSchedule();
        else {
            _computeOngoingVestingWallets(schedule.base.vestingWallet, false);
        }

        claimableAmount= schedule.balance.tgePortion;
        if(schedule.base.claimedTokens == schedule.base.allocation) claimableAmount = ZERO;
        if(claimableAmount == ZERO) return;

        schedule.base.isTgeClaimed = true;
        schedule.base.claimedTokens += claimableAmount;
        schedule.lifeCycle.lastClaimed = block.timestamp;
        _claimTokens(_templateName, _vestingWallet, claimableAmount);
    }

    /**
     * @notice Claims tokens for a vesting wallet.
     * @param _vestingWallet The address of the vesting wallet.
     * @param _templateName The name of the template.
     */
    function claimTokens(address _vestingWallet, string calldata _templateName) 
    external 
    nonReentrant
    validAddress(_vestingWallet)
    trustedEcoSystem(_vestingWallet)
    onlyVestingClaimContract() 
    whenNotPaused()
    {
        uint256 claimableAmount;
        bool isTgeAdded = false;
        Schedule storage schedule = schedules[_templateName];

        if(schedule.base.vestingWallet != _vestingWallet) revert UnauthorizedClaiming();

        (claimableAmount, isTgeAdded) = _calculateClaimableAmount(_templateName);

        if(claimableAmount == ZERO) revert NoVestedTokens();
               
        if(schedule.vestingType == VestingScheduleType.ICO){
            _claimOnBehalfOfICOContracts(_templateName, _vestingWallet);
            return;
        }

        if (isTgeAdded) schedule.base.isTgeClaimed = true;

        schedule.base.claimedTokens += claimableAmount;
        schedule.lifeCycle.lastClaimed = block.timestamp;

        _claimTokens(_templateName, _vestingWallet, claimableAmount);
    }

    /**
     * @notice Claims tokens for ICO contracts.
     * @param _vestingWallet The address of the vesting wallet.
     */
    function claimTokensForICO(address _vestingWallet)
    external 
    nonReentrant
    validAddress(_vestingWallet)
    trustedEcoSystem(_vestingWallet)
    onlyVestingClaimContract()
    whenNotPaused()
    {
        uint256 length = vestingInfos.length;
        bool claimedForAtLeastOneICO = false;

        for (uint256 i = ZERO; i < length; ++i) {
            if (vestingInfos[i].vestingWallet == _vestingWallet 
                && schedules[vestingInfos[i].templateName].vestingType == VestingScheduleType.ICO) {
                _claimOnBehalfOfICOContracts(vestingInfos[i].templateName, _vestingWallet);
                claimedForAtLeastOneICO = true;
            }
        }

        if (!claimedForAtLeastOneICO) {
            revert NoICOSchedulesFound();
        }
    }

    /* administration --------------------------------------------------------------------------------*/

    /**
     * @notice Rescues tokens from the contract.
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