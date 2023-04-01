
const { expect } = require("chai")
const hre = require("hardhat")
const { waffle } = require("hardhat")
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


describe("Vester", function () {
  let pikaContract, pika, esPika, vesterContract, vester, owner, alice, bob, treasury;
  before(async function () {
    this.wallets = provider.getWallets()
    owner = this.wallets[0]
    alice = this.wallets[1]
    bob = this.wallets[2]
    treasury = this.wallets[3]
    pikaContract = await hre.ethers.getContractFactory("Pika")
    vesterContract = await hre.ethers.getContractFactory("Vester")
  })

  beforeEach(async function () {
    pika = await pikaContract.deploy("Pika", "PIKA", "1000000000000000000000000000", owner.address, treasury.address)
    esPika = await pikaContract.deploy("ePika", "ePIKA", "1000000000000000000000000000", owner.address, owner.address)
    vester = await vesterContract.deploy(esPika.address, pika.address, treasury.address);
    await pika.connect(owner).transfer(vester.address, "6000000000000000000000") //6000 pika
    await esPika.connect(owner).grantRole("0x9143236d81225394f3bd65b44e6e29fdf4d7ba0773d9bb3f5cc15eb80ba37777", owner.address)
    await esPika.connect(owner).grantRole("0x9143236d81225394f3bd65b44e6e29fdf4d7ba0773d9bb3f5cc15eb80ba37777", vester.address)
    await esPika.connect(owner).transfer(alice.address, "10000000000000000000000") //10000 esPika

  })


  describe("test vester", async function(){
    it("deposit", async function () {
      await esPika.connect(alice).approve(vester.address, "100000000000000000000000")
      await vester.connect(alice).deposit("1000000000000000000000")
      await vester.connect(alice).deposit("1000000000000000000000")
      await vester.connect(alice).withdraw("1000000000000000000000", 2)
      expect(await vester.depositedAll(alice.address)).to.be.equal("1000000000000000000000")
      await vester.connect(alice).deposit("1000000000000000000000")
      expect(await vester.depositedAll(alice.address)).to.be.equal("2000000000000000000000")
      expect(await esPika.balanceOf(alice.address)).to.be.equal("8000000000000000000000")

      assertAlmostEqual(await vester.connect(alice).claimableAll(alice.address), "200000000000000000000")

      await provider.send("evm_increaseTime", [86400*365/2])
      await provider.send("evm_mine")
      assertAlmostEqual(await vester.connect(alice).claimableAll(alice.address), "1100000000000000000000")
      assertAlmostEqual(await vester.connect(alice).unvestedAll(alice.address), "900000000000000000000")

      await vester.connect(alice).claimAll();
      // console.log("pika balance", await pika.balanceOf(alice.address))
      assertAlmostEqual(await pika.balanceOf(alice.address), "1100000000000000000000")
      assertAlmostEqual(await pika.balanceOf(treasury.address), "900000000000000000000")

      await vester.connect(alice).deposit("1000000000000000000000")
      await provider.send("evm_increaseTime", [86400*365/4])
      await provider.send("evm_mine")
      assertAlmostEqual(await vester.connect(alice).claimableAll(alice.address), "325000000000000000000")
      await vester.connect(alice).claimAll();
      assertAlmostEqual(await pika.balanceOf(treasury.address), "1575000000000000000000")
      assertAlmostEqual(await pika.balanceOf(alice.address), "1425000000000000000000")
      // console.log("vested", await vester.unvested(alice.address, 1), await vester.vested(alice.address, 1))
      await expect(vester.connect(alice).withdraw("250000000000000000000", 1)).to.be.revertedWith("nothing to withdraw")
      expect(await vester.connect(alice).claimableAll(alice.address)).to.be.equal("0")
      expect(await vester.connect(alice).unvestedAll(alice.address)).to.be.equal("0")

      await vester.connect(alice).deposit("1000000000000000000000")
      await provider.send("evm_increaseTime", [86400*365/4])
      await provider.send("evm_mine")
      await vester.connect(alice).deposit("1000000000000000000000")
      assertAlmostEqual(await vester.connect(alice).claimableAll(alice.address), "425000000000000000000")
      assertAlmostEqual(await vester.connect(alice).unvestedAll(alice.address), "1575000000000000000000")
      await provider.send("evm_increaseTime", [86400*365])
      await provider.send("evm_mine")
      expect(await vester.connect(alice).claimableAll(alice.address)).to.be.equal("2000000000000000000000")
      expect(await vester.connect(alice).unvestedAll(alice.address)).to.be.equal("0")
      await vester.connect(alice).claimAll();
      assertAlmostEqual(await pika.balanceOf(alice.address), "3425000000000000000000");

      await vester.connect(alice).deposit("1000000000000000000000")
      await provider.send("evm_increaseTime", [86400*365/4])
      await provider.send("evm_mine")
      await vester.connect(alice).withdraw("500000000000000000000", 7)
      assertAlmostEqual(await vester.connect(alice).claimableAll(alice.address), "162500000000000000000");
      assertAlmostEqual(await vester.connect(alice).unvestedAll(alice.address), "337500000000000000000");

      await vester.connect(alice).claimAll();
      assertAlmostEqual(await pika.balanceOf(alice.address), "3587500000000000000000");
      assertAlmostEqual(await pika.balanceOf(treasury.address), "1912500000000000000000");
      assertAlmostEqual(await pika.balanceOf(vester.address), "500000000000000000000");
      assertAlmostEqual(await vester.totalPikaClaimed(), "3587500000000000000000");
      assertAlmostEqual(await vester.totalClaimFee(), "1912500000000000000000");
      assertAlmostEqual(await vester.totalEsPikaDeposit(), "5500000000000000000000");
    })
  })
})
