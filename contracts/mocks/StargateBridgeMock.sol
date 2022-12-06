// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;
pragma abicoder v2;

// imports
import "@openzeppelin/contracts/access/Ownable.sol";

import "./StargatePoolMock.sol";
import "./StargateRouterMock.sol";

// libraries
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "../interfaces/ILayerZeroReceiver.sol";
import "../interfaces/ILayerZeroEndpoint.sol";
import "../interfaces/ILayerZeroUserApplicationConfig.sol";

contract StargateBridgeMock is Ownable, ILayerZeroReceiver, ILayerZeroUserApplicationConfig {
    using SafeMath for uint;

    //---------------------------------------------------------------------------
    // CONSTANTS
    uint8 internal constant TYPE_SWAP_REMOTE = 1;
    uint8 internal constant TYPE_ADD_LIQUIDITY = 2;
    uint8 internal constant TYPE_REDEEM_LOCAL_CALL_BACK = 3;
    uint8 internal constant TYPE_WITHDRAW_REMOTE = 4;

    //---------------------------------------------------------------------------
    // VARIABLES
    ILayerZeroEndpoint public immutable layerZeroEndpoint;
    mapping(uint16 => bytes) public bridgeLookup;
    mapping(uint16 => mapping(uint8 => uint)) public gasLookup;
    StargateRouterMock public immutable router;
    bool public useLayerZeroToken;

    //---------------------------------------------------------------------------
    // EVENTS
    event SendMsg(uint8 msgType, uint64 nonce);

    //---------------------------------------------------------------------------
    // MODIFIERS
    modifier onlyRouter() {
        require(msg.sender == address(router), "Stargate: caller must be Router.");
        _;
    }

    constructor(address _layerZeroEndpoint, address _router) {
        require(_layerZeroEndpoint != address(0x0), "Stargate: _layerZeroEndpoint cannot be 0x0");
        require(_router != address(0x0), "Stargate: _router cannot be 0x0");
        layerZeroEndpoint = ILayerZeroEndpoint(_layerZeroEndpoint);
        router = StargateRouterMock(_router);
    }

    //---------------------------------------------------------------------------
    // EXTERNAL functions

    function lzReceive(
        uint16 _srcChainId,
        bytes memory _srcAddress,
        uint64 _nonce,
        bytes memory _payload
    ) external override {
        require(msg.sender == address(layerZeroEndpoint), "Stargate: only LayerZero endpoint can call lzReceive");
        require(_srcAddress.length == bridgeLookup[_srcChainId].length && keccak256(_srcAddress) == keccak256(bridgeLookup[_srcChainId]), "Stargate: bridge does not match");

        uint8 functionType;
        assembly {
            functionType := mload(add(_payload, 32))
        }

        if (functionType == TYPE_SWAP_REMOTE) {
            (, uint srcPoolId, uint dstPoolId, uint dstGasForCall, StargatePoolMock.CreditObj memory c, StargatePoolMock.SwapObj memory s, bytes memory to, bytes memory payload) = abi.decode(_payload, (uint8, uint, uint, uint, StargatePoolMock.CreditObj, StargatePoolMock.SwapObj, bytes, bytes));
            address toAddress;
            assembly {
                toAddress := mload(add(to, 20))
            }
            router.creditChainPath(_srcChainId, srcPoolId, dstPoolId, c);
            router.swapRemote(_srcChainId, _srcAddress, _nonce, srcPoolId, dstPoolId, dstGasForCall, toAddress, s, payload);
        } else if (functionType == TYPE_ADD_LIQUIDITY) {
            (, uint srcPoolId, uint dstPoolId, StargatePoolMock.CreditObj memory c) = abi.decode(_payload, (uint8, uint, uint, StargatePoolMock.CreditObj));
            router.creditChainPath(_srcChainId, srcPoolId, dstPoolId, c);
        } else if (functionType == TYPE_REDEEM_LOCAL_CALL_BACK) {
            (, uint srcPoolId, uint dstPoolId, StargatePoolMock.CreditObj memory c, uint amountSD, uint mintAmountSD, bytes memory to) = abi.decode(_payload, (uint8, uint, uint, StargatePoolMock.CreditObj, uint, uint, bytes));
            address toAddress;
            assembly {
                toAddress := mload(add(to, 20))
            }
            router.creditChainPath(_srcChainId, srcPoolId, dstPoolId, c);
            router.redeemLocalCallback(_srcChainId, _srcAddress, _nonce, srcPoolId, dstPoolId, toAddress, amountSD, mintAmountSD);
        } else if (functionType == TYPE_WITHDRAW_REMOTE) {
            (, uint srcPoolId, uint dstPoolId, StargatePoolMock.CreditObj memory c, uint amountSD, bytes memory to) = abi.decode(_payload, (uint8, uint, uint, StargatePoolMock.CreditObj, uint, bytes));
            router.creditChainPath(_srcChainId, srcPoolId, dstPoolId, c);
            router.redeemLocalCheckOnRemote(_srcChainId, _srcAddress, _nonce, srcPoolId, dstPoolId, amountSD, to);
        }
    }

    //---------------------------------------------------------------------------
    // LOCAL CHAIN FUNCTIONS
    function swap(
        uint16 _chainId,
        uint _srcPoolId,
        uint _dstPoolId,
        address payable _refundAddress,
        StargatePoolMock.CreditObj memory _c,
        StargatePoolMock.SwapObj memory _s,
        IStargateRouter.lzTxObj memory _lzTxParams,
        bytes calldata _to,
        bytes calldata _payload
    ) external payable onlyRouter {
        bytes memory payload = abi.encode(TYPE_SWAP_REMOTE, _srcPoolId, _dstPoolId, _lzTxParams.dstGasForCall, _c, _s, _to, _payload);
        _call(_chainId, TYPE_SWAP_REMOTE, _refundAddress, _lzTxParams, payload);
    }

    function redeemLocalCallback(
        uint16 _chainId,
        address payable _refundAddress,
        StargatePoolMock.CreditObj memory _c,
        IStargateRouter.lzTxObj memory _lzTxParams,
        bytes memory _payload
    ) external payable onlyRouter {
        bytes memory payload;

        {
            (, uint srcPoolId, uint dstPoolId, uint amountSD, uint mintAmountSD, bytes memory to) = abi.decode(_payload, (uint8, uint, uint, uint, uint, bytes));

            // swap dst and src because we are headed back
            payload = abi.encode(TYPE_REDEEM_LOCAL_CALL_BACK, dstPoolId, srcPoolId, _c, amountSD, mintAmountSD, to);
        }

        _call(_chainId, TYPE_REDEEM_LOCAL_CALL_BACK, _refundAddress, _lzTxParams, payload);
    }

    function redeemLocal(
        uint16 _chainId,
        uint _srcPoolId,
        uint _dstPoolId,
        address payable _refundAddress,
        StargatePoolMock.CreditObj memory _c,
        uint _amountSD,
        bytes calldata _to,
        IStargateRouter.lzTxObj memory _lzTxParams
    ) external payable onlyRouter {
        bytes memory payload = abi.encode(TYPE_WITHDRAW_REMOTE, _srcPoolId, _dstPoolId, _c, _amountSD, _to);
        _call(_chainId, TYPE_WITHDRAW_REMOTE, _refundAddress, _lzTxParams, payload);
    }

    function sendCredits(
        uint16 _chainId,
        uint _srcPoolId,
        uint _dstPoolId,
        address payable _refundAddress,
        StargatePoolMock.CreditObj memory _c
    ) external payable onlyRouter {
        bytes memory payload = abi.encode(TYPE_ADD_LIQUIDITY, _srcPoolId, _dstPoolId, _c);
        IStargateRouter.lzTxObj memory lzTxObj = IStargateRouter.lzTxObj(0, 0, "0x");
        _call(_chainId, TYPE_ADD_LIQUIDITY, _refundAddress, lzTxObj, payload);
    }

    function quoteLayerZeroFee(
        uint16 _chainId,
        uint8 _functionType,
        bytes calldata _toAddress,
        bytes calldata _transferAndCallPayload,
        IStargateRouter.lzTxObj memory _lzTxParams
    ) external view returns (uint, uint) {
        bytes memory payload = "";
        StargatePoolMock.CreditObj memory c = StargatePoolMock.CreditObj(1, 1);
        if (_functionType == TYPE_SWAP_REMOTE) {
            StargatePoolMock.SwapObj memory s = StargatePoolMock.SwapObj(1, 1, 1, 1, 1, 1);
            payload = abi.encode(TYPE_SWAP_REMOTE, 0, 0, 0, c, s, _toAddress, _transferAndCallPayload);
        } else if (_functionType == TYPE_ADD_LIQUIDITY) {
            payload = abi.encode(TYPE_ADD_LIQUIDITY, 0, 0, c);
        } else if (_functionType == TYPE_REDEEM_LOCAL_CALL_BACK) {
            payload = abi.encode(TYPE_REDEEM_LOCAL_CALL_BACK, 0, 0, c, 0, 0, _toAddress);
        } else if (_functionType == TYPE_WITHDRAW_REMOTE) {
            payload = abi.encode(TYPE_WITHDRAW_REMOTE, 0, 0, c, 0, _toAddress);
        } else {
            revert("Stargate: unsupported function type");
        }

        bytes memory lzTxParamBuilt = _txParamBuilder(_chainId, _functionType, _lzTxParams);
        return layerZeroEndpoint.estimateFees(_chainId, address(this), payload, useLayerZeroToken, lzTxParamBuilt);
    }

    //---------------------------------------------------------------------------
    // dao functions
    function setBridge(uint16 _chainId, bytes calldata _bridgeAddress) external onlyOwner {
        require(bridgeLookup[_chainId].length == 0, "Stargate: Bridge already set!");
        bridgeLookup[_chainId] = _bridgeAddress;
    }

    function setGasAmount(
        uint16 _chainId,
        uint8 _functionType,
        uint _gasAmount
    ) external onlyOwner {
        require(_functionType >= 1 && _functionType <= 4, "Stargate: invalid _functionType");
        gasLookup[_chainId][_functionType] = _gasAmount;
    }

    function approveTokenSpender(
        address token,
        address spender,
        uint amount
    ) external onlyOwner {
        IERC20(token).approve(spender, amount);
    }

    function setUseLayerZeroToken(bool enable) external onlyOwner {
        useLayerZeroToken = enable;
    }

    function forceResumeReceive(uint16 _srcChainId, bytes calldata _srcAddress) external override onlyOwner {
        layerZeroEndpoint.forceResumeReceive(_srcChainId, _srcAddress);
    }

    //---------------------------------------------------------------------------
    // generic config for user Application
    function setConfig(
        uint16 _version,
        uint16 _chainId,
        uint _configType,
        bytes calldata _config
    ) external override onlyOwner {
        layerZeroEndpoint.setConfig(_version, _chainId, _configType, _config);
    }

    function setSendVersion(uint16 version) external override onlyOwner {
        layerZeroEndpoint.setSendVersion(version);
    }

    function setReceiveVersion(uint16 version) external override onlyOwner {
        layerZeroEndpoint.setReceiveVersion(version);
    }

    //---------------------------------------------------------------------------
    // INTERNAL functions
    function txParamBuilderType1(uint _gasAmount) internal pure returns (bytes memory) {
        uint16 txType = 1;
        return abi.encodePacked(txType, _gasAmount);
    }

    function txParamBuilderType2(
        uint _gasAmount,
        uint _dstNativeAmount,
        bytes memory _dstNativeAddr
    ) internal pure returns (bytes memory) {
        uint16 txType = 2;
        return abi.encodePacked(txType, _gasAmount, _dstNativeAmount, _dstNativeAddr);
    }

    function _txParamBuilder(
        uint16 _chainId,
        uint8 _type,
        IStargateRouter.lzTxObj memory _lzTxParams
    ) internal view returns (bytes memory) {
        bytes memory lzTxParam;
        address dstNativeAddr;
        {
            bytes memory dstNativeAddrBytes = _lzTxParams.dstNativeAddr;
            assembly {
                dstNativeAddr := mload(add(dstNativeAddrBytes, 20))
            }
        }

        uint totalGas = gasLookup[_chainId][_type].add(_lzTxParams.dstGasForCall);
        if (_lzTxParams.dstNativeAmount > 0 && dstNativeAddr != address(0x0)) {
            lzTxParam = txParamBuilderType2(totalGas, _lzTxParams.dstNativeAmount, _lzTxParams.dstNativeAddr);
        } else {
            lzTxParam = txParamBuilderType1(totalGas);
        }

        return lzTxParam;
    }

    function _call(
        uint16 _chainId,
        uint8 _type,
        address payable _refundAddress,
        IStargateRouter.lzTxObj memory _lzTxParams,
        bytes memory _payload
    ) internal {
        bytes memory lzTxParamBuilt = _txParamBuilder(_chainId, _type, _lzTxParams);
        uint64 nextNonce = layerZeroEndpoint.getOutboundNonce(_chainId, address(this)) + 1;
        layerZeroEndpoint.send{value: msg.value}(_chainId, bridgeLookup[_chainId], _payload, _refundAddress, address(this), lzTxParamBuilt);
        emit SendMsg(_type, nextNonce);
    }

    function renounceOwnership() public override onlyOwner {}
}
