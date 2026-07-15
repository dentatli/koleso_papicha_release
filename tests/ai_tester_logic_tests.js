'use strict';

const fs = require('fs');
const path = require('path');
const Logic = require('../tools/ai_tester/ai_tester_logic.js');

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function equal(actual, expected, message) {
  if (actual !== expected) throw new Error(`${message} Expected=${JSON.stringify(expected)} Actual=${JSON.stringify(actual)}`);
}

async function tick() {
  await new Promise(resolve => setImmediate(resolve));
}

function donation(index, amount = index) {
  return { name: `Donor ${index}`, amount, message: `Message ${index}` };
}

async function run() {
  const eightyOne = Array.from({ length: 81 }, (_, index) => donation(index + 1, index % 2 ? String(index + 1) : index + 1));
  const parsed81 = Logic.parseDonationInput(JSON.stringify(eightyOne));
  equal(parsed81.mode, 'json', 'JSON array mode was not detected.');
  equal(parsed81.donations.length, 81, '81 synthetic donations were not loaded.');
  equal(parsed81.donations[0].amount, 1, 'Numeric amount was not preserved.');
  equal(parsed81.donations[1].amount, 2, 'String amount was not normalized.');
  assert(parsed81.donations.every(item => item.id.startsWith('ai-tester-local-')), 'Generated IDs are not tester-local.');

  const wrapped = Logic.parseDonationInput(JSON.stringify({ donations: [{ username: 'Alias', sum: '1500', comment: 'Alias message', externalId: 'safe-1' }] }));
  equal(wrapped.donations[0].name, 'Alias', 'Name alias was not accepted.');
  equal(wrapped.donations[0].amount, 1500, 'Amount alias was not accepted.');
  equal(wrapped.donations[0].message, 'Alias message', 'Message alias was not accepted.');
  equal(wrapped.donations[0].id, 'safe-1', 'ID alias was not accepted.');

  const lines = Logic.parseDonationInput('one\ntwo\n\nthree');
  equal(lines.mode, 'text', 'Plain text mode was not detected.');
  equal(lines.donations.length, 3, 'Plain non-empty lines were not split into donations.');
  equal(lines.donations[0].name, 'Тестовый донат', 'Plain text donor default is wrong.');
  equal(lines.donations[0].currency, 'RUB', 'Plain text currency default is wrong.');

  const blocks = Logic.parseDonationInput('first line\nsecond line\n---\nthird line');
  equal(blocks.donations.length, 2, 'The --- separator did not create two donations.');
  equal(blocks.donations[0].message, 'first line\nsecond line', 'Multiline donation content was not preserved.');

  const partial = Logic.parseDonationInput(JSON.stringify([
    donation(1),
    { name: 'Bad', amount: 'not-money', message: 'Still invalid' },
    { name: 'Empty', amount: 1, message: '' },
    donation(4)
  ]));
  equal(partial.donations.length, 2, 'Valid records in a partially invalid list were lost.');
  equal(partial.skipped.length, 2, 'Invalid records were not reported.');
  equal(partial.skipped[0].index, 1, 'Skipped item index is wrong.');

  let virtualNow = 0;
  let active = 0;
  let maxActive = 0;
  const requestStarts = [];
  const delaySleeps = [];
  const sequential = new Logic.SequentialQueue({
    items: Logic.createQueueItems(parsed81.donations.slice(0, 4)),
    delayMs: 2000,
    now: () => virtualNow,
    sleep: async milliseconds => { delaySleeps.push(milliseconds); virtualNow += milliseconds; await tick(); },
    request: async current => {
      requestStarts.push({ id: current.id, at: virtualNow });
      active += 1;
      maxActive = Math.max(maxActive, active);
      await tick();
      active -= 1;
      return { aiResponse: { items: [] }, usage: {}, latencyMs: 5 };
    }
  });
  await sequential.start();
  equal(requestStarts.length, 4, 'Sequential queue did not process every donation.');
  equal(maxActive, 1, 'Requests were processed in parallel.');
  for (let index = 1; index < requestStarts.length; index += 1) {
    assert(requestStarts[index].at - requestStarts[index - 1].at >= 2000, 'Configured completion-to-start delay was not respected.');
  }
  assert(delaySleeps.length > 0, 'Queue did not use the injected delay.');

  let releaseFirst;
  let startedCount = 0;
  const paused = new Logic.SequentialQueue({
    items: Logic.createQueueItems([donation(1), donation(2)]),
    sleep: async () => {},
    request: async () => {
      startedCount += 1;
      if (startedCount === 1) await new Promise(resolve => { releaseFirst = resolve; });
      return { aiResponse: { items: [] } };
    }
  });
  const pausedRun = paused.start();
  while (!releaseFirst) await tick();
  paused.pause();
  releaseFirst();
  await pausedRun;
  equal(paused.state, 'paused', 'Pause did not wait for the in-flight request and stop before the next one.');
  equal(startedCount, 1, 'Pause allowed the next request to start.');
  await paused.resume();
  equal(startedCount, 2, 'Resume did not continue with the first unprocessed donation.');

  let releaseStop;
  let stopStarts = 0;
  const stopped = new Logic.SequentialQueue({
    items: Logic.createQueueItems([donation(1), donation(2)]),
    sleep: async () => {},
    request: async () => {
      stopStarts += 1;
      if (stopStarts === 1) await new Promise(resolve => { releaseStop = resolve; });
      return { aiResponse: { items: [] } };
    }
  });
  const stoppedRun = stopped.start();
  while (!releaseStop) await tick();
  stopped.stop();
  releaseStop();
  await stoppedRun;
  equal(stopped.state, 'stopped', 'Stop did not leave the queue stopped.');
  equal(stopStarts, 1, 'Stop started another request after the current request completed.');
  equal(stopped.items[0].status, 'success', 'Stop incorrectly discarded the completed in-flight result.');
  equal(stopped.items[1].status, 'stopped', 'Stop did not mark remaining items as explicitly stopped/resumable.');

  let nonCriticalCalls = 0;
  const continueAfterError = new Logic.SequentialQueue({
    items: Logic.createQueueItems([donation(1), donation(2)]),
    sleep: async () => {},
    maxAttempts: 1,
    request: async () => {
      nonCriticalCalls += 1;
      if (nonCriticalCalls === 1) throw Object.assign(new Error('bad response'), { code: 'AI_PARSE_ERROR' });
      return { aiResponse: { items: [] } };
    }
  });
  await continueAfterError.start();
  equal(continueAfterError.items[0].status, 'error', 'Per-donation error was not stored.');
  equal(continueAfterError.items[1].status, 'success', 'A non-critical error stopped the remaining queue.');

  let authCalls = 0;
  const authStop = new Logic.SequentialQueue({
    items: Logic.createQueueItems([donation(1), donation(2), donation(3)]),
    sleep: async () => {},
    request: async () => {
      authCalls += 1;
      throw Object.assign(new Error('Authorization failed'), { code: 'OPENROUTER_HTTP_401', critical: true });
    }
  });
  await authStop.start();
  equal(authCalls, 1, 'Authorization error did not stop the remaining queue.');
  equal(authStop.state, 'stopped', 'Authorization error did not set stopped state.');

  let retryCalls = 0;
  const retryRateLimit = new Logic.SequentialQueue({
    items: Logic.createQueueItems([donation(1)]),
    now: () => virtualNow,
    sleep: async milliseconds => { virtualNow += milliseconds; },
    request: async () => {
      retryCalls += 1;
      if (retryCalls === 1) throw Object.assign(new Error('Rate limit'), { code: 'OPENROUTER_HTTP_429', retryable: true, retryAfterSeconds: 3 });
      return { aiResponse: { items: [] } };
    }
  });
  await retryRateLimit.start();
  equal(retryCalls, 2, 'Retryable rate-limit was not retried sequentially.');
  equal(retryRateLimit.items[0].status, 'success', 'Retryable result did not recover.');

  let errorRetryCalls = 0;
  const retryErrors = new Logic.SequentialQueue({
    items: Logic.createQueueItems([donation(1)]),
    sleep: async () => {},
    maxAttempts: 1,
    request: async () => {
      errorRetryCalls += 1;
      if (errorRetryCalls === 1) throw new Error('once');
      return { aiResponse: { items: [] } };
    }
  });
  await retryErrors.start();
  equal(retryErrors.items[0].status, 'error', 'Initial error fixture did not fail.');
  await retryErrors.retryErrors();
  equal(retryErrors.items[0].status, 'success', 'Explicit retry-errors action did not reprocess the error.');
  await retryErrors.reprocess(0);
  equal(retryErrors.items[0].status, 'success', 'Selected-donation reprocessing did not complete.');
  equal(errorRetryCalls, 3, 'Selected-donation reprocessing did not create exactly one new request.');

  const restored = Logic.normalizeRestoredItems([{ ...Logic.createQueueItems([donation(1)])[0], status: 'running' }]);
  equal(restored[0].status, 'stopped', 'Reload did not make an interrupted running item resumable.');
  const restoredQueue = new Logic.SequentialQueue({ items: restored, sleep: async () => {}, request: async () => ({ aiResponse: { items: [] } }) });
  equal(restoredQueue.pendingIndices().length, 1, 'Interrupted item was not eligible for explicit continuation after reload.');

  const exportItems = Logic.createQueueItems([donation(1), donation(2)]);
  exportItems[0].status = 'success';
  exportItems[0].result = {
    aiResponse: { items: [{ displayTitle: 'Digger Online' }] },
    rawAiContent: '{"safe":true}', catalogResults: {}, usage: { promptTokens: 10, completionTokens: 5, cachedTokens: 2, cost: 0.001 },
    model: 'model', provider: 'provider', requestId: 'request', latencyMs: 100,
    prompt: { fingerprint: 'result-fingerprint' },
    apiKey: 'must-not-export', proxyUrl: 'http://user:password@example.test'
  };
  exportItems[0].evaluation = { verdict: 'correct', comment: 'ok' };
  exportItems[1].status = 'error';
  exportItems[1].error = {
    code: 'SAFE_ERROR', message: 'safe message', secret: 'must-not-export',
    details: {
      requestId: 'failed-request', model: 'failed-model', provider: 'failed-provider', finishReason: 'stop', latencyMs: 25,
      promptFingerprint: 'failed-fingerprint', rawAiContent: '{bad json',
      openRouterMessage: 'Unsupported parameter: temperature', errorType: 'invalid_request', providerCode: 'unsupported_parameter',
      usage: { promptTokens: 12, completionTokens: 3, cachedTokens: 0, cost: 0.002 }, secret: 'must-not-export'
    }
  };
  exportItems[1].evaluation = { verdict: 'partial', comment: 'needs review' };
  const exported = Logic.buildExport({
    items: exportItems,
    source: { fileName: 'donations.json' },
    prompt: { version: 'compact-v1', fingerprint: 'prompt-fingerprint', text: 'prompt text' },
    model: 'model',
    apiKey: 'top-secret', localAppToken: 'local-secret', proxyUrl: 'proxy-secret'
  }, '2026-07-15T12:00:00.000Z');
  equal(exported.results.length, 2, 'Partial export lost source order or items.');
  equal(exported.results[0].donation.message, 'Message 1', 'Export changed donation order.');
  equal(exported.summary.processed, 2, 'Partial export summary is wrong.');
  equal(exported.results[0].evaluation.verdict, 'correct', 'Manual evaluation was not exported.');
  equal(exported.summary.evaluations.evaluated, 2, 'Evaluation summary did not count reviewed donations.');
  equal(exported.summary.evaluations.correct, 1, 'Correct evaluation count is wrong.');
  equal(exported.summary.evaluations.partial, 1, 'Partial evaluation count is wrong.');
  equal(exported.summary.evaluations.withComments, 2, 'Evaluation comment count is wrong.');
  equal(exported.evaluations.length, 2, 'Top-level evaluation list was not exported.');
  equal(exported.evaluations[1].comment, 'needs review', 'Top-level evaluation comment was lost.');
  equal(exported.results[1].error.details.requestId, 'failed-request', 'Safe OpenRouter error diagnostics were not exported.');
  equal(exported.results[1].error.details.rawAiContent, '{bad json', 'Raw malformed AI content was not exported.');
  equal(exported.results[1].error.details.openRouterMessage, 'Unsupported parameter: temperature', 'Safe OpenRouter message was not exported.');
  equal(exported.results[1].error.details.errorType, 'invalid_request', 'OpenRouter error type was not exported.');
  equal(exported.results[1].error.details.providerCode, 'unsupported_parameter', 'OpenRouter provider code was not exported.');
  equal(exported.results[1].requestId, 'failed-request', 'Error request ID was not promoted into the result row.');
  equal(exported.results[1].promptFingerprint, 'failed-fingerprint', 'Error prompt fingerprint was not exported.');
  equal(exported.summary.totalKnownCost, 0.003, 'Known cost subtotal including failed responses is wrong.');
  equal(exported.summary.costedRequests, 2, 'Known cost coverage is wrong.');
  equal(exported.summary.uncostedRequests, 0, 'Unknown cost coverage is wrong.');
  const exportJson = JSON.stringify(exported);
  for (const forbidden of ['must-not-export', 'top-secret', 'local-secret', 'proxy-secret', 'password@example']) {
    assert(!exportJson.includes(forbidden), `Export leaked forbidden value: ${forbidden}`);
  }
  const fullItems = Logic.createQueueItems([donation(1), donation(2)]);
  fullItems.forEach((item, index) => {
    item.status = 'success';
    item.result = { aiResponse: { items: [] }, rawAiContent: '{}', usage: { promptTokens: 2, completionTokens: 1, cachedTokens: 0, cost: null }, latencyMs: 10 + index };
  });
  const fullExport = Logic.buildExport({ items: fullItems, source: {}, prompt: {}, model: 'model' });
  equal(fullExport.summary.success, 2, 'Full export summary lost successful results.');
  equal(fullExport.summary.processed, 2, 'Full export did not report all items processed.');
  equal(fullExport.summary.totalCost, null, 'Unknown provider cost was incorrectly exported as zero.');
  equal(fullExport.summary.totalKnownCost, 0, 'Known cost subtotal for unknown costs is wrong.');

  const testerRoot = path.join(__dirname, '..', 'tools', 'ai_tester');
  const serverSource = fs.readFileSync(path.join(testerRoot, 'ai_tester_server.ps1'), 'utf8');
  const htmlSource = fs.readFileSync(path.join(testerRoot, 'ai_tester.html'), 'utf8');
  assert(serverSource.includes("Loopback, $Port"), 'Tester server is not explicitly bound to loopback.');
  assert(serverSource.includes("[int]$Port = 5501"), 'Tester default port is not 5501.');
  assert(!serverSource.includes('llm_jobs.json') && !serverSource.includes('collector_state.json'), 'Tester references production runtime storage.');
  assert(!serverSource.includes('local_server.ps1') && !htmlSource.includes('/api/llm/'), 'Tester depends on the production AI pipeline.');
  assert(!serverSource.includes('DonationAlerts') && !serverSource.includes('DonatePay'), 'Tester unexpectedly includes donation integrations.');
  equal((serverSource.match(/Invoke-ExperimentalOpenRouter \$Donation \$Model/g) || []).length, 1, 'Analyze route can invoke the main OpenRouter operation more than once.');
  assert(htmlSource.includes('new Logic.SequentialQueue'), 'UI does not use the tested production queue helper.');
  assert(htmlSource.includes("comment.addEventListener('input'"), 'Evaluation comments are not persisted while typing.');
  assert(htmlSource.includes("detailBlock('Диагностика ошибки'"), 'UI does not expose safe OpenRouter error diagnostics.');
  assert(serverSource.includes("$Exception.Data['Details']"), 'Server does not attach safe OpenRouter failure diagnostics.');
  assert(serverSource.includes("provider = @{ require_parameters = $true }"), 'Tester does not require providers to honor structured output parameters.');
  assert(serverSource.includes("modelDefault = 'google/gemini-3-flash-preview'"), 'Tester server does not advertise Gemini 3 Flash Preview by default.');
  assert(htmlSource.includes("const DEFAULT_MODEL = 'google/gemini-3-flash-preview';"), 'Tester UI does not default to Gemini 3 Flash Preview.');
  assert(htmlSource.includes('savedModel === LEGACY_DEFAULT_MODEL ? DEFAULT_MODEL : savedModel'), 'Tester does not migrate the previous default model.');
  assert(!serverSource.includes('temperature = 0.1'), 'Tester still sends a model-incompatible temperature parameter.');
  assert(serverSource.includes('Get-PortableStructuredSchema'), 'Tester does not build a provider-portable structured output schema.');
  assert(serverSource.includes('openRouterMessage'), 'Tester does not preserve the safe OpenRouter error message.');
  assert(serverSource.includes("if ($Seen.ContainsKey($Key)) { continue }"), 'Tester rejects harmless case-only duplicate search queries instead of normalizing them.');
  assert(serverSource.includes("$FinishReason -eq 'error'"), 'Tester does not mark provider-aborted structured responses for a bounded queue retry.');
  assert(htmlSource.includes('textContent'), 'UI source contract lost safe text rendering.');
  const promptSource = fs.readFileSync(path.join(testerRoot, 'experimental_prompt.txt'), 'utf8');
  assert(promptSource.startsWith('Prompt version: auction-precision-v6'), 'Tester default prompt is not auction-precision-v6.');
  const schema = JSON.parse(fs.readFileSync(path.join(testerRoot, 'experimental_schema.json'), 'utf8'));
  const itemProperties = schema.properties.items.items.properties;
  assert(!Object.prototype.hasOwnProperty.call(itemProperties, 'existingEntryId'), 'Experimental schema leaks current auction entries into AI analysis.');
  assert(!Object.prototype.hasOwnProperty.call(itemProperties, 'externalId'), 'Experimental schema accepts untrusted external IDs.');

  console.log('AI tester logic tests ok');
}

run().catch(error => {
  console.error(error.stack || error.message || String(error));
  process.exit(1);
});
