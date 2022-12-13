const LZ_ENDPOINTS = require("../constants/layerzeroEndpoints.json")
const TOKENS = require("../constants/tokens.json")
const STARGATE = require("../constants/stargate.json")

module.exports = async function ({ deployments, getNamedAccounts }) {
  const { deploy } = deployments
  const { deployer } = await getNamedAccounts()
  console.log(`>>> your address: ${deployer}`)

  // get the Endpoint address
  const endpointAddr = LZ_ENDPOINTS[hre.network.name]
  console.log(`[${hre.network.name}] Endpoint address: ${endpointAddr}`)

  // get usdc address
  const usdcAddress = TOKENS["usdc"][hre.network.name]
  console.log(`[${hre.network.name}] USDC address: ${usdcAddress}`)

  // get Permit2 address
  const stargateRouterAddress = STARGATE.router[hre.network.name]
  console.log(`[${hre.network.name}] Stargate Router address: ${stargateRouterAddress}`)

  await deploy("LiquidityAggregator", {
    from: deployer,
    args: [endpointAddr, usdcAddress, stargateRouterAddress],
    log: true,
    waitConfirmations: 1,
  })
}

module.exports.tags = ["LiquidityAggregator"]
