task(
  "setTrustedRemote",
  "setTrustedRemote(chainId, sourceAddr) to enable inbound/outbound messages with your other contracts",
  require("./setTrustedRemote")
).addParam("targetNetwork", "the target network to set as a trusted remote")
  .addOptionalParam("localContract", "Name of local contract if the names are different")
  .addOptionalParam("remoteContract", "Name of remote contract if the names are different")
  .addOptionalParam("contract", "If both contracts are the same name")