// SPDX-License-Identifier: ISC
pragma solidity ^0.8.0;

// imports
import { LasmOwnable } from "./imports/LasmOwnable.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { Address } from "./libs/Address.sol";
import { IVesting } from "./interfaces/IVesting.sol";

/**
 * @title VestingClaimingContract
 * @notice Allows beneficiaries to claim vested tokens through a vesting contract.
 * @dev The contract facilitates token claims, can be activated/deactivated, handles token rescues, and ensures 
 * secure operations. It validates contract interactions, supports ERC-20 tokens, and emits events for key actions.
 * Only the owner can modify the working status and perform administrative tasks such as rescuing tokens.
 */

contract VestingClaimingContract is LasmOwnable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Address for address;

    /// @dev Address of the vesting contract.
    IVesting public vestingContract;

    /// @dev Initial owner of the contract.
    address private _initialOwner;

    /// @dev Status indicating whether the contract is working.
    bool public working = true;

    /// @dev Status flag for the contract's operational status.
    bool private _status;

    /// @dev Constant value for zero.
    uint256 public constant ZERO = 0;

    // Events
    /**
     * @dev Emitted when tokens are claimed.
     * @param templateName The name of the template used for claiming.
     */
    event TokensClaimed(string templateName);

    /**
     * @dev Emitted when ICO tokens are claimed.
     * @param _icoWallet The address of the ICO wallet.
     */
    event ICOTokensClaimed(address indexed _icoWallet);

    /**
     * @dev Emitted when pending tokens are checked.
     * @param beneficiary The address of the beneficiary.
     * @param amount The amount of pending tokens.
     * @param templateName The name of the template.
     */
    event CheckedPendingTokens(address indexed beneficiary, uint256 indexed amount, string templateName);

    /**
     * @dev Emitted when the contract status is updated.
     * @param isWorking The updated status of the contract.
     */
    event ClaimContractStatusUpdated(bool indexed isWorking);

    /**
     * @dev Emitted when tokens are withdrawn from the contract.
     * @param owner The address of the owner initiating the withdrawal.
     * @param destination The address receiving the tokens.
     * @param amount The amount of tokens withdrawn.
     */
    event Withdrawal(address indexed owner, address indexed destination, uint256 indexed amount);

    // Errors
    error OnlyOwnerIsAllowed();
    error InvalidAddressInteraction();
    error InvalidContractInteraction();
    error ReentrancyAttackDetected();
    error ContractIsNotInUse();
    error ContractNotInUse();
    error TokenAmountIsZero();
    error TokenTransferFailed();
    error DoesNotAcceptingEthers();
    error NotPermitted();

    // Modifiers
    /**
     * @dev Modifier to make a function callable only when the contract is working.
     */
    modifier onlyWhenWorking() {
        if (!working) revert ContractIsNotInUse();
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
     * @dev Initializes the contract with the specified vesting contract address.
     * @param _vestingContract The address of the vesting contract.
     */
    constructor(address _vestingContract) {
        if (_vestingContract == address(0)) revert InvalidAddressInteraction();
        vestingContract = IVesting(_vestingContract);
        _transferOwnership(_msgSender());
        _initialOwner = _msgSender();
        _status = false;
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
     * @dev Claims tokens for the caller based on the specified template name.
     * @param templateName The name of the template used for claiming.
     */
    function claimTokensForBeneficiary(string calldata templateName) 
        external 
        nonReentrant 
        onlyWhenWorking 
    {
        vestingContract.claimTokens(_msgSender(), templateName);
        emit TokensClaimed(templateName);
    }

    /**
     * @dev Claims ICO tokens for the caller.
     */
    function claimTokensForICO() 
        external 
        nonReentrant 
        onlyWhenWorking 
    {
        vestingContract.claimTokensForICO(_msgSender());
        emit ICOTokensClaimed(_msgSender());
    }

    /**
     * @dev Sets the working status of the contract.
     * @param isWorking The updated working status.
     */
    function setWorking(bool isWorking) external onlyOwner {
        working = isWorking;
        emit ClaimContractStatusUpdated(isWorking);
    }

    /**
     * @dev Rescues tokens from the contract.
     * @param tokenAddress The address of the token to rescue.
     * @param to The address to send the rescued tokens to.
     * @param amount The amount of tokens to rescue.
     */
    function rescueTokens(address tokenAddress, address to, uint256 amount) 
        external 
        onlyOwner 
        validContract(tokenAddress) 
        validAddress(to) 
    {
        if (amount == ZERO) revert TokenAmountIsZero();
        IERC20 token = IERC20(tokenAddress);
        token.safeTransfer(to, amount);
        emit Withdrawal(tokenAddress, to, amount);
    }

    /**
     * @dev Checks the pending tokens for the caller based on the specified template name.
     * @param templateName The name of the template.
     * @return The amount of pending tokens.
     */
    function checkPendingTokens(string calldata templateName) 
        external 
        view 
        onlyWhenWorking 
        returns (uint256) 
    {
        uint256 pendingAmount;
        pendingAmount = vestingContract.pendingClaimableTokens(templateName);
        return pendingAmount;
    }
}
