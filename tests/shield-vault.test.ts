import { initSimnet, tx } from "@stacks/clarinet-sdk";
import { cvToString, uintCV, stringAsciiCV, standardPrincipalCV, contractPrincipalCV, ClarityVersion } from "@stacks/transactions";
import { assertEquals, expect, it } from "vitest";

// Mock lending market + tokens. Implements shield-vault's traits so tests can
// drive the Health Factor and observe repay/rescue behavior deterministically.
// In milestone 1 this is replaced by real Zest Stacks Market V2 principals.
function mockSource(deployer: string) {
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
  (begin
    (map-set healths { owner: who } { hf: hf })
    (ok true)))
(define-public (transfer (amount uint) (sender principal) (recipient principal) (memo (optional (buff 34)))) (ok true))
(define-read-only (get-balance (who principal)) (ok u0))
`;
}

const OPEN_ARGS = (deployer: string) => [
  contractPrincipalCV(deployer, "mock-market"),
  contractPrincipalCV(deployer, "mock-market"),
  contractPrincipalCV(deployer, "mock-market"),
  stringAsciiCV("sbtc"),
  stringAsciiCV("usdcx"),
  uintCV(10000),
  uintCV(2000),
  uintCV(115),
  uintCV(200),
];

async function setup() {
  const simnet = await initSimnet();
  const accounts = simnet.getAccounts();
  const deployer = accounts.get("deployer")!;
  const user = accounts.get("wallet_1")!;
  const keeper = accounts.get("wallet_2")!;
  const mock = `${deployer}.mock-market`;
  simnet.deployContract("mock-market", mockSource(deployer), { clarityVersion: ClarityVersion.Clarity2 }, deployer);
  const open = () =>
    simnet.mineBlock([tx.callPublicFn("shield-vault", "open-vault", OPEN_ARGS(deployer), user)]);
  return { simnet, deployer, user, keeper, mock, open };
}

it("user can open a protected vault", async () => {
  const { simnet, user, open } = await setup();
  const res = open();
  expect(cvToString(res[0].result)).toBe("(ok true)");
  const vault = simnet.callReadOnlyFn(
    "shield-vault",
    "get-vault",
    [standardPrincipalCV(user)],
    user
  );
  const s = cvToString(vault.result);
  expect(s).toContain("active");
  expect(s).toContain("u115");
});

it("keeper rescue executes when trigger breached and health restored", async () => {
  const { simnet, user, keeper, mock, deployer, open } = await setup();
  open();
  // drive HF below trigger (105 < 115)
  simnet.mineBlock([
    tx.callPublicFn("mock-market", "set-health", [standardPrincipalCV(keeper), uintCV(105)], user),
  ]);
  // keeper repays 100 -> mock raises HF by 10 -> 115 >= trigger 115
  const res = simnet.mineBlock([
    tx.callPublicFn(
      "shield-vault",
      "keeper-rescue",
      [contractPrincipalCV(deployer, "mock-market"), contractPrincipalCV(deployer, "mock-market"), standardPrincipalCV(user), uintCV(100)],
      keeper
    ),
  ]);
  expect(cvToString(res[0].result)).toBe("(ok true)");
  // buffer = 200 - 100 repay - 2 bounty = 98
  const vault = simnet.callReadOnlyFn(
    "shield-vault",
    "get-vault",
    [standardPrincipalCV(user)],
    user
  );
  expect(cvToString(vault.result)).toContain("u98");
});

it("keeper rescue reverts when health is above trigger", async () => {
  const { simnet, user, keeper, mock, deployer, open } = await setup();
  open();
  // HF 120 healthy (above trigger 115) -> revert u103
  simnet.mineBlock([
    tx.callPublicFn("mock-market", "set-health", [standardPrincipalCV(keeper), uintCV(120)], user),
  ]);
  const res = simnet.mineBlock([
    tx.callPublicFn(
      "shield-vault",
      "keeper-rescue",
      [contractPrincipalCV(deployer, "mock-market"), contractPrincipalCV(deployer, "mock-market"), standardPrincipalCV(user), uintCV(100)],
      keeper
    ),
  ]);
  expect(cvToString(res[0].result)).toBe("(err u103)");
});

it("keeper rescue reverts when repay amount exceeds buffer", async () => {
  const { simnet, user, keeper, mock, deployer, open } = await setup();
  open();
  // HF 100 < 115 but repay 500 > buffer 200 -> revert u105
  simnet.mineBlock([
    tx.callPublicFn("mock-market", "set-health", [standardPrincipalCV(keeper), uintCV(100)], user),
  ]);
  const res = simnet.mineBlock([
    tx.callPublicFn(
      "shield-vault",
      "keeper-rescue",
      [contractPrincipalCV(deployer, "mock-market"), contractPrincipalCV(deployer, "mock-market"), standardPrincipalCV(user), uintCV(500)],
      keeper
    ),
  ]);
  expect(cvToString(res[0].result)).toBe("(err u105)");
});

it("keeper rescue reverts when post-state health is not restored", async () => {
  const { simnet, user, keeper, mock, deployer, open } = await setup();
  open();
  // HF 100 < 115, repay 20 -> HF 102 still below trigger -> revert u104
  simnet.mineBlock([
    tx.callPublicFn("mock-market", "set-health", [standardPrincipalCV(keeper), uintCV(100)], user),
  ]);
  const res = simnet.mineBlock([
    tx.callPublicFn(
      "shield-vault",
      "keeper-rescue",
      [contractPrincipalCV(deployer, "mock-market"), contractPrincipalCV(deployer, "mock-market"), standardPrincipalCV(user), uintCV(20)],
      keeper
    ),
  ]);
  expect(cvToString(res[0].result)).toBe("(err u104)");
});
