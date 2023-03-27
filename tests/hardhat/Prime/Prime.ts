import { FakeContract, MockContract, smock } from "@defi-wonderland/smock";
import { loadFixture, mine } from "@nomicfoundation/hardhat-network-helpers";
import { Libraries } from "@nomiclabs/hardhat-ethers/types";
import chai from "chai";
import { BigNumber, Signer } from "ethers";
import { ethers } from "hardhat";

import { convertToUnit } from "../../../helpers/utils";
import {
  BEP20Harness,
  Comptroller,
  ComptrollerLens,
  ComptrollerLens__factory,
  Comptroller__factory,
  IAccessControlManager,
  InterestRateModelHarness,
  PriceOracle,
  PrimeScenario,
  VBep20Harness,
  XVS,
  XVSStore,
  XVSVault,
  XVSVaultScenario,
} from "../../../typechain";
import { xvs } from "../../../typechain/contracts/Tokens";

const { expect } = chai;
chai.use(smock.matchers);

export const bigNumber18 = BigNumber.from("1000000000000000000"); // 1e18
export const bigNumber16 = BigNumber.from("10000000000000000"); // 1e16

type SetupProtocolFixture = {
  oracle: FakeContract<PriceOracle>;
  accessControl: FakeContract<IAccessControlManager>;
  comptrollerLens: MockContract<ComptrollerLens>;
  comptroller: MockContract<Comptroller>;
  usdt: BEP20Harness;
  vusdt: VBep20Harness;
  eth: BEP20Harness;
  veth: VBep20Harness;
  xvsVault: XVSVaultScenario;
  xvs: XVS;
  xvsStore: XVSStore;
  prime: PrimeScenario;
};

async function deployProtocol(): Promise<SetupProtocolFixture> {
  const [wallet, ...accounts] = await ethers.getSigners();

  const oracle = await smock.fake<PriceOracle>("PriceOracle");
  const accessControl = await smock.fake<IAccessControlManager>("AccessControlManager");
  accessControl.isAllowedToCall.returns(true);
  const ComptrollerLensFactory = await smock.mock<ComptrollerLens__factory>("ComptrollerLens");
  const ComptrollerFactory = await smock.mock<Comptroller__factory>("Comptroller");
  const comptroller = await ComptrollerFactory.deploy();
  const comptrollerLens = await ComptrollerLensFactory.deploy();
  await comptroller._setAccessControl(accessControl.address);
  await comptroller._setComptrollerLens(comptrollerLens.address);
  await comptroller._setPriceOracle(oracle.address);
  await comptroller._setLiquidationIncentive(convertToUnit("1", 18));

  const tokenFactory = await ethers.getContractFactory("BEP20Harness");
  const usdt = (await tokenFactory.deploy(
    bigNumber18.mul(100000000),
    "usdt",
    BigNumber.from(18),
    "BEP20 usdt",
  )) as BEP20Harness;

  const eth = (await tokenFactory.deploy(
    bigNumber18.mul(100000000),
    "eth",
    BigNumber.from(18),
    "BEP20 eth",
  )) as BEP20Harness;

  const interestRateModelHarnessFactory = await ethers.getContractFactory("InterestRateModelHarness");
  const InterestRateModelHarness = (await interestRateModelHarnessFactory.deploy(
    BigNumber.from(18).mul(5),
  )) as InterestRateModelHarness;

  const vTokenFactory = await ethers.getContractFactory("VBep20Harness");
  const vusdt = (await vTokenFactory.deploy(
    usdt.address,
    comptroller.address,
    InterestRateModelHarness.address,
    bigNumber18,
    "VToken usdt",
    "vusdt",
    BigNumber.from(18),
    wallet.address,
  )) as VBep20Harness;
  const veth = (await vTokenFactory.deploy(
    eth.address,
    comptroller.address,
    InterestRateModelHarness.address,
    bigNumber18,
    "VToken eth",
    "veth",
    BigNumber.from(18),
    wallet.address,
  )) as VBep20Harness;

  //0.2 reserve factor
  await veth._setReserveFactor(bigNumber16.mul(20));
  await vusdt._setReserveFactor(bigNumber16.mul(20));

  oracle.getUnderlyingPrice.returns((vToken: string) => {
    if (vToken == vusdt.address) {
      return convertToUnit(1, 18);
    } else if (vToken == veth.address) {
      return convertToUnit(1200, 18);
    }
  });

  const half = convertToUnit("0.5", 18);
  await comptroller._supportMarket(vusdt.address);
  await comptroller._setCollateralFactor(vusdt.address, half);
  await comptroller._supportMarket(veth.address);
  await comptroller._setCollateralFactor(veth.address, half);

  eth.transfer(accounts[0].address, bigNumber18.mul(100));
  usdt.transfer(accounts[1].address, bigNumber18.mul(10000));

  await comptroller._setMarketSupplyCaps([vusdt.address, veth.address], [bigNumber18.mul(10000), bigNumber18.mul(100)]);

  await comptroller._setMarketBorrowCaps([vusdt.address, veth.address], [bigNumber18.mul(10000), bigNumber18.mul(100)]);

  const xvsFactory = await ethers.getContractFactory("XVS");
  const xvs: XVS = (await xvsFactory.deploy(wallet.address)) as XVS;

  const xvsStoreFactory = await ethers.getContractFactory("XVSStore");
  const xvsStore: XVSStore = (await xvsStoreFactory.deploy()) as XVSStore;

  const xvsVaultFactory = await ethers.getContractFactory("XVSVaultScenario");
  const xvsVault: XVSVaultScenario = (await xvsVaultFactory.deploy()) as XVSVaultScenario;

  await xvsStore.setNewOwner(xvsVault.address);
  await xvsVault.setXvsStore(xvs.address, xvsStore.address);

  await xvs.transfer(xvsStore.address, bigNumber18.mul(1000));
  await xvs.transfer(accounts[0].address, bigNumber18.mul(1000000));
  await xvs.transfer(accounts[1].address, bigNumber18.mul(1000000));

  await xvsStore.setRewardToken(xvs.address, true);

  const lockPeriod = 300;
  const allocPoint = 100;
  const poolId = 0;
  const rewardPerBlock = bigNumber18.mul(1);
  await xvsVault.add(xvs.address, allocPoint, xvs.address, rewardPerBlock, lockPeriod);

  const primeFactory = await ethers.getContractFactory("PrimeScenario");
  const prime: PrimeScenario = (await primeFactory.deploy()) as PrimeScenario;
  prime.initialize(
    xvsVault.address,
    xvs.address,
    0,
    1, 
    2
  );

  await xvsVault.setPrimeToken(prime.address, xvs.address, poolId);

  await prime.setLimit(1000, 1000);

  await prime.addMarket(
    vusdt.address,
    bigNumber18.mul("1"),
    bigNumber18.mul("1"),
  );

  await prime.addMarket(
    veth.address,
    bigNumber18.mul("1"),
    bigNumber18.mul("1"),
  );

  await vusdt._setPrimeToken(prime.address);
  await veth._setPrimeToken(prime.address);

  return {
    oracle,
    comptroller,
    comptrollerLens,
    accessControl,
    usdt,
    vusdt,
    eth,
    veth,
    xvsVault,
    xvs,
    xvsStore,
    prime,
  };
}

describe("PrimeScenario Token", () => {
  let accounts: Signer[];

  before(async () => {
    [, ...accounts] = await ethers.getSigners();
  });

  describe("protocol setup", () => {
    let comptroller: MockContract<Comptroller>;
    let vusdt: VBep20Harness;
    let veth: VBep20Harness;
    let usdt: BEP20Harness;
    let eth: BEP20Harness;

    beforeEach(async () => {
      ({ comptroller, vusdt, veth, usdt, eth } = await loadFixture(deployProtocol));

      await eth.connect(accounts[0]).approve(veth.address, bigNumber18.mul(90));
      await veth.connect(accounts[0]).mint(bigNumber18.mul(90));

      await usdt.connect(accounts[1]).approve(vusdt.address, bigNumber18.mul(9000));
      await vusdt.connect(accounts[1]).mint(bigNumber18.mul(9000));

      await comptroller.connect(accounts[0]).enterMarkets([vusdt.address, veth.address]);

      await comptroller.connect(accounts[1]).enterMarkets([vusdt.address, veth.address]);

      await vusdt.connect(accounts[0]).borrow(bigNumber18.mul(5));
      await veth.connect(accounts[1]).borrow(bigNumber18.mul(1));
    });

    it("markets added", async () => {
      expect(await comptroller.allMarkets(0)).to.be.equal(vusdt.address);
      expect(await comptroller.allMarkets(1)).to.be.equal(veth.address);
    });

    it("borrow balance", async () => {
      expect(await usdt.balanceOf(accounts[0].getAddress())).to.be.gt(0);
      expect(await eth.balanceOf(accounts[1].getAddress())).to.be.gt(0);
    });
  });

  describe("mint and burn", () => {
    let prime: PrimeScenario;
    let xvsVault: XVSVault;
    let xvs: XVS;

    beforeEach(async () => {
      ({ prime, xvsVault, xvs } = await loadFixture(deployProtocol));
    });

    it("stake and mint", async () => {
      const user = accounts[0];

      await expect(prime.connect(user).claim()).to.be.revertedWith("you are not eligible to claim prime token");

      await xvs.connect(user).approve(xvsVault.address, bigNumber18.mul(10000));
      let tx = await xvsVault.connect(user).deposit(xvs.address, 0, bigNumber18.mul(10000));
      
      let stake = await prime.stakedAt(user.getAddress());
      expect(stake).be.gt(0);

      await expect(prime.connect(user).claim()).to.be.revertedWith(
        "you need to wait more time for claiming prime token",
      );

      await mine(90 * 24 * 60 * 60);
      await expect(prime.connect(user).claim()).to.be.not.reverted;

      const token = await prime.tokens(user.getAddress())
      expect(token.isIrrevocable).to.be.equal(false);
      expect(token.exists).to.be.equal(true);

      stake = await prime.stakedAt(user.getAddress());
      expect(stake).be.equal(0);
    });

    it("stake and unstake", async () => {
      const user = accounts[0];

      await xvs.connect(user).approve(xvsVault.address, bigNumber18.mul(10000));
      await xvsVault.connect(user).deposit(xvs.address, 0, bigNumber18.mul(10000));

      let stake = await prime.stakedAt(user.getAddress());
      expect(stake).be.gt(0);

      await xvsVault.connect(user).requestWithdrawal(xvs.address, 0, bigNumber18.mul(1));

      stake = await prime.stakedAt(user.getAddress());
      expect(stake).be.gt(0);

      await xvsVault.connect(user).requestWithdrawal(xvs.address, 0, bigNumber18.mul(9999));
      stake = await prime.stakedAt(user.getAddress());
      expect(stake).be.equal(0);
    });

    it("burn", async () => {
      const user = accounts[0];

      await xvs.connect(user).approve(xvsVault.address, bigNumber18.mul(10000));
      await xvsVault.connect(user).deposit(xvs.address, 0, bigNumber18.mul(10000));
      await mine(90 * 24 * 60 * 60);
      await prime.connect(user).claim();

      expect(await prime._totalRevocable()).to.be.equal(1);

      await xvsVault.connect(user).requestWithdrawal(xvs.address, 0, bigNumber18.mul(5000));

      let token = await prime.tokens(user.getAddress())
      expect(token.exists).to.be.equal(true);
      expect(token.isIrrevocable).to.be.equal(false);

      await xvsVault.connect(user).requestWithdrawal(xvs.address, 0, bigNumber18.mul(5000));
      
      token = await prime.tokens(user.getAddress())
      expect(token.exists).to.be.equal(false);
      expect(token.isIrrevocable).to.be.equal(false);

      expect(await prime._totalRevocable()).to.be.equal(0);
    });

    it("issue", async () => {
      const [user1, user2, user3, user4] = accounts;

      await expect(prime.connect(user1).issue(false, [user1.getAddress()])).to.be.revertedWith(
        "Ownable: caller is not the owner",
      );

      await prime.issue(true, [user1.getAddress(), user2.getAddress()]);

      let token = await prime.tokens(user1.getAddress())
      expect(token.exists).to.be.equal(true);
      expect(token.isIrrevocable).to.be.equal(true);

      token = await prime.tokens(user2.getAddress())
      expect(token.isIrrevocable).to.be.equal(true);
      expect(token.exists).to.be.equal(true);

      await prime.issue(false, [user3.getAddress(), user4.getAddress()]);

      token = await prime.tokens(user3.getAddress())
      expect(token.isIrrevocable).to.be.equal(false);
      expect(token.exists).to.be.equal(true);

      token = await prime.tokens(user4.getAddress())
      expect(token.isIrrevocable).to.be.equal(false);
      expect(token.exists).to.be.equal(true);
    });
  });

  describe("boosted yield", () => {
    let comptroller: MockContract<Comptroller>;
    let prime: PrimeScenario;
    let vusdt: VBep20Harness;
    let veth: VBep20Harness;
    let usdt: BEP20Harness;
    let eth: BEP20Harness;
    let oracle: FakeContract<PriceOracle>;

    beforeEach(async () => {
      ({ comptroller, prime, vusdt, veth, usdt, eth, oracle } = await loadFixture(deployProtocol));

      await eth.connect(accounts[0]).approve(veth.address, bigNumber18.mul(90));
      await veth.connect(accounts[0]).mint(bigNumber18.mul(90));

      await usdt.connect(accounts[1]).approve(vusdt.address, bigNumber18.mul(9000));
      await vusdt.connect(accounts[1]).mint(bigNumber18.mul(9000));

      await comptroller.connect(accounts[0]).enterMarkets([vusdt.address, veth.address]);

      await comptroller.connect(accounts[1]).enterMarkets([vusdt.address, veth.address]);

      await vusdt.connect(accounts[0]).borrow(bigNumber18.mul(5));
      await veth.connect(accounts[1]).borrow(bigNumber18.mul(1));
    });

    it("calculate score", async () => {
      const xvsBalance = bigNumber18.mul(5000)
      const capital = bigNumber18.mul(120)

      // 5000^0.5 * 120^1-0.5 = 774.5966692
      expect((await prime.calculateScore(xvsBalance, capital)).toString()).to.be.equal("774596669241483420144")

      await prime.updateAlpha(4, 5); //0.80

      //  5000^0.8 * 120^1-0.8 = 2371.44061
      expect((await prime.calculateScore(xvsBalance, capital)).toString()).to.be.equal("2371440609779311958519")
    })

  //   it("accrue interest", async () => {
  //     const [user1, user2] = accounts;

  //     await prime.executeBoost(user1.getAddress(), vusdt.address);

  //     let interest = await prime._interests(vusdt.address, user1.getAddress());
  //     expect(interest.totalQVL).to.be.equal(0);

  //     await prime.issue(true, [user1.getAddress(), user2.getAddress()], [1, 1]);

  //     interest = await prime._interests(vusdt.address, user1.getAddress());
  //     expect(interest.totalQVL).to.be.equal(bigNumber18.mul(5));
  //     expect(interest.index).to.be.equal(bigNumber18.mul(1));
  //     expect(interest.accrued).to.be.equal(0);

  //     interest = await prime._interests(veth.address, user1.getAddress());
  //     expect(interest.totalQVL).to.be.equal(bigNumber18.mul(90));

  //     const market = await prime._markets(vusdt.address);
  //     expect(market.totalQVL).to.be.equal(bigNumber18.mul(9005));

  //     await mine(24 * 60 * 20);
  //     await prime.executeBoost(user1.getAddress(), vusdt.address);

  //     interest = await prime._interests(vusdt.address, user1.getAddress());

  //     /**
  //      * incomePerBlock * totalBlocks / totalQVL = 18 * 28800 / 9005000000000000000000 = 57
  //      */
  //     expect(interest.index).to.be.equal(BigNumber.from("1000000000000000057"));

  //     /**
  //      * accrued = index * qvl = 57 * 5 = 285
  //      */
  //     expect(interest.accrued).to.be.equal("285");

  //     expect(await prime.callStatic.getInterestAccrued(vusdt.address, user1.getAddress())).to.be.equal("285");
  //   });

  //   it("claim interest", async () => {
  //     const [user1, user2] = accounts;

  //     await prime.issue(true, [user1.getAddress(), user2.getAddress()], [1, 1]);

  //     await mine(24 * 60 * 20);
  //     await prime.executeBoost(user1.getAddress(), vusdt.address);

  //     await expect(prime.connect(user1).claimInterest(vusdt.address)).to.be.reverted;

  //     const interest = await prime.callStatic.getInterestAccrued(vusdt.address, user1.getAddress());
  //     await usdt.transfer(prime.address, interest);

  //     const previousBalance = await usdt.balanceOf(user1.getAddress());

  //     await expect(prime.connect(user1).claimInterest(vusdt.address)).to.be.not.reverted;

  //     const newBalance = await usdt.balanceOf(user1.getAddress());

  //     expect(newBalance).to.be.equal(previousBalance.add(interest));
  //   });

  //   describe("update QVL", () => {
  //     let vbnb: VBep20Harness;
  //     let bnb: BEP20Harness;

  //     beforeEach(async () => {
  //       const [wallet, ...accounts] = await ethers.getSigners();

  //       const tokenFactory = await ethers.getContractFactory("BEP20Harness");
  //       bnb = (await tokenFactory.deploy(
  //         bigNumber18.mul(100000000),
  //         "bnb",
  //         BigNumber.from(18),
  //         "BEP20 bnb",
  //       )) as BEP20Harness;

  //       const interestRateModelHarnessFactory = await ethers.getContractFactory("InterestRateModelHarness");
  //       const InterestRateModelHarness = (await interestRateModelHarnessFactory.deploy(
  //         BigNumber.from(18).mul(5),
  //       )) as InterestRateModelHarness;

  //       const vTokenFactory = await ethers.getContractFactory("VBep20Harness");
  //       vbnb = (await vTokenFactory.deploy(
  //         bnb.address,
  //         comptroller.address,
  //         InterestRateModelHarness.address,
  //         bigNumber18,
  //         "VToken bnb",
  //         "vbnb",
  //         BigNumber.from(18),
  //         wallet.address,
  //       )) as VBep20Harness;

  //       await vbnb._setReserveFactor(bigNumber16.mul(20));

  //       oracle.getUnderlyingPrice.returns((vToken: string) => {
  //         if (vToken == vusdt.address) {
  //           return convertToUnit(1, 18);
  //         } else if (vToken == veth.address) {
  //           return convertToUnit(1200, 18);
  //         } else if (vToken == vbnb.address) {
  //           return convertToUnit(300, 18);
  //         }
  //       });

  //       const half = convertToUnit("0.5", 8);
  //       await comptroller._supportMarket(vbnb.address);
  //       await comptroller._setCollateralFactor(vbnb.address, half);

  //       bnb.transfer(accounts[0].address, bigNumber18.mul(100));

  //       await comptroller._setMarketSupplyCaps([vbnb.address], [bigNumber18.mul(100)]);
  //       await comptroller._setMarketBorrowCaps([vbnb.address], [bigNumber18.mul(100)]);

  //       await bnb.connect(accounts[0]).approve(vbnb.address, bigNumber18.mul(90));
  //       await vbnb.connect(accounts[0]).mint(bigNumber18.mul(90));

  //       await vbnb.connect(accounts[1]).borrow(bigNumber18.mul(1));

  //       await prime.issue(false, [accounts[0].getAddress(), accounts[1].getAddress()], [1, 1]);

  //       await comptroller._setPrimeToken(prime.address);
  //       await vbnb._setPrimeToken(prime.address);
  //     });

  //     it("add existing market after issuing prime tokens", async () => {
  //       const [user1] = accounts;

  //       await mine(24 * 60 * 20);
  //       await prime.executeBoost(user1.getAddress(), vusdt.address);

  //       let interest = await prime._interests(vusdt.address, user1.getAddress());
  //       expect(interest.index).to.be.equal(BigNumber.from("1000000000000000057"));

  //       interest = await prime._interests(vbnb.address, user1.getAddress());
  //       expect(interest.index).to.be.equal(0);

  //       let status = await prime.isMarketPaused(vbnb.address);
  //       expect(status).to.be.equal(false);

  //       await prime.toggleMarketPause(vbnb.address);
  //       status = await prime.isMarketPaused(vbnb.address);
  //       expect(status).to.be.equal(true);

  //       await expect(prime.accrueInterest(vbnb.address)).to.be.revertedWith(
  //         "market is temporarily paused for configuring prime token",
  //       );

  //       await prime.addMarket(
  //         vbnb.address,
  //         [
  //           bigNumber18.mul("5"),
  //           bigNumber18.mul("25"),
  //           bigNumber18.mul("100"),
  //           bigNumber18.mul("500"),
  //           bigNumber18.mul("1000"),
  //         ],
  //         [
  //           bigNumber18.mul("10"),
  //           bigNumber18.mul("50"),
  //           bigNumber18.mul("200"),
  //           bigNumber18.mul("1000"),
  //           bigNumber18.mul("2000"),
  //         ],
  //       );

  //       await expect(vbnb.connect(accounts[0]).mint(bigNumber18.mul(90))).to.be.reverted;

  //       await prime.updateQVLs([accounts[0].getAddress()], vbnb.address);

  //       await prime.toggleMarketPause(vbnb.address);
  //       status = await prime.isMarketPaused(vbnb.address);
  //       expect(status).to.be.equal(false);

  //       let accruedInterest = await prime.callStatic.getInterestAccrued(vbnb.address, accounts[0].getAddress());
  //       expect(accruedInterest).to.be.equal(10);

  //       await mine(24 * 60 * 20);

  //       accruedInterest = await prime.callStatic.getInterestAccrued(vbnb.address, accounts[0].getAddress());
  //       expect(accruedInterest).to.be.equal("103690");
  //     });

  //     it("update QVL of existing market", async () => {
  //       const [user1] = accounts;

  //       let interest = await prime._interests(vusdt.address, user1.getAddress());
  //       expect(interest.totalQVL).to.be.equal(bigNumber18.mul(5));
  //       expect(interest.index).to.be.equal(bigNumber18.mul(1));
  //       expect(interest.accrued).to.be.equal(0);

  //       await mine(24 * 60 * 20);

  //       await prime.toggleMarketPause(vusdt.address);
  //       await prime.accrueInterestForUsers([user1.getAddress()], vusdt.address);
  //       await prime.updateQVLCaps(
  //         vusdt.address,
  //         [
  //           bigNumber18.mul("1"),
  //           bigNumber18.mul("4"),
  //           bigNumber18.mul("5"),
  //           bigNumber18.mul("6"),
  //           bigNumber18.mul("7"),
  //         ],
  //         [
  //           bigNumber18.mul("1"),
  //           bigNumber18.mul("4"),
  //           bigNumber18.mul("5"),
  //           bigNumber18.mul("6"),
  //           bigNumber18.mul("7"),
  //         ],
  //       );
  //       await prime.updateQVLs([user1.getAddress()], vusdt.address);
  //       await prime.toggleMarketPause(vusdt.address);

  //       interest = await prime._interests(vusdt.address, user1.getAddress());
  //       expect(interest.totalQVL).to.be.equal(bigNumber18.mul(1));
  //       expect(interest.accrued).to.be.equal(285);

  //       let reward = await prime.callStatic.getInterestAccrued(vusdt.address, user1.getAddress());
  //       expect(reward).to.be.equal(285);

  //       await usdt.transfer(prime.address, reward);
  //       await expect(prime.connect(user1).claimInterest(vusdt.address)).to.be.not.reverted;

  //       await mine(24 * 60 * 20);
  //       reward = await prime.callStatic.getInterestAccrued(vusdt.address, user1.getAddress());
  //       expect(reward).to.be.equal(57);
  //     });
  //   });
  });
});