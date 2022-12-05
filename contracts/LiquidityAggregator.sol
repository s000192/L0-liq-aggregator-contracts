// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import "./NonblockingLzApp.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/ILiquidityAggregator.sol";
import "./interfaces/IPermit2.sol";
import "./interfaces/IStargateRouter.sol";

contract LiquidityAggregator is NonblockingLzApp, ILiquidityAggregator {
    // TODO: Hardcoded for now. Make this generic for different kinds of tokens
    IERC20 public immutable TOKEN;
    IPermit2 public immutable PERMIT2;
    IStargateRouter public immutable STARGATE_ROUTER;
    uint public immutable SRC_POOL_ID;
    uint public immutable DST_POOL_ID;

    constructor(
        address _lzEndpoint,
        IERC20 _token,
        IPermit2 _permit2,
        IStargateRouter _stargateRouter,
        uint _srcPoolId,
        uint _dstPoolId
    ) NonblockingLzApp(_lzEndpoint) {
        TOKEN = _token;
        PERMIT2 = _permit2;
        STARGATE_ROUTER = _stargateRouter;
        SRC_POOL_ID = _srcPoolId;
        DST_POOL_ID = _dstPoolId;
    }

    function aggregate(
        uint16[] calldata _dstChainIds,
        uint[] calldata _amounts,
        uint[] calldata _permitNonces,
        uint[] calldata _deadlines,
        bytes[] calldata signatures
    ) external payable override {
        uint length = _dstChainIds.length;
        // check if the array length of all parameters are the same
        require(length == _amounts.length && length == _permitNonces.length && length == _deadlines.length && length == signatures.length, "Length mismatch");

        // loop through destination chains
        for (uint i = 0; i < length; ) {
            // encode the payload with above params
            bytes memory payload = abi.encode(Payload(_amounts[i], _permitNonces[i], _deadlines[i], signatures[i]));

            // send payload to destination chain
            _lzSend(_dstChainIds[i], payload, payable(msg.sender), address(0x0), bytes(""), msg.value);

            unchecked {
                ++i;
            }
        }
    }

    function _nonblockingLzReceive(
        uint16 _srcChainId,
        bytes memory _srcAddress,
        uint64, // nonce for L0
        bytes memory _payload
    ) internal override {
        // decode payload
        Payload memory payload = abi.decode(_payload, (Payload));

        if (payload.amount > 0) {
            // use assembly to extract the address from the bytes memory parameter
            address _owner;
            assembly {
                _owner := mload(add(_srcAddress, 20))
            }

            // TODO: Improve readability
            PERMIT2.permitTransferFrom(IPermit2.PermitTransferFrom(IPermit2.TokenPermissions(TOKEN, payload.amount), payload.permitNonce, payload.deadline), IPermit2.SignatureTransferDetails(address(STARGATE_ROUTER), payload.amount), _owner, payload.signature);

            // call stargate swap
            _executeStargateSwap(_srcChainId, _srcAddress, payload.amount, _owner);
        }
    }

    function _executeStargateSwap(
        uint16 _srcChainId,
        bytes memory _srcAddress,
        uint _amount,
        address _owner
    ) private {
        STARGATE_ROUTER.swap{value: msg.value}( // TODO: check if we need msg.value
            _srcChainId,
            SRC_POOL_ID,
            DST_POOL_ID,
            payable(_owner),
            _amount,
            _amount, // TODO: Setting min amount the same as amonut.  Should include a min amount in message.
            IStargateRouter.lzTxObj(0, 0, "0x"), // TODO: Check if this is generic.
            _srcAddress,
            bytes("")
        );
    }
}
