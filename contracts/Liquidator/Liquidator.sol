// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.13;

import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@venusprotocol/governance-contracts/contracts/Governance/AccessControlledV8.sol";
import "./LiquidatorStorage.sol";

interface IComptroller {
    enum Action {
        MINT,
        REDEEM,
        BORROW,
        REPAY,
        SEIZE,
        LIQUIDATE,
        TRANSFER,
        ENTER_MARKET,
        EXIT_MARKET
    }

    function liquidationIncentiveMantissa() external view returns (uint256);

    function vaiController() external view returns (IVAIController);

    function actionPaused(address market, Action action) external view returns (bool);
}

interface IVToken is IERC20Upgradeable {
    function redeem(uint256 redeemTokens) external returns (uint256);
}

interface IVBep20 is IVToken {
    function underlying() external view returns (address);

    function liquidateBorrow(
        address borrower,
        uint256 repayAmount,
        IVToken vTokenCollateral
    ) external returns (uint256);
}

interface IVBNB is IVToken {
    function liquidateBorrow(address borrower, IVToken vTokenCollateral) external payable;
}

interface IVAIController {
    function liquidateVAI(
        address borrower,
        uint256 repayAmount,
        IVToken vTokenCollateral
    ) external returns (uint256, uint256);

    function getVAIAddress() external view returns (address);

    function getVAIRepayAmount(address borrower) external view returns (uint256);
}

interface IProtocolShareReserve {
    enum IncomeType {
        SPREAD,
        LIQUIDATION
    }

    function updateAssetsState(address comptroller, address asset, IncomeType kind) external;
}

interface IWBNB {
    function deposit() external payable;

    function transfer(address to, uint value) external returns (bool);

    function withdraw(uint) external;

    function balanceOf(address owner) external view returns (uint256 balance);
}

contract Liquidator is Ownable2StepUpgradeable, ReentrancyGuardUpgradeable, LiquidatorStorage, AccessControlledV8 {
    /// @notice Address of vBNB contract.
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    IVBNB public immutable vBnb;

    /// @notice Address of Venus Unitroller contract.
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    IComptroller public immutable comptroller;

    /// @notice Address of VAIUnitroller contract.
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    IVAIController public immutable vaiController;

    /// @notice Address of wBNB contract
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable wBNB;

    /// @dev VToken return value signalling about successful execution
    uint256 internal constant NO_ERROR = 0;

    /* Events */

    /// @notice Emitted when the percent of the seized amount that goes to treasury changes.
    event NewLiquidationTreasuryPercent(uint256 oldPercent, uint256 newPercent);

    /// @notice Emitted when a borrow is liquidated
    event LiquidateBorrowedTokens(
        address indexed liquidator,
        address indexed borrower,
        uint256 repayAmount,
        address vTokenBorrowed,
        address indexed vTokenCollateral,
        uint256 seizeTokensForTreasury,
        uint256 seizeTokensForLiquidator
    );

    /// @notice Emitted when the liquidation is restricted for a borrower
    event LiquidationRestricted(address indexed borrower);

    /// @notice Emitted when the liquidation restrictions are removed for a borrower
    event LiquidationRestrictionsDisabled(address indexed borrower);

    /// @notice Emitted when a liquidator is added to the allowedLiquidatorsByAccount mapping
    event AllowlistEntryAdded(address indexed borrower, address indexed liquidator);

    /// @notice Emitted when a liquidator is removed from the allowedLiquidatorsByAccount mapping
    event AllowlistEntryRemoved(address indexed borrower, address indexed liquidator);

    /// @notice Emitted when the amount of minLiquidatableVAI is updated
    event NewMinLiquidatableVAI(uint256 oldMinLiquidatableVAI, uint256 newMinLiquidatableVAI);

    /// @notice Emitted when the length of chunk gets updated
    event NewPendingRedeemChunkLength(uint256 oldPendingRedeemChunkLength, uint256 newPendingRedeemChunkLength);

    /// @notice Emitted when force liquidation is paused
    event ForceVAILiquidationPaused(address indexed sender);

    /// @notice Emitted when force liquidation is resumed
    event ForceVAILiquidationResumed(address indexed sender);

    /// @notice Emitted when new address of protocol share reserve is set
    event NewProtocolShareReserve(address indexed oldProtocolShareReserve, address indexed newProtocolShareReserves);

    /// @notice Emitted when reserves are reduced from liquidator contract to protocol share reserves
    event ProtocolLiquidationIncentiveTransferred(address indexed sender, address indexed token, uint256 reducedAmount);

    /* Errors */

    /// @notice Thrown if the liquidation is restricted and the liquidator is not in the allowedLiquidatorsByAccount mapping
    error LiquidationNotAllowed(address borrower, address liquidator);

    /// @notice Thrown if VToken transfer fails after the liquidation
    error VTokenTransferFailed(address from, address to, uint256 amount);

    /// @notice Thrown if the liquidation is not successful (the error code is from TokenErrorReporter)
    error LiquidationFailed(uint256 errorCode);

    /// @notice Thrown if trying to restrict liquidations for an already restricted borrower
    error AlreadyRestricted(address borrower);

    /// @notice Thrown if trying to unrestrict liquidations for a borrower that is not restricted
    error NoRestrictionsExist(address borrower);

    /// @notice Thrown if the liquidator is already in the allowedLiquidatorsByAccount mapping
    error AlreadyAllowed(address borrower, address liquidator);

    /// @notice Thrown if trying to remove a liquidator that is not in the allowedLiquidatorsByAccount mapping
    error AllowlistEntryNotFound(address borrower, address liquidator);

    /// @notice Thrown if BNB amount sent with the transaction doesn't correspond to the
    ///         intended BNB repayment
    error WrongTransactionAmount(uint256 expected, uint256 actual);

    /// @notice Thrown if the argument is a zero address because probably it is a mistake
    error UnexpectedZeroAddress();

    /// @notice Thrown if trying to set treasury percent larger than the liquidation profit
    error TreasuryPercentTooHigh(uint256 maxTreasuryPercentMantissa, uint256 treasuryPercentMantissa_);

    /// @notice Thrown if trying to liquidate any token when VAI debt is too high
    error VAIDebtTooHigh(uint256 vaiDebt, uint256 minLiquidatableVAI);

    /// @notice Thrown when transfer of underlying assets to protocol share reserve failed
    error UnderlyingTransferFailed(address vToken, address underlying);

    using SafeERC20Upgradeable for IERC20Upgradeable;

    /// @notice Constructor for the implementation contract. Sets immutable variables.
    /// @param comptroller_ The address of the Comptroller contract
    /// @param vBnb_ The address of the VBNB
    /// @param wBNB_ The address of wBNB
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address comptroller_, address payable vBnb_, address wBNB_) {
        ensureNonzeroAddress(vBnb_);
        ensureNonzeroAddress(comptroller_);
        ensureNonzeroAddress(wBNB_);
        vBnb = IVBNB(vBnb_);
        wBNB = wBNB_;
        comptroller = IComptroller(comptroller_);
        vaiController = IVAIController(IComptroller(comptroller_).vaiController());
        _disableInitializers();
    }

    receive() external payable {}

    /// @notice Initializer for the implementation contract.
    /// @param treasuryPercentMantissa_ Treasury share, scaled by 1e18 (e.g. 0.2 * 1e18 for 20%)
    /// @param accessControlManager_ address of access control manager
    /// @param protocolShareReserve_ The address of the protocol share reserve contract
    function initialize(
        uint256 treasuryPercentMantissa_,
        address accessControlManager_,
        address protocolShareReserve_
    ) external virtual reinitializer(2) {
        __Liquidator_init(treasuryPercentMantissa_, accessControlManager_, protocolShareReserve_);
    }

    /// @dev Liquidator initializer for derived contracts.
    /// @param treasuryPercentMantissa_ Treasury share, scaled by 1e18 (e.g. 0.2 * 1e18 for 20%)
    /// @param accessControlManager_ address of access control manager
    /// @param protocolShareReserve_ The address of the protocol share reserve contract
    function __Liquidator_init(
        uint256 treasuryPercentMantissa_,
        address accessControlManager_,
        address protocolShareReserve_
    ) internal onlyInitializing {
        __Ownable2Step_init();
        __ReentrancyGuard_init();
        __Liquidator_init_unchained(treasuryPercentMantissa_, protocolShareReserve_);
        __AccessControlled_init_unchained(accessControlManager_);
    }

    /// @dev Liquidator initializer for derived contracts that doesn't call parent initializers.
    /// @param treasuryPercentMantissa_ Treasury share, scaled by 1e18 (e.g. 0.2 * 1e18 for 20%)
    /// @param protocolShareReserve_ The address of the protocol share reserve contract
    function __Liquidator_init_unchained(
        uint256 treasuryPercentMantissa_,
        address protocolShareReserve_
    ) internal onlyInitializing {
        validateTreasuryPercentMantissa(treasuryPercentMantissa_);
        treasuryPercentMantissa = treasuryPercentMantissa_;
        _setProtocolShareReserve(protocolShareReserve_);
    }

    /// @notice An admin function to restrict liquidations to allowed addresses only.
    /// @dev Use {addTo,removeFrom}AllowList to configure the allowed addresses.
    /// @param borrower The address of the borrower
    function restrictLiquidation(address borrower) external {
        _checkAccessAllowed("restrictLiquidation(address)");
        if (liquidationRestricted[borrower]) {
            revert AlreadyRestricted(borrower);
        }
        liquidationRestricted[borrower] = true;
        emit LiquidationRestricted(borrower);
    }

    /// @notice An admin function to remove restrictions for liquidations.
    /// @dev Does not impact the allowedLiquidatorsByAccount mapping for the borrower, just turns off the check.
    /// @param borrower The address of the borrower
    function unrestrictLiquidation(address borrower) external {
        _checkAccessAllowed("unrestrictLiquidation(address)");
        if (!liquidationRestricted[borrower]) {
            revert NoRestrictionsExist(borrower);
        }
        liquidationRestricted[borrower] = false;
        emit LiquidationRestrictionsDisabled(borrower);
    }

    /// @notice An admin function to add the liquidator to the allowedLiquidatorsByAccount mapping for a certain
    ///         borrower. If the liquidations are restricted, only liquidators from the
    ///         allowedLiquidatorsByAccount mapping can participate in liquidating the positions of this borrower.
    /// @param borrower The address of the borrower
    /// @param borrower The address of the liquidator
    function addToAllowlist(address borrower, address liquidator) external {
        _checkAccessAllowed("addToAllowlist(address,address)");
        if (allowedLiquidatorsByAccount[borrower][liquidator]) {
            revert AlreadyAllowed(borrower, liquidator);
        }
        allowedLiquidatorsByAccount[borrower][liquidator] = true;
        emit AllowlistEntryAdded(borrower, liquidator);
    }

    /// @notice An admin function to remove the liquidator from the allowedLiquidatorsByAccount mapping of a certain
    ///         borrower. If the liquidations are restricted, this liquidator will not be
    ///         able to liquidate the positions of this borrower.
    /// @param borrower The address of the borrower
    /// @param borrower The address of the liquidator
    function removeFromAllowlist(address borrower, address liquidator) external {
        _checkAccessAllowed("removeFromAllowlist(address,address)");
        if (!allowedLiquidatorsByAccount[borrower][liquidator]) {
            revert AllowlistEntryNotFound(borrower, liquidator);
        }
        allowedLiquidatorsByAccount[borrower][liquidator] = false;
        emit AllowlistEntryRemoved(borrower, liquidator);
    }

    /// @notice Liquidates a borrow and splits the seized amount between protocol share reserve and
    ///         liquidator. The liquidators should use this interface instead of calling
    ///         vToken.liquidateBorrow(...) directly.
    /// @notice Checks force VAI liquidation first; vToken should be address of vaiController if vaiDebt is greater than threshold
    /// @notice For BNB borrows msg.value should be equal to repayAmount; otherwise msg.value
    ///      should be zero.
    /// @param vToken Borrowed vToken
    /// @param borrower The address of the borrower
    /// @param repayAmount The amount to repay on behalf of the borrower
    /// @param vTokenCollateral The collateral to seize
    function liquidateBorrow(
        address vToken,
        address borrower,
        uint256 repayAmount,
        IVToken vTokenCollateral
    ) external payable nonReentrant {
        ensureNonzeroAddress(borrower);
        checkRestrictions(borrower, msg.sender);
        _checkForceVAILiquidate(vToken, borrower);
        uint256 ourBalanceBefore = vTokenCollateral.balanceOf(address(this));
        if (vToken == address(vBnb)) {
            if (repayAmount != msg.value) {
                revert WrongTransactionAmount(repayAmount, msg.value);
            }
            vBnb.liquidateBorrow{ value: msg.value }(borrower, vTokenCollateral);
        } else {
            if (msg.value != 0) {
                revert WrongTransactionAmount(0, msg.value);
            }
            if (vToken == address(vaiController)) {
                _liquidateVAI(borrower, repayAmount, vTokenCollateral);
            } else {
                _liquidateBep20(IVBep20(vToken), borrower, repayAmount, vTokenCollateral);
            }
        }
        uint256 ourBalanceAfter = vTokenCollateral.balanceOf(address(this));
        uint256 seizedAmount = ourBalanceAfter - ourBalanceBefore;
        (uint256 ours, uint256 theirs) = _distributeLiquidationIncentive(vTokenCollateral, seizedAmount);
        _reduceReservesInternal();
        emit LiquidateBorrowedTokens(
            msg.sender,
            borrower,
            repayAmount,
            vToken,
            address(vTokenCollateral),
            ours,
            theirs
        );
    }

    /// @notice Sets the new percent of the seized amount that goes to treasury. Should
    ///         be less than or equal to comptroller.liquidationIncentiveMantissa().sub(1e18).
    /// @param newTreasuryPercentMantissa New treasury percent (scaled by 10^18).
    function setTreasuryPercent(uint256 newTreasuryPercentMantissa) external {
        _checkAccessAllowed("setTreasuryPercent(uint256)");
        validateTreasuryPercentMantissa(newTreasuryPercentMantissa);
        emit NewLiquidationTreasuryPercent(treasuryPercentMantissa, newTreasuryPercentMantissa);
        treasuryPercentMantissa = newTreasuryPercentMantissa;
    }

    /**
     * @notice Sets protocol share reserve contract address
     * @param protocolShareReserve_ The address of the protocol share reserve contract
     */
    function setProtocolShareReserve(address payable protocolShareReserve_) external onlyOwner {
        _setProtocolShareReserve(protocolShareReserve_);
    }

    /**
     * @notice Reduce the reserves of the pending accumulated reserves
     */
    function reduceReserves() external {
        _reduceReservesInternal();
    }

    function _reduceReservesInternal() internal {
        uint256 pendingReedemLength_ = pendingRedeem.length;
        uint256 range = pendingReedemLength_ >= pendingRedeemChunkLength
            ? pendingRedeemChunkLength
            : pendingReedemLength_;
        if (range == 0) return;
        for (int256 index = int256(range) - 1; index >= 0; index--) {
            address vToken = pendingRedeem[uint256(index)];
            uint256 vTokenBalance_ = IVToken(vToken).balanceOf(address(this));
            if (_redeemUnderlying(vToken, vTokenBalance_)) {
                if (vToken == address(vBnb)) {
                    _reduceBnbReserves();
                } else {
                    _reduceVTokenReserves(vToken);
                }
                pendingRedeem[uint256(index)] = pendingRedeem[pendingRedeem.length - 1];
                pendingRedeem.pop();
            }
        }
    }

    /// @dev Transfers BEP20 tokens to self, then approves vToken to take these tokens.
    function _liquidateBep20(IVBep20 vToken, address borrower, uint256 repayAmount, IVToken vTokenCollateral) internal {
        IERC20Upgradeable borrowedToken = IERC20Upgradeable(vToken.underlying());
        uint256 actualRepayAmount = _transferBep20(borrowedToken, msg.sender, address(this), repayAmount);
        borrowedToken.safeApprove(address(vToken), 0);
        borrowedToken.safeApprove(address(vToken), actualRepayAmount);
        requireNoError(vToken.liquidateBorrow(borrower, actualRepayAmount, vTokenCollateral));
    }

    /// @dev Transfers BEP20 tokens to self, then approves VAI to take these tokens.
    function _liquidateVAI(address borrower, uint256 repayAmount, IVToken vTokenCollateral) internal {
        IERC20Upgradeable vai = IERC20Upgradeable(vaiController.getVAIAddress());
        vai.safeTransferFrom(msg.sender, address(this), repayAmount);
        vai.safeApprove(address(vaiController), 0);
        vai.safeApprove(address(vaiController), repayAmount);

        (uint err, ) = vaiController.liquidateVAI(borrower, repayAmount, vTokenCollateral);
        requireNoError(err);
    }

    /// @dev Distribute seized collateral between liquidator and protocol share reserve
    function _distributeLiquidationIncentive(
        IVToken vTokenCollateral,
        uint256 siezedAmount
    ) internal returns (uint256 ours, uint256 theirs) {
        (ours, theirs) = _splitLiquidationIncentive(siezedAmount);
        if (!vTokenCollateral.transfer(msg.sender, theirs)) {
            revert VTokenTransferFailed(address(this), msg.sender, theirs);
        }

        if (!_redeemUnderlying(address(vTokenCollateral), ours)) {
            pendingRedeem.push(address(vTokenCollateral));
        } else {
            if (address(vTokenCollateral) == address(vBnb)) {
                _reduceBnbReserves();
            } else {
                _reduceVTokenReserves(address(vTokenCollateral));
            }
        }
        return (ours, theirs);
    }

    /// @dev Wrap BNB to wBNB and sends to protocol share reserve
    function _reduceBnbReserves() private {
        uint256 bnbBalance = address(this).balance;
        IWBNB(wBNB).deposit{ value: bnbBalance }();
        if (!IWBNB(wBNB).transfer(protocolShareReserve, bnbBalance)) {
            revert UnderlyingTransferFailed(address(vBnb), wBNB);
        }
        IProtocolShareReserve(protocolShareReserve).updateAssetsState(
            address(comptroller),
            wBNB,
            IProtocolShareReserve.IncomeType.LIQUIDATION
        );
        emit ProtocolLiquidationIncentiveTransferred(msg.sender, address(wBNB), bnbBalance);
    }

    /// @dev Redeem seized collateral to underlying assets
    function _redeemUnderlying(address vToken, uint256 amount) private returns (bool) {
        try IVToken(address(vToken)).redeem(amount) returns (uint256 response) {
            if (response == 0) {
                return true;
            } else {
                return false;
            }
        } catch {
            return false;
        }
    }

    /// @dev Transfers seized collateral other than BNB to protocol share reserve
    function _reduceVTokenReserves(address vToken) private {
        address underlying = IVBep20(vToken).underlying();
        uint256 underlyingBalance = IERC20Upgradeable(underlying).balanceOf(address(this));
        IERC20Upgradeable(underlying).safeTransfer(protocolShareReserve, underlyingBalance);
        IProtocolShareReserve(protocolShareReserve).updateAssetsState(
            address(comptroller),
            underlying,
            IProtocolShareReserve.IncomeType.LIQUIDATION
        );
        emit ProtocolLiquidationIncentiveTransferred(msg.sender, underlying, underlyingBalance);
    }

    /// @dev Transfers tokens and returns the actual transfer amount
    function _transferBep20(
        IERC20Upgradeable token,
        address from,
        address to,
        uint256 amount
    ) internal returns (uint256 actualAmount) {
        uint256 prevBalance = token.balanceOf(to);
        token.safeTransferFrom(from, to, amount);
        return token.balanceOf(to) - prevBalance;
    }

    /// @dev Computes the amounts that would go to treasury and to the liquidator.
    function _splitLiquidationIncentive(uint256 seizedAmount) internal view returns (uint256 ours, uint256 theirs) {
        uint256 totalIncentive = comptroller.liquidationIncentiveMantissa();
        ours = (seizedAmount * treasuryPercentMantissa) / totalIncentive;
        theirs = seizedAmount - ours;
        return (ours, theirs);
    }

    function requireNoError(uint errCode) internal pure {
        if (errCode == uint(0)) {
            return;
        }

        revert LiquidationFailed(errCode);
    }

    function ensureNonzeroAddress(address address_) internal pure {
        if (address_ == address(0)) {
            revert UnexpectedZeroAddress();
        }
    }

    function checkRestrictions(address borrower, address liquidator) internal view {
        if (liquidationRestricted[borrower] && !allowedLiquidatorsByAccount[borrower][liquidator]) {
            revert LiquidationNotAllowed(borrower, liquidator);
        }
    }

    function validateTreasuryPercentMantissa(uint256 treasuryPercentMantissa_) internal view {
        uint256 maxTreasuryPercentMantissa = comptroller.liquidationIncentiveMantissa() - 1e18;
        if (treasuryPercentMantissa_ > maxTreasuryPercentMantissa) {
            revert TreasuryPercentTooHigh(maxTreasuryPercentMantissa, treasuryPercentMantissa_);
        }
    }

    /// @dev Checks liquidation action in comptroller and vaiDebt with minLiquidatableVAI threshold
    function _checkForceVAILiquidate(address vToken, address borrower) private view {
        uint256 vaiDebt_ = vaiController.getVAIRepayAmount(borrower);
        bool isVAILiquidationPaused_ = comptroller.actionPaused(address(vaiController), IComptroller.Action.LIQUIDATE);
        if (
            isVAILiquidationPaused_ ||
            !forceVAILiquidate ||
            vaiDebt_ < minLiquidatableVAI ||
            vToken == address(vaiController)
        ) return;
        revert VAIDebtTooHigh(vaiDebt_, minLiquidatableVAI);
    }

    function _setProtocolShareReserve(address protocolShareReserve_) internal {
        ensureNonzeroAddress(protocolShareReserve_);
        address oldProtocolShareReserve = protocolShareReserve;
        protocolShareReserve = protocolShareReserve_;
        emit NewProtocolShareReserve(oldProtocolShareReserve, protocolShareReserve_);
    }

    /**
     * @notice Sets the address of the access control of this contract
     * @dev Admin function to set the access control address
     * @param newAccessControlAddress New address for the access control
     */
    function setAccessControl(address newAccessControlAddress) external onlyOwner {
        _setAccessControlManager(newAccessControlAddress);
    }

    /**
     * @notice Sets the threshold for minimum amount of vaiLiquidate
     * @param _minLiquidatableVAI New address for the access control
     */
    function setMinLiquidatableVAI(uint256 _minLiquidatableVAI) external {
        _checkAccessAllowed("setMinLiquidatableVAI(uint256)");
        uint256 oldMinLiquidatableVAI_ = minLiquidatableVAI;
        minLiquidatableVAI = _minLiquidatableVAI;
        emit NewMinLiquidatableVAI(oldMinLiquidatableVAI_, _minLiquidatableVAI);
    }

    /**
     * @notice Length of the pendingRedeem array to be consider while redeeming in Liquidation transaction
     * @param newLength_ Length of the chunk
     */
    function setPendingRedeemChunkLength(uint256 newLength_) external {
        _checkAccessAllowed("setPendingRedeemChunkLength(uint256)");
        uint256 oldPendingRedeemChunkLength_ = pendingRedeemChunkLength;
        pendingRedeemChunkLength = newLength_;
        emit NewPendingRedeemChunkLength(oldPendingRedeemChunkLength_, pendingRedeemChunkLength);
    }

    /**
     * @notice Pause Force Liquidation of VAI
     */
    function pauseForceVAILiquidate() external {
        _checkAccessAllowed("pauseForceVAILiquidate()");
        require(forceVAILiquidate, "Force Liquidation of VAI is already Paused");
        forceVAILiquidate = false;
        emit ForceVAILiquidationPaused(msg.sender);
    }

    /**
     * @notice Pause Force Liquidation of VAI
     */
    function resumeForceVAILiquidate() external {
        _checkAccessAllowed("resumeForceVAILiquidate()");
        require(!forceVAILiquidate, "Force Liquidation of VAI is already resumed");
        forceVAILiquidate = true;
        emit ForceVAILiquidationResumed(msg.sender);
    }
}
