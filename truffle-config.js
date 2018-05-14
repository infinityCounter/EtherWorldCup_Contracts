module.exports = {
  // See <http://truffleframework.com/docs/advanced/configuration>
  // to customize your Truffle configuration!networks: {
  networks: {
    ropsten: {
      host: "127.0.0.1",
      port: 8545,
      network_id: 3,
      gas: 4700036,
      gasPrice: 60000000000, // Match any network id
      from: "0xdfffc978720962e2770bc7ea5c1d304b99862e20"
    }
	},
  rpc: {
    host: "127.0.0.1",
    port: 8545
  }
};
