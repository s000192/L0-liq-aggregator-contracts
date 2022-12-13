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
    IStargateRouter public immutable STARGATE_ROUTER;
    // Permit2 is deployed at the same address on all chains
    address public constant PERMIT2_ADDRESS = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint public constant POOL_ID = 1;

    constructor(
        address _lzEndpoint,
        IERC20 _token,
        IStargateRouter _stargateRouter
    ) NonblockingLzApp(_lzEndpoint) {
        TOKEN = _token;
        STARGATE_ROUTER = _stargateRouter;
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

        // TODO: need a better way to divide msg.value
        uint valueToBeSent = msg.value / length;
        // loop through destination chains
        for (uint i = 0; i < length; ) {
            // encode the payload with above params
            bytes memory payload = abi.encode(Payload(_amounts[i], _permitNonces[i], _deadlines[i], signatures[i]));

            // send payload to destination chain
            _lzSend(_dstChainIds[i], payload, payable(msg.sender), address(0x0), bytes(""), valueToBeSent);

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
            IPermit2(PERMIT2_ADDRESS).permitTransferFrom(IPermit2.PermitTransferFrom(IPermit2.TokenPermissions(TOKEN, payload.amount), payload.permitNonce, payload.deadline), IPermit2.SignatureTransferDetails(address(STARGATE_ROUTER), payload.amount), _owner, payload.signature);

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
            POOL_ID,
            POOL_ID,
            payable(_owner),
            _amount,
            _amount, // TODO: Setting min amount the same as amonut.  Should include a min amount in message.
            IStargateRouter.lzTxObj(0, 0, "0x"), // TODO: Check if this is generic.
            _srcAddress,
            bytes("")
        );
    }
}
