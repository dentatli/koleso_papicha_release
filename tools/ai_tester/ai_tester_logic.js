(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.AiTesterLogic = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  const LIMITS = Object.freeze({
    maxInputBytes: 2 * 1024 * 1024,
    maxDonations: 500,
    maxNameLength: 120,
    maxMessageLength: 4000,
    maxIdLength: 128,
    maxCurrencyLength: 12,
    maxAmount: 1000000000,
    maxRawAiContentLength: 65536,
    maxEvaluationCommentLength: 1000
  });

  const STORAGE_KEY = 'papich-ai-tester-state-v1';

  function stringValue(value) {
    return value === null || value === undefined ? '' : String(value);
  }

  function cleanText(value, maxLength, multiline) {
    let text = stringValue(value).replace(/\u0000/g, '');
    text = text.replace(multiline ? /[\u0001-\u0008\u000b\u000c\u000e-\u001f\u007f]/g : /[\u0001-\u001f\u007f]/g, ' ');
    text = multiline ? text.trim() : text.replace(/\s+/g, ' ').trim();
    if (text.length > maxLength) throw new Error(`Значение длиннее ${maxLength} символов.`);
    return text;
  }

  function firstValue(record, names) {
    for (const name of names) {
      if (Object.prototype.hasOwnProperty.call(record, name) && record[name] !== null && record[name] !== undefined) {
        return record[name];
      }
    }
    return undefined;
  }

  function normalizeAmount(value) {
    if (value === undefined || value === null || value === '') return 0;
    if (typeof value === 'boolean') throw new Error('Сумма не может быть boolean.');
    let number;
    if (typeof value === 'number') number = value;
    else {
      const raw = String(value).trim().replace(/[\s\u00a0]/g, '');
      if (!/^[+-]?\d+(?:[.,]\d+)?$/.test(raw)) throw new Error('Некорректная сумма.');
      number = Number(raw.replace(',', '.'));
    }
    if (!Number.isFinite(number) || number < 0 || number > LIMITS.maxAmount) {
      throw new Error(`Сумма должна быть от 0 до ${LIMITS.maxAmount}.`);
    }
    return number;
  }

  function smallHash(text) {
    let hash = 2166136261;
    for (let index = 0; index < text.length; index += 1) {
      hash ^= text.charCodeAt(index);
      hash = Math.imul(hash, 16777619);
    }
    return (hash >>> 0).toString(16).padStart(8, '0');
  }

  function normalizeDonationRecord(record, index) {
    if (!record || typeof record !== 'object' || Array.isArray(record)) throw new Error('Ожидался JSON-объект доната.');
    const message = cleanText(firstValue(record, ['message', 'comment', 'text']), LIMITS.maxMessageLength, true);
    if (!message) throw new Error('Сообщение доната пустое.');
    const name = cleanText(firstValue(record, ['name', 'username', 'donorName']) || 'Тестовый донат', LIMITS.maxNameLength, false);
    const amount = normalizeAmount(firstValue(record, ['amount', 'sum']));
    let currency = cleanText(firstValue(record, ['currency']) || 'RUB', LIMITS.maxCurrencyLength, false).toUpperCase();
    if (!/^[A-Z]{3,12}$/.test(currency)) throw new Error('Некорректный код валюты.');
    let id = cleanText(firstValue(record, ['id', 'externalId']), LIMITS.maxIdLength, false);
    const localId = !id;
    if (!id) id = `ai-tester-local-${String(index + 1).padStart(4, '0')}-${smallHash(`${name}\n${message}\n${amount}`)}`;
    if (!/^[\p{L}\p{N}_.:@-]+$/u.test(id)) throw new Error('ID содержит недопустимые символы.');
    return { id, localId, name, amount, currency, message };
  }

  function normalizeDonationList(records) {
    if (!Array.isArray(records)) throw new Error('Ожидался массив донатов.');
    const donations = [];
    const skipped = [];
    const maximum = Math.min(records.length, LIMITS.maxDonations);
    for (let index = 0; index < maximum; index += 1) {
      try {
        donations.push(normalizeDonationRecord(records[index], index));
      } catch (error) {
        skipped.push({ index, reason: stringValue(error.message).slice(0, 200) });
      }
    }
    for (let index = maximum; index < records.length; index += 1) {
      skipped.push({ index, reason: `Превышен лимит ${LIMITS.maxDonations} донатов.` });
    }
    return { donations, skipped };
  }

  function splitPlainText(text) {
    const normalized = String(text).replace(/\r\n?/g, '\n');
    if (/^\s*---\s*$/m.test(normalized)) {
      return normalized.split(/^\s*---\s*$/m).map(value => value.trim()).filter(Boolean);
    }
    return normalized.split('\n').map(value => value.trim()).filter(Boolean);
  }

  function parseDonationInput(input) {
    const text = String(input || '');
    if (new TextEncoder().encode(text).length > LIMITS.maxInputBytes) {
      throw new Error(`Ввод превышает лимит ${LIMITS.maxInputBytes} байт.`);
    }
    const trimmed = text.trim();
    if (!trimmed) throw new Error('Ввод пуст.');
    if (trimmed.startsWith('[') || trimmed.startsWith('{')) {
      let parsed;
      try { parsed = JSON.parse(trimmed); }
      catch { throw new Error('JSON не удалось разобрать.'); }
      const records = Array.isArray(parsed) ? parsed : parsed && Array.isArray(parsed.donations) ? parsed.donations : null;
      if (!records) throw new Error('JSON должен быть массивом или объектом с массивом donations.');
      const result = normalizeDonationList(records);
      return { mode: 'json', ...result };
    }
    const records = splitPlainText(trimmed).map(message => ({ message }));
    const result = normalizeDonationList(records);
    return { mode: 'text', ...result };
  }

  function createQueueItems(donations) {
    return donations.slice(0, LIMITS.maxDonations).map((donation, index) => ({
      index,
      donation: { ...donation },
      status: 'pending',
      attempts: 0,
      startedAt: '',
      completedAt: '',
      result: null,
      error: null,
      evaluation: { verdict: '', comment: '' }
    }));
  }

  function normalizeRestoredItems(items) {
    if (!Array.isArray(items)) return [];
    return items.slice(0, LIMITS.maxDonations).map((item, index) => {
      const restored = { ...item, index };
      if (restored.status === 'running') restored.status = 'stopped';
      if (!['pending', 'success', 'error', 'stopped'].includes(restored.status)) restored.status = 'pending';
      restored.attempts = Number.isFinite(Number(restored.attempts)) ? Math.max(0, Number(restored.attempts)) : 0;
      restored.evaluation = restored.evaluation && typeof restored.evaluation === 'object'
        ? { verdict: stringValue(restored.evaluation.verdict), comment: stringValue(restored.evaluation.comment).slice(0, LIMITS.maxEvaluationCommentLength) }
        : { verdict: '', comment: '' };
      return restored;
    });
  }

  function safeError(error) {
    const sourceDetails = error && error.details && typeof error.details === 'object' ? error.details : null;
    const sourceUsage = sourceDetails && sourceDetails.usage && typeof sourceDetails.usage === 'object' ? sourceDetails.usage : {};
    const rawCost = sourceUsage.cost;
    const details = sourceDetails ? {
      requestId: stringValue(sourceDetails.requestId).slice(0, 200),
      model: stringValue(sourceDetails.model).slice(0, 200),
      provider: stringValue(sourceDetails.provider).slice(0, 200),
      finishReason: stringValue(sourceDetails.finishReason).slice(0, 200),
      promptFingerprint: stringValue(sourceDetails.promptFingerprint).slice(0, 100),
      latencyMs: Math.max(0, Number(sourceDetails.latencyMs) || 0),
      rawAiContent: stringValue(sourceDetails.rawAiContent).slice(0, LIMITS.maxRawAiContentLength),
      openRouterMessage: stringValue(sourceDetails.openRouterMessage).slice(0, 500),
      errorType: stringValue(sourceDetails.errorType).slice(0, 100),
      providerCode: stringValue(sourceDetails.providerCode).slice(0, 100),
      usage: {
        promptTokens: Math.max(0, Number(sourceUsage.promptTokens) || 0),
        completionTokens: Math.max(0, Number(sourceUsage.completionTokens) || 0),
        cachedTokens: Math.max(0, Number(sourceUsage.cachedTokens) || 0),
        cost: rawCost !== null && rawCost !== undefined && rawCost !== '' && Number.isFinite(Number(rawCost)) ? Number(rawCost) : null
      }
    } : null;
    return {
      code: stringValue(error && error.code || 'AI_TESTER_REQUEST_FAILED').slice(0, 100),
      message: stringValue(error && error.message || 'Запрос завершился ошибкой.').slice(0, 500),
      retryable: Boolean(error && error.retryable),
      critical: Boolean(error && error.critical),
      retryAfterSeconds: Math.max(0, Math.min(300, Number(error && error.retryAfterSeconds) || 0)),
      details
    };
  }

  class SequentialQueue {
    constructor(options) {
      if (!options || typeof options.request !== 'function') throw new Error('Queue request function is required.');
      this.items = normalizeRestoredItems(options.items || []);
      this.request = options.request;
      this.sleep = options.sleep || (milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds)));
      this.now = options.now || (() => Date.now());
      this.onChange = options.onChange || (() => {});
      this.delayMs = Math.max(500, Math.min(60000, Number(options.delayMs) || 2000));
      this.maxAttempts = Math.max(1, Math.min(5, Number(options.maxAttempts) || 3));
      this.state = 'idle';
      this.pauseRequested = false;
      this.stopRequested = false;
      this.countdownMs = 0;
      this.runPromise = null;
    }

    setDelay(milliseconds) {
      this.delayMs = Math.max(500, Math.min(60000, Number(milliseconds) || 2000));
      this.emit();
    }

    emit() {
      this.onChange(this);
    }

    getSummary() {
      const success = this.items.filter(item => item.status === 'success').length;
      const errors = this.items.filter(item => item.status === 'error').length;
      return {
        total: this.items.length,
        processed: success + errors,
        success,
        errors,
        remaining: this.items.length - success - errors,
        current: Math.max(0, this.items.findIndex(item => item.status === 'running') + 1),
        state: this.state,
        countdownMs: this.countdownMs
      };
    }

    pause() {
      if (this.state === 'running') {
        this.pauseRequested = true;
        this.state = 'pausing';
        this.emit();
      }
    }

    stop() {
      if (this.state === 'running' || this.state === 'pausing') {
        this.stopRequested = true;
        this.state = 'stopping';
        this.emit();
      }
    }

    async wait(milliseconds) {
      let remaining = Math.max(0, milliseconds);
      while (remaining > 0 && !this.stopRequested && !this.pauseRequested) {
        const part = Math.min(remaining, 100);
        this.countdownMs = remaining;
        this.emit();
        const before = this.now();
        await this.sleep(part);
        const elapsed = Math.max(part, this.now() - before);
        remaining = Math.max(0, remaining - elapsed);
      }
      this.countdownMs = 0;
      this.emit();
      return !this.stopRequested && !this.pauseRequested;
    }

    pendingIndices(selectedIndices) {
      const selected = Array.isArray(selectedIndices) ? new Set(selectedIndices.map(Number)) : null;
      return this.items
        .filter(item => (!selected || selected.has(item.index)) && (item.status === 'pending' || item.status === 'stopped'))
        .map(item => item.index);
    }

    async processItem(item) {
      let lastError = null;
      for (let attempt = 1; attempt <= this.maxAttempts; attempt += 1) {
        item.status = 'running';
        item.attempts += 1;
        item.startedAt = new Date(this.now()).toISOString();
        item.error = null;
        this.emit();
        try {
          item.result = await this.request(item.donation, item, attempt);
          item.status = 'success';
          item.completedAt = new Date(this.now()).toISOString();
          this.emit();
          return { critical: false };
        } catch (error) {
          lastError = safeError(error);
          const mayRetry = lastError.retryable && !lastError.critical && attempt < this.maxAttempts;
          if (mayRetry && !this.pauseRequested && !this.stopRequested) {
            const retryMs = Math.max(lastError.retryAfterSeconds * 1000, Math.min(60000, 1000 * (2 ** (attempt - 1))));
            if (await this.wait(retryMs)) continue;
          }
          item.status = 'error';
          item.error = lastError;
          item.completedAt = new Date(this.now()).toISOString();
          this.emit();
          return { critical: lastError.critical };
        }
      }
      item.status = 'error';
      item.error = lastError || safeError(null);
      this.emit();
      return { critical: false };
    }

    async run(selectedIndices) {
      const targets = this.pendingIndices(selectedIndices);
      for (let position = 0; position < targets.length; position += 1) {
        if (this.stopRequested || this.pauseRequested) break;
        const item = this.items[targets[position]];
        const outcome = await this.processItem(item);
        if (outcome.critical) this.stopRequested = true;
        if (this.stopRequested || this.pauseRequested) break;
        if (position < targets.length - 1 && !(await this.wait(this.delayMs))) break;
      }
      this.countdownMs = 0;
      if (this.pauseRequested) this.state = 'paused';
      else if (this.stopRequested) {
        this.state = 'stopped';
        for (const index of targets) {
          if (this.items[index].status === 'pending') this.items[index].status = 'stopped';
        }
      }
      else this.state = 'completed';
      this.emit();
    }

    start(selectedIndices) {
      if (this.runPromise) return this.runPromise;
      this.pauseRequested = false;
      this.stopRequested = false;
      this.state = 'running';
      this.emit();
      this.runPromise = this.run(selectedIndices).finally(() => { this.runPromise = null; });
      return this.runPromise;
    }

    resume() {
      if (this.state !== 'paused' && this.state !== 'stopped' && this.state !== 'idle') return this.runPromise || Promise.resolve();
      return this.start();
    }

    retryErrors() {
      const indices = [];
      for (const item of this.items) {
        if (item.status === 'error') {
          item.status = 'pending';
          item.error = null;
          indices.push(item.index);
        }
      }
      this.emit();
      return this.start(indices);
    }

    reprocess(index) {
      const item = this.items[Number(index)];
      if (!item) return Promise.reject(new Error('Донат не найден.'));
      item.status = 'pending';
      item.result = null;
      item.error = null;
      item.completedAt = '';
      this.emit();
      return this.start([item.index]);
    }
  }

  function boundedRaw(value) {
    return stringValue(value).slice(0, LIMITS.maxRawAiContentLength);
  }

  function buildExport(state, exportedAt) {
    const items = Array.isArray(state.items) ? state.items : [];
    let promptTokens = 0;
    let completionTokens = 0;
    let cachedTokens = 0;
    let latency = 0;
    let latencyCount = 0;
    const evaluationSummary = { evaluated: 0, unevaluated: 0, correct: 0, partial: 0, incorrect: 0, withComments: 0 };
    const evaluations = [];
    const results = items.map((item, index) => {
      const result = item.result || {};
      const errorDetails = item.error && item.error.details && typeof item.error.details === 'object' ? item.error.details : {};
      const usage = result.usage || errorDetails.usage || {};
      promptTokens += Number(usage.promptTokens) || 0;
      completionTokens += Number(usage.completionTokens) || 0;
      cachedTokens += Number(usage.cachedTokens) || 0;
      if (Number(result.latencyMs) >= 0 && item.status === 'success') {
        latency += Number(result.latencyMs);
        latencyCount += 1;
      }
      const rawVerdict = stringValue(item.evaluation && item.evaluation.verdict);
      const verdict = ['correct', 'partial', 'incorrect'].includes(rawVerdict) ? rawVerdict : '';
      const comment = stringValue(item.evaluation && item.evaluation.comment).slice(0, LIMITS.maxEvaluationCommentLength);
      if (verdict) {
        evaluationSummary.evaluated += 1;
        evaluationSummary[verdict] += 1;
      } else evaluationSummary.unevaluated += 1;
      if (comment) evaluationSummary.withComments += 1;
      if (verdict || comment) evaluations.push({ index, verdict, comment });
      return {
        index,
        donation: {
          name: stringValue(item.donation && item.donation.name),
          amount: Number(item.donation && item.donation.amount) || 0,
          currency: stringValue(item.donation && item.donation.currency || 'RUB'),
          message: stringValue(item.donation && item.donation.message)
        },
        status: stringValue(item.status),
        aiResponse: result.aiResponse && typeof result.aiResponse === 'object' ? result.aiResponse : null,
        rawAiContent: boundedRaw(result.rawAiContent || errorDetails.rawAiContent),
        catalogResults: result.catalogResults && typeof result.catalogResults === 'object' ? result.catalogResults : {},
        usage: {
          promptTokens: Number(usage.promptTokens) || 0,
          completionTokens: Number(usage.completionTokens) || 0,
          cachedTokens: Number(usage.cachedTokens) || 0,
          cost: usage.cost !== null && usage.cost !== undefined && usage.cost !== '' && Number.isFinite(Number(usage.cost))
            ? Number(usage.cost)
            : null
        },
        model: stringValue(result.model || errorDetails.model),
        provider: stringValue(result.provider || errorDetails.provider),
        requestId: stringValue(result.requestId || errorDetails.requestId),
        latencyMs: Number(result.latencyMs || errorDetails.latencyMs) || 0,
        error: item.error ? safeError(item.error) : null,
        evaluation: {
          verdict,
          comment
        },
        promptFingerprint: stringValue(result.prompt && result.prompt.fingerprint || errorDetails.promptFingerprint)
      };
    });
    const success = items.filter(item => item.status === 'success').length;
    const errors = items.filter(item => item.status === 'error').length;
    const costs = results.map(item => item.usage.cost).filter(value => value !== null);
    const totalKnownCost = costs.reduce((sum, value) => sum + value, 0);
    return {
      exportedAt: exportedAt || new Date().toISOString(),
      source: {
        fileName: stringValue(state.source && state.source.fileName),
        totalDonations: items.length
      },
      prompt: {
        version: stringValue(state.prompt && state.prompt.version),
        fingerprint: stringValue(state.prompt && state.prompt.fingerprint),
        text: stringValue(state.prompt && state.prompt.text)
      },
      model: stringValue(state.model),
      summary: {
        total: items.length,
        processed: success + errors,
        success,
        errors,
        promptTokens,
        completionTokens,
        cachedTokens,
        totalCost: costs.length === results.length && results.length > 0 ? totalKnownCost : null,
        totalKnownCost,
        costedRequests: costs.length,
        uncostedRequests: results.length - costs.length,
        averageLatencyMs: latencyCount ? Math.round(latency / latencyCount) : 0,
        evaluations: evaluationSummary
      },
      evaluations,
      results
    };
  }

  return {
    LIMITS,
    STORAGE_KEY,
    normalizeAmount,
    normalizeDonationRecord,
    normalizeDonationList,
    parseDonationInput,
    splitPlainText,
    createQueueItems,
    normalizeRestoredItems,
    safeError,
    SequentialQueue,
    buildExport
  };
});
