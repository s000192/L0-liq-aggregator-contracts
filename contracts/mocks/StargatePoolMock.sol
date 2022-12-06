// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;
pragma abicoder v2;

// imports
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./LPTokenERC20Mock.sol";
import "../interfaces/IStargateFeeLibrary.sol";

// libraries
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

/// Pool contracts on other chains and managed by the Stargate protocol.
contract StargatePoolMock is LPTokenERC20Mock, ReentrancyGuard {
    using SafeMath for uint;

    //---------------------------------------------------------------------------
    // CONSTANTS
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes("transfer(address,uint256)")));
    uint public constant BP_DENOMINATOR = 10000;

    //---------------------------------------------------------------------------
    // STRUCTS
    struct ChainPath {
        bool ready; // indicate if the counter chainPath has been created.
        uint16 dstChainId;
        uint dstPoolId;
        uint weight;
        uint balance;
        uint lkb;
        uint credits;
        uint idealBalance;
    }

    struct SwapObj {
        uint amount;
        uint eqFee;
        uint eqReward;
        uint lpFee;
        uint protocolFee;
        uint lkbRemove;
    }

    struct CreditObj {
        uint credits;
        uint idealBalance;
    }

    //---------------------------------------------------------------------------
    // VARIABLES

    // chainPath
    ChainPath[] public chainPaths; // list of connected chains with shared pools
    mapping(uint16 => mapping(uint => uint)) public chainPathIndexLookup; // lookup for chainPath by chainId => poolId =>index

    // metadata
    uint public immutable poolId; // shared id between chains to represent same pool
    uint public sharedDecimals; // the shared decimals (lowest common decimals between chains)
    uint public localDecimals; // the decimals for the token
    uint public immutable convertRate; // the decimals for the token
    address public immutable token; // the token for the pool
    address public immutable router; // the token for the pool

    bool public stopSwap; // flag to stop swapping in extreme cases

    // Fee and Liquidity
    uint public totalLiquidity; // the total amount of tokens added on this side of the chain (fees + deposits - withdrawals)
    uint public totalWeight; // total weight for pool percentages
    uint public mintFeeBP; // fee basis points for the mint/deposit
    uint public protocolFeeBalance; // fee balance created from dao fee
    uint public mintFeeBalance; // fee balance created from mint fee
    uint public eqFeePool; // pool rewards in Shared Decimal format. indicate the total budget for reverse swap incentive
    address public feeLibrary; // address for retrieving fee params for swaps

    // Delta related
    uint public deltaCredit; // credits accumulated from txn
    bool public batched; // flag to indicate if we want batch processing.
    bool public defaultSwapMode; // flag for the default mode for swap
    bool public defaultLPMode; // flag for the default mode for lp
    uint public swapDeltaBP; // basis points of poolCredits to activate Delta in swap
    uint public lpDeltaBP; // basis points of poolCredits to activate Delta in liquidity events

    //---------------------------------------------------------------------------
    // EVENTS
    event Mint(address to, uint amountLP, uint amountSD, uint mintFeeAmountSD);
    event Burn(address from, uint amountLP, uint amountSD);
    event RedeemLocalCallback(address _to, uint _amountSD, uint _amountToMintSD);
    event Swap(uint16 chainId, uint dstPoolId, address from, uint amountSD, uint eqReward, uint eqFee, uint protocolFee, uint lpFee);
    event SendCredits(uint16 dstChainId, uint dstPoolId, uint credits, uint idealBalance);
    event RedeemRemote(uint16 chainId, uint dstPoolId, address from, uint amountLP, uint amountSD);
    event RedeemLocal(address from, uint amountLP, uint amountSD, uint16 chainId, uint dstPoolId, bytes to);
    event InstantRedeemLocal(address from, uint amountLP, uint amountSD, address to);
    event CreditChainPath(uint16 chainId, uint srcPoolId, uint amountSD, uint idealBalance);
    event SwapRemote(address to, uint amountSD, uint protocolFee, uint dstFee);
    event WithdrawRemote(uint16 srcChainId, uint srcPoolId, uint swapAmount, uint mintAmount);
    event ChainPathUpdate(uint16 dstChainId, uint dstPoolId, uint weight);
    event FeesUpdated(uint mintFeeBP);
    event FeeLibraryUpdated(address feeLibraryAddr);
    event StopSwapUpdated(bool swapStop);
    event WithdrawProtocolFeeBalance(address to, uint amountSD);
    event WithdrawMintFeeBalance(address to, uint amountSD);
    event DeltaParamUpdated(bool batched, uint swapDeltaBP, uint lpDeltaBP, bool defaultSwapMode, bool defaultLPMode);

    //---------------------------------------------------------------------------
    // MODIFIERS
    modifier onlyRouter() {
        require(msg.sender == router, "Stargate: only the router can call this method");
        _;
    }

    constructor(
        uint _poolId,
        address _router,
        address _token,
        uint _sharedDecimals,
        uint _localDecimals,
        address _feeLibrary,
        string memory _name,
        string memory _symbol
    ) LPTokenERC20Mock(_name, _symbol) {
        require(_token != address(0x0), "Stargate: _token cannot be 0x0");
        require(_router != address(0x0), "Stargate: _router cannot be 0x0");
        poolId = _poolId;
        router = _router;
        token = _token;
        sharedDecimals = _sharedDecimals;
        decimals = uint8(_sharedDecimals);
        localDecimals = _localDecimals;
        convertRate = 10**(uint(localDecimals).sub(sharedDecimals));
        totalWeight = 0;
        feeLibrary = _feeLibrary;

        //delta algo related
        batched = false;
        defaultSwapMode = true;
        defaultLPMode = true;
    }

    function getChainPathsLength() public view returns (uint) {
        return chainPaths.length;
    }

    //---------------------------------------------------------------------------
    // LOCAL CHAIN FUNCTIONS

    function mint(address _to, uint _amountLD) external nonReentrant onlyRouter returns (uint) {
        return _mintLocal(_to, _amountLD, true, true);
    }

    // Local                                    Remote
    // -------                                  ---------
    // swap             ->                      swapRemote
    function swap(
        uint16 _dstChainId,
        uint _dstPoolId,
        address _from,
        uint _amountLD,
        uint _minAmountLD,
        bool newLiquidity
    ) external nonReentrant onlyRouter returns (SwapObj memory) {
        require(!stopSwap, "Stargate: swap func stopped");
        ChainPath storage cp = getAndCheckCP(_dstChainId, _dstPoolId);
        require(cp.ready == true, "Stargate: counter chainPath is not ready");

        uint amountSD = amountLDtoSD(_amountLD);
        uint minAmountSD = amountLDtoSD(_minAmountLD);

        // request fee params from library
        SwapObj memory s = IStargateFeeLibrary(feeLibrary).getFees(poolId, _dstPoolId, _dstChainId, _from, amountSD);

        // equilibrium fee and reward. note eqFee/eqReward are separated from swap liquidity
        eqFeePool = eqFeePool.sub(s.eqReward);
        // update the new amount the user gets minus the fees
        s.amount = amountSD.sub(s.eqFee).sub(s.protocolFee).sub(s.lpFee);
        // users will also get the eqReward
        require(s.amount.add(s.eqReward) >= minAmountSD, "Stargate: slippage too high");

        // behaviours
        //     - protocolFee: booked, stayed and withdrawn at remote.
        //     - eqFee: booked, stayed and withdrawn at remote.
        //     - lpFee: booked and stayed at remote, can be withdrawn anywhere

        s.lkbRemove = amountSD.sub(s.lpFee).add(s.eqReward);
        // check for transfer solvency.
        require(cp.balance >= s.lkbRemove, "Stargate: dst balance too low");
        cp.balance = cp.balance.sub(s.lkbRemove);

        if (newLiquidity) {
            deltaCredit = deltaCredit.add(amountSD).add(s.eqReward);
        } else if (s.eqReward > 0) {
            deltaCredit = deltaCredit.add(s.eqReward);
        }

        // distribute credits on condition.
        if (!batched || deltaCredit >= totalLiquidity.mul(swapDeltaBP).div(BP_DENOMINATOR)) {
            _delta(defaultSwapMode);
        }

        emit Swap(_dstChainId, _dstPoolId, _from, s.amount, s.eqReward, s.eqFee, s.protocolFee, s.lpFee);
        return s;
    }

    // Local                                    Remote
    // -------                                  ---------
    // sendCredits      ->                      creditChainPath
    function sendCredits(uint16 _dstChainId, uint _dstPoolId) external nonReentrant onlyRouter returns (CreditObj memory c) {
        ChainPath storage cp = getAndCheckCP(_dstChainId, _dstPoolId);
        require(cp.ready == true, "Stargate: counter chainPath is not ready");
        cp.lkb = cp.lkb.add(cp.credits);
        c.idealBalance = totalLiquidity.mul(cp.weight).div(totalWeight);
        c.credits = cp.credits;
        cp.credits = 0;
        emit SendCredits(_dstChainId, _dstPoolId, c.credits, c.idealBalance);
    }

    // Local                                    Remote
    // -------                                  ---------
    // redeemRemote   ->                        swapRemote
    function redeemRemote(
        uint16 _dstChainId,
        uint _dstPoolId,
        address _from,
        uint _amountLP
    ) external nonReentrant onlyRouter {
        require(_from != address(0x0), "Stargate: _from cannot be 0x0");
        uint amountSD = _burnLocal(_from, _amountLP);
        //run Delta
        if (!batched || deltaCredit > totalLiquidity.mul(lpDeltaBP).div(BP_DENOMINATOR)) {
            _delta(defaultLPMode);
        }
        uint amountLD = amountSDtoLD(amountSD);
        emit RedeemRemote(_dstChainId, _dstPoolId, _from, _amountLP, amountLD);
    }

    function instantRedeemLocal(
        address _from,
        uint _amountLP,
        address _to
    ) external nonReentrant onlyRouter returns (uint amountSD) {
        require(_from != address(0x0), "Stargate: _from cannot be 0x0");
        uint _deltaCredit = deltaCredit; // sload optimization.
        uint _capAmountLP = _amountSDtoLP(_deltaCredit);

        if (_amountLP > _capAmountLP) _amountLP = _capAmountLP;

        amountSD = _burnLocal(_from, _amountLP);
        deltaCredit = _deltaCredit.sub(amountSD);
        uint amountLD = amountSDtoLD(amountSD);
        _safeTransfer(token, _to, amountLD);
        emit InstantRedeemLocal(_from, _amountLP, amountSD, _to);
    }

    // Local                                    Remote
    // -------                                  ---------
    // redeemLocal   ->                         redeemLocalCheckOnRemote
    // redeemLocalCallback             <-
    function redeemLocal(
        address _from,
        uint _amountLP,
        uint16 _dstChainId,
        uint _dstPoolId,
        bytes calldata _to
    ) external nonReentrant onlyRouter returns (uint amountSD) {
        require(_from != address(0x0), "Stargate: _from cannot be 0x0");

        // safeguard.
        require(chainPaths[chainPathIndexLookup[_dstChainId][_dstPoolId]].ready == true, "Stargate: counter chainPath is not ready");
        amountSD = _burnLocal(_from, _amountLP);

        // run Delta
        if (!batched || deltaCredit > totalLiquidity.mul(lpDeltaBP).div(BP_DENOMINATOR)) {
            _delta(false);
        }
        emit RedeemLocal(_from, _amountLP, amountSD, _dstChainId, _dstPoolId, _to);
    }

    //---------------------------------------------------------------------------
    // REMOTE CHAIN FUNCTIONS

    // Local                                    Remote
    // -------                                  ---------
    // sendCredits      ->                      creditChainPath
    function creditChainPath(
        uint16 _dstChainId,
        uint _dstPoolId,
        CreditObj memory _c
    ) external nonReentrant onlyRouter {
        ChainPath storage cp = chainPaths[chainPathIndexLookup[_dstChainId][_dstPoolId]];
        cp.balance = cp.balance.add(_c.credits);
        if (cp.idealBalance != _c.idealBalance) {
            cp.idealBalance = _c.idealBalance;
        }
        emit CreditChainPath(_dstChainId, _dstPoolId, _c.credits, _c.idealBalance);
    }

    // Local                                    Remote
    // -------                                  ---------
    // swap             ->                      swapRemote
    function swapRemote(
        uint16 _srcChainId,
        uint _srcPoolId,
        address _to,
        SwapObj memory _s
    ) external nonReentrant onlyRouter returns (uint amountLD) {
        // booking lpFee
        totalLiquidity = totalLiquidity.add(_s.lpFee);
        // booking eqFee
        eqFeePool = eqFeePool.add(_s.eqFee);
        // booking stargateFee
        protocolFeeBalance = protocolFeeBalance.add(_s.protocolFee);

        // update LKB
        uint chainPathIndex = chainPathIndexLookup[_srcChainId][_srcPoolId];
        chainPaths[chainPathIndex].lkb = chainPaths[chainPathIndex].lkb.sub(_s.lkbRemove);

        // user receives the amount + the srcReward
        amountLD = amountSDtoLD(_s.amount.add(_s.eqReward));
        _safeTransfer(token, _to, amountLD);
        emit SwapRemote(_to, _s.amount.add(_s.eqReward), _s.protocolFee, _s.eqFee);
    }

    // Local                                    Remote
    // -------                                  ---------
    // redeemLocal   ->                         redeemLocalCheckOnRemote
    // redeemLocalCallback             <-
    function redeemLocalCallback(
        uint16 _srcChainId,
        uint _srcPoolId,
        address _to,
        uint _amountSD,
        uint _amountToMintSD
    ) external nonReentrant onlyRouter {
        if (_amountToMintSD > 0) {
            _mintLocal(_to, amountSDtoLD(_amountToMintSD), false, false);
        }

        ChainPath storage cp = getAndCheckCP(_srcChainId, _srcPoolId);
        cp.lkb = cp.lkb.sub(_amountSD);

        uint amountLD = amountSDtoLD(_amountSD);
        _safeTransfer(token, _to, amountLD);
        emit RedeemLocalCallback(_to, _amountSD, _amountToMintSD);
    }

    // Local                                    Remote
    // -------                                  ---------
    // redeemLocal(amount)   ->               redeemLocalCheckOnRemote
    // redeemLocalCallback             <-
    function redeemLocalCheckOnRemote(
        uint16 _srcChainId,
        uint _srcPoolId,
        uint _amountSD
    ) external nonReentrant onlyRouter returns (uint swapAmount, uint mintAmount) {
        ChainPath storage cp = getAndCheckCP(_srcChainId, _srcPoolId);
        if (_amountSD > cp.balance) {
            mintAmount = _amountSD - cp.balance;
            swapAmount = cp.balance;
            cp.balance = 0;
        } else {
            cp.balance = cp.balance.sub(_amountSD);
            swapAmount = _amountSD;
            mintAmount = 0;
        }
        emit WithdrawRemote(_srcChainId, _srcPoolId, swapAmount, mintAmount);
    }

    //---------------------------------------------------------------------------
    // DAO Calls
    function createChainPath(
        uint16 _dstChainId,
        uint _dstPoolId,
        uint _weight
    ) external onlyRouter {
        for (uint i = 0; i < chainPaths.length; ++i) {
            ChainPath memory cp = chainPaths[i];
            bool exists = cp.dstChainId == _dstChainId && cp.dstPoolId == _dstPoolId;
            require(!exists, "Stargate: cant createChainPath of existing dstChainId and _dstPoolId");
        }
        totalWeight = totalWeight.add(_weight);
        chainPathIndexLookup[_dstChainId][_dstPoolId] = chainPaths.length;
        chainPaths.push(ChainPath(false, _dstChainId, _dstPoolId, _weight, 0, 0, 0, 0));
        emit ChainPathUpdate(_dstChainId, _dstPoolId, _weight);
    }

    function setWeightForChainPath(
        uint16 _dstChainId,
        uint _dstPoolId,
        uint16 _weight
    ) external onlyRouter {
        ChainPath storage cp = getAndCheckCP(_dstChainId, _dstPoolId);
        totalWeight = totalWeight.sub(cp.weight).add(_weight);
        cp.weight = _weight;
        emit ChainPathUpdate(_dstChainId, _dstPoolId, _weight);
    }

    function setFee(uint _mintFeeBP) external onlyRouter {
        require(_mintFeeBP <= BP_DENOMINATOR, "Bridge: cum fees > 100%");
        mintFeeBP = _mintFeeBP;
        emit FeesUpdated(mintFeeBP);
    }

    function setFeeLibrary(address _feeLibraryAddr) external onlyRouter {
        require(_feeLibraryAddr != address(0x0), "Stargate: fee library cant be 0x0");
        feeLibrary = _feeLibraryAddr;
        emit FeeLibraryUpdated(_feeLibraryAddr);
    }

    function setSwapStop(bool _swapStop) external onlyRouter {
        stopSwap = _swapStop;
        emit StopSwapUpdated(_swapStop);
    }

    function setDeltaParam(
        bool _batched,
        uint _swapDeltaBP,
        uint _lpDeltaBP,
        bool _defaultSwapMode,
        bool _defaultLPMode
    ) external onlyRouter {
        require(_swapDeltaBP <= BP_DENOMINATOR && _lpDeltaBP <= BP_DENOMINATOR, "Stargate: wrong Delta param");
        batched = _batched;
        swapDeltaBP = _swapDeltaBP;
        lpDeltaBP = _lpDeltaBP;
        defaultSwapMode = _defaultSwapMode;
        defaultLPMode = _defaultLPMode;
        emit DeltaParamUpdated(_batched, _swapDeltaBP, _lpDeltaBP, _defaultSwapMode, _defaultLPMode);
    }

    function callDelta(bool _fullMode) external onlyRouter {
        _delta(_fullMode);
    }

    function activateChainPath(uint16 _dstChainId, uint _dstPoolId) external onlyRouter {
        ChainPath storage cp = getAndCheckCP(_dstChainId, _dstPoolId);
        require(cp.ready == false, "Stargate: chainPath is already active");
        // this func will only be called once
        cp.ready = true;
    }

    function withdrawProtocolFeeBalance(address _to) external onlyRouter {
        if (protocolFeeBalance > 0) {
            uint amountOfLD = amountSDtoLD(protocolFeeBalance);
            protocolFeeBalance = 0;
            _safeTransfer(token, _to, amountOfLD);
            emit WithdrawProtocolFeeBalance(_to, amountOfLD);
        }
    }

    function withdrawMintFeeBalance(address _to) external onlyRouter {
        if (mintFeeBalance > 0) {
            uint amountOfLD = amountSDtoLD(mintFeeBalance);
            mintFeeBalance = 0;
            _safeTransfer(token, _to, amountOfLD);
            emit WithdrawMintFeeBalance(_to, amountOfLD);
        }
    }

    //---------------------------------------------------------------------------
    // INTERNAL
    // Conversion Helpers
    //---------------------------------------------------------------------------
    function amountLPtoLD(uint _amountLP) external view returns (uint) {
        return amountSDtoLD(_amountLPtoSD(_amountLP));
    }

    function _amountLPtoSD(uint _amountLP) internal view returns (uint) {
        require(totalSupply > 0, "Stargate: cant convert LPtoSD when totalSupply == 0");
        return _amountLP.mul(totalLiquidity).div(totalSupply);
    }

    function _amountSDtoLP(uint _amountSD) internal view returns (uint) {
        require(totalLiquidity > 0, "Stargate: cant convert SDtoLP when totalLiq == 0");
        return _amountSD.mul(totalSupply).div(totalLiquidity);
    }

    function amountSDtoLD(uint _amount) internal view returns (uint) {
        return _amount.mul(convertRate);
    }

    function amountLDtoSD(uint _amount) internal view returns (uint) {
        return _amount.div(convertRate);
    }

    function getAndCheckCP(uint16 _dstChainId, uint _dstPoolId) internal view returns (ChainPath storage) {
        require(chainPaths.length > 0, "Stargate: no chainpaths exist");
        ChainPath storage cp = chainPaths[chainPathIndexLookup[_dstChainId][_dstPoolId]];
        require(cp.dstChainId == _dstChainId && cp.dstPoolId == _dstPoolId, "Stargate: local chainPath does not exist");
        return cp;
    }

    function getChainPath(uint16 _dstChainId, uint _dstPoolId) external view returns (ChainPath memory) {
        ChainPath memory cp = chainPaths[chainPathIndexLookup[_dstChainId][_dstPoolId]];
        require(cp.dstChainId == _dstChainId && cp.dstPoolId == _dstPoolId, "Stargate: local chainPath does not exist");
        return cp;
    }

    function _burnLocal(address _from, uint _amountLP) internal returns (uint) {
        require(totalSupply > 0, "Stargate: cant burn when totalSupply == 0");
        uint amountOfLPTokens = balanceOf[_from];
        require(amountOfLPTokens >= _amountLP, "Stargate: not enough LP tokens to burn");

        uint amountSD = _amountLP.mul(totalLiquidity).div(totalSupply);
        //subtract totalLiquidity accordingly
        totalLiquidity = totalLiquidity.sub(amountSD);

        _burn(_from, _amountLP);
        emit Burn(_from, _amountLP, amountSD);
        return amountSD;
    }

    function _delta(bool fullMode) internal {
        if (deltaCredit > 0 && totalWeight > 0) {
            uint cpLength = chainPaths.length;
            uint[] memory deficit = new uint[](cpLength);
            uint totalDeficit = 0;

            // algorithm steps 6-9: calculate the total and the amounts required to get to balance state
            for (uint i = 0; i < cpLength; ++i) {
                ChainPath storage cp = chainPaths[i];
                // (liquidity * (weight/totalWeight)) - (lkb+credits)
                uint balLiq = totalLiquidity.mul(cp.weight).div(totalWeight);
                uint currLiq = cp.lkb.add(cp.credits);
                if (balLiq > currLiq) {
                    // save gas since we know balLiq > currLiq and we know deficit[i] > 0
                    deficit[i] = balLiq - currLiq;
                    totalDeficit = totalDeficit.add(deficit[i]);
                }
            }

            // indicates how much delta credit is distributed
            uint spent;

            // handle credits with 2 tranches. the [ < totalDeficit] [excessCredit]
            // run full Delta, allocate all credits
            if (totalDeficit == 0) {
                // only fullMode delta will allocate excess credits
                if (fullMode && deltaCredit > 0) {
                    // credit ChainPath by weights
                    for (uint i = 0; i < cpLength; ++i) {
                        ChainPath storage cp = chainPaths[i];
                        // credits = credits + toBalanceChange + remaining allocation based on weight
                        uint amtToCredit = deltaCredit.mul(cp.weight).div(totalWeight);
                        spent = spent.add(amtToCredit);
                        cp.credits = cp.credits.add(amtToCredit);
                    }
                } // else do nth
            } else if (totalDeficit <= deltaCredit) {
                if (fullMode) {
                    // algorithm step 13: calculate amount to disperse to bring to balance state or as close as possible
                    uint excessCredit = deltaCredit - totalDeficit;
                    // algorithm steps 14-16: calculate credits
                    for (uint i = 0; i < cpLength; ++i) {
                        if (deficit[i] > 0) {
                            ChainPath storage cp = chainPaths[i];
                            // credits = credits + deficit + remaining allocation based on weight
                            uint amtToCredit = deficit[i].add(excessCredit.mul(cp.weight).div(totalWeight));
                            spent = spent.add(amtToCredit);
                            cp.credits = cp.credits.add(amtToCredit);
                        }
                    }
                } else {
                    // totalDeficit <= deltaCredit but not running fullMode
                    // credit chainPaths as is if any deficit, not using all deltaCredit
                    for (uint i = 0; i < cpLength; ++i) {
                        if (deficit[i] > 0) {
                            ChainPath storage cp = chainPaths[i];
                            uint amtToCredit = deficit[i];
                            spent = spent.add(amtToCredit);
                            cp.credits = cp.credits.add(amtToCredit);
                        }
                    }
                }
            } else {
                // totalDeficit > deltaCredit, fullMode or not, normalize the deficit by deltaCredit
                for (uint i = 0; i < cpLength; ++i) {
                    if (deficit[i] > 0) {
                        ChainPath storage cp = chainPaths[i];
                        uint proportionalDeficit = deficit[i].mul(deltaCredit).div(totalDeficit);
                        spent = spent.add(proportionalDeficit);
                        cp.credits = cp.credits.add(proportionalDeficit);
                    }
                }
            }

            // deduct the amount of credit sent
            deltaCredit = deltaCredit.sub(spent);
        }
    }

    function _mintLocal(
        address _to,
        uint _amountLD,
        bool _feesEnabled,
        bool _creditDelta
    ) internal returns (uint amountSD) {
        require(totalWeight > 0, "Stargate: No ChainPaths exist");
        amountSD = amountLDtoSD(_amountLD);

        uint mintFeeSD = 0;
        if (_feesEnabled) {
            mintFeeSD = amountSD.mul(mintFeeBP).div(BP_DENOMINATOR);
            amountSD = amountSD.sub(mintFeeSD);
            mintFeeBalance = mintFeeBalance.add(mintFeeSD);
        }

        if (_creditDelta) {
            deltaCredit = deltaCredit.add(amountSD);
        }

        uint amountLPTokens = amountSD;
        if (totalSupply != 0) {
            amountLPTokens = amountSD.mul(totalSupply).div(totalLiquidity);
        }
        totalLiquidity = totalLiquidity.add(amountSD);

        _mint(_to, amountLPTokens);
        emit Mint(_to, amountLPTokens, amountSD, mintFeeSD);

        // add to credits and call delta. short circuit to save gas
        if (!batched || deltaCredit > totalLiquidity.mul(lpDeltaBP).div(BP_DENOMINATOR)) {
            _delta(defaultLPMode);
        }
    }

    function _safeTransfer(
        address _token,
        address _to,
        uint _value
    ) private {
        (bool success, bytes memory data) = _token.call(abi.encodeWithSelector(SELECTOR, _to, _value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "Stargate: TRANSFER_FAILED");
    }
}
