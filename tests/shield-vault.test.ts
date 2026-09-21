import { initSimnet, tx } from "@stacks/clarinet-sdk";
import {
  cvToString,
  uintCV,
  stringAsciiCV,
  standardPrincipalCV,
  contractPrincipalCV,
  ClarityVersion,
} from "@stacks/transactions";
import { expect, it } from "vitest";

const TRIGGER = 115;
const BUFFER = 200;

// Stand-in lending market: set-health lets the tests drive the vault's health
// factor so rescue behaviour can be exercised without Zest. repay-debt raises
// health by amount/10, which makes the post-state check deterministic.
function mockMarket(deployer: string) {
  return `
(define-map healths { owner: principal } { hf: uint })
(impl-trait '${deployer}.shield-vault.lending-market-trait)
(impl-trait '${deployer}.shield-vault.sip010-trait)
(define-public (deposit-collateral (who principal) (amount uint)) (ok true))
(define-public (borrow-asset (who principal) (amount uint)) (ok true))
(define-public (repay-debt (who principal) (amount uint))
  (begin
    (map-set healths { owner: who }
      { hf: (+ (get hf (default-to { hf: u100 } (map-get? healths { owner: who }))) (/ amount u10)) })
    (ok true)))
(define-read-only (get-health-factor (who principal))
  (ok (get hf (default-to { hf: u100 } (map-get? healths { owner: who })))))
(define-public (set-health (who principal) (hf uint))
  (begin (map-set healths { owner: who } { hf: hf }) (ok true)))
(define-public (transfer (amount uint) (sender principal) (recipient principal) (memo (optional (buff 34)))) (ok true))
(define-read-only (get-balance (who principal)) (ok u0))
`;
}

async function setup() {
  const simnet = await initSimnet();
  const accounts = simnet.getAccounts();
  const deployer = accounts.get("deployer")!;
  const user = accounts.get("wallet_1")!;
  const keeper = accounts.get("wallet_2")!;

  simnet.deployContract(
    "mock-market",
    mockMarket(deployer),
    { clarityVersion: ClarityVersion.Clarity2 },
    deployer
  );

  const market = contractPrincipalCV(deployer, "mock-market");
  // the vault is the position principal, so its health is keyed by the
  // shield-vault contract itself
  const vaultPrincipal = contractPrincipalCV(deployer, "shield-vault");

  const openVault = () =>
    simnet.mineBlock([
      tx.callPublicFn(
        "shield-vault",
        "open-vault",
        [
          market,
          market,
          market,
          stringAsciiCV("sbtc"),
          stringAsciiCV("usdcx"),
          uintCV(10000),
          uintCV(2000),
          uintCV(TRIGGER),
          uintCV(BUFFER),
        ],
        user
      ),
    ]);

  const setHealth = (hf: number) =>
    simnet.mineBlock([
      tx.callPublicFn("mock-market", "set-health", [vaultPrincipal, uintCV(hf)], user),
    ]);

  const rescue = (repayAmount: number) =>
    simnet.mineBlock([
      tx.callPublicFn(
        "shield-vault",
        "keeper-rescue",
        [market, market, standardPrincipalCV(user), uintCV(repayAmount)],
        keeper
      ),
    ]);

  return { simnet, deployer, user, keeper, market, openVault, setHealth, rescue };
}


it("opens a vault and records it", async () => {
  const { simnet, user, openVault } = await setup();

  const [receipt] = openVault();
  expect(cvToString(receipt.result)).toBe("(ok true)");

  const stored = simnet.callReadOnlyFn(
    "shield-vault",
    "get-vault",
    [standardPrincipalCV(user)],
    user
  );
  expect(cvToString(stored.result)).toContain("active");
  expect(cvToString(stored.result)).toContain("u115");
});

it("rescues a breached position and pays the keeper", async () => {
  const { simnet, user, openVault, setHealth, rescue } = await setup();

  openVault();
  setHealth(105); // below trigger
  const [receipt] = rescue(100); // mock raises health by 10 -> 115
  expect(cvToString(receipt.result)).toBe("(ok true)");

  const stored = simnet.callReadOnlyFn(
    "shield-vault",
    "get-vault",
    [standardPrincipalCV(user)],
    user
  );
  // 200 buffer - 100 repay - 2 bounty
  expect(cvToString(stored.result)).toContain("u98");
});

it("rejects a rescue while the position is healthy", async () => {
  const { openVault, setHealth, rescue } = await setup();

  openVault();
  setHealth(120); // above trigger
  const [receipt] = rescue(100);
  expect(cvToString(receipt.result)).toBe("(err u103)");
});

it("rejects a rescue that needs more than the buffer", async () => {
  const { openVault, setHealth, rescue } = await setup();

  openVault();
  setHealth(100);
  const [receipt] = rescue(500); // buffer is 200
  expect(cvToString(receipt.result)).toBe("(err u105)");
});

it("reverts the whole rescue when health is not restored", async () => {
  const { simnet, user, openVault, setHealth, rescue } = await setup();

  openVault();
  setHealth(100);
  const [receipt] = rescue(20); // health 102, still below trigger
  expect(cvToString(receipt.result)).toBe("(err u104)");

  // buffer untouched, no bounty paid
  const stored = simnet.callReadOnlyFn(
    "shield-vault",
    "get-vault",
    [standardPrincipalCV(user)],
    user
  );
  expect(cvToString(stored.result)).toContain("u200");
});
