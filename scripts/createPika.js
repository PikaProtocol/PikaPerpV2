const { ethers } = require("hardhat");


async function main() {
    // We get the contract to deploy
    const Pika = await ethers.getContractFactory("Pika");
    // const pika = await Pika.deploy("0x26D6ff77d5D45c91e288bf24540bb232f775020C", "0x26D6ff77d5D45c91e288bf24540bb232f775020C");
    const pika = await Pika.deploy("Pika", "PIKA", "100000000000000000000000000", "0xc71f84d1f6dfa786B2b7B8B26FCB88120c472e8e", "0xEF4820f560a2294f94e6a019d2964AD61f839f58");
    console.log("Pika deployed to:", pika.address);
}

main()
    .then(() => process.exit(0))
    .catch(error => {
        console.error(error);
        process.exit(1);
    });
