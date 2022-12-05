// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

interface ILiquidityAggregator {
    struct Payload {
        uint amount;
        uint permitNonce;
        uint deadline;
        bytes signature;
    }

    function aggregate(
        uint16[] calldata _dstChainIds,
        uint[] calldata _amounts,
        uint[] calldata _permitNonces,
        uint[] calldata _deadlines,
        bytes[] calldata signatures
    ) external payable;
}
