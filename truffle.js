const HDWalletProvider = require("truffle-hdwallet-provider");
const mnemonic = process.env.HDMNEMONIC;

module.exports = {
  // See <http://truffleframework.com/docs/advanced/configuration>
  // to customize your Truffle configuration!networks: {
  networks: {
    ropsten: {
      host: "127.0.0.1",
      port: 8545,
      network_id: 3,
      gas: 4700036,
      gasPrice: 20000000000, // Match any network id
      from: "0xdfffc978720962e2770bc7ea5c1d304b99862e20"
    },
    rinkeby: {
      provider: function() {
        return new HDWalletProvider(mnemonic, "https://rinkeby.infura.io/PwcyIGszs2x6sS6NIU1Q")
      },
      gas: 7484176,
      gasPrice: 9000000000,
      network_id: 4,
    }
  }
};
