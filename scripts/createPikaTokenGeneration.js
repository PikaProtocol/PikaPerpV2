const { ethers, upgrades } = require("hardhat");

async function main() {
    const PikaTokenGeneration = await ethers.getContractFactory("PikaTokenGeneration");
    const startTime = 1684850400;
    const pikaTokenGeneration = await PikaTokenGeneration.deploy("0x6c4ed8CCCD7546d5bc30f468b1451a3936489276", "0xc52888bF1beD863F1079a4C84779C99d7bBBA56d",
        startTime.toString(), (startTime + 1800).toString(), (startTime + 86400).toString(), (startTime + 86400 * 4).toString(),
        ["1000000000000000000000", "6600000000000000000000"], "19000000000000000000000000", "1000000000000000000", ["1000000000000000000", "3000000000000000000", "5000000000000000000"],
        "0x90381b977a3a6bde48cbb85ec99ae1c4adf33e605daf0e57f17fc08ccd18fc56"); // rinkeby
    await pikaTokenGeneration.deployed();
    console.log("PikaTokenGeneration deployed to:", pikaTokenGeneration.address);
}

main();
