//SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.4;

import "../libraries/MathLib.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../interfaces/IExchangeFactory.sol";

/**
 * @title Exchange contract for Elastic Swap representing a single ERC20 pair of tokens to be swapped.
 * @author Elastic DAO
 * @notice This contract provides all of the needed functionality for a liquidity provider to supply/withdraw ERC20
 * tokens and traders to swap tokens for one another.
 */
contract Exchange is ERC20, ReentrancyGuard {
    using MathLib for uint256;
    using SafeERC20 for IERC20;

    address public immutable baseToken; // address of ERC20 base token (elastic or fixed supply)
    address public immutable quoteToken; // address of ERC20 quote token (WETH or a stable coin w/ fixed supply)
    address public immutable exchangeFactoryAddress;

    uint256 public constant TOTAL_LIQUIDITY_FEE = 30; // fee provided to liquidity providers + DAO in basis points

    MathLib.InternalBalances public internalBalances =
        MathLib.InternalBalances(0, 0, 0);

    event AddLiquidity(
        address indexed liquidityProvider,
        uint256 baseTokenQtyAdded,
        uint256 quoteTokenQtyAdded
    );
    event RemoveLiquidity(
        address indexed liquidityProvider,
        uint256 baseTokenQtyRemoved,
        uint256 quoteTokenQtyRemoved
    );
    event Swap(
        address indexed sender,
        uint256 baseTokenQtyIn,
        uint256 quoteTokenQtyIn,
        uint256 baseTokenQtyOut,
        uint256 quoteTokenQtyOut
    );

    /**
     * @dev Called to check timestamps from users for expiration of their calls.
     * Used in place of a modifier for byte code savings
     */
    function isNotExpired(uint256 _expirationTimeStamp) internal view {
        require(_expirationTimeStamp >= block.timestamp, "Exchange: EXPIRED");
    }

    /**
     * @notice called by the exchange factory to create a new erc20 token swap pair (do not call this directly!)
     * @param _name The human readable name of this pair (also used for the liquidity token name)
     * @param _symbol Shortened symbol for trading pair (also used for the liquidity token symbol)
     * @param _baseToken address of the ERC20 base token in the pair. This token can have a fixed or elastic supply
     * @param _quoteToken address of the ERC20 quote token in the pair. This token is assumed to have a fixed supply.
     */
    constructor(
        string memory _name,
        string memory _symbol,
        address _baseToken,
        address _quoteToken,
        address _exchangeFactoryAddress
    ) ERC20(_name, _symbol) {
        baseToken = _baseToken;
        quoteToken = _quoteToken;
        exchangeFactoryAddress = _exchangeFactoryAddress;
    }

    /**
     * @notice primary entry point for a liquidity provider to add new liquidity (base and quote tokens) to the exchange
     * and receive liquidity tokens in return.
     * Requires approvals to be granted to this exchange for both base and quote tokens.
     * @param _baseTokenQtyDesired qty of baseTokens that you would like to add to the exchange
     * @param _quoteTokenQtyDesired qty of quoteTokens that you would like to add to the exchange
     * @param _baseTokenQtyMin minimum acceptable qty of baseTokens that will be added (or transaction will revert)
     * @param _quoteTokenQtyMin minimum acceptable qty of quoteTokens that will be added (or transaction will revert)
     * @param _liquidityTokenRecipient address for the exchange to issue the resulting liquidity tokens from
     * this transaction to
     * @param _expirationTimestamp timestamp that this transaction must occur before (or transaction will revert)
     */
    function addLiquidity(
        uint256 _baseTokenQtyDesired,
        uint256 _quoteTokenQtyDesired,
        uint256 _baseTokenQtyMin,
        uint256 _quoteTokenQtyMin,
        address _liquidityTokenRecipient,
        uint256 _expirationTimestamp
    ) external nonReentrant {
        //@note
        //Intention
        //  1) Guard: nonReentrant
        //  2) Guard: check for expiration
        //  3) Process: calculate quantities and fees
        //      3.1) Handles "decay" resolution if internal and external balances differ (due to rebases)
        //  4) Process: update inKLast
        //  5) Push: mint outstanding fees to DAO fee address
        //  6) Push: mint liquidity tokens to recipient
        //  7) Pull: transfer base tokens from sender
        //      7.1) Guard: revert if Fee-on-Transfer detected on first deposit
        //  8) Pull: transfer quote tokens from sender

        //2
        isNotExpired(_expirationTimestamp);

        //3
        MathLib.TokenQtys memory tokenQtys = MathLib
            .calculateAddLiquidityQuantities(
                _baseTokenQtyDesired,
                _quoteTokenQtyDesired,
                _baseTokenQtyMin,
                _quoteTokenQtyMin,
                IERC20(baseToken).balanceOf(address(this)),
                IERC20(quoteToken).balanceOf(address(this)),
                this.totalSupply(),
                internalBalances
            );

        //4
        internalBalances.kLast =
            internalBalances.baseTokenReserveQty *
            internalBalances.quoteTokenReserveQty;

        //5
        if (tokenQtys.liquidityTokenFeeQty > 0) {
            // mint liquidity tokens to fee address for k growth.
            _mint(
                IExchangeFactory(exchangeFactoryAddress).feeAddress(),
                tokenQtys.liquidityTokenFeeQty
            );
        }

        //6
        _mint(_liquidityTokenRecipient, tokenQtys.liquidityTokenQty); // mint liquidity tokens to recipient

        //7 {
        if (tokenQtys.baseTokenQty != 0) {
            bool isExchangeEmpty = IERC20(baseToken).balanceOf(address(this)) ==
                0;

            // transfer base tokens to Exchange
            IERC20(baseToken).safeTransferFrom(
                msg.sender,
                address(this),
                tokenQtys.baseTokenQty
            );

            if (isExchangeEmpty) {
                require(
                    IERC20(baseToken).balanceOf(address(this)) ==
                        tokenQtys.baseTokenQty,
                    "Exchange: FEE_ON_TRANSFER_NOT_SUPPORTED"
                );
            }
        }
        //} 7

        //8 {
        if (tokenQtys.quoteTokenQty != 0) {
            // transfer quote tokens to Exchange
            IERC20(quoteToken).safeTransferFrom(
                msg.sender,
                address(this),
                tokenQtys.quoteTokenQty
            );
        }
        //} 8

        emit AddLiquidity(
            msg.sender,
            tokenQtys.baseTokenQty,
            tokenQtys.quoteTokenQty
        );
    }

    /**
     * @notice called by a liquidity provider to redeem liquidity tokens from the exchange and receive back
     * base and quote tokens. Required approvals to be granted to this exchange for the liquidity token
     * @param _liquidityTokenQty qty of liquidity tokens that you would like to redeem
     * @param _baseTokenQtyMin minimum acceptable qty of base tokens to receive back (or transaction will revert)
     * @param _quoteTokenQtyMin minimum acceptable qty of quote tokens to receive back (or transaction will revert)
     * @param _tokenRecipient address for the exchange to issue the resulting base and
     * quote tokens from this transaction to
     * @param _expirationTimestamp timestamp that this transaction must occur before (or transaction will revert)
     */
    function removeLiquidity(
        uint256 _liquidityTokenQty,
        uint256 _baseTokenQtyMin,
        uint256 _quoteTokenQtyMin,
        address _tokenRecipient,
        uint256 _expirationTimestamp
    ) external nonReentrant {
        //@note
        //Intention
        //  1) Guard: nonReentrant
        //  2) Guard: check for expiration
        //  3) Guard: check for initialized pool and valid minimums
        //  4) Process: calculate DAO fees and proportional external quantities to return
        //      4.1) Include pending fee
        //  5) Guard: verify output quantities meet slippage minimums
        //  6) Process: update internal reserves and kLast
        //      6.1) baseToken internal removal is proportional to internal reserves
        //      6.2) quoteToken internal removal matches external removal
        //      6.3) update kLast
        //  7) mint fees to DAO
        //  8) burn liquidity tokens from sender
        //  9) push base and quote tokens to recipient

        //2
        isNotExpired(_expirationTimestamp);

        //3 {
        require(this.totalSupply() > 0, "Exchange: INSUFFICIENT_LIQUIDITY");
        require(
            _baseTokenQtyMin > 0 && _quoteTokenQtyMin > 0,
            "Exchange: MINS_MUST_BE_GREATER_THAN_ZERO"
        );
        //} 3

        //4 {
        uint256 baseTokenReserveQty = IERC20(baseToken).balanceOf(
            address(this)
        );
        uint256 quoteTokenReserveQty = IERC20(quoteToken).balanceOf(
            address(this)
        );

        //4.1 {
        uint256 totalSupplyOfLiquidityTokens = this.totalSupply();
        // calculate any DAO fees here.
        uint256 liquidityTokenFeeQty = MathLib.calculateLiquidityTokenFees(
            totalSupplyOfLiquidityTokens,
            internalBalances
        );
        // we need to factor this quantity in to any total supply before redemption
        totalSupplyOfLiquidityTokens += liquidityTokenFeeQty;
        //} 4.1

        uint256 baseTokenQtyToReturn = (_liquidityTokenQty *
            baseTokenReserveQty) / totalSupplyOfLiquidityTokens;
        uint256 quoteTokenQtyToReturn = (_liquidityTokenQty *
            quoteTokenReserveQty) / totalSupplyOfLiquidityTokens;
        //} 4

        //5 {
        require(
            baseTokenQtyToReturn >= _baseTokenQtyMin,
            "Exchange: INSUFFICIENT_BASE_QTY"
        );
        require(
            quoteTokenQtyToReturn >= _quoteTokenQtyMin,
            "Exchange: INSUFFICIENT_QUOTE_QTY"
        );
        //} 5

        //6 {
        // this ensure that we are removing the equivalent amount of decay
        // when this person exits.
        //6.1 {
        uint256 baseTokenQtyToRemoveFromInternalAccounting = (_liquidityTokenQty *
                internalBalances.baseTokenReserveQty) /
                totalSupplyOfLiquidityTokens;

        internalBalances
            .baseTokenReserveQty -= baseTokenQtyToRemoveFromInternalAccounting;
        //} 6.1

        //6.2 {
        // We should ensure no possible overflow here.
        if (quoteTokenQtyToReturn > internalBalances.quoteTokenReserveQty) {
            internalBalances.quoteTokenReserveQty = 0;
        } else {
            internalBalances.quoteTokenReserveQty -= quoteTokenQtyToReturn;
        }
        //} 6.2

        //6.3
        internalBalances.kLast =
            internalBalances.baseTokenReserveQty *
            internalBalances.quoteTokenReserveQty;
        //} 6

        //7 {
        if (liquidityTokenFeeQty > 0) {
            _mint(
                IExchangeFactory(exchangeFactoryAddress).feeAddress(),
                liquidityTokenFeeQty
            );
        }
        //} 7

        //8
        _burn(msg.sender, _liquidityTokenQty);

        //9 {
        IERC20(baseToken).safeTransfer(_tokenRecipient, baseTokenQtyToReturn);
        IERC20(quoteToken).safeTransfer(_tokenRecipient, quoteTokenQtyToReturn);
        //} 9

        emit RemoveLiquidity(
            msg.sender,
            baseTokenQtyToReturn,
            quoteTokenQtyToReturn
        );
    }

    /**
     * @notice swaps base tokens for a minimum amount of quote tokens.  Fees are included in all transactions.
     * The exchange must be granted approvals for the base token by the caller.
     * @param _baseTokenQty qty of base tokens to swap
     * @param _minQuoteTokenQty minimum qty of quote tokens to receive in exchange for
     * your base tokens (or the transaction will revert)
     * @param _expirationTimestamp timestamp that this transaction must occur before (or transaction will revert)
     */
    function swapBaseTokenForQuoteToken(
        uint256 _baseTokenQty,
        uint256 _minQuoteTokenQty,
        uint256 _expirationTimestamp
    ) external nonReentrant {
        //@note
        //Intention
        //  1) Guard: nonReentrant
        //  2) Guard: check for expiration and positive quantities
        //  3) Process: calculate swap output and update internal balances
        //  4) Pull: base tokens from sender
        //  5) Push: quote tokens to sender

        //2 {
        isNotExpired(_expirationTimestamp);
        require(
            _baseTokenQty > 0 && _minQuoteTokenQty > 0,
            "Exchange: INSUFFICIENT_TOKEN_QTY"
        );
        //} 2

        //3
        uint256 quoteTokenQty = MathLib.calculateQuoteTokenQty(
            _baseTokenQty,
            _minQuoteTokenQty,
            TOTAL_LIQUIDITY_FEE,
            internalBalances
        );

        //4
        IERC20(baseToken).safeTransferFrom(
            msg.sender,
            address(this),
            _baseTokenQty
        );

        //5
        IERC20(quoteToken).safeTransfer(msg.sender, quoteTokenQty);
        emit Swap(msg.sender, _baseTokenQty, 0, 0, quoteTokenQty);
    }

    /**
     * @notice swaps quote tokens for a minimum amount of base tokens.  Fees are included in all transactions.
     * The exchange must be granted approvals for the quote token by the caller.
     * @param _quoteTokenQty qty of quote tokens to swap
     * @param _minBaseTokenQty minimum qty of base tokens to receive in exchange for
     * your quote tokens (or the transaction will revert)
     * @param _expirationTimestamp timestamp that this transaction must occur before (or transaction will revert)
     */
    function swapQuoteTokenForBaseToken(
        uint256 _quoteTokenQty,
        uint256 _minBaseTokenQty,
        uint256 _expirationTimestamp
    ) external nonReentrant {
        //@note
        //Intention
        //  1) Guard: nonReentrant
        //  2) Guard: check for expiration and positive quantities
        //  3) Process: calculate swap output and update internal balances
        //      3.1) Handles external balance mismatch (decay) if base token supply decreased
        //  4) Pull: quote tokens from sender
        //  5) Push: base tokens to sender

        //2 {
        isNotExpired(_expirationTimestamp);
        require(
            _quoteTokenQty > 0 && _minBaseTokenQty > 0,
            "Exchange: INSUFFICIENT_TOKEN_QTY"
        );
        //} 2

        //3
        uint256 baseTokenQty = MathLib.calculateBaseTokenQty(
            _quoteTokenQty,
            _minBaseTokenQty,
            IERC20(baseToken).balanceOf(address(this)),
            TOTAL_LIQUIDITY_FEE,
            internalBalances
        );

        //4
        IERC20(quoteToken).safeTransferFrom(
            msg.sender,
            address(this),
            _quoteTokenQty
        );

        //5
        IERC20(baseToken).safeTransfer(msg.sender, baseTokenQty);
        emit Swap(msg.sender, 0, _quoteTokenQty, baseTokenQty, 0);
    }
}
