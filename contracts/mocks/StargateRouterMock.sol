// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;
pragma abicoder v2;

// imports
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./StargateFactoryMock.sol";
import "./StargatePoolMock.sol";
import "./StargateBridgeMock.sol";

// interfaces
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IStargateRouter.sol";
import "../interfaces/IStargateReceiver.sol";

// libraries
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract StargateRouterMock is IStargateRouter, Ownable, ReentrancyGuard {
    using SafeMath for uint;

    //---------------------------------------------------------------------------
    // CONSTANTS
    uint8 internal constant TYPE_REDEEM_LOCAL_RESPONSE = 1;
    uint8 internal constant TYPE_REDEEM_LOCAL_CALLBACK_RETRY = 2;
    uint8 internal constant TYPE_SWAP_REMOTE_RETRY = 3;

    //---------------------------------------------------------------------------
    // STRUCTS
    struct CachedSwap {
        address token;
        uint amountLD;
        address to;
        bytes payload;
    }

    //---------------------------------------------------------------------------
    // VARIABLES
    StargateFactoryMock public factory; // used for creating pools
    address public protocolFeeOwner; // can call methods to pull Stargate fees collected in pools
    address public mintFeeOwner; // can call methods to pull mint fees collected in pools
    StargateBridgeMock public bridge;
    mapping(uint16 => mapping(bytes => mapping(uint => bytes))) public revertLookup; //[chainId][srcAddress][nonce]
    mapping(uint16 => mapping(bytes => mapping(uint => CachedSwap))) public cachedSwapLookup; //[chainId][srcAddress][nonce]

    //---------------------------------------------------------------------------
    // EVENTS
    event Revert(uint8 bridgeFunctionType, uint16 chainId, bytes srcAddress, uint nonce);
    event CachedSwapSaved(uint16 chainId, bytes srcAddress, uint nonce, address token, uint amountLD, address to, bytes payload, bytes reason);
    event RevertRedeemLocal(uint16 srcChainId, uint _srcPoolId, uint _dstPoolId, bytes to, uint redeemAmountSD, uint mintAmountSD, uint indexed nonce, bytes indexed srcAddress);
    event RedeemLocalCallback(uint16 srcChainId, bytes indexed srcAddress, uint indexed nonce, uint srcPoolId, uint dstPoolId, address to, uint amountSD, uint mintAmountSD);

    //---------------------------------------------------------------------------
    // MODIFIERS
    modifier onlyBridge() {
        require(msg.sender == address(bridge), "Bridge: caller must be Bridge.");
        _;
    }

    constructor() {}

    function setBridgeAndFactory(StargateBridgeMock _bridge, StargateFactoryMock _factory) external onlyOwner {
        require(address(bridge) == address(0x0) && address(factory) == address(0x0), "Stargate: bridge and factory already initialized"); // 1 time only
        require(address(_bridge) != address(0x0), "Stargate: bridge cant be 0x0");
        require(address(_factory) != address(0x0), "Stargate: factory cant be 0x0");

        bridge = _bridge;
        factory = _factory;
    }

    //---------------------------------------------------------------------------
    // VIEWS
    function _getPool(uint _poolId) internal view returns (StargatePoolMock pool) {
        pool = factory.getPool(_poolId);
        require(address(pool) != address(0x0), "Stargate: Pool does not exist");
    }

    //---------------------------------------------------------------------------
    // INTERNAL
    function _safeTransferFrom(
        address token,
        address from,
        address to,
        uint value
    ) private {
        // bytes4(keccak256(bytes('transferFrom(address,address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "Stargate: TRANSFER_FROM_FAILED");
    }

    function swap(
        uint16 _dstChainId,
        uint _srcPoolId,
        uint _dstPoolId,
        address payable _refundAddress,
        uint _amountLD,
        uint _minAmountLD,
        lzTxObj memory _lzTxParams,
        bytes calldata _to,
        bytes calldata _payload
    ) external payable nonReentrant {
        require(_amountLD > 0, "Stargate: cannot swap 0");
        require(_refundAddress != address(0x0), "Stargate: _refundAddress cannot be 0x0");
        StargatePoolMock.SwapObj memory s;
        StargatePoolMock.CreditObj memory c;
        {
            StargatePoolMock pool = _getPool(_srcPoolId);
            {
                uint convertRate = pool.convertRate();
                _amountLD = _amountLD.div(convertRate).mul(convertRate);
            }

            s = pool.swap(_dstChainId, _dstPoolId, msg.sender, _amountLD, _minAmountLD, true);
            _safeTransferFrom(pool.token(), msg.sender, address(pool), _amountLD);
            c = pool.sendCredits(_dstChainId, _dstPoolId);
        }
        bridge.swap{value: msg.value}(_dstChainId, _srcPoolId, _dstPoolId, _refundAddress, c, s, _lzTxParams, _to, _payload);
    }

    function redeemRemote(
        uint16 _dstChainId,
        uint _srcPoolId,
        uint _dstPoolId,
        address payable _refundAddress,
        uint _amountLP,
        uint _minAmountLD,
        bytes calldata _to,
        lzTxObj memory _lzTxParams
    ) external payable nonReentrant {
        require(_refundAddress != address(0x0), "Stargate: _refundAddress cannot be 0x0");
        require(_amountLP > 0, "Stargate: not enough lp to redeemRemote");
        StargatePoolMock.SwapObj memory s;
        StargatePoolMock.CreditObj memory c;
        {
            StargatePoolMock pool = _getPool(_srcPoolId);
            uint amountLD = pool.amountLPtoLD(_amountLP);
            // perform a swap with no liquidity
            s = pool.swap(_dstChainId, _dstPoolId, msg.sender, amountLD, _minAmountLD, false);
            pool.redeemRemote(_dstChainId, _dstPoolId, msg.sender, _amountLP);
            c = pool.sendCredits(_dstChainId, _dstPoolId);
        }
        // equal to a swap, with no payload ("0x") no dstGasForCall 0
        bridge.swap{value: msg.value}(_dstChainId, _srcPoolId, _dstPoolId, _refundAddress, c, s, _lzTxParams, _to, "");
    }

    function instantRedeemLocal(
        uint16 _srcPoolId,
        uint _amountLP,
        address _to
    ) external nonReentrant returns (uint amountSD) {
        require(_amountLP > 0, "Stargate: not enough lp to redeem");
        StargatePoolMock pool = _getPool(_srcPoolId);
        amountSD = pool.instantRedeemLocal(msg.sender, _amountLP, _to);
    }

    function redeemLocal(
        uint16 _dstChainId,
        uint _srcPoolId,
        uint _dstPoolId,
        address payable _refundAddress,
        uint _amountLP,
        bytes calldata _to,
        lzTxObj memory _lzTxParams
    ) external payable nonReentrant {
        require(_refundAddress != address(0x0), "Stargate: _refundAddress cannot be 0x0");
        StargatePoolMock pool = _getPool(_srcPoolId);
        require(_amountLP > 0, "Stargate: not enough lp to redeem");
        uint amountSD = pool.redeemLocal(msg.sender, _amountLP, _dstChainId, _dstPoolId, _to);
        require(amountSD > 0, "Stargate: not enough lp to redeem with amountSD");

        StargatePoolMock.CreditObj memory c = pool.sendCredits(_dstChainId, _dstPoolId);
        bridge.redeemLocal{value: msg.value}(_dstChainId, _srcPoolId, _dstPoolId, _refundAddress, c, amountSD, _to, _lzTxParams);
    }

    function sendCredits(
        uint16 _dstChainId,
        uint _srcPoolId,
        uint _dstPoolId,
        address payable _refundAddress
    ) external payable nonReentrant {
        require(_refundAddress != address(0x0), "Stargate: _refundAddress cannot be 0x0");
        StargatePoolMock pool = _getPool(_srcPoolId);
        StargatePoolMock.CreditObj memory c = pool.sendCredits(_dstChainId, _dstPoolId);
        bridge.sendCredits{value: msg.value}(_dstChainId, _srcPoolId, _dstPoolId, _refundAddress, c);
    }

    function quoteLayerZeroFee(
        uint16 _dstChainId,
        uint8 _functionType,
        bytes calldata _toAddress,
        bytes calldata _transferAndCallPayload,
        StargateRouterMock.lzTxObj memory _lzTxParams
    ) external view returns (uint, uint) {
        return bridge.quoteLayerZeroFee(_dstChainId, _functionType, _toAddress, _transferAndCallPayload, _lzTxParams);
    }

    function revertRedeemLocal(
        uint16 _dstChainId,
        bytes calldata _srcAddress,
        uint _nonce,
        address payable _refundAddress,
        lzTxObj memory _lzTxParams
    ) external payable {
        require(_refundAddress != address(0x0), "Stargate: _refundAddress cannot be 0x0");
        bytes memory payload = revertLookup[_dstChainId][_srcAddress][_nonce];
        require(payload.length > 0, "Stargate: no retry revert");
        {
            uint8 functionType;
            assembly {
                functionType := mload(add(payload, 32))
            }
            require(functionType == TYPE_REDEEM_LOCAL_RESPONSE, "Stargate: invalid function type");
        }

        // empty it
        revertLookup[_dstChainId][_srcAddress][_nonce] = "";

        uint srcPoolId;
        uint dstPoolId;
        assembly {
            srcPoolId := mload(add(payload, 64))
            dstPoolId := mload(add(payload, 96))
        }

        StargatePoolMock.CreditObj memory c;
        {
            StargatePoolMock pool = _getPool(dstPoolId);
            c = pool.sendCredits(_dstChainId, srcPoolId);
        }

        bridge.redeemLocalCallback{value: msg.value}(_dstChainId, _refundAddress, c, _lzTxParams, payload);
    }

    function retryRevert(
        uint16 _srcChainId,
        bytes calldata _srcAddress,
        uint _nonce
    ) external payable {
        bytes memory payload = revertLookup[_srcChainId][_srcAddress][_nonce];
        require(payload.length > 0, "Stargate: no retry revert");

        // empty it
        revertLookup[_srcChainId][_srcAddress][_nonce] = "";

        uint8 functionType;
        assembly {
            functionType := mload(add(payload, 32))
        }

        if (functionType == TYPE_REDEEM_LOCAL_CALLBACK_RETRY) {
            (, uint srcPoolId, uint dstPoolId, address to, uint amountSD, uint mintAmountSD) = abi.decode(payload, (uint8, uint, uint, address, uint, uint));
            _redeemLocalCallback(_srcChainId, _srcAddress, _nonce, srcPoolId, dstPoolId, to, amountSD, mintAmountSD);
        }
        // for retrying the swapRemote. if it fails again, retry
        else if (functionType == TYPE_SWAP_REMOTE_RETRY) {
            (, uint srcPoolId, uint dstPoolId, uint dstGasForCall, address to, StargatePoolMock.SwapObj memory s, bytes memory p) = abi.decode(payload, (uint8, uint, uint, uint, address, StargatePoolMock.SwapObj, bytes));
            _swapRemote(_srcChainId, _srcAddress, _nonce, srcPoolId, dstPoolId, dstGasForCall, to, s, p);
        } else {
            revert("Stargate: invalid function type");
        }
    }

    function clearCachedSwap(
        uint16 _srcChainId,
        bytes calldata _srcAddress,
        uint _nonce
    ) external {
        CachedSwap memory cs = cachedSwapLookup[_srcChainId][_srcAddress][_nonce];
        require(cs.to != address(0x0), "Stargate: cache already cleared");
        // clear the data
        cachedSwapLookup[_srcChainId][_srcAddress][_nonce] = CachedSwap(address(0x0), 0, address(0x0), "");
        IStargateReceiver(cs.to).sgReceive(_srcChainId, _srcAddress, _nonce, cs.token, cs.amountLD, cs.payload);
    }

    function creditChainPath(
        uint16 _dstChainId,
        uint _dstPoolId,
        uint _srcPoolId,
        StargatePoolMock.CreditObj memory _c
    ) external onlyBridge {
        StargatePoolMock pool = _getPool(_srcPoolId);
        pool.creditChainPath(_dstChainId, _dstPoolId, _c);
    }

    //---------------------------------------------------------------------------
    // REMOTE CHAIN FUNCTIONS
    function redeemLocalCheckOnRemote(
        uint16 _srcChainId,
        bytes memory _srcAddress,
        uint _nonce,
        uint _srcPoolId,
        uint _dstPoolId,
        uint _amountSD,
        bytes calldata _to
    ) external onlyBridge {
        StargatePoolMock pool = _getPool(_dstPoolId);
        try pool.redeemLocalCheckOnRemote(_srcChainId, _srcPoolId, _amountSD) returns (uint redeemAmountSD, uint mintAmountSD) {
            revertLookup[_srcChainId][_srcAddress][_nonce] = abi.encode(TYPE_REDEEM_LOCAL_RESPONSE, _srcPoolId, _dstPoolId, redeemAmountSD, mintAmountSD, _to);
            emit RevertRedeemLocal(_srcChainId, _srcPoolId, _dstPoolId, _to, redeemAmountSD, mintAmountSD, _nonce, _srcAddress);
        } catch {
            // if the func fail, return [swapAmount: 0, mintAMount: _amountSD]
            // swapAmount represents the amount of chainPath balance deducted on the remote side, which because the above tx failed, should be 0
            // mintAmount is the full amount of tokens the user attempted to redeem on the src side, which gets converted back into the lp amount
            revertLookup[_srcChainId][_srcAddress][_nonce] = abi.encode(TYPE_REDEEM_LOCAL_RESPONSE, _srcPoolId, _dstPoolId, 0, _amountSD, _to);
            emit Revert(TYPE_REDEEM_LOCAL_RESPONSE, _srcChainId, _srcAddress, _nonce);
        }
    }

    function redeemLocalCallback(
        uint16 _srcChainId,
        bytes memory _srcAddress,
        uint _nonce,
        uint _srcPoolId,
        uint _dstPoolId,
        address _to,
        uint _amountSD,
        uint _mintAmountSD
    ) external onlyBridge {
        _redeemLocalCallback(_srcChainId, _srcAddress, _nonce, _srcPoolId, _dstPoolId, _to, _amountSD, _mintAmountSD);
    }

    function _redeemLocalCallback(
        uint16 _srcChainId,
        bytes memory _srcAddress,
        uint _nonce,
        uint _srcPoolId,
        uint _dstPoolId,
        address _to,
        uint _amountSD,
        uint _mintAmountSD
    ) internal {
        StargatePoolMock pool = _getPool(_dstPoolId);
        try pool.redeemLocalCallback(_srcChainId, _srcPoolId, _to, _amountSD, _mintAmountSD) {} catch {
            revertLookup[_srcChainId][_srcAddress][_nonce] = abi.encode(TYPE_REDEEM_LOCAL_CALLBACK_RETRY, _srcPoolId, _dstPoolId, _to, _amountSD, _mintAmountSD);
            emit Revert(TYPE_REDEEM_LOCAL_CALLBACK_RETRY, _srcChainId, _srcAddress, _nonce);
        }
        emit RedeemLocalCallback(_srcChainId, _srcAddress, _nonce, _srcPoolId, _dstPoolId, _to, _amountSD, _mintAmountSD);
    }

    function swapRemote(
        uint16 _srcChainId,
        bytes memory _srcAddress,
        uint _nonce,
        uint _srcPoolId,
        uint _dstPoolId,
        uint _dstGasForCall,
        address _to,
        StargatePoolMock.SwapObj memory _s,
        bytes memory _payload
    ) external onlyBridge {
        _swapRemote(_srcChainId, _srcAddress, _nonce, _srcPoolId, _dstPoolId, _dstGasForCall, _to, _s, _payload);
    }

    function _swapRemote(
        uint16 _srcChainId,
        bytes memory _srcAddress,
        uint _nonce,
        uint _srcPoolId,
        uint _dstPoolId,
        uint _dstGasForCall,
        address _to,
        StargatePoolMock.SwapObj memory _s,
        bytes memory _payload
    ) internal {
        StargatePoolMock pool = _getPool(_dstPoolId);
        // first try catch the swap remote
        try pool.swapRemote(_srcChainId, _srcPoolId, _to, _s) returns (uint amountLD) {
            if (_payload.length > 0) {
                // then try catch the external contract call
                try IStargateReceiver(_to).sgReceive{gas: _dstGasForCall}(_srcChainId, _srcAddress, _nonce, pool.token(), amountLD, _payload) {
                    // do nothing
                } catch (bytes memory reason) {
                    cachedSwapLookup[_srcChainId][_srcAddress][_nonce] = CachedSwap(pool.token(), amountLD, _to, _payload);
                    emit CachedSwapSaved(_srcChainId, _srcAddress, _nonce, pool.token(), amountLD, _to, _payload, reason);
                }
            }
        } catch {
            revertLookup[_srcChainId][_srcAddress][_nonce] = abi.encode(TYPE_SWAP_REMOTE_RETRY, _srcPoolId, _dstPoolId, _dstGasForCall, _to, _s, _payload);
            emit Revert(TYPE_SWAP_REMOTE_RETRY, _srcChainId, _srcAddress, _nonce);
        }
    }

    //---------------------------------------------------------------------------
    // DAO Calls
    function createPool(
        uint _poolId,
        address _token,
        uint8 _sharedDecimals,
        uint8 _localDecimals,
        string memory _name,
        string memory _symbol
    ) external onlyOwner returns (address) {
        require(_token != address(0x0), "Stargate: _token cannot be 0x0");
        return factory.createPool(_poolId, _token, _sharedDecimals, _localDecimals, _name, _symbol);
    }

    function createChainPath(
        uint _poolId,
        uint16 _dstChainId,
        uint _dstPoolId,
        uint _weight
    ) external onlyOwner {
        StargatePoolMock pool = _getPool(_poolId);
        pool.createChainPath(_dstChainId, _dstPoolId, _weight);
    }

    function activateChainPath(
        uint _poolId,
        uint16 _dstChainId,
        uint _dstPoolId
    ) external onlyOwner {
        StargatePoolMock pool = _getPool(_poolId);
        pool.activateChainPath(_dstChainId, _dstPoolId);
    }

    function setWeightForChainPath(
        uint _poolId,
        uint16 _dstChainId,
        uint _dstPoolId,
        uint16 _weight
    ) external onlyOwner {
        StargatePoolMock pool = _getPool(_poolId);
        pool.setWeightForChainPath(_dstChainId, _dstPoolId, _weight);
    }

    function setProtocolFeeOwner(address _owner) external onlyOwner {
        require(_owner != address(0x0), "Stargate: _owner cannot be 0x0");
        protocolFeeOwner = _owner;
    }

    function setMintFeeOwner(address _owner) external onlyOwner {
        require(_owner != address(0x0), "Stargate: _owner cannot be 0x0");
        mintFeeOwner = _owner;
    }

    function setFees(uint _poolId, uint _mintFeeBP) external onlyOwner {
        StargatePoolMock pool = _getPool(_poolId);
        pool.setFee(_mintFeeBP);
    }

    function setFeeLibrary(uint _poolId, address _feeLibraryAddr) external onlyOwner {
        StargatePoolMock pool = _getPool(_poolId);
        pool.setFeeLibrary(_feeLibraryAddr);
    }

    function setSwapStop(uint _poolId, bool _swapStop) external onlyOwner {
        StargatePoolMock pool = _getPool(_poolId);
        pool.setSwapStop(_swapStop);
    }

    function setDeltaParam(
        uint _poolId,
        bool _batched,
        uint _swapDeltaBP,
        uint _lpDeltaBP,
        bool _defaultSwapMode,
        bool _defaultLPMode
    ) external onlyOwner {
        StargatePoolMock pool = _getPool(_poolId);
        pool.setDeltaParam(_batched, _swapDeltaBP, _lpDeltaBP, _defaultSwapMode, _defaultLPMode);
    }

    function callDelta(uint _poolId, bool _fullMode) external {
        StargatePoolMock pool = _getPool(_poolId);
        pool.callDelta(_fullMode);
    }

    function withdrawMintFee(uint _poolId, address _to) external {
        require(mintFeeOwner == msg.sender, "Stargate: only mintFeeOwner");
        StargatePoolMock pool = _getPool(_poolId);
        pool.withdrawMintFeeBalance(_to);
    }

    function withdrawProtocolFee(uint _poolId, address _to) external {
        require(protocolFeeOwner == msg.sender, "Stargate: only protocolFeeOwner");
        StargatePoolMock pool = _getPool(_poolId);
        pool.withdrawProtocolFeeBalance(_to);
    }
}
