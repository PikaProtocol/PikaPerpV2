
const { expect } = require("chai")
const hre = require("hardhat")
const { waffle, ethers} = require("hardhat")
const {BigNumber} = require("ethers");

const provider = waffle.provider

// Assert that actual is less than 1/accuracy difference from expected
function assertAlmostEqual(actual, expected, accuracy = 100000) {
    const expectedBN = BigNumber.isBigNumber(expected) ? expected : BigNumber.from(expected)
    const actualBN = BigNumber.isBigNumber(actual) ? actual : BigNumber.from(actual)
    const diffBN = expectedBN.gt(actualBN) ? expectedBN.sub(actualBN) : actualBN.sub(expectedBN)
    if (expectedBN.gt(0)) {
        return expect(
            diffBN).to.lt(expectedBN.div(BigNumber.from(accuracy.toString()))
        )
    }
    return expect(
        diffBN).to.lt(-1 * expectedBN.div(BigNumber.from(accuracy.toString()))
    )
}


describe("PikaStaking", function () {
    let pika, esPika, vePika, pikaStaking, pikaFeeReward, pikaTokenReward, testPikaPerp, owner, alice, bob, usdc;
    beforeEach(async function () {
        this.wallets = provider.getWallets()
        owner = this.wallets[0]
        alice = this.wallets[1]
        bob = this.wallets[2]
        const pikaContract = await hre.ethers.getContractFactory("Pika")
        const ePikaContract = await hre.ethers.getContractFactory("EsPika")
        const pikaStakingContract = await hre.ethers.getContractFactory("PikaStaking")
        const vePikaContract = await hre.ethers.getContractFactory("VePika")
        const testPikaPerpContract = await hre.ethers.getContractFactory("TestPikaPerp")
        const usdcContract = await ethers.getContractFactory("TestUSDC");
        usdc = await usdcContract.deploy();
        await usdc.mint(owner.address, 1000000000000);

        pika = await pikaContract.deploy("Pika", "PIKA", "1000000000000000000000000000", owner.address, owner.address)
        await pika.connect(owner).transfer(alice.address, "3000000000000000000000") //3000 pika
        await pika.connect(owner).transfer(bob.address, "9000000000000000000000") //9000 pika

        esPika = await ePikaContract.deploy("ePika", "ePIKA", "1000000000000000000000000000", owner.address, owner.address)
        await esPika.connect(owner).grantRole("0x9143236d81225394f3bd65b44e6e29fdf4d7ba0773d9bb3f5cc15eb80ba37777", owner.address)

        pikaStaking = await pikaStakingContract.connect(owner).deploy(pika.address, 86400);

        vePika = await vePikaContract.deploy(pikaStaking.address)

        const pikaFeeRewardContract = await ethers.getContractFactory("PikaFeeReward");
        pikaFeeReward = await pikaFeeRewardContract.deploy(pikaStaking.address, usdc.address);

        testPikaPerp = await testPikaPerpContract.connect(owner).deploy();
        await pikaFeeReward.setPikaPerp(testPikaPerp.address);

        const pikaTokenRewardContract = await ethers.getContractFactory("PikaTokenReward");
        pikaTokenReward = await pikaTokenRewardContract.deploy(pikaStaking.address, esPika.address);
        await esPika.connect(owner).grantRole("0x9143236d81225394f3bd65b44e6e29fdf4d7ba0773d9bb3f5cc15eb80ba37777", pikaTokenReward.address)
        await esPika.connect(owner).approve(pikaTokenReward.address, "100000000000000000000000")

        await pikaStaking.setRewardPools([pikaFeeReward.address, pikaFeeReward.address, pikaTokenReward.address])
    })

    describe("test pikaStaking", async function(){
        it("stake", async function () {
            pikaTokenReward.connect(owner).queueNewRewards("1000000000000000000000"); //1000 esPika

            await pika.connect(alice).approve(pikaStaking.address, "100000000000000000000000")
            await pika.connect(bob).approve(pikaStaking.address, "100000000000000000000000")
            await pikaStaking.connect(alice).stake("1000000000000000000000")
            await expect(pikaStaking.connect(alice).withdraw("1000000000000000000000")).to.be.revertedWith("!period")
            await pikaStaking.connect(alice).stake("1000000000000000000000")
            // console.log("total supply", await vePika.totalSupply())
            expect(await pikaFeeReward.getClaimableReward(alice.address)).to.be.equal("2000000000000000000")
            await pikaStaking.connect(bob).stake("8000000000000000000000")
            await pikaFeeReward.updateReward(bob.address)
            expect(await vePika.balanceOf(alice.address)).to.equal("2000000000000000000000");
            expect(await vePika.balanceOf(bob.address)).to.equal("8000000000000000000000");

            await provider.send("evm_increaseTime", [86400*30])
            await provider.send("evm_mine")

            expect(await pikaFeeReward.getClaimableReward(alice.address)).to.be.equal("4200000000000000000")
            expect(await pikaFeeReward.getClaimableReward(bob.address)).to.be.equal("800000000000000000")
            assertAlmostEqual((await pikaTokenReward.earned(alice.address)).mul(4), await pikaTokenReward.earned(bob.address))
            await pikaTokenReward.connect(alice).getReward();
            await pikaTokenReward.connect(bob).getReward();
            assertAlmostEqual((await esPika.balanceOf(alice.address)).mul(4), await esPika.balanceOf(bob.address))

            await pikaStaking.connect(alice).withdraw("1000000000000000000000");
            // expect(await pikaStaking.depositedAll(alice.address)).to.be.equal("1000000000000000000000")
            expect(await vePika.balanceOf(alice.address)).to.equal("1000000000000000000000");

            await pikaStaking.connect(alice).stake("1000000000000000000000")
            expect(await vePika.balanceOf(alice.address)).to.equal("2000000000000000000000");
            await pikaTokenReward.connect(owner).queueNewRewards("1000000000000000000000"); //1000 esPika

            await provider.send("evm_increaseTime", [86400*15])
            await provider.send("evm_mine")
            assertAlmostEqual(await pikaTokenReward.earned(alice.address), "100000000000000000000")
            assertAlmostEqual((await pikaTokenReward.earned(alice.address)).mul(4), await pikaTokenReward.earned(bob.address))
            await provider.send("evm_increaseTime", [86400*15])
            await provider.send("evm_mine")
            const beforeWithdrawBob = await pika.balanceOf(bob.address)
            await pikaStaking.connect(bob).withdraw("2000000000000000000000");
            assertAlmostEqual((await pika.balanceOf(bob.address)).sub(beforeWithdrawBob), "2000000000000000000000")
            
            await pikaTokenReward.connect(alice).getReward()
            assertAlmostEqual(await esPika.balanceOf(alice.address), "400000000000000000000")

        })
    })
})
