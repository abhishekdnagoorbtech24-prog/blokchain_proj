// Usage: RPC_URL=https://sepolia... PRIVATE_KEY=0x... node deploy.js   (compile first: node compile.js)
const { ethers } = require("ethers"), fs = require("fs");
(async () => {
  const w = new ethers.Wallet(process.env.PRIVATE_KEY, new ethers.JsonRpcProvider(process.env.RPC_URL));
  const a = JSON.parse(fs.readFileSync("build/StablePaySettlement.json"));
  const c = await new ethers.ContractFactory(a.abi, a.bytecode, w).deploy(); await c.waitForDeployment();
  console.log("StablePaySettlement:", await c.getAddress(), "\nThen call setFeed(token, chainlinkFeed) and setKyc(addr,true).");
})();
