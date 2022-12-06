// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;
pragma abicoder v2;
import "../mocks/StargatePoolMock.sol";

interface IStargateFeeLibrary {
    function getFees(
        uint _srcPoolId,
        uint _dstPoolId,
        uint16 _dstChainId,
        address _from,
        uint _amountSD
    ) external returns (StargatePoolMock.SwapObj memory s);

    function getVersion() external view returns (string memory);
}
