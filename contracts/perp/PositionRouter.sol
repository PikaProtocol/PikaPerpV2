pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import '../lib/UniERC20.sol';
import "./IPositionManager.sol";
import "./IOrderBook.sol";
import "./IPikaPerp.sol";
import "./IFeeCalculator.sol";
import "../access/Governable.sol";

contract PositionRouter {
    using UniERC20 for IERC20;

    address public immutable positionManager;
    address public immutable orderbook;
    address public immutable pikaPerp;
    address public immutable feeCalculator;
    address public immutable collateralToken;
    uint256 public immutable tokenBase;
    uint256 public constant BASE = 1e8;
    uint256 public constant FEE_BASE = 1e4;

    constructor(
        address _positionManager,
        address _orderbook,
        address _pikaPerp,
        address _feeCalculator,
        address _collateralToken,
        uint256 _tokenBase
    ) public {
        positionManager = _positionManager;
        orderbook = _orderbook;
        pikaPerp = _collateralToken;
        feeCalculator = _feeCalculator;
        collateralToken = _collateralToken;
        tokenBase = _tokenBase;
    }

    function createOpenMarketOrderWithCloseTriggerOrders (
        uint256 _productId,
        uint256 _margin,
        uint256 _leverage,
        bool _isLong,
        uint256 _acceptablePrice,
        uint256 _executionFee,
        uint256 _stopLossPrice,
        uint256 _takeProfitPrice,
        bytes32 _referralCode
    ) external payable {
        uint256 tradeFee = _getTradeFee(_margin, _leverage, _productId, msg.sender);
        IERC20(collateralToken).uniTransferFromSenderToThis((_margin + tradeFee) * tokenBase / BASE);
        IPositionManager(positionManager).createOpenPosition{value: _executionFee * 1e18 / BASE}(
            msg.sender,
            _productId,
            _margin,
            _leverage,
            _isLong,
            _acceptablePrice,
            _executionFee,
            _referralCode
        );
        if (_stopLossPrice != 0) {
            IOrderBook(orderbook).createCloseOrder{value: _executionFee * 1e18 / BASE}(
                msg.sender,
                _productId,
                _margin * _leverage / BASE,
                _isLong,
                _stopLossPrice,
                _isLong ? false : true
            );
        }
        if (_takeProfitPrice != 0) {
            IOrderBook(orderbook).createCloseOrder{value: _executionFee * 1e18 / BASE}(
                msg.sender,
                _productId,
                _margin * _leverage / BASE,
                _isLong,
                _takeProfitPrice,
                _isLong ? true : false
            );
        }
    }

    function createCloseTriggerOrders (
        uint256 _productId,
        uint256 _margin,
        uint256 _leverage,
        bool _isLong,
        uint256 _executionFee,
        uint256 _stopLossPrice,
        uint256 _takeProfitPrice
    ) external payable {
        if (_stopLossPrice != 0) {
            IOrderBook(orderbook).createCloseOrder{value: _executionFee * 1e18 / BASE}(
                msg.sender,
                _productId,
                _margin * _leverage / BASE,
                _isLong,
                _stopLossPrice,
                _isLong ? false : true
            );
        }
        if (_takeProfitPrice != 0) {
            IOrderBook(orderbook).createCloseOrder{value: _executionFee * 1e18 / BASE}(
                msg.sender,
                _productId,
                _margin * _leverage / BASE,
                _isLong,
                _takeProfitPrice,
                _isLong ? true : false
            );
        }
    }

    function _getTradeFee(uint256 margin, uint256 leverage, uint256 _productId, address _account) private returns(uint256) {
        (address productToken,,uint256 fee,,,,,,) = IPikaPerp(pikaPerp).getProduct(_productId);
        return IFeeCalculator(feeCalculator).getFee(margin, leverage, productToken, fee, _account, msg.sender);
    }
}
