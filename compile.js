const solc = require("solc"), fs = require("fs");
const src = fs.readFileSync("contracts/StablePay.sol", "utf8");
const out = JSON.parse(solc.compile(JSON.stringify({
  language: "Solidity", sources: { "StablePay.sol": { content: src } },
  settings: { evmVersion: "paris", optimizer: { enabled: true, runs: 200 }, outputSelection: { "*": { "*": ["abi", "evm.bytecode.object"] } } }
})));
(out.errors || []).forEach(e => console.log(e.severity, e.formattedMessage));
if ((out.errors || []).some(e => e.severity === "error")) process.exit(1);
fs.mkdirSync("build", { recursive: true });
for (const [n, c] of Object.entries(out.contracts["StablePay.sol"])) fs.writeFileSync(`build/${n}.json`, JSON.stringify({ abi: c.abi, bytecode: "0x" + c.evm.bytecode.object }));
console.log("compiled:", Object.keys(out.contracts["StablePay.sol"]).join(", "));
