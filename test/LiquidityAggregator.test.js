const { expect } = require("chai")
const { BigNumber, constants, utils } = require('ethers')
const { ethers } = require("hardhat")

describe("LiquidityAggregator", function () {
    beforeEach(async function () {
        this.accounts = await ethers.getSigners()
        this.owner = this.accounts[0]

        // use this chainId
        this.chainIdSrc = 1
        this.chainIdDst = 2

        // create a LayerZero Endpoint mock for testing
        const LZEndpointMock = await ethers.getContractFactory("LZEndpointMock")
        this.layerZeroEndpointMockSrc = await LZEndpointMock.deploy(this.chainIdSrc)
        this.layerZeroEndpointMockDst = await LZEndpointMock.deploy(this.chainIdDst)

        // create a ERC20 mock for testing
        const ERC20Mock = await ethers.getContractFactory("ERC20Mock")
        this.erc20Mock = await ERC20Mock.deploy("Mock", "MOCK")
        await this.erc20Mock.mint(this.accounts[0].address, utils.parseEther("10000"))
        console.log("DEPLOYED ERC20Mock")

        // create a Stargate Bridge mock for testing
        const StargateRouterMock = await ethers.getContractFactory("StargateRouterMock")
        this.stargateRouterMock = await StargateRouterMock.deploy()

        // create two PingPong instances
        const LiquidityAggregator = await ethers.getContractFactory("LiquidityAggregator")
        this.liquidityAggregatorA = await LiquidityAggregator.deploy(this.layerZeroEndpointMockSrc.address, this.erc20Mock.address, this.stargateRouterMock.address)
        this.liquidityAggregatorB = await LiquidityAggregator.deploy(this.layerZeroEndpointMockDst.address, this.erc20Mock.address, this.stargateRouterMock.address)

        this.layerZeroEndpointMockSrc.setDestLzEndpoint(this.liquidityAggregatorB.address, this.layerZeroEndpointMockDst.address)
        this.layerZeroEndpointMockDst.setDestLzEndpoint(this.liquidityAggregatorA.address, this.layerZeroEndpointMockSrc.address)

        // set each contracts source address so it can send to each other
        await this.liquidityAggregatorA.setTrustedRemote(
            this.chainIdDst,
            utils.solidityPack(["address", "address"], [this.liquidityAggregatorB.address, this.liquidityAggregatorA.address])
        ) // for A, set B
        await this.liquidityAggregatorB.setTrustedRemote(
            this.chainIdSrc,
            utils.solidityPack(["address", "address"], [this.liquidityAggregatorA.address, this.liquidityAggregatorB.address])
        ) // for B, set A
    })

    // it("increment the counter of the destination PingPong when paused should revert", async function () {
    //     await expect(this.pingPongA.ping(this.chainIdDst, this.pingPongB.address, 0)).to.revertedWith("Pausable: paused")
    // })

    it("increment the counter of the destination PingPong when unpaused show not revert", async function () {
        await expect(this.liquidityAggregatorA.aggregate(
            [this.chainIdDst],
            [BigNumber.from(1)],
            [BigNumber.from(1)],
            [constants.MaxUint256],
            ["0x0e2d44da6238ebd52796a329de7289f67fd292fcd74b548bc6e2ea18c2189d4f6c0f3073cd95f0c034f649ac500edf611d78e6b9293aa4dec0f4aacad2b0a38e1b"],
            { value: ethers.utils.parseEther("0.5") }
        )).to.not.reverted;
    })
})
