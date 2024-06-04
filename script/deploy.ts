import fs from "fs";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { ChildProcessWithoutNullStreams, exec, execSync, spawn } from "child_process";
import { ethers } from "ethers";

const CROSS_CHAIN_CREATE2_FACTORY = "0x0000000000FFe8B47B3e2130213B802212439497";

yargs(hideBin(process.argv))
  .usage("$0 <cmd> [args]")
  .command(
    "deploy <contract>",
    "deploy the given contract",
    (yargs) => {
      return yargs
        .positional("contract", {
          describe: "contract to deploy",
          type: "string",
          demandOption: "true",
        })
        .describe("rpc", "The URL of the RPC to use for deployment")
        .describe("pk", "The private key to use for deployment")
        .describe("salt", "The salt used at deployment. Defaults to 0")
        .describe("explorer-api-key", "Explorer key for etherscan product on the given network")
        .array("constructor-args")
        .string("constructor-args")
        .string("pk")
        .string("rpc")
        .string("salt")
        .string("explorer-api-key")
        .demandOption(["rpc", "pk"]);
    },
    (argv) => {
      runDeploy(
        argv.contract,
        argv.rpc,
        argv.pk,
        argv["constructor-args"],
        argv.salt ?? ethers.ZeroHash,
        argv.explorerApiKey,
      );
    },
  )
  .command(
    "init <chainId>",
    "initialize the deployment file for a given network",
    (yargs) => {
      return yargs.positional("chainId", {
        describe: "network id to initialize for",
        type: "string",
        demandOption: "true",
      });
    },
    (argv) => {
      initProject(argv.chainId);
    },
  )
  .parse();

async function runDeploy(
  contract: string,
  rpcUrl: string,
  privateKey: string,
  constructorArgs: any,
  salt: string,
  explorerApiKey: string | undefined,
) {
  const contracts = getProjectContracts();
  if (!contracts.includes(contract)) {
    throw new Error(`Contract ${contract} not found in project`);
  }

  const provider = new ethers.JsonRpcProvider(rpcUrl);
  const chainId = (await provider.getNetwork()).chainId.toString();

  // If no constructor args are given, try to resolve from deployment file
  if (!constructorArgs || constructorArgs.length == 0) {
    constructorArgs = resolveConstructorArgs(contract, chainId);
  }

  const encodedConstructorArgs = encodeConstructorArgs(contract, constructorArgs);
  let newDeploy: Deploy = { deployedArgs: encodedConstructorArgs } as Deploy;
  newDeploy.version = await getUndeployedContractVersion(contract, constructorArgs);

  validateDeploy(contract, newDeploy, chainId);

  console.log("Deploying contract...");

  const deploymentBytecode = ethers.solidityPacked(
    ["bytes", "bytes"],
    [
      JSON.parse(fs.readFileSync(`out/${contract}.sol/${contract}.json`, "utf-8")).bytecode.object,
      encodedConstructorArgs,
    ],
  );

  const getDeterministicAddressCall = `cast call ${CROSS_CHAIN_CREATE2_FACTORY} "findCreate2Address(bytes32,bytes)" ${salt} ${deploymentBytecode} --rpc-url ${rpcUrl}`;
  const deterministicCreateCall = `cast send ${CROSS_CHAIN_CREATE2_FACTORY} "safeCreate2(bytes32,bytes)" ${salt} ${deploymentBytecode} --rpc-url ${rpcUrl} --private-key ${privateKey}`;

  const getAddrResult = (await execSync(getDeterministicAddressCall)).toString().trim();
  const addr = ethers.AbiCoder.defaultAbiCoder().decode(["address"], getAddrResult)[0];
  if (addr == ethers.ZeroAddress) {
    throw new Error(`Contract ${contract} already deployed using salt ${salt} with version ${newDeploy.version}`);
  }
  newDeploy.address = addr;

  await execSync(deterministicCreateCall);
  console.log(`Contract ${contract} deployed to ${newDeploy.address} with version ${newDeploy.version}`);

  if (!!explorerApiKey) {
    const verifyCall = `forge v --rpc-url ${rpcUrl} --etherscan-api-key ${explorerApiKey!} ${
      encodedConstructorArgs != "" ? `--constructor-args ${encodedConstructorArgs}` : ""
    } ${newDeploy.address} ${contract}`;
    console.log(`Verifying ${contract}`);
    const res = await execSync(verifyCall);
    console.log(res.toString());
  }

  writeDeploy(contract, newDeploy, chainId);
}

/**
 * Resolves the constructor arguments for a contract. Must be other contracts in the repo or constants in the deployment file.
 * @param contractName Contract to resolve args for
 * @param chainId Chain to deploy to
 */
function resolveConstructorArgs(contractName: string, chainId: string): string[] {
  if (!fs.existsSync(`deployments/${chainId}.json`)) {
    throw new Error(`Deployment file for network ${chainId} does not exist`);
  }
  const deploymentFile: DeploymentFile = JSON.parse(fs.readFileSync(`deployments/${chainId}.json`, "utf-8"));

  if (!(contractName in deploymentFile.contracts)) {
    throw new Error(`Contract ${contractName} does not exist in project`);
  }

  const args = deploymentFile.contracts[contractName].constructorArgs;

  let resolvedArgs: string[] = new Array<string>(args.length);

  for (let i = 0; i < args.length; i++) {
    if (args[i] in deploymentFile.contracts) {
      const contractObj = deploymentFile.contracts[args[i]];
      if (contractObj.deploys.length == 0) throw new Error(`Contract ${args[i]} doesn't have any deploy`);
      resolvedArgs[i] = contractObj.deploys.at(-1)!.address;
    } else {
      // Must be in constants or revert
      if (args[i] in deploymentFile.constants) {
        resolvedArgs[i] = deploymentFile.constants[args[i]];
      } else {
        throw new Error(`Argument ${args[i]} not found in deployment file or constants`);
      }
    }
  }

  return resolvedArgs;
}

/**
 * Validates a deploy. Should be called prior to writing anything to chain.
 * @param contract Name of the contract to be deployed
 * @param deploy Deployments specifications to be used
 * @param chainId Chain to deploy to
 */
function validateDeploy(contract: string, deploy: Deploy, chainId: string) {
  // First check if deployment file exists
  if (!fs.existsSync(`deployments/${chainId}.json`)) {
    initProject(chainId);
  }
  const existingDeployments = JSON.parse(fs.readFileSync(`deployments/${chainId}.json`, "utf-8"));

  if (
    !!existingDeployments.contracts[contract].deploys.find(
      (d: Deploy) => d.version == deploy.version && d.deployedArgs == deploy.deployedArgs,
    )
  ) {
    throw new Error(
      `Contract ${contract} with version ${deploy.version} and deployed args ${
        deploy.deployedArgs || "<empty>"
      } already deployed`,
    );
  }
}

/**
 * Writes a new deploy to the deployment file
 * @param contract Name of the contract deployed
 * @param deploy Deployments specifications
 * @param chainId The chain deployed to
 */
function writeDeploy(contract: string, deploy: Deploy, chainId: string) {
  // First check if deployment file exists
  if (!fs.existsSync(`deployments/${chainId}.json`)) {
    initProject(chainId);
  }
  const existingDeployments = JSON.parse(fs.readFileSync(`deployments/${chainId}.json`, "utf-8"));
  existingDeployments.contracts[contract].deploys.push(deploy);
  fs.writeFileSync(`deployments/${chainId}.json`, JSON.stringify(existingDeployments));
}

/**
 * Launches a local anvil instance using the `mnemonic-seed` 123
 * @returns Returns the child process. Must be killed.
 */
async function launchAnvil(): Promise<ChildProcessWithoutNullStreams> {
  var anvil = spawn("anvil", ["--mnemonic-seed-unsafe", "123"]);
  return new Promise((resolve) => {
    anvil.stdout.on("data", function (data) {
      if (data.includes("Listening")) {
        resolve(anvil);
      }
    });
    anvil.stderr.on("data", function (err) {
      throw new Error(err.toString());
    });
  });
}

/**
 * Gets the version of an undeployed contract via deploying to a local network.
 * @param contractName Name of the contract in the repo
 * @returns
 */
async function getUndeployedContractVersion(contractName: string, constructorArgs: any): Promise<string> {
  const anvil = await launchAnvil();

  // Private key generated from mnemonic 123
  const createCommand = `forge create ${contractName} --private-key 0x78427d179c2c0f8467881bc37f9453a99854977507ca53ff65e1c875208a4a03 --rpc-url "127.0.0.1:8545" ${
    !!constructorArgs && constructorArgs.length != 0 ? "--constructor-args " + constructorArgs.join(" ") : ""
  }`;
  let addr = "";

  const out = await execSync(createCommand);
  const lines = out.toString().split("\n");
  for (const line of lines) {
    if (line.startsWith("Deployed to: ")) {
      // Get the address
      addr = line.split("Deployed to: ")[1];
    }
  }

  const res = await getContractVersion(addr, "http://127.0.0.1:8545");
  anvil.kill();

  return res;
}

/**
 * Fetches the version of the given contract by calling `VERSION`
 * @param contractAddress Address the contract is deployed to
 * @param rpcUrl RPC to connect to the network where the contract is deployed
 * @returns
 */
async function getContractVersion(contractAddress: string, rpcUrl: string): Promise<string> {
  const provider = new ethers.JsonRpcProvider(rpcUrl);
  try {
    const versionRes = await provider.call({ to: contractAddress, data: "0xffa1ad74" /* Version function */ });
    return ethers.AbiCoder.defaultAbiCoder().decode(["string"], versionRes)[0];
  } catch (err) {
    throw new Error("Contract does not implement version function. Please implement `VERSION` in your contract");
  }
}

function encodeConstructorArgs(contractName: string, args: string[] | undefined): string {
  if (!!args) {
    const contractABI = JSON.parse(fs.readFileSync(`out/${contractName}.sol/${contractName}.json`, "utf-8")).abi;
    const contractInterface = new ethers.Interface(contractABI);
    return contractInterface.encodeDeploy(args);
  }
  return "";
}

type Deploy = {
  version: string;
  address: string;
  deployedArgs: string;
};
type Contract = {
  deploys: Deploy[];
  constructorArgs: string[];
};
type DeploymentFile = {
  contracts: { [key: string]: Contract };
  constants: { [key: string]: string };
};

/**
 * Initialize the deployment file for a given network
 * @param chainId
 */
function initProject(chainId: string) {
  console.log(`Initializing project for network ${chainId}...`);

  if (fs.existsSync(`deployments/${chainId}.json`)) {
    throw new Error(`Deployment file for network ${chainId} already exists`);
  }

  let fileToStore: DeploymentFile = {
    contracts: {},
    constants: {},
  };
  const contracts = getProjectContracts();
  contracts.map((contract) => {
    fileToStore.contracts[contract] = {
      deploys: [],
      constructorArgs: [],
    };
  });

  if (!fs.existsSync("deployments")) {
    fs.mkdirSync("deployments");
  }

  fs.writeFileSync(`deployments/${chainId}.json`, JSON.stringify(fileToStore));
}

/**
 * Gets all the deployable contracts in the project
 * @returns An array of contract names not including the path or extension
 */
function getProjectContracts(): string[] {
  console.log("Building project...");
  execSync("forge build");
  const buildCache = JSON.parse(fs.readFileSync("cache/solidity-files-cache.json", "utf-8"));
  // Get files in src directory
  const filesOfInterest = Object.keys(buildCache.files).filter((file: string) => file.startsWith("src/"));

  // Get contracts that have bytecode
  let deployableContracts: string[] = [];
  for (const file of filesOfInterest) {
    const fileName = file.split("/").pop()!;
    const buildOutput = JSON.parse(fs.readFileSync(`out/${fileName}/${fileName.split(".")[0]}.json`, "utf-8"));
    // Only consider contracts that are deployable
    if (buildOutput.bytecode.object !== "0x") {
      deployableContracts.push(fileName.split(".")[0]);
    }
  }

  return deployableContracts;
}
