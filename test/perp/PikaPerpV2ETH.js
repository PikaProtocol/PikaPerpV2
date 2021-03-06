
const { ethers } = require("hardhat");
const { expect } = require("chai");
const { waffle } = require("hardhat");
const { parseUnits, formatUnits } = require('./utils.js');
const { utils, BigNumber } = require("ethers")
require("@nomiclabs/hardhat-web3");
const provider = waffle.provider

const maxShift = 0.003e8; // max shift (shift is used adjust the price to balance the longs and shorts)


let latestPrice = 3000e8;

function getOraclePrice(feed) {
	return latestPrice;
}

function _calculatePrice(feed, isLong, openInterestLong, openInterestShort, maxExposure, reserve, amount) {
	let oraclePrice = getOraclePrice(feed);

	let shift = (openInterestLong - openInterestShort) * maxShift / maxExposure;
	if (isLong) {
		// console.log("amount", amount)
		let slippage = parseInt((reserve * reserve / (reserve - amount) - reserve) * (10**8) / amount);
		slippage = shift >= 0 ? parseInt(slippage + shift) : Math.ceil(slippage - (-1 * shift / 2));
		// console.log("shift", shift)
		let price = oraclePrice * slippage / (10**8);
		// console.log("price", price);
		// console.log("price", price + price * fee / 10**4);
		return Math.ceil(price);
	} else {
		let slippage = parseInt((reserve - reserve * reserve / (reserve + amount)) * (10**8) / amount);
		slippage = shift >= 0 ? parseInt(slippage + shift / 2) : parseInt(slippage - (-1 * shift));
		// console.log("shift", shift)
		let price = oraclePrice * slippage / (10**8);
		// console.log("oraclePrice", oraclePrice);
		// console.log("price", price);
		// console.log("price", price - price * fee / 10**4);
		return Math.ceil(price);
	}
}

function getInterestFee(margin, leverage, interest, interval) {
	return margin * leverage * interest * interval / ((10**12) * (86400 * 365));
}

function getPositionId(account, productId, isLong) {
	return web3.utils.soliditySha3(
		{t: 'address', v: account},
		{t: 'uint256', v: productId},
		{t: 'bool', v: isLong}
	);
}

// Assert that actual is less than 1/accuracy difference from expected
function assertAlmostEqual(actual, expected, accuracy = 10000000) {
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


describe("Trading", () => {

	let trading, addrs = [], owner, oracle, pika, pikaStaking, vaultFeeReward, vaultTokenReward, rewardToken;

	before(async () => {

		addrs = provider.getWallets();
		owner = addrs[0];

		const oracleContract = await ethers.getContractFactory("MockOracle");
		oracle = await oracleContract.deploy();

		const tradingContract = await ethers.getContractFactory("PikaPerpV2");
		trading = await tradingContract.deploy("0x0000000000000000000000000000000000000000", 18, oracle.address, 1000000);

		const pikaContract = await ethers.getContractFactory("TestUSDC");
		pika = await pikaContract.deploy();
		const pikaStakingContract = await ethers.getContractFactory("PikaStaking");
		pikaStaking = await pikaStakingContract.deploy(pika.address, "0x0000000000000000000000000000000000000000");
		const vaultFeeRewardContract = await ethers.getContractFactory("VaultFeeReward");
		vaultFeeReward = await vaultFeeRewardContract.deploy(trading.address, "0x0000000000000000000000000000000000000000", 18);
		const mockRewardTokenContract = await ethers.getContractFactory("TestUSDC");
		rewardToken = await mockRewardTokenContract.deploy();
		await rewardToken.mint(owner.address, 100000000000);
		const vaultTokenRewardContract = await ethers.getContractFactory("VaultTokenReward");
		vaultTokenReward = await vaultTokenRewardContract.deploy(owner.address, rewardToken.address, trading.address);

		await trading.setDistributors(addrs[2].address, pikaStaking.address, vaultFeeReward.address, vaultTokenReward.address);
		await pikaStaking.setPikaPerp(trading.address);
		await vaultFeeReward.setPikaPerp(trading.address);
		await pika.mint(owner.address, "10000000000000000000000000")
		await pika.mint(addrs[1].address, "10000000000000000000000000")
		await pika.approve(pikaStaking.address, "1000000000000000000000000000");
		await pika.connect(addrs[1]).approve(pikaStaking.address, "1000000000000000000000000000");

		let v = [
			100000000000, //1k eth cap
			0,
			0,
			0,
			3600
		]

		await trading.updateVault(v);

		let p = [
			oracle.address, // chainlink
			50e8,
			0.1 * 100, // 0.1%
			true,
			0,
			0,
			0, // 0% annual interest
			80 * 100, // 80%
			50 * 100, // 50%
			150, // 1.5%, minPriceChange
			10,
			5000e8 // 5k eth
		]
		// add products
		await trading.addProduct(1, p);
		// set maxMargin
		await trading.setMaxPositionMargin(10000000000000);


	});

	it("Owner should be set", async () => {
		expect(await trading.owner()).to.equal(owner.address);
	});


	it("Should fail setting owner from other address", async () => {
		await expect(trading.connect(addrs[1]).setOwner(addrs[1].address)).to.be.revertedWith('!owner');
	});


	describe("trade", () => {


		const productId = 1;
		const margin = 1e8; // 1eth
		const leverage = 10e8;
		const userId = 1;
		const gasPrice = 3e8

		before(async () => {
			// console.log("owner", await trading.owner());
			// console.log(owner.address)
			await trading.connect(owner).stake(10000000000, {from: owner.address, value: "100000000000000000000"}); // stake 100 eth
		})

		it(`long positions`, async () => {

			const user = addrs[userId].address;

			const balance_user = await provider.getBalance(user);
			const balance_contract = await provider.getBalance(trading.address);

			// 1. open long
			const price1 = _calculatePrice(oracle.address, true, 0, 0, parseFloat((await trading.getVault()).balance), 5000e8, margin*leverage/1e8);
			let fee = margin*leverage/1e8*0.001;
			const tx1 = await trading.connect(addrs[userId]).openPosition(productId, margin, true, leverage.toString(), {from: addrs[1].address, value: (margin*1e10 + fee*1e10).toString(), gasPrice: gasPrice.toString()});
			const receipt = await provider.getTransactionReceipt(tx1.hash);

			let positionId = getPositionId(user, productId, true);
			expect(await tx1).to.emit(trading, "NewPosition").withArgs(positionId, user, productId, true, price1.toString(), getOraclePrice(oracle.address), margin.toString(), leverage.toString(), margin*leverage/1e8*0.001);
			// Check balances
			// console.log("balance contract", (balance_contract + margin*1e10 + fee*1e10*0.7).toLocaleString('fullwide', {useGrouping:false}))
			// console.log(margin*1e10, fee*1e10*0.7)
			// console.log("current contract balance", (await provider.getBalance(trading.address)).toString())
			assertAlmostEqual(await provider.getBalance(user), (balance_user - margin*1e10 - fee*1e10).toLocaleString('fullwide', {useGrouping:false}))
			assertAlmostEqual(await provider.getBalance(trading.address), (parseFloat(balance_contract) + margin*1e10 + fee*1e10).toLocaleString('fullwide', {useGrouping:false}))
			// // Check user positions
			const position1 = (await trading.getPositions([positionId]))[0];
			expect(position1.productId).to.equal(productId);
			expect(position1.owner).to.equal(user);
			expect(position1.isLong).to.equal(true);
			expect(position1.margin).to.equal(margin);
			expect(position1.leverage).to.equal(leverage);
			assertAlmostEqual(position1.price, price1);
			// console.log("after open long", (await usdc.balanceOf(trading.address)).toString());

			// 2. increase position
			const leverage2 = parseUnits(20)
			const price2 = _calculatePrice(oracle.address, true, margin*leverage/1e8, 0, parseFloat((await trading.getVault()).balance), 5000e8, margin*leverage2/1e8);
			await trading.connect(addrs[userId]).openPosition(productId, margin, true, leverage2.toString(), {from: addrs[1].address, value:  (margin*1e10 + fee*2e10).toString(), gasPrice: gasPrice});
			const position2 = (await trading.getPositions([positionId]))[0];
			expect(position2.margin).to.equal(margin*2);
			expect(position2.leverage).to.equal(leverage*1.5);
			assertAlmostEqual(position2.price, ((price1+price2*2)/3).toFixed(0));
			// console.log("after increase long", (await usdc.balanceOf(trading.address)).toString());

			// 3. close long before minProfitTime with profit less than threshold
			await provider.send("evm_increaseTime", [500])
			latestPrice = 3029e8;
			const price3 = _calculatePrice(oracle.address, false, 3*margin*leverage/1e8, 0, parseFloat((await trading.getVault()).balance), 5000e8, 3*margin*leverage/1e8);
			await oracle.setPrice(3029e8);
			const totalFee = parseInt(3*margin*leverage/1e8*0.001 + getInterestFee(3*margin, leverage, 0, 500));
			const tx3 = await trading.connect(addrs[userId]).closePositionWithId(positionId, 3*margin);
			expect(await tx3).to.emit(trading, "ClosePosition").withArgs(positionId, user, productId, price3.toString(), position2.price, (2*margin).toString(), (leverage*1.5).toString(), totalFee.toString(), 0, false);
			// console.log("after close long", (await usdc.balanceOf(trading.address)).toString());
			// console.log("vault balance", (await trading.getVault()).balance.toString());
		});

		it(`long and partial close`, async () => {

			const user = addrs[userId].address;

			const balance_user = await provider.getBalance(user);
			const balance_contract = await provider.getBalance(trading.address);

			// 1. open long
			const price1 = _calculatePrice(oracle.address, true, 0, 0, parseFloat((await trading.getVault()).balance), 5000e8, margin*leverage/1e8);
			let fee = margin*leverage/1e8*0.001;
			const tx1 = await trading.connect(addrs[userId]).openPosition(productId, margin, true, leverage.toString(), {from: addrs[1].address, value:  (margin*1e10 + fee*2e10).toString(), gasPrice: gasPrice});
			const receipt = await provider.getTransactionReceipt(tx1.hash);

			let positionId = getPositionId(user, productId, true);
			expect(await tx1).to.emit(trading, "NewPosition").withArgs(positionId, user, productId, true, price1.toString(), getOraclePrice(oracle.address), margin.toString(), leverage.toString(), margin*leverage/1e8*0.001);
			// Check balances
			let newUserBalance = balance_user - margin*1e10 - fee*1e10;
			let newContractBalance = parseFloat(balance_contract) + margin*1e10 + fee*1e10;
			assertAlmostEqual(await provider.getBalance(user), newUserBalance.toLocaleString('fullwide', {useGrouping:false}))
			assertAlmostEqual(await provider.getBalance(trading.address), newContractBalance.toLocaleString('fullwide', {useGrouping:false}))

			// // Check user positions
			const position1 = (await trading.getPositions([positionId]))[0];
			expect(position1.productId).to.equal(productId);
			expect(position1.owner).to.equal(user);
			expect(position1.isLong).to.equal(true);
			expect(position1.margin).to.equal(margin);
			expect(position1.leverage).to.equal(leverage);
			assertAlmostEqual(position1.price, price1);
			// console.log("after open long", (await usdc.balanceOf(trading.address)).toString());

			// 2. partial close long before minProfitTime with profit less than threshold
			await provider.send("evm_increaseTime", [500])
			latestPrice = 3029e8;
			const price3 = _calculatePrice(oracle.address, false, margin*leverage/1e8, 0, parseFloat((await trading.getVault()).balance), 5000e8, margin/2*leverage/1e8);
			await oracle.setPrice(3029e8);
			const tx3 = await trading.connect(addrs[userId]).closePositionWithId(positionId, margin/2);
			// expect(await tx3).to.emit(trading, "ClosePosition").withArgs(positionId, user, productId, false, price3.toString(), position1.price, (margin/2).toString(), leverage.toString(), 0, true, false);
			// assertAlmostEqual(await usdc.balanceOf(user),  (newUserBalance - margin/200 - fee/200).toLocaleString('fullwide', {useGrouping:false}))
			// assertAlmostEqual(await usdc.balanceOf(trading.address), newContractBalance.add(BigNumber.from(margin/200 + fee/200)))
			await trading.connect(addrs[userId]).closePositionWithId(positionId, margin/2);
		});

		it(`short positions`, async () => {

			const user = addrs[userId].address;

			const balance_user = await provider.getBalance(user);
			const balance_contract = await provider.getBalance(trading.address);

			// 1. open short
			const price1 = _calculatePrice(oracle.address, false, 0, 0, parseFloat((await trading.getVault()).balance), 5000e8, margin*leverage/1e8);
			let fee = margin*leverage/1e8*0.001;
			const tx1 = await trading.connect(addrs[userId]).openPosition(productId, margin, false, leverage.toString(), {from: addrs[1].address, value:  (margin*1e10 + fee*2e10).toString(), gasPrice: gasPrice});
			let positionId = getPositionId(user, productId, false, false);
			expect(await tx1).to.emit(trading, "NewPosition").withArgs(positionId, user, productId, false, price1.toString(), getOraclePrice(oracle.address), margin.toString(), leverage.toString(), margin*leverage/1e8*0.001);

			// Check balances
			assertAlmostEqual(await provider.getBalance(user), (balance_user - margin*1e10 - fee*1e10).toLocaleString('fullwide', {useGrouping:false}))
			assertAlmostEqual(await provider.getBalance(trading.address), (parseFloat(balance_contract) + margin*1e10 + fee*1e10).toLocaleString('fullwide', {useGrouping:false}))

			// // Check user positions
			const position1 = (await trading.getPositions([positionId]))[0];
			expect(position1.productId).to.equal(productId);
			expect(position1.owner).to.equal(user);
			expect(position1.isLong).to.equal(false);
			expect(position1.margin).to.equal(margin);
			expect(position1.leverage).to.equal(leverage);
			assertAlmostEqual(position1.price, price1);
			// console.log("after open short", (await usdc.balanceOf(trading.address)).toString());

			// 2. increase position
			const leverage2 = parseUnits(20)
			const price2 = _calculatePrice(oracle.address, false, 0, margin*leverage/1e8, parseFloat((await trading.getVault()).balance), 5000e8, margin*leverage2/1e8);
			await trading.connect(addrs[userId]).openPosition(productId, margin, false, leverage2.toString(), {from: addrs[1].address, value:  (margin*1e10 + fee*2e10).toString(), gasPrice: gasPrice});
			const position2 = (await trading.getPositions([positionId]))[0];
			expect(position2.margin).to.equal(margin*2);
			expect(position2.leverage).to.equal(leverage*1.5);
			// console.log("postion2 price", position2.price.toString());
			assertAlmostEqual(position2.price, ((price1+price2*2)/3).toFixed(0));
			// console.log("after increase short", (await usdc.balanceOf(trading.address)).toString());

			// 3. close short before minProfitTime with profit less than threshold
			// console.log("closing short")
			await provider.send("evm_increaseTime", [200])
			latestPrice = 3000e8;
			const price3 = _calculatePrice(oracle.address, true, 0, 3*margin*leverage/1e8, parseFloat((await trading.getVault()).balance), 5000e8, 3*margin*leverage/1e8);
			await oracle.setPrice(3000e8);
			// await trading.setFees(0.01e8, 0);
			// const tx3 = await trading.connect(addrs[userId]).closePosition(positionId, 3*margin);
			const tx3 = await trading.connect(addrs[userId]).closePosition(1, 3*margin, false);
			// console.log("after close short", (await usdc.balanceOf(trading.address)).toString());
			// console.log("vault balance", (await trading.getVault()).balance.toString());
			const totalFee = 3*margin*leverage/1e8*0.001 + getInterestFee(3*margin, leverage, 0, 200);
			// console.log(totalFee);
			expect(await tx3).to.emit(trading, "ClosePosition").withArgs(positionId, user, productId, price3.toString(), position2.price, (2*margin).toString(), (leverage*1.5).toString(), totalFee.toString(), 0, false);

		});

		it(`liquidations`, async () => {

			const user = addrs[userId].address;

			const balance_user = await provider.getBalance(user);
			const balance_contract = await provider.getBalance(trading.address);

			// 1. open long
			latestPrice = 3000e8;
			await oracle.setPrice(3000e8);
			const price1 = _calculatePrice(oracle.address, true, 0, 0, parseFloat((await trading.getVault()).balance), 5000e8, margin*leverage/1e8);
			let fee = margin*leverage/1e8*0.001;
			const tx1 = await trading.connect(addrs[userId]).openPosition(productId, margin, true, leverage.toString(), {from: addrs[1].address, value:  (margin*1e10 + fee*2e10).toString(), gasPrice: gasPrice});

			let positionId = getPositionId(user, productId, true);
			expect(await tx1).to.emit(trading, "NewPosition").withArgs(positionId, user, productId, true, price1.toString(), getOraclePrice(oracle.address), margin.toString(), leverage.toString(), margin*leverage/1e8*0.001);

			// Check balances
			assertAlmostEqual(await provider.getBalance(user), (balance_user - margin*1e10 - fee*1e10).toLocaleString('fullwide', {useGrouping:false}))
			// assertAlmostEqual(await usdc.balanceOf(trading.address), (balance_contract.add(BigNumber.from(margin/100))))

			// // Check user positions
			const position1 = (await trading.getPositions([positionId]))[0];
			expect(position1.productId).to.equal(productId);
			expect(position1.owner).to.equal(user);
			expect(position1.isLong).to.equal(true);
			expect(position1.margin).to.equal(margin);
			expect(position1.leverage).to.equal(leverage);
			assertAlmostEqual(position1.price, price1);
			// console.log("after open long", (await usdc.balanceOf(trading.address)).toString());

			// 2. liquidation
			await provider.send("evm_increaseTime", [500])
			latestPrice = 2760e8;
			// const price3 = _calculatePriceWithFee(oracle.address, 10, false, margin*leverage/1e8, 0, 100000000e8, 50000000e8, margin*leverage/1e8);
			await oracle.setPrice(2760e8);
			await trading.connect(owner).setAllowPublicLiquidator(true);
			const tx3 = await trading.connect(addrs[userId]).liquidatePositions([positionId]);
			const totalFee = getInterestFee(3*margin, leverage, 0, 500);
			expect(await tx3).to.emit(trading, "ClosePosition").withArgs(positionId, user, productId, latestPrice, position1.price, margin.toString(), leverage.toString(), totalFee, margin.toString(), true);
			// console.log("after liquidation", (await usdc.balanceOf(trading.address)).toString());
			// console.log("vault balance", (await trading.getVault()).balance.toString());
		});

		it(`stake`, async () => {
			await provider.send("evm_increaseTime", [80])
			const vault1 = await trading.getVault();
			// console.log(vault1.staked.toString())
			// console.log("Vault1 balance", vault1.balance.toString())
			// console.log(vault1.shares.toString())
			await trading.connect(owner).setCanUserStake(true);
			const amount = 10000000000;
			await trading.connect(addrs[1]).stake(amount, {from: addrs[1].address, value:  (amount*1e10).toString(), gasPrice: gasPrice});

			const stake0 = await trading.getStake(owner.address);
			const stake1 = await trading.getStake(addrs[1].address);
			expect(stake0.shares).to.equal(BigNumber.from(vault1.shares))
			expect(stake1.shares).to.equal(BigNumber.from(amount).mul(vault1.shares).div(vault1.balance))
			const vault2 = await trading.getVault();
			// console.log(vault2.staked.toString())
			// console.log(vault2.balance.toString())
			// console.log(vault2.shares.toString())
			const userBalanceStart = await provider.getBalance(owner.address);
			await trading.connect(owner).redeem(5000000000); // redeem half
			// const userBalanceNow = await provider.getBalance(owner.address);
			// assertAlmostEqual(userBalanceNow.sub(userBalanceStart), vault1.balance.div(100).div(2))
		})

		it(`pika staking`, async () => {
			// staking
			let fee = margin*leverage/1e8*0.001;
			const pendingPikaReward = await trading.getPendingPikaReward();
			await pikaStaking.connect(owner).stake("100000000000000000000");
			expect(await provider.getBalance(pikaStaking.address)).to.be.equal(pendingPikaReward);
			expect(await trading.getPendingPikaReward()).to.be.equal(0);
			await trading.connect(addrs[userId]).openPosition(productId, margin, true, leverage.toString(), {from: addrs[1].address, value:  (margin*1e10 + fee*2e10).toString(), gasPrice: gasPrice});
			await pikaStaking.connect(owner).stake("100000000000000000000");
			expect((await pikaStaking.getClaimableReward(owner.address)).toString()).to.be.equal("3000000000000000");
			await trading.connect(addrs[userId]).openPosition(productId, margin, true, leverage.toString(), {from: addrs[userId].address, value:  (margin*1e10 + fee*2e10).toString(), gasPrice: gasPrice});
			await pikaStaking.connect(addrs[1]).stake("100000000000000000000");
			expect((await pikaStaking.getClaimableReward(owner.address)).toString()).to.be.equal("6000000000000000");
			expect(await pikaStaking.totalSupply()).to.be.equal("300000000000000000000");

			await trading.connect(addrs[userId]).openPosition(productId, margin, true, leverage.toString(), {from: addrs[userId].address, value:  (margin*1e10 + fee*2e10).toString(), gasPrice: gasPrice});
			expect((await pikaStaking.getClaimableReward(owner.address)).toString()).to.be.equal("8000000000000000");
			expect((await pikaStaking.connect(addrs[1]).getClaimableReward(addrs[1].address)).toString()).to.be.equal("1000000000000000");
			// claim
			const ethBeforeClaim = await provider.getBalance(owner.address);
			await pikaStaking.connect(owner).claimReward();
			assertAlmostEqual((await provider.getBalance(owner.address)).sub(ethBeforeClaim), "8000000000000000", 10);
			// withdraw
			const pikaBalanceBefore = await pika.balanceOf(addrs[1].address);
			await pikaStaking.connect(addrs[1]).withdraw("100000000000000000000");
			expect((await pika.balanceOf(addrs[1].address)).sub(pikaBalanceBefore), "100000000000000000000");
			const ethBeforeClaim2 = await provider.getBalance(addrs[1].address);
			await pikaStaking.connect(addrs[1]).claimReward();
			assertAlmostEqual((await provider.getBalance(addrs[1].address)).sub(ethBeforeClaim2), "1000000000000000", 1);

			await trading.connect(addrs[userId]).closePosition(productId, margin*3, true);
		})


		it(`vault fee reward`, async () => {
			// redeem all
			let fee = margin*leverage/1e8*0.001;
			await provider.send("evm_increaseTime", [3600])
			const startVaultFeeContractETH = await provider.getBalance(vaultFeeReward.address);
			const pendingVaultReward = await trading.getPendingVaultReward();
			await trading.redeem((await trading.getShare(owner.address)));
			await trading.connect(addrs[1]).redeem(await trading.getShare(addrs[1].address));
			expect((await provider.getBalance(vaultFeeReward.address)).sub(startVaultFeeContractETH)).to.be.equal(pendingVaultReward)

			// stake
			expect(await trading.getPendingVaultReward()).to.be.equal(0);
			// console.log("pendingPikaReward", (await trading.getPendingPikaReward()).toString());
			const startOwnerClaimableReward = await vaultFeeReward.getClaimableReward(owner.address);
			const startAddress1ClaimableReward = await vaultFeeReward.getClaimableReward(addrs[1].address);
			await trading.connect(owner).stake("10000000000", {from: owner.address, value: "100000000000000000000"});
			await trading.connect(owner).openPosition(productId, margin, true, leverage.toString(), {from: owner.address, value:  (margin*1e10 + fee*2e10).toString(), gasPrice: gasPrice});

			expect((await vaultFeeReward.getClaimableReward(owner.address)).sub(startOwnerClaimableReward)).to.be.equal("5000000000000000");

			await trading.connect(addrs[1]).stake("10000000000", {from: addrs[1].address, value: "100000000000000000000"});
			expect((await vaultFeeReward.getClaimableReward(addrs[1].address)).sub(startAddress1ClaimableReward)).to.be.equal("0");
			expect(await trading.getTotalShare()).to.be.equal("20000000000");

			await trading.connect(addrs[userId]).openPosition(productId, margin, true, leverage.toString(), {from: addrs[userId].address, value:  (margin*1e10 + fee*2e10).toString(), gasPrice: gasPrice});

			expect((await vaultFeeReward.getClaimableReward(owner.address)).sub(startOwnerClaimableReward)).to.be.equal("7500000000000000");
			expect((await vaultFeeReward.getClaimableReward(addrs[1].address)).sub(startAddress1ClaimableReward)).to.be.equal("2500000000000000");
			const ethBeforeClaim = await provider.getBalance(owner.address);
			const currentClaimableReward = await vaultFeeReward.getClaimableReward(owner.address);
			await vaultFeeReward.connect(owner).claimReward();
			assertAlmostEqual(((await provider.getBalance(owner.address)).sub(ethBeforeClaim)), currentClaimableReward, 100);

			// redeem
			const shareBefore = await trading.getShare(addrs[1].address);
			await provider.send("evm_increaseTime", [3600])
			await trading.connect(addrs[1]).redeem(shareBefore);
			expect(await trading.getShare(addrs[1].address)).to.be.equal(0);
			const ethBeforeClaim2 = await provider.getBalance(addrs[1].address);
			const currentClaimableRewardAddrs1 = await vaultFeeReward.getClaimableReward(addrs[1].address);
			await vaultFeeReward.connect(addrs[1]).claimReward();
			// assertAlmostEqual(((await provider.getBalance(addrs[1].address)).sub(ethBeforeClaim2)), currentClaimableRewardAddrs1, 100);
			assertAlmostEqual(((await provider.getBalance(addrs[1].address)).sub(ethBeforeClaim2)), currentClaimableRewardAddrs1, 10);
			//
			await trading.connect(owner).closePosition(productId, margin, true);
			await trading.connect(addrs[userId]).closePosition(productId, margin, true);
			await trading.connect(owner).redeem((await trading.getShare(owner.address)));
		})

		it(`vault token reward`, async () => {
			const account1 = addrs[3]
			const account2 = addrs[4]

			// account1 stake
			await trading.connect(account1).stake("50000000000", {from: account1.address, value: "500000000000000000000"});
			expect(await vaultTokenReward.balanceOf(account1.address)).to.be.equal("500000000000000000000")

			await rewardToken.mint(owner.address, "1000000000000000000000");
			await rewardToken.connect(owner).transfer(vaultTokenReward.address, "1000000000000000000000");
			await vaultTokenReward.connect(owner).notifyRewardAmount("1000000000000000000000");
			const rewardRate = await vaultTokenReward.rewardRate();

			// 1 hour later stakingAccount1 check rewards
			await provider.send("evm_increaseTime", [3600])
			await provider.send("evm_mine")
			const account1Earned = await vaultTokenReward.earned(account1.address);
			assertAlmostEqual(account1Earned, rewardRate.mul(3600), 1000)

			// account2 stake the same amount as stakingAccount1's current staked balance
			await trading.connect(account2).stake("50000000000", {from: account2.address, value: "500000000000000000000"});
			expect(await vaultTokenReward.balanceOf(account2.address)).to.be.equal("500000000000000000000")
			expect(await trading.getTotalShare()).to.be.equal("100000000000")

			// 1 hour later check rewards
			await provider.send("evm_increaseTime", [3600])
			await provider.send("evm_mine")
			const newRewardRate = await vaultTokenReward.rewardRate();
			const newAccount1Earned = await vaultTokenReward.earned(account1.address)
			const account2Earned = await vaultTokenReward.earned(account2.address)
			assertAlmostEqual(newAccount1Earned.sub(account1Earned), newRewardRate.mul(3600).div(2), 100)
			assertAlmostEqual(account2Earned, newRewardRate.mul(3600).div(2), 100)

			// claim reward for account1
			await vaultTokenReward.connect(account1).getReward()
			assertAlmostEqual(await rewardToken.balanceOf(account1.address), newAccount1Earned, 1000)

			// claim reward for account2
			await vaultTokenReward.connect(account2).getReward()
			assertAlmostEqual(await rewardToken.balanceOf(account2.address), account2Earned, 1000)
			expect(await trading.getTotalShare()).to.be.equal("100000000000")
		})
	});
});
