const { ethers, upgrades } = require("hardhat");

async function main() {
    const OrderBook = await ethers.getContractFactory("OrderBook");
    // const pikaPerp = await PikaPerp.deploy("0x0a5ed85Bda88fc3fB6602D41308Eeb03F5D13dFb", "0x197922887aD5f21fE40cF517b255CDFa2F21A9bb"); // kovan
    // const pikaPerp = await PikaPerp.deploy("0x03f2922448261FB9920b5aFD0C339a9086F4881E", "0x61FeDB3C73F3DFb809118f937C32CbB944a306e7"); // optimistic kovan
    // const pikaPerp = await PikaPerp.deploy("0x84cca0E31CDbD21A99b81b6AB07aD80e4582F65e", 6, "0x7cb5d785847028c51a7adc253e21b3ac2582b40d", 5000000000); // rinkeby
    const orderBook = await OrderBook.deploy("0x9b86B2Be8eDB2958089E522Fe0eB7dD5935975AB", "0x2A3c0592dCb58accD346cCEE2bB46e3fB744987a", "0x7f5c764cbc14f9669b88837ca1490cca17c31607",
        "1000000", "20000", "0xe3451b170806Aab3e24b5Cd03a331C1CCdb4d7C1", "1000000", "0x2561688d2212A38D82247143EeD78506c8b23df7"); // optimism mainnet
    await orderBook.deployed();
    console.log("OrderBook deployed to:", orderBook.address);
}

main();
