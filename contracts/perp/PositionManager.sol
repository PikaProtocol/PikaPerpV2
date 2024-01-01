// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./IPikaPerp.sol";
import '../lib/UniERC20.sol';
import "./IPikaPerp.sol";
import "./PikaPerpV4.sol";
import "../access/Governable.sol";
import "../referrals/IReferralStorage.sol";
import "./IUserMapping.sol";

contract PositionManager is Governable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using UniERC20 for IERC20;
    using Address for address payable;

    struct OpenPositionRequest {
        address account;
        uint256 productId;
        uint256 margin;
        uint256 leverage;
        uint256 tradeFee;
        bool isLong;
        uint256 acceptablePrice;
        uint256 executionFee;
        uint256 index;
        uint256 blockNumber;
        uint256 blockTime;
    }

    struct ClosePositionRequest {
        address account;
        uint256 productId;
        uint256 margin;
        bool isLong;
        uint256 acceptablePrice;
        uint256 executionFee;
        uint256 index;
        uint256 blockNumber;
        uint256 blockTime;
    }

    address public admin;

    address public immutable pikaPerp;
    address public feeCalculator;
    address public oracle;
    address public referralStorage;
    address public fundingManager;
    address public immutable collateralToken;
    address public immutable userMapping;
    uint256 public minExecutionFee;
    uint256 public liquidationThreshold;

    uint256 public minBlockDelayKeeper;
    uint256 public minTimeExecuteDelayPublic;
    uint256 public minTimeCancelDelayPublic;
    uint256 public maxTimeDelay;

    bool public isUserExecuteEnabled = true;
    bool public isUserCancelEnabled = true;
    bool public allowPublicKeeper = false;
    bool public allowUserCloseOnly = false;

    bytes32[] public openPositionRequestKeys;
    bytes32[] public closePositionRequestKeys;

    uint256 public openPositionRequestKeysStart;
    uint256 public closePositionRequestKeysStart;

    uint256 public immutable tokenBase;
    uint256 public constant BASE = 1e8;

    mapping (address => bool) public isPositionKeeper;

    mapping (address => uint256) public openPositionsIndex;
    mapping (bytes32 => OpenPositionRequest) public openPositionRequests;

    mapping (address => uint256) public closePositionsIndex;
    mapping (bytes32 => ClosePositionRequest) public closePositionRequests;

    mapping (address => mapping (address => bool)) public approvedManagers;

    event CreateOpenPosition(
        address indexed account,
        uint256 productId,
        uint256 margin,
        uint256 leverage,
        uint256 tradeFee,
        bool isLong,
        uint256 acceptablePrice,
        uint256 executionFee,
        uint256 index,
        uint256 blockNumber,
        uint256 blockTime,
        uint256 gasPrice
    );

    event ExecuteOpenPosition(
        address indexed account,
        uint256 productId,
        uint256 margin,
        uint256 leverage,
        uint256 tradeFee,
        bool isLong,
        uint256 acceptablePrice,
        uint256 executionFee,
        uint256 index,
        uint256 timeGap,
        bytes32 referralCode,
        address referral
    );

    event CancelOpenPosition(
        address indexed account,
        uint256 productId,
        uint256 margin,
        uint256 leverage,
        uint256 tradeFee,
        bool isLong,
        uint256 acceptablePrice,
        uint256 executionFee,
        uint256 index,
        uint256 blockGap,
        uint256 timeGap
    );

    event CreateClosePosition(
        address indexed account,
        uint256 productId,
        uint256 margin,
        bool isLong,
        uint256 acceptablePrice,
        uint256 executionFee,
        uint256 index,
        uint256 blockNumber,
        uint256 blockTime
    );

    event ExecuteClosePosition(
        address indexed account,
        uint256 productId,
        uint256 margin,
        bool isLong,
        uint256 acceptablePrice,
        uint256 executionFee,
        uint256 index,
        uint256 blockGap,
        uint256 timeGap,
        bytes32 referralCode,
        address referral
    );

    event CancelClosePosition(
        address indexed account,
        uint256 productId,
        uint256 margin,
        bool isLong,
        uint256 acceptablePrice,
        uint256 executionFee,
        uint256 index,
        uint256 blockGap,
        uint256 timeGap
    );
    event ExecuteOpenPositionError(address indexed account, uint256 index, string executionError);
    event ExecuteClosePositionError(address indexed account, uint256 index, string executionError);
    event SetPositionKeeper(address indexed account, bool isActive);
    event SetMinExecutionFee(uint256 minExecutionFee);
    event SetLiquidationThreshold(uint256 liquidationThreshold);
    event SetIsUserExecuteEnabled(bool isUserExecuteEnabled);
    event SetIsUserCancelEnabled(bool isUserCancelEnabled);
    event SetDelayValues(uint256 minBlockDelayKeeper, uint256 minTimeExecuteDelayPublic,
        uint256 minTimeCancelDelayPublic, uint256 maxTimeDelay);
    event SetRequestKeysStartValues(uint256 increasePositionRequestKeysStart, uint256 decreasePositionRequestKeysStart);
    event SetAllowPublicKeeper(bool allowPublicKeeper);
    event SetAllowUserCloseOnly(bool allowUserCloseOnly);
    event SetManager(address manager, bool isActive);
    event SetAccountManager(address account, address manager, bool isActive);
    event SetReferralStorage(address referralStorage);
    event SetAdmin(address admin);

    modifier onlyAdmin() {
        require(msg.sender == admin, "PositionManager: !admin");
        _;
    }

    constructor(
        address _pikaPerp,
        address _feeCalculator,
        address _oracle,
        address _collateralToken,
        address _userMapping,
        address _fundingManager,
        uint256 _minExecutionFee,
        uint256 _liquidationThreshold,
        uint256 _tokenBase
    ) public {
        pikaPerp = _pikaPerp;
        feeCalculator = _feeCalculator;
        oracle = _oracle;
        collateralToken = _collateralToken;
        userMapping = _userMapping;
        fundingManager = _fundingManager;
        minExecutionFee = _minExecutionFee;
        liquidationThreshold = _liquidationThreshold;
        tokenBase = _tokenBase;
        admin = msg.sender;
    }

    function setFeeCalculator(address _feeCalculator) external onlyAdmin {
        feeCalculator = _feeCalculator;
    }

    function setOracle(address _oracle) external onlyAdmin {
        oracle = _oracle;
    }

    function setFundingManger(address _fundingManager) external onlyAdmin {
        fundingManager = _fundingManager;
    }

    function setPositionKeeper(address _account, bool _isActive) external onlyAdmin {
        isPositionKeeper[_account] = _isActive;
        emit SetPositionKeeper(_account, _isActive);
    }

    function setMinExecutionFee(uint256 _minExecutionFee) external onlyAdmin {
        minExecutionFee = _minExecutionFee;
        emit SetMinExecutionFee(_minExecutionFee);
    }

    function setIsUserExecuteEnabled(bool _isUserExecuteEnabled) external onlyAdmin {
        isUserExecuteEnabled = _isUserExecuteEnabled;
        emit SetIsUserExecuteEnabled(_isUserExecuteEnabled);
    }

    function setIsUserCancelEnabled(bool _isUserCancelEnabled) external onlyAdmin {
        isUserCancelEnabled = _isUserCancelEnabled;
        emit SetIsUserCancelEnabled(_isUserCancelEnabled);
    }

    function setLiquidationThreshold(uint256 _liquidationThreshold) external onlyAdmin {
        liquidationThreshold = _liquidationThreshold;
        emit SetLiquidationThreshold(_liquidationThreshold);
    }

    function setDelayValues(
        uint256 _minBlockDelayKeeper,
        uint256 _minTimeExecuteDelayPublic,
        uint256 _minTimeCancelDelayPublic,
        uint256 _maxTimeDelay
    ) external onlyAdmin {
        minBlockDelayKeeper = _minBlockDelayKeeper;
        minTimeExecuteDelayPublic = _minTimeExecuteDelayPublic;
        minTimeCancelDelayPublic = _minTimeCancelDelayPublic;
        maxTimeDelay = _maxTimeDelay;
        emit SetDelayValues(_minBlockDelayKeeper, _minTimeExecuteDelayPublic, _minTimeCancelDelayPublic, _maxTimeDelay);
    }

    function setRequestKeysStartValues(uint256 _increasePositionRequestKeysStart, uint256 _decreasePositionRequestKeysStart) external onlyAdmin {
        openPositionRequestKeysStart = _increasePositionRequestKeysStart;
        closePositionRequestKeysStart = _decreasePositionRequestKeysStart;

        emit SetRequestKeysStartValues(_increasePositionRequestKeysStart, _decreasePositionRequestKeysStart);
    }

    function setAllowPublicKeeper(bool _allowPublicKeeper) external onlyAdmin {
        allowPublicKeeper = _allowPublicKeeper;
        emit SetAllowPublicKeeper(_allowPublicKeeper);
    }

    function setAllowUserCloseOnly(bool _allowUserCloseOnly) external onlyAdmin {
        allowUserCloseOnly = _allowUserCloseOnly;
        emit SetAllowUserCloseOnly(_allowUserCloseOnly);
    }

    function setAccountManager(address _manager, bool _isActive) external {
        approvedManagers[msg.sender][_manager] = _isActive;
        emit SetAccountManager(msg.sender, _manager, _isActive);
    }

    function setReferralStorage(address _referralStorage) external onlyAdmin {
        referralStorage = _referralStorage;
        emit SetReferralStorage(_referralStorage);
    }

    function setAdmin(address _admin) external onlyGov {
        admin = _admin;
        emit SetAdmin(_admin);
    }

    function executeNPositionsWithPrices(
        bytes[] calldata _priceUpdateData,
        uint256 n,
        address payable _executionFeeReceiver
    ) external payable {
        executePositionsWithPrices(_priceUpdateData, openPositionRequestKeysStart + n, closePositionRequestKeysStart + n, _executionFeeReceiver);
    }

    function executePositionsWithPrices(
        bytes[] calldata _priceUpdateData,
        uint256 _openEndIndex,
        uint256 _closeEndIndex,
        address payable _executionFeeReceiver
    ) public payable {
        require(isPositionKeeper[msg.sender] || allowPublicKeeper, "PositionManager: !positionKeeper");
        IOracle(oracle).setPrices{value: msg.value}(msg.sender, _priceUpdateData);
        _executePositions(_openEndIndex, _closeEndIndex, _executionFeeReceiver);
    }

    function _executeNPositions(uint256 n, address payable _executionFeeReceiver) private {
        require(canKeeperExecute(), "PositionManager: cannot execute");
        _executePositions(openPositionRequestKeysStart + n, closePositionRequestKeysStart + n, _executionFeeReceiver);
    }

    function _executePositions(uint256 _openEndIndex, uint256 _closeEndIndex, address payable _executionFeeReceiver) private {
        _executeOpenPositions(_openEndIndex, _executionFeeReceiver);
        _executeClosePositions(_closeEndIndex, _executionFeeReceiver);
    }

    function _executeOpenPositions(uint256 _endIndex, address payable _executionFeeReceiver) private {
        uint256 index = openPositionRequestKeysStart;
        uint256 length = openPositionRequestKeys.length;

        if (index >= length) { return; }

        if (_endIndex > length) {
            _endIndex = length;
        }

        while (index < _endIndex) {
            bytes32 key = openPositionRequestKeys[index];

            // if the request was executed then delete the key from the array
            // if the request was not executed then break from the loop, this can happen if the
            // minimum number of blocks has not yet passed
            // an error could be thrown if the request is too old or if the slippage is
            // higher than what the user specified, or if there is insufficient liquidity for the position
            // in case an error was thrown, cancel the request
            try this.executeOpenPosition(key, _executionFeeReceiver) returns (bool _wasExecuted) {
                if (!_wasExecuted) { break; }
            } catch Error(string memory executionError) {
                emit ExecuteOpenPositionError(openPositionRequests[key].account, index, executionError);
                // wrap this call in a try catch to prevent invalid cancels from blocking the loop
                try this.cancelOpenPosition(key, _executionFeeReceiver) returns (bool _wasCancelled) {
                    if (!_wasCancelled) { break; }
                } catch {}
            } catch (bytes memory /*lowLevelData*/) {
                // wrap this call in a try catch to prevent invalid cancels from blocking the loop
                try this.cancelOpenPosition(key, _executionFeeReceiver) returns (bool _wasCancelled) {
                    if (!_wasCancelled) { break; }
                } catch {}
            }

            delete openPositionRequestKeys[index];
            index++;
        }

        openPositionRequestKeysStart = index;
    }

    function _executeClosePositions(uint256 _endIndex, address payable _executionFeeReceiver) private {
        uint256 index = closePositionRequestKeysStart;
        uint256 length = closePositionRequestKeys.length;

        if (index >= length) { return; }

        if (_endIndex > length) {
            _endIndex = length;
        }

        while (index < _endIndex) {
            bytes32 key = closePositionRequestKeys[index];

            // if the request was executed then delete the key from the array
            // if the request was not executed then break from the loop, this can happen if the
            // minimum number of blocks has not yet passed
            // an error could be thrown if the request is too old
            // in case an error was thrown, cancel the request
            try this.executeClosePosition(key, _executionFeeReceiver) returns (bool _wasExecuted) {
                if (!_wasExecuted) { break; }
            } catch Error(string memory executionError)  {
                emit ExecuteClosePositionError(closePositionRequests[key].account, index, executionError);
                // wrap this call in a try catch to prevent invalid cancels from blocking the loop
                try this.cancelClosePosition(key, _executionFeeReceiver) returns (bool _wasCancelled) {
                    if (!_wasCancelled) { break; }
                } catch {}
            } catch (bytes memory /*lowLevelData*/) {
                // wrap this call in a try catch to prevent invalid cancels from blocking the loop
                try this.cancelClosePosition(key, _executionFeeReceiver) returns (bool _wasCancelled) {
                    if (!_wasCancelled) { break; }
                } catch {}
            }

            delete closePositionRequestKeys[index];
            index++;
        }

        closePositionRequestKeysStart = index;
    }

    function createOpenPosition(
        address _user,
        uint256 _productId,
        uint256 _margin,
        uint256 _leverage,
        bool _isLong,
        uint256 _acceptablePrice,
        uint256 _executionFee,
        bytes32 _referralCode
    ) external payable nonReentrant {
        require(_executionFee >= minExecutionFee, "PositionManager: invalid executionFee");
        require(msg.sender == _user || _validateManager(_user), "PositionManager: no permission for account");
        address _account = IUserMapping(userMapping).getOrCreateProxy(_user, address(this));

        uint256 tradeFee = _getTradeFee(_margin, _leverage, _productId, _account);
        if (IERC20(collateralToken).isETH()) {
            IERC20(collateralToken).uniTransferFromSenderToThis((_executionFee + _margin + tradeFee) * tokenBase / BASE);
        } else {
            require(msg.value == _executionFee * 1e18 / BASE, "PositionManager: incorrect execution fee transferred");
            IERC20(collateralToken).uniTransferFromSenderToThis((_margin + tradeFee) * tokenBase / BASE);
        }

        _setTraderReferralCode(_referralCode);

        _createOpenPosition(
            _account,
            _productId,
            _margin,
            tradeFee,
            _leverage,
            _isLong,
            _acceptablePrice,
            _executionFee
        );
    }

    function createClosePosition(
        address _user,
        uint256 _productId,
        uint256 _margin,
        bool _isLong,
        uint256 _acceptablePrice,
        uint256 _executionFee
    ) external payable nonReentrant {
        require(_executionFee >= minExecutionFee, "PositionManager: invalid executionFee");
        require(msg.value == _executionFee * 1e18 / BASE, "PositionManager: invalid msg.value");
        require(msg.sender == _user || _validateManager(_user), "PositionManager: no permission for account");
        address _account = IUserMapping(userMapping).getProxyFromUser(_user);
        _createClosePosition(
            _account,
            _productId,
            _margin,
            _isLong,
            _acceptablePrice,
            _executionFee
        );
    }

    function getRequestQueueLengths() external view returns (uint256, uint256, uint256, uint256) {
        return (
        openPositionRequestKeysStart,
        openPositionRequestKeys.length,
        closePositionRequestKeysStart,
        closePositionRequestKeys.length
        );
    }

    function executeOpenPosition(bytes32 _key, address payable _executionFeeReceiver) public nonReentrant returns (bool) {
        OpenPositionRequest memory request = openPositionRequests[_key];
        // if the request was already executed or cancelled, return true so that the executeOpenPositions loop will continue executing the next request
        if (request.account == address(0)) { return true; }

        (address productToken,,,,,,,,) = IPikaPerp(pikaPerp).getProduct(request.productId);
        uint256 oraclePrice = request.isLong ? IOracle(oracle).getPrice(productToken, true) : IOracle(oracle).getPrice(productToken, false);

        if (!_validateExecution(request.blockNumber, request.blockTime, request.account, true, request.isLong, request.acceptablePrice, oraclePrice)) {
            return false;
        }

        delete openPositionRequests[_key];

        if (IERC20(collateralToken).isETH()) {
            IPikaPerp(pikaPerp).openPosition{value: (request.margin + request.tradeFee) * tokenBase / BASE }(request.account, request.productId, request.margin, request.isLong, request.leverage, oraclePrice);
        } else {
            IERC20(collateralToken).safeApprove(pikaPerp, 0);
            IERC20(collateralToken).safeApprove(pikaPerp, (request.margin + request.tradeFee) * tokenBase / BASE);
            IPikaPerp(pikaPerp).openPosition(request.account, request.productId, request.margin, request.isLong, request.leverage, oraclePrice);
        }

        _executionFeeReceiver.sendValue(request.executionFee * 1e18 / BASE);

        bytes32 referralCode;
        address referrer;
        if (referralStorage != address(0)) {
            (referralCode, referrer) = IReferralStorage(referralStorage).getTraderReferralInfo(request.account);
        }

        emit ExecuteOpenPosition(
            request.account,
            request.productId,
            request.margin,
            request.leverage,
            request.tradeFee,
            request.isLong,
            request.acceptablePrice,
            request.executionFee,
            request.index,
            block.timestamp.sub(request.blockTime),
            referralCode,
            referrer
        );

        return true;
    }

    function cancelOpenPosition(bytes32 _key, address payable _executionFeeReceiver) public nonReentrant returns (bool) {
        OpenPositionRequest memory request = openPositionRequests[_key];
        // if the request was already executed or cancelled, return true so that the executeOpenePositions loop will continue executing the next request
        if (request.account == address(0)) { return true; }

        bool shouldCancel = _validateCancellation(request.blockNumber, request.blockTime, request.account);
        if (!shouldCancel) { return false; }

        delete openPositionRequests[_key];

        address user = IUserMapping(userMapping).getUserFromProxy(request.account);

        if (IERC20(collateralToken).isETH()) {
            IERC20(collateralToken).uniTransfer(user, (request.margin + request.tradeFee) * tokenBase / BASE);
            IERC20(collateralToken).uniTransfer(_executionFeeReceiver, request.executionFee * tokenBase / BASE);
        } else {
            IERC20(collateralToken).uniTransfer(user, (request.margin + request.tradeFee) * tokenBase / BASE);
            payable(_executionFeeReceiver).sendValue(request.executionFee * 1e18 / BASE);
        }

        emit CancelOpenPosition(
            request.account,
            request.productId,
            request.margin,
            request.leverage,
            request.tradeFee,
            request.isLong,
            request.acceptablePrice,
            request.executionFee,
            request.index,
            block.number.sub(request.blockNumber),
            block.timestamp.sub(request.blockTime)
        );

        return true;
    }

    function executeClosePosition(bytes32 _key, address payable _executionFeeReceiver) public nonReentrant returns (bool) {
        ClosePositionRequest memory request = closePositionRequests[_key];
        // if the request was already executed or cancelled, return true so that the executeClosePositions loop will continue executing the next request
        if (request.account == address(0)) { return true; }
        (address productToken,,,,,,,,) = IPikaPerp(pikaPerp).getProduct(request.productId);
        uint256 oraclePrice = !request.isLong ? IOracle(oracle).getPrice(productToken, true) : IOracle(oracle).getPrice(productToken, false);
        bool shouldExecute = _validateExecution(request.blockNumber, request.blockTime, request.account, false, !request.isLong, request.acceptablePrice, oraclePrice);
        if (!shouldExecute) { return false; }

        delete closePositionRequests[_key];

        IPikaPerp(pikaPerp).closePosition(request.account, request.productId, request.margin , request.isLong, oraclePrice);

        _executionFeeReceiver.sendValue(request.executionFee * 1e18 / BASE);

        bytes32 referralCode;
        address referrer;
        if (referralStorage != address(0)) {
            (referralCode, referrer) = IReferralStorage(referralStorage).getTraderReferralInfo(request.account);
        }

        emit ExecuteClosePosition(
            request.account,
            request.productId,
            request.margin,
            request.isLong,
            request.acceptablePrice,
            request.executionFee,
            request.index,
            block.number.sub(request.blockNumber),
            block.timestamp.sub(request.blockTime),
            referralCode,
            referrer
        );

        return true;
    }

    function cancelClosePosition(bytes32 _key, address payable _executionFeeReceiver) public nonReentrant returns (bool) {
        ClosePositionRequest memory request = closePositionRequests[_key];
        // if the request was already executed or cancelled, return true so that the executeClosePositions loop will continue executing the next request
        if (request.account == address(0)) { return true; }

        bool shouldCancel = _validateCancellation(request.blockNumber, request.blockTime, request.account);
        if (!shouldCancel) { return false; }

        delete closePositionRequests[_key];

        _executionFeeReceiver.sendValue(request.executionFee * 1e18 / BASE);

        emit CancelClosePosition(
                request.account,
                request.productId,
                request.margin,
                request.isLong,
                request.acceptablePrice,
                request.executionFee,
                request.index,
                block.number.sub(request.blockNumber),
                block.timestamp.sub(request.blockTime)
            );

        return true;
    }

    function modifyMargin(uint256 _margin, uint256 _productId, bool _isLong, bool _shouldIncrease) external payable {
        address account = IUserMapping(userMapping).getProxyFromUser(msg.sender);
        (,uint256 leverage,uint256 price,,uint256 margin,,,,int256 funding) = IPikaPerp(pikaPerp).getPosition(
            account, _productId, _isLong);
        (address productToken,,,,,,,,) = IPikaPerp(pikaPerp).getProduct(_productId);
        int256 pnl = PerpLib._getPnl(_isLong, price, leverage, margin, IOracle(oracle).getPrice(productToken)) -
            PerpLib._getFundingPayment(fundingManager, _isLong, _productId, leverage, margin, funding);
        require (pnl > 0 || uint256(-1 * pnl) < uint256(margin) * liquidationThreshold / (10**4), "liquidatable");
        if (_shouldIncrease) {
            IERC20(collateralToken).uniTransferFromSenderToThis(_margin * tokenBase / BASE);
        }
        uint256 positionId = uint256(keccak256(abi.encodePacked(account, _productId, _isLong)));
        if (IERC20(collateralToken).isETH()) {
            IPikaPerp(pikaPerp).modifyMargin{value: _margin * tokenBase / BASE }(positionId, _margin, _shouldIncrease);
        } else {
            IERC20(collateralToken).safeApprove(pikaPerp, 0);
            IERC20(collateralToken).safeApprove(pikaPerp, _margin * tokenBase / BASE);
            IPikaPerp(pikaPerp).modifyMargin(positionId, _margin, _shouldIncrease);
        }
        if (!_shouldIncrease) {
            IERC20(collateralToken).uniTransfer(msg.sender, _margin * tokenBase / BASE);
        }
    }

    function getRequestKey(address _account, uint256 _index) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_account, _index));
    }

    function getOpenPositionRequest(address _account, uint256 _index) public view returns (OpenPositionRequest memory) {
        return openPositionRequests[getRequestKey(_account, _index)];
    }

    function getClosePositionRequest(address _account, uint256 _index) public view returns (ClosePositionRequest memory) {
        return closePositionRequests[getRequestKey(_account, _index)];
    }

    function getOpenPositionRequestFromKey(bytes32 _key) public view returns (OpenPositionRequest memory) {
        return openPositionRequests[_key];
    }

    function getClosePositionRequestFromKey(bytes32 _key) public view returns (ClosePositionRequest memory) {
        return closePositionRequests[_key];
    }

    function canKeeperExecute() public view returns(bool) {
        return (openPositionRequestKeysStart < openPositionRequestKeys.length &&
        openPositionRequests[openPositionRequestKeys[openPositionRequestKeysStart]].blockNumber.add(minBlockDelayKeeper) <= block.number) ||
        (closePositionRequestKeysStart < closePositionRequestKeys.length &&
        closePositionRequests[closePositionRequestKeys[closePositionRequestKeysStart]].blockNumber.add(minBlockDelayKeeper) <= block.number);
    }

    function _validateExecution(uint256 _positionBlockNumber, uint256 _positionBlockTime, address _account,
        bool _isOpen, bool _isLong, uint256 _acceptablePrice, uint256 _oraclePrice
    ) internal view returns (bool) {
        if (_positionBlockTime.add(maxTimeDelay) <= block.timestamp) {
            revert("PositionManager: request has expired");
        }

        bool isKeeperCall = msg.sender == address(this);

        if (!isUserExecuteEnabled && !isKeeperCall) {
            revert("PositionManager: forbidden");
        }
        if (isKeeperCall) {
            if (_isLong) {
                require(_oraclePrice <= _acceptablePrice, "PositionManager: current price too high");
            } else {
                require(_oraclePrice >= _acceptablePrice, "PositionManager: current price too low");
            }
            return _positionBlockNumber.add(minBlockDelayKeeper) <= block.number;
        }
        address user = IUserMapping(userMapping).getUserFromProxy(_account);
        require((!_isOpen || !allowUserCloseOnly) && msg.sender == user, "PositionManager: forbidden");
        require(_positionBlockTime.add(minTimeExecuteDelayPublic) <= block.timestamp, "PositionManager: min delay not yet passed for execution");

        return true;
    }

    function _validateCancellation(uint256 _positionBlockNumber, uint256 _positionBlockTime, address _account) internal view returns (bool) {
        bool isKeeperCall = msg.sender == address(this);

        if (!isUserCancelEnabled && !isKeeperCall) {
            revert("PositionManager: forbidden");
        }

        if (isKeeperCall) {
            return _positionBlockNumber.add(minBlockDelayKeeper) <= block.number;
        }

        require(msg.sender == IUserMapping(userMapping).getUserFromProxy(_account), "PositionManager: forbidden");

        require(_positionBlockTime.add(minTimeCancelDelayPublic) <= block.timestamp, "PositionManager: min delay not yet passed for cancellation");

        return true;
    }

    function _createOpenPosition(
        address _account,
        uint256 _productId,
        uint256 _margin,
        uint256 _tradeFee,
        uint256 _leverage,
        bool _isLong,
        uint256 _acceptablePrice,
        uint256 _executionFee
    ) internal {
        uint256 index = openPositionsIndex[_account].add(1);
        openPositionsIndex[_account] = index;

        OpenPositionRequest memory request = OpenPositionRequest(
            _account,
            _productId,
            _margin,
            _leverage,
            _tradeFee,
            _isLong,
            _acceptablePrice,
            _executionFee,
            index,
            block.number,
            block.timestamp
        );

        bytes32 key = getRequestKey(_account, index);
        openPositionRequests[key] = request;

        openPositionRequestKeys.push(key);

        emit CreateOpenPosition(
            _account,
            _productId,
            _margin,
            _leverage,
            _tradeFee,
            _isLong,
            _acceptablePrice,
            _executionFee,
            index,
            block.number,
            block.timestamp,
            tx.gasprice
        );
    }

    function _createClosePosition(
        address _account,
        uint256 _productId,
        uint256 _margin,
        bool _isLong,
        uint256 _acceptablePrice,
        uint256 _executionFee
    ) internal {
        uint256 index = closePositionsIndex[_account].add(1);
        closePositionsIndex[_account] = index;

        ClosePositionRequest memory request = ClosePositionRequest(
            _account,
            _productId,
            _margin,
            _isLong,
            _acceptablePrice,
            _executionFee,
            index,
            block.number,
            block.timestamp
        );

        bytes32 key = getRequestKey(_account, index);
        closePositionRequests[key] = request;

        closePositionRequestKeys.push(key);

        emit CreateClosePosition(
            _account,
            _productId,
            _margin,
            _isLong,
            _acceptablePrice,
            _executionFee,
            index,
            block.number,
            block.timestamp
        );
    }

    function _validateManager(address _account) private view returns(bool) {
        return approvedManagers[_account][msg.sender];
    }

    function _setTraderReferralCode(bytes32 _referralCode) internal {
        if (_referralCode != bytes32(0) && referralStorage != address(0)) {
            IReferralStorage(referralStorage).setTraderReferralCode(msg.sender, _referralCode);
        }
    }

    function _getTradeFee(uint256 margin, uint256 leverage, uint256 _productId, address _account) private returns(uint256) {
        (address productToken,,uint256 fee,,,,,,) = IPikaPerp(pikaPerp).getProduct(_productId);
        return IFeeCalculator(feeCalculator).getFee(margin, leverage, productToken, fee, _account, msg.sender);
    }

    fallback() external payable {}
    receive() external payable {}
}