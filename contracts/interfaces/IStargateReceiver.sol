// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

interface IStargateReceiver {
    function sgReceive(
        uint16 _chainId,
        bytes memory _srcAddress,
        uint _nonce,
        address _token,
        uint amountLD,
        bytes memory payload
    ) external;
}
