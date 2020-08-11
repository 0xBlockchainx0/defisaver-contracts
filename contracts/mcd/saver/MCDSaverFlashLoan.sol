pragma solidity ^0.6.0;
pragma experimental ABIEncoderV2;

import "../../mcd/saver/MCDSaverProxy.sol";
import "../../utils/FlashLoanReceiverBase.sol";
import "../../exchange/SaverExchangeCore.sol";

contract MCDSaverFlashLoan is MCDSaverProxy, AdminAuth, FlashLoanReceiverBase {

    ILendingPoolAddressesProvider public LENDING_POOL_ADDRESS_PROVIDER = ILendingPoolAddressesProvider(0x24a42fD28C976A61Df5D00D0599C34c4f90748c8);

    constructor() FlashLoanReceiverBase(LENDING_POOL_ADDRESS_PROVIDER) public {}

    struct SaverData {
        uint cdpId;
        uint gasCost;
        uint loanAmount;
        uint fee;
        address joinAddr;
    }

    function executeOperation(
        address _reserve,
        uint256 _amount,
        uint256 _fee,
        bytes calldata _params)
    external override {

        //check the contract has the specified balance
        require(_amount <= getBalanceInternal(address(this), _reserve),
            "Invalid balance for the contract");

        (
            uint[6] memory numData,
            address[5] memory addrData,
            bytes memory callData,
            bool isRepay
        )
         = abi.decode(_params, (uint256[6],address[5],bytes,bool));

        ExchangeData memory exchangeData = ExchangeData({
            srcAddr: addrData[0],
            destAddr: addrData[1],
            srcAmount: numData[0],
            destAmount: numData[1],
            minPrice: numData[2],
            wrapper: addrData[3],
            exchangeAddr: addrData[2],
            callData: callData,
            price0x: numData[3]
        });

        SaverData memory saverData = SaverData({
            cdpId: numData[4],
            gasCost: numData[5],
            loanAmount: _amount,
            fee: _fee,
            joinAddr: addrData[4]
        });

        if (isRepay) {
            repayWithLoan(saverData, exchangeData);
        } else {
            boostWithLoan(saverData, exchangeData);
        }

        transferFundsBackToPoolInternal(_reserve, _amount.add(_fee));

        // if there is some eth left (0x fee), return it to user
        if (address(this).balance > 0) {
            tx.origin.transfer(address(this).balance);
        }
    }

    function boostWithLoan(
        SaverData memory _saverData,
        ExchangeData memory _exchangeData
    ) internal boostCheck(_saverData.cdpId) {

        address user = getOwner(manager, _saverData.cdpId);

        // Draw users Dai
        uint maxDebt = getMaxDebt(_saverData.cdpId, manager.ilks(_saverData.cdpId));
        uint daiDrawn = drawDai(_saverData.cdpId, manager.ilks(_saverData.cdpId), maxDebt);

        // Calc. fees
        uint dsfFee = getFee((daiDrawn + _saverData.loanAmount), _saverData.gasCost, user);
        uint afterFee = (daiDrawn + _saverData.loanAmount) - dsfFee;

        // Swap
        _exchangeData.srcAmount = (_saverData.loanAmount + afterFee);
        (, uint swapedAmount) = _sell(_exchangeData);

        // Return collateral
        addCollateral(_saverData.cdpId, _saverData.joinAddr, swapedAmount);

        // Draw Dai to repay the flash loan
        drawDai(_saverData.cdpId,  manager.ilks(_saverData.cdpId), (_saverData.loanAmount + _saverData.fee));

        // SaverLogger(LOGGER_ADDRESS).LogBoost(_cdpId, user, (amounts[1] + _loanAmount), amounts[4]);
    }

    function repayWithLoan(
        SaverData memory _saverData,
        ExchangeData memory _exchangeData
    ) internal repayCheck(_saverData.cdpId) {

        address user = getOwner(manager, _saverData.cdpId);
        bytes32 ilk = manager.ilks(_saverData.cdpId);

        // Draw collateral
        uint maxColl = getMaxCollateral(_saverData.cdpId, ilk, _saverData.joinAddr);
        uint collDrawn = drawCollateral(_saverData.cdpId, ilk, _saverData.joinAddr, maxColl);

        // Swap
        _exchangeData.srcAmount = (_saverData.loanAmount + collDrawn);
        (, uint swapedAmount) = _sell(_exchangeData);

        uint paybackAmount = (swapedAmount - getFee(swapedAmount, _saverData.gasCost, user));
        paybackAmount = limitLoanAmount(_saverData.cdpId, ilk, paybackAmount, user);

        // Payback the debt
        paybackDebt(_saverData.cdpId, ilk, paybackAmount, user);

        // Draw collateral to repay the flash loan
        drawCollateral(_saverData.cdpId, ilk, _saverData.joinAddr, (_saverData.loanAmount + _saverData.fee));

        // SaverLogger(LOGGER_ADDRESS).LogRepay(_cdpId, owner, (amounts[1] + _loanAmount), amounts[2]);
    }

    /// @notice Handles that the amount is not bigger than cdp debt and not dust
    function limitLoanAmount(uint _cdpId, bytes32 _ilk, uint _paybackAmount, address _owner) internal returns (uint256) {
        uint debt = getAllDebt(address(vat), manager.urns(_cdpId), manager.urns(_cdpId), _ilk);

        if (_paybackAmount > debt) {
            ERC20(DAI_ADDRESS).transfer(_owner, (_paybackAmount - debt));
            return debt;
        }

        uint debtLeft = debt - _paybackAmount;

        // Less than dust value
        if (debtLeft < 20 ether) { // TODO: dust value not fixed
            uint amountOverDust = ((20 ether) - debtLeft);

            ERC20(DAI_ADDRESS).transfer(_owner, amountOverDust);

            return (_paybackAmount - amountOverDust);
        }

        return _paybackAmount;
    }

    receive() external override(FlashLoanReceiverBase, SaverExchangeCore) payable {}

}
