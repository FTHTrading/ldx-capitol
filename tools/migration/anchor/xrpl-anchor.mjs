#!/usr/bin/env node
// Anchor the archive Merkle root on the XRP Ledger, and verify an anchor later.
//
//   node xrpl-anchor.mjs submit  --payload <anchor-payload.json> --network testnet|mainnet|<wss://…> [--yes] [--receipt <out.json>]
//   node xrpl-anchor.mjs verify  --receipt <anchor-receipt.json> [--merkle <merkle.json>] [--network …]
//   node xrpl-anchor.mjs selftest
//
// The signing seed is read from the XRPL_ANCHOR_SEED environment variable and never from a file or flag.
// Without --yes, submit stops after printing the fully prepared transaction (autofilled, unsigned). That is
// the human approval gate: nothing is signed or broadcast until the operator re-runs with --yes.
//
// The transaction is an AccountSet on the signing account with no flag changes and three Memos:
//   MemoType   ldx/archive-anchor/v1
//   MemoFormat application/json
//   MemoData   {"v":1,"kind":"ldx-archive-anchor","root":…,"n":…,"run":…,"col":…,"ts":…}
// Cost is the network fee only (about 10 drops). Nothing but the 32-byte root and counters goes on-chain.

import { readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { Client, Wallet, validate } from 'xrpl';

const NETWORKS = {
  testnet: 'wss://s.altnet.rippletest.net:51233',
  devnet: 'wss://s.devnet.rippletest.net:51233',
  mainnet: 'wss://xrplcluster.com',
};
const MEMO_TYPE = 'ldx/archive-anchor/v1';

function parseArgs(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith('--')) out[key] = true;
      else { out[key] = next; i++; }
    } else out._.push(a);
  }
  return out;
}
const hex = (s) => Buffer.from(s, 'utf8').toString('hex').toUpperCase();
const unhex = (h) => Buffer.from(h, 'hex').toString('utf8');
const sha256 = (buf) => createHash('sha256').update(buf).digest();
const die = (msg, code = 1) => { console.error(msg); process.exit(code); };

function resolveNetwork(name) {
  if (!name) return NETWORKS.testnet;
  if (NETWORKS[name]) return NETWORKS[name];
  if (/^wss?:\/\//.test(name)) return name;
  die(`Unknown network "${name}". Use testnet, devnet, mainnet, or a wss:// URL.`);
}

function loadPayload(path) {
  const p = JSON.parse(readFileSync(path, 'utf8'));
  if (p.schema !== 'ldx-anchor/1') die(`Unexpected payload schema: ${p.schema}`);
  if (!/^[0-9a-f]{64}$/.test(p.merkleRoot)) die('merkleRoot is not a 64-hex SHA-256');
  const memoObj = JSON.parse(p.memo.json);
  if (memoObj.root !== p.merkleRoot) die('memo.json root does not match merkleRoot');
  if (hex(p.memo.json) !== p.memo.MemoData.toUpperCase()) die('memo.MemoData is not the hex of memo.json');
  if (unhex(p.memo.MemoType) !== MEMO_TYPE) die(`memo.MemoType is not ${MEMO_TYPE}`);
  if (Buffer.byteLength(p.memo.json, 'utf8') > 1000) die('memo exceeds the 1 KB XRPL limit');
  return p;
}

function buildTx(account, payload) {
  return {
    TransactionType: 'AccountSet',
    Account: account,
    Memos: [{
      Memo: {
        MemoType: payload.memo.MemoType,
        MemoFormat: payload.memo.MemoFormat,
        MemoData: payload.memo.MemoData,
      },
    }],
  };
}

function decodeAnchorMemo(tx) {
  const memos = tx.Memos || [];
  for (const m of memos) {
    const memo = m.Memo || {};
    if (!memo.MemoType || unhex(memo.MemoType) !== MEMO_TYPE) continue;
    const json = unhex(memo.MemoData || '');
    return JSON.parse(json);
  }
  return null;
}

async function withClient(url, fn) {
  const client = new Client(url, { connectionTimeout: 20000 });
  await client.connect();
  try { return await fn(client); } finally { await client.disconnect(); }
}

async function cmdSubmit(args) {
  if (!args.payload) die('--payload <anchor-payload.json> is required');
  const payload = loadPayload(args.payload);
  const url = resolveNetwork(args.network);
  const seed = process.env.XRPL_ANCHOR_SEED;
  if (!seed) die('XRPL_ANCHOR_SEED is not set. Export the seed of the anchoring account in this shell only.');
  const wallet = Wallet.fromSeed(seed);
  const receiptPath = args.receipt || 'anchor-receipt.json';

  console.log(`network   : ${url}`);
  console.log(`account   : ${wallet.classicAddress}`);
  console.log(`root      : ${payload.merkleRoot}`);
  console.log(`leaves    : ${payload.leafCount}`);
  console.log(`memo      : ${payload.memo.json}`);

  const result = await withClient(url, async (client) => {
    const prepared = await client.autofill(buildTx(wallet.classicAddress, payload));
    validate(prepared);
    console.log('\nprepared transaction:');
    console.log(JSON.stringify(prepared, null, 2));
    if (!args.yes) {
      console.log('\nNot signed, not submitted. Re-run with --yes to sign with XRPL_ANCHOR_SEED and broadcast.');
      return null;
    }
    const signed = wallet.sign(prepared);
    console.log(`\nsigned hash : ${signed.hash}`);
    const res = await client.submitAndWait(signed.tx_blob);
    const meta = res.result.meta;
    const code = typeof meta === 'object' && meta ? meta.TransactionResult : String(meta);
    return {
      schema: 'ldx-anchor-receipt/1',
      network: url,
      account: wallet.classicAddress,
      txHash: res.result.hash,
      ledgerIndex: res.result.ledger_index,
      validated: res.result.validated === true,
      engineResult: code,
      merkleRoot: payload.merkleRoot,
      leafCount: payload.leafCount,
      manifestRunId: payload.manifestRunId,
      manifestSha256: payload.manifestSha256,
      memoJson: payload.memo.json,
      submittedAt: new Date().toISOString(),
    };
  });
  if (!result) return;
  if (result.engineResult !== 'tesSUCCESS' || !result.validated) {
    writeFileSync(receiptPath, JSON.stringify(result, null, 2) + '\n');
    die(`Transaction did not succeed: ${result.engineResult} (validated=${result.validated}). Receipt written to ${receiptPath}.`, 2);
  }
  writeFileSync(receiptPath, JSON.stringify(result, null, 2) + '\n');
  console.log(`\nANCHORED  tx ${result.txHash}  ledger ${result.ledgerIndex}`);
  console.log(`receipt   : ${receiptPath}`);
}

async function cmdVerify(args) {
  if (!args.receipt) die('--receipt <anchor-receipt.json> is required');
  const receipt = JSON.parse(readFileSync(args.receipt, 'utf8'));
  const url = resolveNetwork(args.network || Object.keys(NETWORKS).find((k) => NETWORKS[k] === receipt.network) || receipt.network);
  let expectedRoot = receipt.merkleRoot;
  if (args.merkle) {
    const m = JSON.parse(readFileSync(args.merkle, 'utf8'));
    expectedRoot = m.root;
    if (m.root !== receipt.merkleRoot) console.log(`note: merkle.json root differs from the receipt root (a newer build?)`);
  }
  const tx = await withClient(url, async (client) => {
    const r = await client.request({ command: 'tx', transaction: receipt.txHash });
    return r.result;
  });
  const txJson = tx.tx_json || tx;
  const memo = decodeAnchorMemo(txJson);
  const validated = tx.validated === true;
  const engine = tx.meta && typeof tx.meta === 'object' ? tx.meta.TransactionResult : undefined;
  console.log(`tx        : ${receipt.txHash}`);
  console.log(`ledger    : ${tx.ledger_index}  validated=${validated}  result=${engine}`);
  console.log(`account   : ${txJson.Account}`);
  console.log(`on-chain  : ${memo ? memo.root : '(no anchor memo)'}`);
  console.log(`expected  : ${expectedRoot}`);
  if (!memo) die('No ldx/archive-anchor/v1 memo on that transaction.', 2);
  if (!validated || engine !== 'tesSUCCESS') die('Transaction is not a validated tesSUCCESS.', 2);
  if (memo.root !== expectedRoot) die('ROOT MISMATCH between chain and local record.', 2);
  if (txJson.Account !== receipt.account) die('Account on chain differs from the receipt.', 2);
  console.log('ANCHOR OK  -  on-chain root matches the local Merkle root');
}

function selftest() {
  // Round-trip the memo encoding and signing with a throwaway wallet, entirely offline.
  const root = sha256(Buffer.from('selftest')).toString('hex');
  const memoJson = JSON.stringify({ v: 1, kind: 'ldx-archive-anchor', root, n: 3, run: 'selftest', col: 'Self Test', ts: '2026-01-01T00:00:00Z' });
  const payload = {
    schema: 'ldx-anchor/1', collection: 'Self Test', merkleRoot: root, leafCount: 3, manifestRunId: 'selftest',
    manifestSha256: root, generated: '2026-01-01T00:00:00.000Z',
    memo: { json: memoJson, MemoType: hex(MEMO_TYPE), MemoFormat: hex('application/json'), MemoData: hex(memoJson) },
  };
  const tmp = `${process.env.TMPDIR || '/tmp'}/ldx-anchor-selftest-${process.pid}.json`;
  writeFileSync(tmp, JSON.stringify(payload));
  const loaded = loadPayload(tmp);
  const wallet = Wallet.generate();
  const tx = { ...buildTx(wallet.classicAddress, loaded), Sequence: 1, Fee: '12', LastLedgerSequence: 1000 };
  validate(tx);
  const signed = wallet.sign(tx);
  const decoded = decodeAnchorMemo(tx);
  const checks = [
    ['memo type round-trips', unhex(loaded.memo.MemoType) === MEMO_TYPE],
    ['memo data decodes to the root', decoded && decoded.root === root],
    ['signature produced', /^[0-9A-F]{64}$/.test(signed.hash)],
    ['memo under 1 KB', Buffer.byteLength(memoJson) <= 1000],
  ];
  let failed = 0;
  for (const [name, ok] of checks) { console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}`); if (!ok) failed++; }
  process.exit(failed ? 1 : 0);
}

const args = parseArgs(process.argv.slice(2));
const cmd = args._[0];
try {
  if (cmd === 'submit') await cmdSubmit(args);
  else if (cmd === 'verify') await cmdVerify(args);
  else if (cmd === 'selftest') selftest();
  else die('usage: xrpl-anchor.mjs <submit|verify|selftest> [options]');
} catch (e) {
  die(`error: ${e && e.message ? e.message : e}`, 1);
}
