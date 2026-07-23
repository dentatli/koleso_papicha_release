'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const htmlPath = path.join(__dirname, '..', 'koleso_papich.html');
// GitHub Actions checks out the repository on Windows, where text files may use
// CRLF. Normalize only the test fixture so source-contract assertions behave
// identically on Windows and Linux.
const source = fs.readFileSync(htmlPath, 'utf8').replace(/\r\n?/g, '\n');
const centrifugeSource = fs.readFileSync(path.join(__dirname, '..', 'centrifuge.min.js'), 'utf8').replace(/\r\n?/g, '\n');
const centrifugeHash = crypto.createHash('sha256').update(centrifugeSource, 'utf8').digest('hex');
const thirdPartyNotices = fs.readFileSync(path.join(__dirname, '..', 'assets', 'THIRD_PARTY_NOTICES.md'), 'utf8');
const inlineScripts = [...source.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/gi)]
  .map(match => match[1])
  .filter(script => script.trim());
assert(inlineScripts.length > 0, 'Inline application script not found');
inlineScripts.forEach(script => new Function(script));
const start = source.indexOf('    function normalizeAiComparableText');
const end = source.indexOf('    function createEntryFromAiCandidate', start);
if (start < 0 || end < 0) throw new Error('AI frontend helper block not found');

function loadHelpers(entries) {
  const block = source.slice(start, end);
  return new Function('entries', `${block}
    return {
      compareAiLotTitles,
      isValidAiRomanNumeral,
      areAiLotCategoriesCompatible,
      getCurrentEntryFingerprint,
      doesEntryMatchAiFingerprint,
      findExistingEntryForAiCandidate,
      doesAiManualSuggestionDuplicateCandidate
    };
  `)(entries);
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

assert(centrifugeHash === 'c99b88dd95dc8d5e0a8d654ef650d5040efd87cbcfa22eba724f3bfdaef8961a', 'Vendored Centrifuge source no longer matches the documented upstream build');
assert(thirdPartyNotices.includes('centrifuge@2.8.5') && thirdPartyNotices.includes(centrifugeHash), 'Centrifuge version or integrity metadata is missing');

assert(source.includes('id="show-added-order"') && source.includes('<span>Показать номер добавления</span>'), 'Added-order checkbox is not phrased as an opt-in');
assert(!source.includes('id="hide-added-order"') && !source.includes('<span>Скрыть номер добавления</span>'), 'Legacy hide-added-order control is still present');
assert(source.includes('let hideAddedOrder = true;'), 'Added-order numbers are not hidden by default');
assert(source.includes("document.getElementById('show-added-order').checked = !hideAddedOrder;"), 'Added-order checkbox does not reflect positive show semantics');
assert(source.includes('hideAddedOrder = !e.target.checked;'), 'Added-order checkbox does not invert the stored hide flag');
assert(source.includes("title: 'Порядок в текущем списке'") && source.includes('text: displayIdx + 1'), 'Current list position number was removed');
assert(source.includes("title: 'Порядок добавления'") && source.includes('text: `#${addedOrder}`'), 'Opt-in added-order number is missing');

const identityStart = source.indexOf('    function limitAiServerText');
const identityEnd = source.indexOf('    function removeDonationAiJob', identityStart);
if (identityStart < 0 || identityEnd < 0) throw new Error('AI identity helper block not found');
function loadAiIdentityHelpers(pipelineVersion = 8) {
  return new Function('LLM_PIPELINE_VERSION', 'getEntriesForAiPayload', `${source.slice(identityStart, identityEnd)}; return {
    limitAiServerText,
    getActiveEntriesForAiIdentity,
    getAiInputFingerprint,
    getDonationAnalysisKey
  };`)(pipelineVersion, () => []);
}
const identityHelpers = loadAiIdentityHelpers(8);
const identityDonation = {
  source: 'donatepay',
  externalId: 'identity-1',
  message: 'на булли... МЯУ!',
  llm: null
};
const identityEntries = [{
  id: 'bully-entry',
  name: 'Bully',
  category: 'game',
  source: 'steam',
  externalId: '12200',
  eliminated: false
}];
const identityKey = identityHelpers.getDonationAnalysisKey(identityDonation, { preferTracked: false, entriesPayload: identityEntries });
assert(identityKey.startsWith('v8:donatepay:identity-1:'), 'Frontend analysis key does not include pipeline version');
assert(identityKey === 'v8:donatepay:identity-1:78d83657', 'Frontend analysisKey no longer matches the server UTF-16 fingerprint contract');
assert(
  identityHelpers.getDonationAnalysisKey({ ...identityDonation, message: 'на другую игру' }, { preferTracked: false, entriesPayload: identityEntries }) !== identityKey,
  'Frontend analysis key ignores donation message changes'
);
assert(
  identityHelpers.getDonationAnalysisKey(identityDonation, { preferTracked: false, entriesPayload: [...identityEntries, { id: 'other', name: 'Other', category: 'game' }] }) !== identityKey,
  'Frontend analysis key ignores active entry changes'
);
assert(
  loadAiIdentityHelpers(9).getDonationAnalysisKey(identityDonation, { preferTracked: false, entriesPayload: identityEntries }) !== identityKey,
  'Frontend analysis key ignores pipeline version changes'
);

const skipStart = source.indexOf('    function shouldSkipDonationAi');
const skipEnd = source.indexOf('    function getEntriesForAiPayload', skipStart);
if (skipStart < 0 || skipEnd < 0) throw new Error('AI skip helper not found');
const { shouldSkipDonationAi } = new Function('LLM_PIPELINE_VERSION', `${source.slice(skipStart, skipEnd)}; return { shouldSkipDonationAi };`)(8);
assert(!shouldSkipDonationAi({ status: 'pending', llm: { pipelineVersion: 3, status: 'done' } }), 'Legacy AI result was reused after pipeline upgrade');
assert(shouldSkipDonationAi({ status: 'pending', llm: { pipelineVersion: 8, status: 'done' } }), 'Current completed AI result was needlessly resubmitted');

const settingsStart = source.indexOf('    function createDefaultLlmSettings');
const settingsEnd = source.indexOf('    // Cryptographically-strong randomness helpers', settingsStart);
if (settingsStart < 0 || settingsEnd < 0) throw new Error('LLM settings normalization block not found');
const settingsHelpers = new Function(
  'DEFAULT_LLM_MODEL',
  'LEGACY_DEFAULT_LLM_MODELS',
  `${source.slice(settingsStart, settingsEnd)}; return { createDefaultLlmSettings, normalizeStoredLlmSettings };`
)('google/gemini-3-flash-preview', new Set(['google/gemini-2.5-flash-lite']));
assert(settingsHelpers.createDefaultLlmSettings().model === 'google/gemini-3-flash-preview', 'New installations do not use Gemini 3 Flash Preview.');
assert(settingsHelpers.normalizeStoredLlmSettings({ model: 'google/gemini-2.5-flash-lite' }).model === 'google/gemini-3-flash-preview', 'Legacy default model is not migrated.');
assert(settingsHelpers.normalizeStoredLlmSettings({ model: 'custom/provider-model' }).model === 'custom/provider-model', 'A user-selected custom model was overwritten.');

const mojibakeStart = source.indexOf('    function isLikelyMojibakeText');
const mojibakeEnd = source.indexOf('    function getSafeExternalUrl', mojibakeStart);
if (mojibakeStart < 0 || mojibakeEnd < 0) throw new Error('AI display safety helper block not found');
const displayHelpers = new Function('limitStoredText', `${source.slice(mojibakeStart, mojibakeEnd)}; return {
  isLikelyMojibakeText,
  getSafeAiDisplayText
};`)((value, maxLength) => String(value || '').slice(0, maxLength));
assert(displayHelpers.getSafeAiDisplayText('Сообщение указывает на игру Bully', 'fallback').includes('Bully'), 'Valid Russian AI reason was hidden');
assert(displayHelpers.getSafeAiDisplayText('Ð½Ð° Ð±ÑƒÐ»Ð»Ð¸', 'Безопасный текст') === 'Безопасный текст', 'Mojibake-like AI reason reached the UI');

const daDisplayStart = source.indexOf('    function getDonationAlertsServerDisplayState');
const daDisplayEnd = source.indexOf('    function getEffectiveIntegrationState', daDisplayStart);
if (daDisplayStart < 0 || daDisplayEnd < 0) throw new Error('DonationAlerts display helper not found');
const { getDonationAlertsServerDisplayState } = new Function(
  'formatIntegrationEventTime',
  `${source.slice(daDisplayStart, daDisplayEnd)}; return { getDonationAlertsServerDisplayState };`
)(value => value || '—');
const degradedDaState = getDonationAlertsServerDisplayState({ status: 'degraded', degraded: true }, '');
assert(degradedDaState.status === 'connecting', 'Transient DonationAlerts failure is shown as a terminal error');
assert(degradedDaState.message.includes('выполняется повтор'), 'DonationAlerts degraded UI does not explain automatic retry');
const authDaState = getDonationAlertsServerDisplayState({ status: 'auth_error' }, '');
assert(authDaState.label.includes('переподключение'), 'DonationAlerts auth failure does not request reconnection');

assert(source.includes('pipelineVersion: LLM_PIPELINE_VERSION,\n          auctionGeneration:'), 'AI job request does not send pipelineVersion');
assert(source.includes('const LLM_PIPELINE_VERSION = 8;'), 'Frontend pipeline version was not advanced for prompt/model semantics.');
assert(source.includes("const DEFAULT_LLM_MODEL = 'google/gemini-3-flash-preview';"), 'Frontend default model is not Gemini 3 Flash Preview.');
const defaultModelDeclarationIndex = source.indexOf("const DEFAULT_LLM_MODEL = 'google/gemini-3-flash-preview';");
const initialLlmSettingsIndex = source.indexOf('let llmSettings = createDefaultLlmSettings();');
assert(defaultModelDeclarationIndex >= 0 && defaultModelDeclarationIndex < initialLlmSettingsIndex, 'Default LLM model is initialized after its first runtime use.');
assert(source.includes("title.appendChild(document.createTextNode('AI выбрал существующий лот: '))"), 'Existing-entry AI result has no clear Russian UI state');
assert(!source.includes('AI понял: Неизвестно · unknown'), 'Raw unknown enum is still shown to users');
assert(source.includes("'LLM_RESPONSE_CONTENT_MISSING'"), 'Missing OpenRouter content has no safe UI state');
assert(source.includes("'LLM_RESPONSE_REFUSAL'"), 'OpenRouter refusal has no safe UI state');
assert(source.includes('result.items.length > 0 && !normalized.items.length'), 'A valid empty no-target result is rejected by the frontend.');
const aiBlockStart = source.indexOf('    function createDonationAiBlock');
const aiBlockEnd = source.indexOf('    function formatDonationMoney', aiBlockStart);
const aiBlockSource = source.slice(aiBlockStart, aiBlockEnd);
assert(aiBlockSource.includes('reason.textContent = getSafeAiDisplayText'), 'AI reason bypasses safe text rendering');
assert(aiBlockSource.includes("AI не нашёл явного предложения лота"), 'No-target result has no clear frontend state.');
assert(!aiBlockSource.includes('.innerHTML'), 'AI result UI inserts model output as HTML');
const aiItemsStart = source.indexOf('    function appendAiCategoryMismatchWarning');
const aiItemsSource = source.slice(aiItemsStart, aiBlockEnd);
assert(aiItemsSource.includes('Добавить в «${entry.name}»'), 'Existing AI option is not rendered as a separate add button');
assert(aiItemsSource.includes('Создать «${candidate.title}» и добавить'), 'Steam candidate is not rendered as a separate create-and-add button');
assert(aiItemsSource.includes("'Открыть в Steam'"), 'Steam candidate has no verification link');
assert(aiItemsSource.includes('Категория лота:'), 'Cross-category AI option has no visible warning');
assert(aiItemsSource.includes('llm.items.forEach'), 'Multi-item AI result is not rendered item-by-item');
assert(aiItemsSource.includes('item.displayTitle || item.officialTitleGuess'), 'AI card does not prioritize displayTitle.');
assert(aiItemsSource.includes('createEntryFromAiManualSuggestionAndAssign'), 'Manual AI suggestion has no create-and-add action.');
assert(aiItemsSource.includes('!doesAiManualSuggestionDuplicateCandidate(item)'), 'Manual suggestion duplicates a confirmed catalog create button.');
for (const text of ['Не подтверждено каталогом', 'временно недоступен', 'отключён', 'внешний каталог не используется']) {
  assert(aiItemsSource.includes(text), `AI UI is missing catalog state: ${text}`);
}
assert(aiItemsSource.includes('Низкая уверенность AI'), 'Low-confidence manual suggestion has no visible warning.');
assert(aiItemsSource.includes('ручной лот будет создан в категории «Другое»'), 'Unknown-category manual creation has no warning.');
assert(aiItemsSource.includes('candidate.titleConfirmed === false'), 'Unconfirmed localized Steam title can create a lot');
assert(!aiItemsSource.includes('.innerHTML'), 'Multi-item AI UI inserts external text as HTML');
assert(source.includes('name: limitStoredText(String(candidate.title).trim(), MAX_LOT_NAME_LENGTH)'), 'Created AI lot does not use the confirmed catalog title');
assert(!source.includes("candidate.title || donation.llm?.query || 'Новый лот'"), 'AI title guess can still become the final Steam lot name');

const llmNormalizerStart = source.indexOf('    function normalizeAiDisplayTitle');
const llmNormalizerEnd = source.indexOf('    function isDonationConversionUnavailable', llmNormalizerStart);
if (llmNormalizerStart < 0 || llmNormalizerEnd < 0) throw new Error('AI result normalizer block not found');
const { normalizeDonationLlmState, normalizeAiManualSuggestion } = new Function(
  'limitStoredText',
  'getSafeExternalUrl',
  'AI_ANALYSIS_ALLOWED_CATEGORIES',
  'isSafeAiExistingMatchEvidence',
  'MAX_LOT_NAME_LENGTH',
  `${source.slice(llmNormalizerStart, llmNormalizerEnd)}; return { normalizeDonationLlmState, normalizeAiManualSuggestion };`
)(
  (value, maxLength) => String(value || '').slice(0, maxLength),
  value => /^https?:\/\//.test(String(value || '')) ? String(value) : '',
  ['game', 'anime', 'movie', 'tv_show', 'cartoon', 'other', 'unknown'],
  value => ['exact_title', 'exact_external_identity'].includes(value?.existingMatchKind),
  200
);
const multiItemState = normalizeDonationLlmState({
  action: 'ask_manual',
  items: [
    {
      itemId: 'digger', category: 'game', catalog: 'steam', mentionedTitle: 'Копатель Онлайн', displayTitle: 'Digger Online', officialTitleGuess: 'Digger Online', originalLanguage: 'en',
      query: 'Digger Online', searchQueries: ['Digger Online', 'Копатель Онлайн'], intentConfidence: 0.92,
      existingOptions: [], candidates: [{ source: 'steam', externalId: '278970', title: 'Digger Online', sourceUrl: 'https://store.steampowered.com/app/278970' }]
    },
    {
      itemId: 'minecraft', category: 'game', catalog: 'steam', mentionedTitle: 'Майнкрафт', displayTitle: 'Minecraft', officialTitleGuess: 'Minecraft', originalLanguage: 'en',
      query: 'Minecraft', searchQueries: ['Minecraft'], intentConfidence: 0.86, existingOptions: [], candidates: []
    }
  ]
});
assert(multiItemState.items.length === 2, 'Multi-item AI result was collapsed to one item');
assert(multiItemState.items[0].candidates[0].title === 'Digger Online', 'Confirmed Steam candidate metadata was lost in frontend normalization');
assert(multiItemState.items[0].displayTitle === 'Digger Online', 'Digger Online display title regressed to a translated/transliterated title.');
assert(multiItemState.items[0].manualSuggestion?.title === 'Digger Online', 'Digger Online lost its independent manual suggestion.');
const duplicateHelpers = loadHelpers([]);
assert(duplicateHelpers.doesAiManualSuggestionDuplicateCandidate(multiItemState.items[0]), 'Identical catalog and manual Digger actions were not detected as duplicates.');
assert(!duplicateHelpers.doesAiManualSuggestionDuplicateCandidate({
  candidates: [{ title: 'Alyosha Popovich and the Magic Horse', titleConfirmed: true }],
  manualSuggestion: { title: 'Алёша Попович и Тугарин Змей' }
}), 'A distinct canonical Russian manual title was hidden by an English catalog alias.');
for (const catalogStatus of ['not_found', 'unavailable', 'disabled', 'not_applicable']) {
  const state = normalizeDonationLlmState({
    action: 'ask_manual',
    items: [{
      category: 'game', catalog: 'steam', mentionedTitle: 'алеша попович',
      displayTitle: 'Алёша Попович и Тугарин Змей', officialTitleGuess: 'Alyosha Popovich and the Magic Horse',
      originalLanguage: 'ru', intentConfidence: 0.2, catalogStatus, candidates: [], existingOptions: []
    }]
  });
  assert(state.items[0].displayTitle === 'Алёша Попович и Тугарин Змей', `${catalogStatus} damaged Russian displayTitle.`);
  assert(state.items[0].manualSuggestion?.title === 'Алёша Попович и Тугарин Змей', `${catalogStatus} hid manual creation.`);
  assert(state.items[0].manualSuggestion?.source === 'llm_manual', `${catalogStatus} forged a catalog source for manual creation.`);
  assert(state.items[0].manualSuggestion?.externalId === '' && state.items[0].manualSuggestion?.sourceUrl === '', `${catalogStatus} retained external identity for a manual lot.`);
}
const unknownCategoryState = normalizeDonationLlmState({
  action: 'ask_manual',
  items: [{ category: 'unknown', catalog: 'none', displayTitle: 'Осмысленное произведение', intentConfidence: 0.1, catalogStatus: 'not_applicable' }]
});
assert(unknownCategoryState.items[0].manualSuggestion?.category === 'other', 'Unknown category was not mapped to other for manual creation.');
for (const category of ['game', 'anime', 'movie', 'tv_show', 'cartoon', 'other']) {
  const categoryState = normalizeDonationLlmState({
    action: 'ask_manual',
    items: [{ category, catalog: 'none', displayTitle: `Название ${category}`, intentConfidence: 0.1, catalogStatus: 'not_applicable' }]
  });
  assert(categoryState.items[0].manualSuggestion?.category === category, `Frontend manual suggestion lost category ${category}.`);
}
const noisyTitleState = normalizeDonationLlmState({
  action: 'ask_manual',
  items: [{ category: 'game', catalog: 'steam', displayTitle: 'https://example.test/game', intentConfidence: 0.9, catalogStatus: 'not_found' }]
});
assert(!noisyTitleState.items[0].manualSuggestion, 'URL received a manual create action.');
const crossCategoryNormalized = normalizeDonationLlmState({
  action: 'ask_manual',
  items: [{
    category: 'game', query: 'Naruto', existingOptions: [{
      entryId: 'anime-naruto', title: 'Naruto', category: 'anime', categoryMismatch: true,
      entryFingerprint: { normalizedName: 'naruto', source: 'anilist', externalId: '20' }
    }], candidates: []
  }]
});
assert(crossCategoryNormalized.items[0].existingOptions[0].categoryMismatch, 'Cross-category warning metadata was lost');
assert(!crossCategoryNormalized.items[0].existingOptions[0].safeAutoAssign, 'Cross-category option became auto-applicable during normalization');
const legacySingleState = normalizeDonationLlmState({
  action: 'create_lot_candidate', category: 'game', query: 'Digger Online', intentConfidence: 0.9,
  candidate: { source: 'steam', externalId: '278970', title: 'Digger Online', sourceUrl: 'https://store.steampowered.com/app/278970' }
});
assert(legacySingleState.items.length === 1, 'Legacy single-item AI result no longer loads');
assert(legacySingleState.items[0].displayTitle === 'Digger Online', 'Legacy AI result did not use confirmed candidate title as display fallback.');
const partiallyInvalidState = normalizeDonationLlmState({
  action: 'ask_manual',
  items: [null, { category: 'game', query: 'Bully', candidates: [], existingOptions: [] }]
});
assert(partiallyInvalidState.items.length === 1, 'One malformed AI item discarded the entire valid result');
const oversizedItemsState = normalizeDonationLlmState({
  action: 'ask_manual',
  items: Array.from({ length: 8 }, (_, index) => ({ category: 'game', query: `Game ${index}`, candidates: [], existingOptions: [] }))
});
assert(oversizedItemsState.items.length === 5, 'Frontend does not enforce the AI item limit');

const actionClaimStart = source.indexOf('    function tryClaimAiDonationAction');
const actionClaimEnd = source.indexOf('    function createEntryFromAiCandidate', actionClaimStart);
if (actionClaimStart < 0 || actionClaimEnd < 0) throw new Error('AI action lock helpers not found');
const actionClaims = new Function(`${source.slice(actionClaimStart, actionClaimEnd)}; return { tryClaimAiDonationAction, releaseAiDonationAction };`)();
const actionLocks = new Set();
assert(actionClaims.tryClaimAiDonationAction('donation-1', actionLocks), 'First AI action could not claim the donation');
assert(!actionClaims.tryClaimAiDonationAction('donation-1', actionLocks), 'The same donation can be claimed twice');
actionClaims.releaseAiDonationAction('donation-1', actionLocks);
assert(actionClaims.tryClaimAiDonationAction('donation-1', actionLocks), 'AI donation lock was not released');

const manualActionStart = source.indexOf('    function findExistingEntryForAiManualSuggestion');
const manualActionEnd = source.indexOf('    function createEntryFromAiCandidateAndAssign', manualActionStart);
if (manualActionStart < 0 || manualActionEnd < 0) throw new Error('Manual AI create-and-assign helper not found');
const manualActionBlock = source.slice(manualActionStart, manualActionEnd);
function createManualActionHarness({ initialEntries = [], assignSucceeds = true } = {}) {
  const donation = { id: 'manual-donation', status: 'pending', amount: 1500, source: 'donatepay', externalId: 'dp-1', llm: { status: 'done' } };
  return new Function(
    'initialEntries', 'initialDonation', 'normalizeAiManualSuggestion', 'assignSucceeds',
    `${source.slice(start, end)}
     let entries = initialEntries;
     let donationsPending = [initialDonation];
     const donationsAdded = [];
     const aiDonationActionLocks = new Set();
     let assignmentCount = 0;
      function canMutateAuctionState() { return true; }
      function canCreateAuctionEntry() { return entries.length < 2000; }
      function canCreditDonationAmount(value) { return Number(value?.amount) > 0; }
     function getPendingDonationById(id) { return donationsPending.find(item => item.id === id && item.status === 'pending') || null; }
     function isDonationKnownOutsidePending(value) { return donationsAdded.some(item => item.externalId === value.externalId); }
     function tryClaimAiDonationAction(id) { if (aiDonationActionLocks.has(id)) return false; aiDonationActionLocks.add(id); return true; }
     function releaseAiDonationAction(id) { aiDonationActionLocks.delete(id); }
     function cryptoRandomUint32() { return 1; }
     function pickWheelColor() { return '#ffffff'; }
     function resetAuctionProgressForCompositionChange() {}
     function saveData() {}
     function renderList() {}
     function drawWheel() {}
     function renderDonationsPanel() {}
     function assignDonationToEntry(donationId, entryId) {
       if (assignSucceeds === 'throw') throw new Error('simulated assignment failure');
       if (!assignSucceeds) return false;
       const pending = getPendingDonationById(donationId);
       const entry = entries.find(item => item.id === entryId && !item.eliminated);
       if (!pending || !entry) return false;
       entry.price = Number(entry.price || 0) + Number(pending.amount || 0);
       pending.status = 'added';
       donationsPending = donationsPending.filter(item => item.id !== donationId);
       donationsAdded.push(pending);
       assignmentCount += 1;
       if (assignSucceeds === 'throw_after') throw new Error('simulated post-mutation failure');
       return true;
     }
     ${manualActionBlock}
     return {
       apply: createEntryFromAiManualSuggestionAndAssign,
       getEntries: () => entries,
       getAssignmentCount: () => assignmentCount
     };`
  )(initialEntries, donation, normalizeAiManualSuggestion, assignSucceeds);
}

const alyoshaSuggestion = {
  title: 'Алёша Попович и Тугарин Змей', category: 'game', originalLanguage: 'ru',
  source: 'llm_manual', externalId: '', sourceUrl: ''
};
const manualSuccess = createManualActionHarness();
assert(manualSuccess.apply('manual-donation', alyoshaSuggestion), 'Manual AI lot was not created and credited.');
assert(manualSuccess.getEntries().length === 1, 'Manual AI action created an unexpected number of lots.');
assert(manualSuccess.getEntries()[0].name === 'Алёша Попович и Тугарин Змей', 'Manual AI lot lost its canonical Russian display title.');
assert(manualSuccess.getEntries()[0].category === 'game', 'Manual AI lot lost its category.');
assert(manualSuccess.getEntries()[0].source === 'llm_manual', 'Manual AI lot forged a catalog source.');
assert(manualSuccess.getEntries()[0].externalId === '' && manualSuccess.getEntries()[0].sourceUrl === '', 'Manual AI lot retained external metadata.');
assert(manualSuccess.getEntries()[0].price === 1500 && manualSuccess.getAssignmentCount() === 1, 'Manual AI donation was not credited exactly once.');
assert(!manualSuccess.apply('manual-donation', alyoshaSuggestion), 'Processed donation could be credited a second time.');
assert(manualSuccess.getEntries()[0].price === 1500 && manualSuccess.getAssignmentCount() === 1, 'Repeated manual action duplicated the donation amount.');

const manualRollback = createManualActionHarness({ assignSucceeds: false });
assert(!manualRollback.apply('manual-donation', alyoshaSuggestion), 'Failed donation assignment was reported as successful.');
assert(manualRollback.getEntries().length === 0, 'Failed assignment left an orphaned manual AI lot.');
const manualExceptionRollback = createManualActionHarness({ assignSucceeds: 'throw' });
assert(!manualExceptionRollback.apply('manual-donation', alyoshaSuggestion), 'Thrown assignment failure was reported as successful.');
assert(manualExceptionRollback.getEntries().length === 0, 'Thrown assignment failure left an orphaned manual AI lot.');
const manualPostMutationRollback = createManualActionHarness({ assignSucceeds: 'throw_after' });
assert(!manualPostMutationRollback.apply('manual-donation', alyoshaSuggestion), 'Post-mutation assignment failure was reported as successful.');
assert(manualPostMutationRollback.getEntries().length === 0, 'Post-mutation assignment failure left an orphaned manual AI lot.');

const existingRussianLot = { id: 'alyosha-existing', name: 'Алёша Попович и Тугарин Змей', price: 0, category: 'game', source: 'llm_manual', externalId: '', eliminated: false };
const manualDuplicateGuard = createManualActionHarness({ initialEntries: [existingRussianLot] });
assert(manualDuplicateGuard.apply('manual-donation', { ...alyoshaSuggestion, title: 'Алеша Попович и Тугарин Змей' }), 'Existing Russian lot was not found through е/ё normalization.');
assert(manualDuplicateGuard.getEntries().length === 1, 'Manual action created an exact duplicate Russian lot.');
assert(manualDuplicateGuard.getEntries()[0].name === 'Алёша Попович и Тугарин Змей', 'Existing lot display spelling was overwritten by normalized text.');
assert(manualDuplicateGuard.getEntries()[0].price === 1500, 'Donation was not credited to the existing Russian lot.');
const existingRollbackLot = { id: 'alyosha-existing', name: 'Алёша Попович и Тугарин Змей', price: 25, category: 'game', source: 'llm_manual', externalId: '', eliminated: false };
const existingRollback = createManualActionHarness({ initialEntries: [existingRollbackLot], assignSucceeds: 'throw_after' });
assert(!existingRollback.apply('manual-donation', alyoshaSuggestion), 'Existing-lot post-mutation failure was reported as successful.');
assert(existingRollback.getEntries().length === 1 && existingRollback.getEntries()[0].price === 25, 'Existing lot amount was not rolled back after an assignment exception.');

assert(source.includes('--link-color:'), 'Global link color variable is missing');
assert(source.includes('a:visited {\n      color: var(--link-color);'), 'Visited text links can fall back to browser purple');
assert(source.includes('a:hover {\n      color: var(--link-hover-color);'), 'Global link hover state is missing');
assert(source.includes('a:focus-visible {'), 'Global link focus-visible state is missing');
assert(!/\.integration-external-link\s*\{[^}]*color:\s*#74c0fc/s.test(source), 'Integration links still force the old blue color');
assert(!/\.help-card a[^{]*\{[^}]*color:\s*#74c0fc/s.test(source), 'Help links still force the old blue color');
assert(source.includes('.version-update-notice:visited') && source.includes('.app-version-badge:visited'), 'Link-like badges do not preserve their button styling after visit');

const existingEvidenceStart = source.indexOf('    function isSafeAiExistingMatchEvidence');
const existingEvidenceEnd = source.indexOf('    function normalizeAiComparableText', existingEvidenceStart);
if (existingEvidenceStart < 0 || existingEvidenceEnd < 0) throw new Error('AI existing-match evidence helper not found');
const { isSafeAiExistingMatchEvidence } = new Function(
  `${source.slice(existingEvidenceStart, existingEvidenceEnd)}; return { isSafeAiExistingMatchEvidence };`
)();
assert(isSafeAiExistingMatchEvidence({ existingMatchKind: 'exact_title' }), 'Exact-title AI evidence was rejected by frontend');
assert(isSafeAiExistingMatchEvidence({ existingMatchKind: 'exact_external_identity' }), 'Exact external identity was rejected by frontend');
assert(!isSafeAiExistingMatchEvidence({ matchedBy: 'llm_existing_entry', finalConfidence: 1 }), 'Legacy generic existing match can still auto-apply');
assert(!isSafeAiExistingMatchEvidence({ matchedBy: 'manual_required', finalConfidence: 1 }), 'Manual-only existing result can auto-apply');
const autoAssignStart = source.indexOf('    function canAutoApplyAiSuggestion');
const autoAssignEnd = source.indexOf('    function normalizeAiComparableText', autoAssignStart);
const autoAssignSource = source.slice(autoAssignStart, autoAssignEnd);
assert(autoAssignSource.includes('isSafeAiExistingMatchEvidence(llm)'), 'Auto-assign bypasses safe semantic match evidence');

const autoCreateStart = source.indexOf('    function getAiAutoCreateOption');
const autoCreateEnd = source.indexOf('    function canAutoApplyAiSuggestion', autoCreateStart);
if (autoCreateStart < 0 || autoCreateEnd < 0) throw new Error('AI auto-create helper not found');
const { getAiAutoCreateOption } = new Function(
  'getSafeExternalUrl',
  'findExistingEntryForAiCandidate',
  `${source.slice(autoCreateStart, autoCreateEnd)}; return { getAiAutoCreateOption };`
)(
  value => /^https:\/\//.test(String(value || '')) ? String(value) : '',
  candidate => candidate?.matchesExisting ? { id: 'existing' } : null
);
const safeAutoCreateItem = {
  category: 'game',
  catalogStatus: 'ok',
  intentConfidence: 1,
  candidates: [{
    source: 'steam', externalId: '2378900', title: 'The Coffin of Andy and Leyley',
    sourceUrl: 'https://store.steampowered.com/app/2378900', titleConfirmed: true,
    categoryMismatch: false, score: 1
  }]
};
const safeAutoCreateResult = {
  action: 'ask_manual',
  items: [safeAutoCreateItem]
};
const safeAutoCreateOption = getAiAutoCreateOption(safeAutoCreateResult, 0.92);
assert(safeAutoCreateOption?.candidate?.externalId === '2378900', 'One confirmed high-confidence catalog candidate cannot auto-create.');
assert(safeAutoCreateOption.finalConfidence === 1, 'Auto-create confidence does not combine intent and catalog confidence.');
assert(!getAiAutoCreateOption({ ...safeAutoCreateResult, items: [{ ...safeAutoCreateItem, intentConfidence: 0.9 }] }, 0.92), 'Low intent confidence can auto-create a lot.');
assert(!getAiAutoCreateOption({ ...safeAutoCreateResult, items: [{ ...safeAutoCreateItem, candidates: [{ ...safeAutoCreateItem.candidates[0], score: 0.9 }] }] }, 0.92), 'Low catalog confidence can auto-create a lot.');
assert(!getAiAutoCreateOption({ ...safeAutoCreateResult, items: [safeAutoCreateItem, { ...safeAutoCreateItem }] }, 0.92), 'A multi-work donation can auto-create a lot.');
assert(!getAiAutoCreateOption({
  ...safeAutoCreateResult,
  items: [{ ...safeAutoCreateItem, candidates: [safeAutoCreateItem.candidates[0], { ...safeAutoCreateItem.candidates[0], externalId: 'other' }] }]
}, 0.92), 'Two high-confidence catalog candidates can auto-create a lot.');
for (const unsafeCandidate of [
  { titleConfirmed: false },
  { categoryMismatch: true },
  { sourceUrl: 'javascript:alert(1)' },
  { matchesExisting: true }
]) {
  assert(!getAiAutoCreateOption({
    ...safeAutoCreateResult,
    items: [{ ...safeAutoCreateItem, candidates: [{ ...safeAutoCreateItem.candidates[0], ...unsafeCandidate }] }]
  }, 0.92), `Unsafe catalog candidate can auto-create: ${JSON.stringify(unsafeCandidate)}`);
}
assert(!getAiAutoCreateOption(safeAutoCreateResult, Number.NaN), 'Invalid auto-create threshold became permissive.');
assert(getAiAutoCreateOption({
  action: 'create_lot_candidate',
  category: 'game',
  finalConfidence: 0.95,
  selectionConfidence: 0,
  candidate: safeAutoCreateItem.candidates[0],
  candidates: [],
  items: [safeAutoCreateItem]
}, 0.92), 'Legacy single-candidate result can no longer auto-create after normalization.');
assert(autoAssignSource.includes("['create_lot_candidate', 'ask_manual'].includes(llm.action)"), 'New items[] results are excluded from auto-create dispatch.');
assert(!autoAssignSource.includes('llm.items.length === 0'), 'Auto-create still requires an impossible empty normalized items list.');
const applyAssignStart = source.indexOf('    async function applyAiAssignSuggestion');
const applyAssignEnd = source.indexOf('    async function applyAiSuggestion', applyAssignStart);
const applyAssignSource = source.slice(applyAssignStart, applyAssignEnd);
assert(applyAssignSource.includes('(auto && !isSafeAiExistingMatchEvidence(donation.llm))'), 'Automatic apply bypasses semantic evidence defense-in-depth');
const applySuggestionStart = source.indexOf('    async function applyAiSuggestion');
const applySuggestionEnd = source.indexOf('    function rejectAiSuggestion', applySuggestionStart);
const applySuggestionSource = source.slice(applySuggestionStart, applySuggestionEnd);
assert(applySuggestionSource.includes("auto && donation.llm.action === 'ask_manual'"), 'Safe items[] auto-create result is not applied.');
assert(applySuggestionSource.includes('createEntryFromAiCandidateAndAssign(donationId, option.candidate, option.item)'), 'items[] auto-create loses its selected candidate or category.');

const viewModeStart = source.indexOf('    function hasDonationAlertsOAuthAccessToken');
const viewModeEnd = source.indexOf('    function buildViewUrl', viewModeStart);
if (viewModeStart < 0 || viewModeEnd < 0) throw new Error('View mode helper block not found');
function loadViewModeHelpers(locationValue) {
  return new Function('location', 'URLSearchParams', `${source.slice(viewModeStart, viewModeEnd)}; return {
    hasDonationAlertsOAuthAccessToken,
    getAppViewMode
  };`)(locationValue, URLSearchParams);
}
const oauthViewHelpers = loadViewModeHelpers({ hash: '#access_token=temporary&token_type=Bearer', search: '' });
assert(oauthViewHelpers.hasDonationAlertsOAuthAccessToken(), 'DonationAlerts OAuth access token was not detected before leader election');
assert(oauthViewHelpers.getAppViewMode() === 'admin', 'DonationAlerts OAuth callback did not force admin mode before leader election');
assert(loadViewModeHelpers({ hash: '', search: '' }).getAppViewMode() === 'wheel', 'Default non-OAuth view mode changed unexpectedly');

const oauthStateStart = source.indexOf('    function createDonationAlertsOAuthState');
const oauthStateEnd = source.indexOf('    function startDonationAlertsImplicitOAuth', oauthStateStart);
if (oauthStateStart < 0 || oauthStateEnd < 0) throw new Error('DonationAlerts OAuth state helpers not found');
const oauthSessionValues = new Map();
const oauthStateHelpers = new Function(
  'crypto',
  'sessionStorage',
  'DONATIONALERTS_OAUTH_STATE_KEY',
  'DONATIONALERTS_OAUTH_STATE_MAX_AGE_MS',
  'DONATIONALERTS_REDIRECT_URL',
  'DONATIONALERTS_SCOPES',
  `${source.slice(oauthStateStart, oauthStateEnd)}; return {
    createDonationAlertsOAuthState,
    consumeDonationAlertsOAuthState,
    buildDonationAlertsImplicitOAuthUrl
  };`
)(
  { getRandomValues: bytes => { bytes.forEach((_, index) => { bytes[index] = index; }); return bytes; } },
  {
    getItem: key => oauthSessionValues.get(key) ?? null,
    setItem: (key, value) => oauthSessionValues.set(key, value),
    removeItem: key => oauthSessionValues.delete(key)
  },
  'oauth-state-test',
  10 * 60 * 1000,
  'http://127.0.0.1:5500/koleso_papich.html',
  'oauth-user-show oauth-donation-index'
);
const oauthState = oauthStateHelpers.createDonationAlertsOAuthState();
assert(oauthState.length === 64, 'DonationAlerts OAuth state is not a 256-bit random value');
assert(oauthStateHelpers.consumeDonationAlertsOAuthState(oauthState), 'Matching DonationAlerts OAuth state was rejected');
assert(!oauthStateHelpers.consumeDonationAlertsOAuthState(oauthState), 'DonationAlerts OAuth state can be reused');
const mismatchedState = oauthStateHelpers.createDonationAlertsOAuthState();
assert(!oauthStateHelpers.consumeDonationAlertsOAuthState(`${mismatchedState}-wrong`), 'Mismatched DonationAlerts OAuth state was accepted');
oauthSessionValues.set('oauth-state-test', JSON.stringify({ value: 'expired', createdAt: Date.now() - 10 * 60 * 1000 - 1 }));
assert(!oauthStateHelpers.consumeDonationAlertsOAuthState('expired'), 'Expired DonationAlerts OAuth state was accepted');
const oauthAuthorizeUrl = new URL(oauthStateHelpers.buildDonationAlertsImplicitOAuthUrl('19587', 'state-value'));
assert(oauthAuthorizeUrl.searchParams.get('state') === 'state-value', 'DonationAlerts authorization URL has no state binding');
const oauthStateCallbackSource = source.slice(
  source.indexOf('    async function handleDonationAlertsOAuthCallback'),
  source.indexOf('    async function finishDonationAlertsConnection')
);
assert(oauthStateCallbackSource.indexOf('consumeDonationAlertsOAuthState') < oauthStateCallbackSource.indexOf('saveDonationAlertsSecretToServer'), 'OAuth token can be stored before state validation');

const legacySecretStripStart = source.indexOf('    function stripLegacyIntegrationSecretsFromStoredState');
const legacySecretStripEnd = source.indexOf('    function loadData', legacySecretStripStart);
if (legacySecretStripStart < 0 || legacySecretStripEnd < 0) throw new Error('Legacy secret stripping helper not found');
const { stripLegacyIntegrationSecretsFromStoredState } = new Function(
  `${source.slice(legacySecretStripStart, legacySecretStripEnd)}; return { stripLegacyIntegrationSecretsFromStoredState };`
)();
const legacyStoredState = {
  donationIntegrations: {
    donatepay: { accessToken: 'legacy-dp', enabled: true },
    donationalerts: { refreshToken: 'legacy-refresh', userId: '42' },
    openrouter: { apiKey: 'legacy-openrouter', proxyUrl: 'http://user:pass@127.0.0.1:7890' },
    steam: { apiKey: 'obsolete' }
  }
};
assert(stripLegacyIntegrationSecretsFromStoredState(legacyStoredState), 'Legacy browser secrets were not detected');
assert(!legacyStoredState.donationIntegrations.donatepay.accessToken, 'Legacy DonatePay token was not removed immediately after load');
assert(!legacyStoredState.donationIntegrations.donationalerts.refreshToken, 'Legacy DonationAlerts secret was not removed immediately after load');
assert(!legacyStoredState.donationIntegrations.openrouter.apiKey && !legacyStoredState.donationIntegrations.openrouter.proxyUrl, 'Legacy OpenRouter secret was not removed immediately after load');
assert(!legacyStoredState.donationIntegrations.steam, 'Obsolete Steam secret storage was not removed');
assert(legacyStoredState.donationIntegrations.donatepay.enabled && legacyStoredState.donationIntegrations.donationalerts.userId === '42', 'Secret stripping changed non-secret integration settings');

const storageSanitizerStart = source.indexOf('    function sanitizeDonationIntegrationsForStorage');
const storageSanitizerEnd = source.indexOf('    function saveData', storageSanitizerStart);
if (storageSanitizerStart < 0 || storageSanitizerEnd < 0) throw new Error('Storage sanitizer helper not found');
const { sanitizeDonationIntegrationsForStorage } = new Function(
  'createDefaultDonationIntegrations',
  `${source.slice(storageSanitizerStart, storageSanitizerEnd)}; return { sanitizeDonationIntegrationsForStorage };`
)(() => ({ donatepay: {}, donationalerts: {}, openrouter: {} }));
const sanitizedIntegrations = sanitizeDonationIntegrationsForStorage({
  donatepay: { accessToken: 'legacy-dp', apiKey: 'legacy-key', token: 'legacy-token' },
  donationalerts: { accessToken: 'legacy-da', refreshToken: 'legacy-refresh' },
  openrouter: { apiKey: 'legacy-openrouter', proxyUrl: 'http://user:pass@127.0.0.1:7890' }
});
assert(!sanitizedIntegrations.donatepay.accessToken, 'Legacy DonatePay token can be written back to localStorage');
assert(!sanitizedIntegrations.donatepay.apiKey && !sanitizedIntegrations.donatepay.token, 'Legacy DonatePay secret fields survived storage sanitization');
assert(!sanitizedIntegrations.donationalerts.accessToken && !sanitizedIntegrations.donationalerts.refreshToken, 'DonationAlerts secrets survived storage sanitization');
assert(!sanitizedIntegrations.openrouter.apiKey && !sanitizedIntegrations.openrouter.proxyUrl, 'OpenRouter secrets survived storage sanitization');

const storageSaveStart = source.indexOf('    function saveData');
const storageSaveEnd = source.indexOf('    function openResetSiteDataModal', storageSaveStart);
const storageSaveSource = source.slice(storageSaveStart, storageSaveEnd);
assert(storageSaveSource.includes('try {\n        localStorage.setItem') && storageSaveSource.includes('notifyStorageFailure(error);'), 'localStorage quota failures are not handled');
assert(storageSaveSource.includes('MAX_RECENT_SPIN_RESULTS') && source.includes('MAX_ADDED_DONATION_HISTORY = 1000'), 'Persisted history is still unbounded');
assert(source.includes('MAX_IGNORED_DONATIONS = 1000') && source.includes("donationsAdded.filter(item => item.status === 'ignored').length >= MAX_IGNORED_DONATIONS"), 'Ignored donation queue is still unbounded');
assert(source.includes('MAX_AUCTION_ENTRIES = 2000') && source.includes('canCreateAuctionEntry({ notify: true })'), 'New lot creation is still unbounded');

const donationNormalizerStart = source.indexOf('    function normalizeDonationForStorage');
const donationNormalizerEnd = source.indexOf('    function addDonationToPending', donationNormalizerStart);
if (donationNormalizerStart < 0 || donationNormalizerEnd < 0) throw new Error('Donation storage normalizer not found');
const { normalizeDonationForStorage } = new Function(
  'normalizeDonationCreatedAt',
  'normalizeDonationLlmState',
  'cryptoRandomUint32',
  'limitStoredText',
  'MAX_DONATION_MESSAGE_LENGTH',
  'MAX_LOT_NAME_LENGTH',
  `${source.slice(donationNormalizerStart, donationNormalizerEnd)}; return { normalizeDonationForStorage };`
)(
  value => String(value || ''),
  value => value || {},
  () => 1,
  (value, maxLength) => String(value || '').slice(0, maxLength),
  1000,
  200
);
const compactDonation = normalizeDonationForStorage({
  id: 'donation-1',
  source: 'donatepay',
  externalId: '1',
  username: 'u'.repeat(300),
  amount: 100,
  message: 'm'.repeat(1500),
  raw: { privatePayload: 'unused' }
});
assert(compactDonation && !Object.prototype.hasOwnProperty.call(compactDonation, 'raw'), 'Unused upstream donation payload is still persisted in browser state');
assert(compactDonation.username.length === 200 && compactDonation.message.length === 1000, 'External donation text is not bounded before browser storage');
assert(source.includes('id="new-name" placeholder="Название лота" maxlength="200"'), 'Lot name input has no browser-side length limit');
const convertedDonation = normalizeDonationForStorage({
  id: 'server-da-1',
  source: 'donationalerts',
  externalId: 'da-1',
  amount: 4388,
  currency: 'RUB',
  originalAmount: 50,
  originalCurrency: 'EUR',
  exchangeRate: 87.76,
  conversionSource: 'cbr',
  conversionStatus: 'converted',
  conversionDate: '2026-07-13',
  rateFetchedAt: '2026-07-13T10:00:00Z'
});
assert(convertedDonation.originalAmount === 50 && convertedDonation.originalCurrency === 'EUR', 'Donation conversion original values were not persisted');
assert(convertedDonation.exchangeRate === 87.76 && convertedDonation.conversionSource === 'cbr', 'Donation conversion rate metadata was not persisted');
assert(convertedDonation.conversionDate === '2026-07-13' && convertedDonation.rateFetchedAt, 'Donation conversion timestamps were not persisted');
const unavailableDonation = normalizeDonationForStorage({
  id: 'server-da-2', source: 'donationalerts', externalId: 'da-2', amount: 0, currency: 'RUB',
  originalAmount: 50, originalCurrency: 'EUR', conversionStatus: 'unavailable', conversionError: 'offline'
});
assert(unavailableDonation && unavailableDonation.amount === 0 && unavailableDonation.conversionStatus === 'unavailable', 'Unavailable DonationAlerts donation was dropped before manual conversion');
const legacyForeignDonation = normalizeDonationForStorage({
  id: 'da-legacy-eur', source: 'donationalerts', externalId: 'da-legacy-eur', amount: 50, currency: 'EUR'
});
assert(
  legacyForeignDonation
    && legacyForeignDonation.amount === 0
    && legacyForeignDonation.originalAmount === 50
    && legacyForeignDonation.originalCurrency === 'EUR'
    && legacyForeignDonation.conversionStatus === 'unavailable',
  'Legacy foreign-currency DonationAlerts donation can still be credited as RUB'
);
const legacyRubDonation = normalizeDonationForStorage({
  id: 'da-legacy-rub', source: 'donationalerts', externalId: 'da-legacy-rub', amount: 1000, currency: 'RUB'
});
assert(legacyRubDonation && legacyRubDonation.amount === 1000 && !legacyRubDonation.conversionStatus, 'Legacy RUB donation stopped loading normally');

const conversionGuardStart = source.indexOf('    function isDonationConversionUnavailable');
const conversionGuardEnd = source.indexOf('    function normalizeDonationForStorage', conversionGuardStart);
if (conversionGuardStart < 0 || conversionGuardEnd < 0) throw new Error('Donation conversion guard helpers not found');
const conversionGuards = new Function(`${source.slice(conversionGuardStart, conversionGuardEnd)}; return { isDonationConversionUnavailable, canCreditDonationAmount };`)();
assert(!conversionGuards.canCreditDonationAmount(unavailableDonation), 'Unavailable foreign-currency donation can be credited');
assert(conversionGuards.canCreditDonationAmount({ source: 'donationalerts', amount: 4388, conversionStatus: 'converted' }), 'Converted DonationAlerts donation cannot be credited');
assert(conversionGuards.canCreditDonationAmount({ source: 'donationalerts', amount: 1000 }), 'Legacy RUB donation stopped working');

const conversionPresentationStart = source.indexOf('    function formatDonationMoney');
const conversionPresentationEnd = source.indexOf('    function createDonationCard', conversionPresentationStart);
if (conversionPresentationStart < 0 || conversionPresentationEnd < 0) throw new Error('Donation conversion presentation helpers not found');
const { getDonationConversionPresentation } = new Function(
  'isDonationConversionUnavailable',
  `${source.slice(conversionPresentationStart, conversionPresentationEnd)}; return { getDonationConversionPresentation };`
)(conversionGuards.isDonationConversionUnavailable);
const convertedPresentation = getDonationConversionPresentation(convertedDonation);
assert(convertedPresentation.amountText.includes('50 EUR') && convertedPresentation.amountText.replace(/\D/g, '').endsWith('4388'), 'Donation card does not show original amount to credited RUB amount');
assert(convertedPresentation.detailText.includes('Курс ЦБ'), 'Donation card does not explain CBR conversion');
const unavailablePresentation = getDonationConversionPresentation(unavailableDonation);
assert(unavailablePresentation.amountText.includes('50 EUR') && unavailablePresentation.warningText, 'Unavailable conversion warning is not visible');
assert(source.includes("if (!donation || !entry || entry.eliminated || !canCreditDonationAmount(donation)) return false;"), 'assignDonationToEntry does not block unavailable amounts');
assert(source.includes('if (!canCreditDonationAmount(donation)) return false;\n      const entry = createEntryFromAiCandidate'), 'AI create-and-assign can create a lot before rejecting unavailable amount');
assert(source.includes("donation.conversionSource = 'manual';") && source.includes("donation.conversionStatus = 'converted';"), 'Manual RUB conversion flow is missing');

const donationAssignmentStart = source.indexOf('    function moveDonationToAdded');
const donationAssignmentEnd = source.indexOf('    function ignoreDonation', donationAssignmentStart);
if (donationAssignmentStart < 0 || donationAssignmentEnd < 0) throw new Error('Donation assignment transition helpers not found');
const donationAssignmentHarness = new Function(`
  let donationsPending = [{ id: 'pending-1', source: 'donatepay', externalId: 'pending-1', status: 'pending', amount: 25 }];
  let donationsAdded = [
    { id: 'ignored-1', source: 'donatepay', externalId: 'ignored-1', status: 'ignored', amount: 50 },
    { id: 'added-1', source: 'donatepay', externalId: 'added-1', status: 'added', amount: 10 }
  ];
  let activeDonationAssignmentId = 'ignored-1';
  const entries = [{ id: 'lot-1', name: 'Lot 1', price: 100, eliminated: false }];
  function removeDonationAiJob() {}
  function canMutateAuctionState() { return true; }
  function getEntryById(id) { return entries.find(entry => entry.id === id) || null; }
  function canCreditDonationAmount(donation) { return Number(donation?.amount) > 0; }
  function addAmountToEntryById(id, amount) {
    const entry = getEntryById(id);
    if (!entry) return false;
    entry.price += Number(amount);
    return true;
  }
  function saveData() {}
  function renderList() {}
  function renderDonationsPanel() {}
  function drawWheel() {}
  ${source.slice(donationAssignmentStart, donationAssignmentEnd)}
  return {
    assignDonationToEntry,
    findAssignableDonationById,
    getState: () => ({ donationsPending, donationsAdded, activeDonationAssignmentId, entries })
  };
`)();
assert(donationAssignmentHarness.findAssignableDonationById('pending-1')?.status === 'pending', 'Pending donation is no longer assignable');
assert(donationAssignmentHarness.findAssignableDonationById('ignored-1')?.status === 'ignored', 'Ignored donation cannot be selected for assignment');
assert(!donationAssignmentHarness.findAssignableDonationById('added-1'), 'Already credited donation can be assigned twice');
assert(donationAssignmentHarness.assignDonationToEntry('ignored-1', 'lot-1'), 'Ignored donation could not be assigned to a lot');
const ignoredAssignmentState = donationAssignmentHarness.getState();
assert(ignoredAssignmentState.entries[0].price === 150, 'Ignored donation amount was not credited exactly once');
assert(ignoredAssignmentState.donationsAdded[0].id === 'ignored-1' && ignoredAssignmentState.donationsAdded[0].status === 'added', 'Assigned ignored donation did not become added');
assert(ignoredAssignmentState.donationsAdded.filter(item => item.id === 'ignored-1').length === 1, 'Assigned ignored donation was duplicated in history');

const assignmentSelectionStart = source.indexOf('    function startDonationAssignment');
const assignmentSelectionEnd = source.indexOf('    function applyManualDonationRubAmount', assignmentSelectionStart);
if (assignmentSelectionStart < 0 || assignmentSelectionEnd < 0) throw new Error('Donation assignment selection helper not found');
const assignmentSelectionHarness = new Function('findAssignableDonationById', `
  let activeDonationAssignmentId = null;
  const entries = [{ id: 'lot-1', eliminated: false }];
  function canRunAdminLeaderActions() { return true; }
  function canCreditDonationAmount() { return true; }
  function renderList() {}
  function renderDonationsPanel() {}
  function alert() {}
  ${source.slice(assignmentSelectionStart, assignmentSelectionEnd)}
  return {
    select: startDonationAssignment,
    current: () => activeDonationAssignmentId
  };
`)(id => ({ id, status: id.startsWith('ignored') ? 'ignored' : 'pending', amount: 1 }));
assignmentSelectionHarness.select('pending-1');
assert(assignmentSelectionHarness.current() === 'pending-1', 'Pending donation did not enter assignment mode');
assignmentSelectionHarness.select('ignored-1');
assert(assignmentSelectionHarness.current() === 'ignored-1', 'Selecting an ignored donation did not replace the previous pending selection');

const addedSortStart = source.indexOf('    function sortProcessedDonationsByTime');
const addedSortEnd = source.indexOf('    function renderAddedDonations', addedSortStart);
if (addedSortStart < 0 || addedSortEnd < 0) throw new Error('Processed donation sorting helpers not found');
const { sortProcessedDonationsByTime, sortIgnoredDonationsByDonor } = new Function('getDonationCreatedAtMs', `${source.slice(addedSortStart, addedSortEnd)}; return { sortProcessedDonationsByTime, sortIgnoredDonationsByDonor };`)(
  donation => Date.parse(donation.createdAt) || 0
);
const processedDonations = [
  { id: 'ignored-zed', username: 'Zed', status: 'ignored', createdAt: '2026-07-20T10:00:00Z' },
  { id: 'added-new', username: 'Added', status: 'added', createdAt: '2026-07-20T12:00:00Z' },
  { id: 'ignored-anna-2', username: 'Анна 2', status: 'ignored', createdAt: '2026-07-20T11:00:00Z' },
  { id: 'ignored-anna-10', username: 'анна 10', status: 'ignored', createdAt: '2026-07-20T09:00:00Z' }
];
assert(sortProcessedDonationsByTime(processedDonations).map(item => item.id).join(',') === 'added-new,ignored-anna-2,ignored-zed,ignored-anna-10', 'Processed donation time order is not newest-first');
assert(sortIgnoredDonationsByDonor(processedDonations.filter(item => item.status === 'ignored')).map(item => item.id).join(',') === 'ignored-anna-2,ignored-anna-10,ignored-zed', 'Ignored donations are not sorted by donor nickname');
const pendingTabIndex = source.indexOf('data-donations-tab="pending">В ожидании</button>');
const ignoredTabIndex = source.indexOf('data-donations-tab="ignored">Игнорировано</button>');
const addedTabIndex = source.indexOf('data-donations-tab="added">Добавлено</button>');
assert(pendingTabIndex >= 0 && pendingTabIndex < ignoredTabIndex && ignoredTabIndex < addedTabIndex, 'Donation tabs are missing or ordered incorrectly');
assert(!source.includes('added-donations-sort') && !source.includes('data-donations-sort'), 'Removed donation sorting switch is still present');
assert(source.includes('function renderIgnoredDonations()') && source.includes('createDonationCard(donation, { assignable: true })'), 'Ignored donation tab has no lot-selection action');

const entries = [
  { id: 'base', name: 'Granny', eliminated: false, source: '', externalId: '', category: '' },
  { id: 'exact', name: 'Granny 3', eliminated: false, source: 'steam', externalId: '123456', category: 'game' }
];
const helpers = loadHelpers(entries);
assert(helpers.compareAiLotTitles('The Witcher 3', 'Witcher 3').exact, 'Safe article match failed');
assert(helpers.compareAiLotTitles('Алёша Попович и Тугарин Змей', 'алеша попович и тугарин змей').exact, 'Frontend title comparison does not treat е and ё as equivalent.');
assert(helpers.compareAiLotTitles('Granny 3', 'Granny').hasVariantConflict, 'Part-number conflict was not detected');
assert(helpers.findExistingEntryForAiCandidate({ title: 'Granny 3' }).id === 'exact', 'Exact candidate match failed');

const onlyBase = loadHelpers([{ id: 'base', name: 'Granny', eliminated: false, source: '', externalId: '' }]);
assert(!onlyBase.findExistingEntryForAiCandidate({ title: 'Granny 3' }), 'Granny 3 incorrectly matched Granny');
for (const [left, right] of [['Portal', 'Postal'], ['Inside', 'Insider'], ['Control', 'Controls'], ['Naruto Shippuden', 'Naruto'], ['The Witcher 3', 'The Witcher']]) {
  const pair = loadHelpers([{ id: 'candidate', name: right, eliminated: false, source: '', externalId: '', category: '' }]);
  assert(!pair.findExistingEntryForAiCandidate({ title: left }), `${left} incorrectly matched ${right}`);
}

const categoryHelpers = loadHelpers([{ id: 'anime', name: 'Naruto', eliminated: false, source: 'anilist', externalId: '1', category: 'anime' }]);
assert(!categoryHelpers.findExistingEntryForAiCandidate({ title: 'Naruto' }, 'game'), 'Game Naruto incorrectly matched anime Naruto');
assert(categoryHelpers.findExistingEntryForAiCandidate({ title: 'Naruto' }, 'anime').id === 'anime', 'Same-category Naruto exact match failed');
const legacyCategoryHelpers = loadHelpers([{ id: 'legacy', name: 'Naruto', eliminated: false, source: '', externalId: '', category: '' }]);
assert(legacyCategoryHelpers.findExistingEntryForAiCandidate({ title: 'Naruto' }, 'game').id === 'legacy', 'Legacy empty category should remain compatible');
const externalCategoryHelpers = loadHelpers([{ id: 'external', name: 'Other title', eliminated: false, source: 'steam', externalId: '42', category: 'anime' }]);
assert(externalCategoryHelpers.findExistingEntryForAiCandidate({ title: 'Naruto', source: 'steam', externalId: '42' }, 'game').id === 'external', 'Exact external identity lost priority');

for (const value of ['I', 'II', 'III', 'IV', 'V', 'VI', 'IX', 'X', 'XII', 'XIV', 'XIX', 'XX']) {
  assert(helpers.isValidAiRomanNumeral(value), `${value} should be a valid Roman part numeral`);
}
for (const value of ['civil', 'dmc', 'mix', 'IIII', 'VX', 'IC']) {
  assert(!helpers.isValidAiRomanNumeral(value), `${value} must not be treated as a Roman part numeral`);
}

const entry = { id: 'entry-1', name: 'Granny 3', eliminated: false, source: '', externalId: '' };
const fingerprintHelpers = loadHelpers([entry]);
const fingerprint = fingerprintHelpers.getCurrentEntryFingerprint(entry);
assert(fingerprintHelpers.doesEntryMatchAiFingerprint(entry, fingerprint), 'Initial fingerprint mismatch');
entry.name = 'Resident Evil';
assert(!fingerprintHelpers.doesEntryMatchAiFingerprint(entry, fingerprint), 'Manual fingerprint accepted renamed entry');
assert(!fingerprintHelpers.doesEntryMatchAiFingerprint(entry, fingerprint, { auto: true }), 'Auto fingerprint accepted renamed entry without external identity');

const externalEntry = { id: 'entry-2', name: 'Old title', eliminated: false, source: 'steam', externalId: '42' };
const externalHelpers = loadHelpers([externalEntry]);
const externalFingerprint = externalHelpers.getCurrentEntryFingerprint(externalEntry);
externalEntry.name = 'Edited title';
assert(!externalHelpers.doesEntryMatchAiFingerprint(externalEntry, externalFingerprint), 'Manual fingerprint ignored a rename');
assert(externalHelpers.doesEntryMatchAiFingerprint(externalEntry, externalFingerprint, { auto: true }), 'Auto fingerprint lost stable source identity');

const leaderStart = source.indexOf('    function normalizeAdminLeaseValue');
const leaderEnd = source.indexOf('    function setupStateSync', leaderStart);
if (leaderStart < 0 || leaderEnd < 0) throw new Error('Admin leader helper block not found');
const leaderHelpers = new Function(
  'clampTimerMs',
  'TIMER_MAX_MS',
  'MAX_CENTER_IMAGE_DATA_URL_LENGTH',
  'SHARED_CONTROL_REQUEST_TYPE',
  `${source.slice(leaderStart, leaderEnd)}
  return {
    normalizeAdminLeaseValue,
    isAdminLeaseActive,
    canAdminTabAcquireLease,
    doesAdminLeaseBelongToTab,
    isMessageFromCurrentAdminLeader,
    canAdminTabRunLeaderAction,
    isAuctionMutationBlocked,
    canSubmitAiJobForGeneration,
    shouldResyncAuctionGeneration,
    createAuctionGenerationResyncSnapshot,
    shouldResetBrowserForServerEpoch,
    shouldResumeCollectorPreserveCursor,
    reduceAuctionClearState,
    reduceAuctionResyncState,
    isAdminOperationClaimAuthoritative,
    canOAuthCallbackPersistSharedState,
    shouldReverifyAdminLeaseAfterPageShow,
    normalizeSpinDurationSec,
    normalizeCenterImageSource,
    normalizeAuthoritativeTimerState,
    normalizeSharedControlChange,
    normalizeSharedControlRequest,
    canHandleSharedControlRequest,
    reduceSharedControlSnapshot
  };
`)(
  value => Math.min(59 * 3600000 + 59 * 60000 + 59 * 1000, Math.max(0, Math.round(Number(value) || 0))),
  59 * 3600000 + 59 * 60000 + 59 * 1000,
  3 * 1024 * 1024,
  'SHARED_CONTROL_REQUEST'
);
const now = Date.now();
const leaseA = leaderHelpers.normalizeAdminLeaseValue({ ownerTabId: 'A', claimId: 'claim-a', heartbeatAt: now, expiresAt: now + 7000, auctionGeneration: 2 });
assert(!leaderHelpers.canAdminTabAcquireLease(leaseA, 'B', now), 'Second tab acquired an active lease');
assert(leaderHelpers.doesAdminLeaseBelongToTab(leaseA, 'A', 'claim-a'), 'Leader failed to verify its own lease');
assert(!leaderHelpers.doesAdminLeaseBelongToTab({ ...leaseA, ownerTabId: 'B' }, 'A', 'claim-a'), 'Old leader accepted a new owner');
assert(leaderHelpers.isMessageFromCurrentAdminLeader({ leaderTabId: 'A', tabInstanceId: '' }, leaseA) === false, 'Leader operation message without an instance id was accepted');
const leaseWithInstance = leaderHelpers.normalizeAdminLeaseValue({ ...leaseA, ownerInstanceId: 'instance-a' });
assert(leaderHelpers.isMessageFromCurrentAdminLeader({ leaderTabId: 'A', tabInstanceId: 'instance-a' }, leaseWithInstance), 'Current leader operation message was rejected');
assert(!leaderHelpers.isMessageFromCurrentAdminLeader({ leaderTabId: 'A', tabInstanceId: 'instance-old' }, leaseWithInstance), 'Delayed former-leader operation message was accepted');
assert(leaderHelpers.canAdminTabAcquireLease(leaseA, 'B', now + 7001), 'Follower could not take over an expired lease');
const duplicatedTabLease = leaderHelpers.normalizeAdminLeaseValue({ ownerTabId: 'A', ownerInstanceId: 'instance-a', claimId: 'claim-a', heartbeatAt: now, expiresAt: now + 7000, auctionGeneration: 2 });
assert(!leaderHelpers.canAdminTabAcquireLease(duplicatedTabLease, 'A', now, 'instance-b'), 'Duplicated tab with cloned session tabId acquired an active lease');
assert(!leaderHelpers.doesAdminLeaseBelongToTab(duplicatedTabLease, 'A', 'claim-a', 'instance-b'), 'Duplicated tab instance accepted another instance lease');
assert(leaderHelpers.canAdminTabRunLeaderAction('admin', true), 'Admin leader action was rejected');
assert(!leaderHelpers.canAdminTabRunLeaderAction('admin', false), 'Follower was allowed to run a leader-only action');
assert(!leaderHelpers.canAdminTabRunLeaderAction('wheel', true), 'Wheel view was allowed to run admin work');

const sharedNow = 1_000_000;
const sharedTimerInitial = leaderHelpers.normalizeAuthoritativeTimerState({
  remainingMs: 120000,
  isRunning: false,
  endsAtMs: 0,
  rememberedMs: 120000
}, sharedNow);
const sharedInitial = {
  spinDurationSec: 10,
  centerImageUrl: 'https://example.com/old.webp',
  timerState: sharedTimerInitial
};
const wheelDurationRequest = {
  type: 'SHARED_CONTROL_REQUEST',
  sourceViewMode: 'wheel',
  requestId: 'wheel-duration-1',
  kind: 'spinDurationSec',
  value: 17,
  entries: [{ id: 'forbidden' }],
  donationsPending: [{ id: 'forbidden' }],
  lastSpinResult: { winnerId: 'forbidden' }
};
assert(
  leaderHelpers.canHandleSharedControlRequest('admin', true, wheelDurationRequest),
  'Admin leader rejected an allowed wheel shared-control request'
);
assert(
  !leaderHelpers.canHandleSharedControlRequest('admin', false, wheelDurationRequest)
    && !leaderHelpers.canHandleSharedControlRequest('wheel', true, wheelDurationRequest),
  'Shared-control request bypassed the admin leader boundary'
);
const normalizedWheelDurationRequest = leaderHelpers.normalizeSharedControlRequest(wheelDurationRequest, sharedNow);
const adminAfterWheelDuration = leaderHelpers.reduceSharedControlSnapshot(
  sharedInitial,
  normalizedWheelDurationRequest.change
);
assert(adminAfterWheelDuration.spinDurationSec === 17, 'Wheel duration was not applied to admin state');
const wheelReloadedDuration = JSON.parse(JSON.stringify(adminAfterWheelDuration));
assert(wheelReloadedDuration.spinDurationSec === 17, 'Wheel duration was not preserved across reload');
assert(
  !Object.prototype.hasOwnProperty.call(normalizedWheelDurationRequest, 'entries')
    && !Object.prototype.hasOwnProperty.call(normalizedWheelDurationRequest, 'donationsPending')
    && !Object.prototype.hasOwnProperty.call(normalizedWheelDurationRequest, 'lastSpinResult'),
  'Shared-control request retained forbidden auction fields'
);
assert(
  leaderHelpers.normalizeSharedControlRequest({
    ...wheelDurationRequest,
    requestId: 'forbidden-lots',
    kind: 'entries',
    value: [{ id: 'lot' }]
  }, sharedNow) === null,
  'Wheel shared-control protocol accepted a lot mutation'
);
const adminDurationChange = leaderHelpers.normalizeSharedControlChange('spinDurationSec', 24, sharedNow);
const wheelAfterAdminDuration = leaderHelpers.reduceSharedControlSnapshot(
  adminAfterWheelDuration,
  adminDurationChange
);
assert(wheelAfterAdminDuration.spinDurationSec === 24, 'Admin duration was not applied to wheel state');

const timerStartRequest = leaderHelpers.normalizeSharedControlRequest({
  type: 'SHARED_CONTROL_REQUEST',
  sourceViewMode: 'wheel',
  requestId: 'timer-start',
  kind: 'timerState',
  value: {
    ...sharedTimerInitial,
    isRunning: true,
    endsAtMs: sharedNow + 120000
  }
}, sharedNow);
const adminTimerRunning = leaderHelpers.reduceSharedControlSnapshot(sharedInitial, timerStartRequest.change);
const reloadedRunningTimer = leaderHelpers.normalizeAuthoritativeTimerState(
  adminTimerRunning.timerState,
  sharedNow + 30000
);
assert(
  reloadedRunningTimer.isRunning && reloadedRunningTimer.remainingMs === 90000,
  'Running timer did not restore from the shared absolute endsAtMs'
);
const timerPauseRequest = leaderHelpers.normalizeSharedControlRequest({
  type: 'SHARED_CONTROL_REQUEST',
  sourceViewMode: 'wheel',
  requestId: 'timer-pause',
  kind: 'timerState',
  value: {
    ...reloadedRunningTimer,
    isRunning: false,
    endsAtMs: 0
  }
}, sharedNow + 30000);
const adminTimerPaused = leaderHelpers.reduceSharedControlSnapshot(adminTimerRunning, timerPauseRequest.change);
assert(
  !adminTimerPaused.timerState.isRunning
    && adminTimerPaused.timerState.remainingMs === 90000
    && adminTimerPaused.timerState.endsAtMs === 0,
  'Timer pause was not synchronized'
);
const timerContinueRequest = leaderHelpers.normalizeSharedControlRequest({
  type: 'SHARED_CONTROL_REQUEST',
  sourceViewMode: 'wheel',
  requestId: 'timer-continue',
  kind: 'timerState',
  value: {
    ...adminTimerPaused.timerState,
    isRunning: true,
    endsAtMs: sharedNow + 130000
  }
}, sharedNow + 40000);
const adminTimerContinued = leaderHelpers.reduceSharedControlSnapshot(adminTimerPaused, timerContinueRequest.change);
const reloadedContinuedTimer = leaderHelpers.normalizeAuthoritativeTimerState(
  adminTimerContinued.timerState,
  sharedNow + 70000
);
assert(
  reloadedContinuedTimer.isRunning && reloadedContinuedTimer.remainingMs === 60000,
  'Continued timer diverged after reload'
);
const timerResetRequest = leaderHelpers.normalizeSharedControlRequest({
  type: 'SHARED_CONTROL_REQUEST',
  sourceViewMode: 'wheel',
  requestId: 'timer-reset',
  kind: 'timerState',
  value: {
    remainingMs: reloadedContinuedTimer.rememberedMs,
    rememberedMs: reloadedContinuedTimer.rememberedMs,
    isRunning: false,
    endsAtMs: 0
  }
}, sharedNow + 70000);
const adminTimerReset = leaderHelpers.reduceSharedControlSnapshot(adminTimerContinued, timerResetRequest.change);
assert(
  !adminTimerReset.timerState.isRunning
    && adminTimerReset.timerState.remainingMs === 120000,
  'Timer reset was not synchronized to the configured time'
);

const standardCenterImage = leaderHelpers.normalizeSharedControlRequest({
  type: 'SHARED_CONTROL_REQUEST',
  sourceViewMode: 'wheel',
  requestId: 'center-standard',
  kind: 'centerImageUrl',
  value: 'https://cdn.example.com/center.webp'
}, sharedNow);
const adminAfterStandardImage = leaderHelpers.reduceSharedControlSnapshot(sharedInitial, standardCenterImage.change);
assert(
  adminAfterStandardImage.centerImageUrl === 'https://cdn.example.com/center.webp',
  'Wheel standard center image was not applied to admin state'
);
const uploadedCenterDataUrl = 'data:image/png;base64,iVBORw0KGgo=';
const uploadedCenterImage = leaderHelpers.normalizeSharedControlRequest({
  type: 'SHARED_CONTROL_REQUEST',
  sourceViewMode: 'wheel',
  requestId: 'center-upload',
  kind: 'centerImageUrl',
  value: uploadedCenterDataUrl
}, sharedNow);
const persistedUploadedImage = JSON.parse(JSON.stringify(
  leaderHelpers.reduceSharedControlSnapshot(adminAfterStandardImage, uploadedCenterImage.change)
));
assert(
  persistedUploadedImage.centerImageUrl === uploadedCenterDataUrl,
  'Uploaded center image was not preserved as a reload-safe Data URL'
);
assert(
  leaderHelpers.normalizeCenterImageSource('blob:http://127.0.0.1/stale') === '',
  'Tab-local blob center image URL was accepted for shared state'
);

const confirmedWheelState = leaderHelpers.reduceSharedControlSnapshot(sharedInitial, normalizedWheelDurationRequest.change);
const afterLaterTimerConfirmation = leaderHelpers.reduceSharedControlSnapshot(confirmedWheelState, timerPauseRequest.change);
assert(
  afterLaterTimerConfirmation.spinDurationSec === 17,
  'A later admin save restored stale shared controls over a confirmed wheel change'
);
const sharedControlHandlerSource = source.slice(
  source.indexOf('    function confirmSharedControlChange'),
  source.indexOf('    function normalizeBootstrapRole')
);
assert(
  sharedControlHandlerSource.indexOf('applySharedControlChange(change)')
    < sharedControlHandlerSource.indexOf('return saveData() !== false;'),
  'Admin leader saves shared-control requests before applying them to authoritative state'
);
assert(
  source.includes('reader.readAsDataURL(file);') && !source.includes('URL.createObjectURL(file)'),
  'Uploaded center image is not converted to persistent shared data'
);

assert(leaderHelpers.isAuctionMutationBlocked({ isSpinning: true }), 'Local admin spin did not block auction mutation');
assert(leaderHelpers.isAuctionMutationBlocked({ isDelaying: true }), 'Local shrink animation did not block auction mutation');
assert(leaderHelpers.isAuctionMutationBlocked({ pendingSpinOperation: { spinRequestId: 'remote-spin' } }), 'Pending authoritative spin did not block auction mutation');
assert(leaderHelpers.isAuctionMutationBlocked({ donationCollectionPauseChangeInFlight: true }), 'Collector pause transition did not block concurrent auction operations');
assert(leaderHelpers.isAuctionMutationBlocked({ collectorPauseReconcileInFlight: true }), 'Collector pause reconciliation did not block concurrent auction operations');
assert(!leaderHelpers.isAuctionMutationBlocked({}), 'Idle auction was incorrectly mutation-blocked');
assert(leaderHelpers.canSubmitAiJobForGeneration(2, 2, false), 'Current generation AI job was rejected');
assert(!leaderHelpers.canSubmitAiJobForGeneration(1, 2, false), 'Stale generation AI job was allowed');
assert(!leaderHelpers.canSubmitAiJobForGeneration(2, 2, true), 'Generation resync did not block AI submission');
assert(leaderHelpers.shouldResyncAuctionGeneration(3, 2), 'New server generation did not request resync');
assert(!leaderHelpers.shouldResyncAuctionGeneration(1, 2), 'Older in-flight server response requested a backwards resync');
const resyncSnapshot = leaderHelpers.createAuctionGenerationResyncSnapshot(3);
assert(resyncSnapshot.currentAuctionGeneration === 3 && resyncSnapshot.sharedStateAuctionGeneration === 3, 'Resync did not synchronize generation values');
assert(resyncSnapshot.entries.length === 0 && resyncSnapshot.donationsPending.length === 0 && resyncSnapshot.donationsAdded.length === 0, 'Resync snapshot retained stale auction data');
assert(leaderHelpers.shouldResetBrowserForServerEpoch('reset-new', 'reset-old', true), 'New reset epoch did not invalidate stored browser state');
assert(!leaderHelpers.shouldResetBrowserForServerEpoch('reset-new', '', false), 'Empty first-install state was incorrectly treated as stale after reset');
assert(leaderHelpers.shouldResumeCollectorPreserveCursor(
  { pausedPreserveCursor: true },
  { leader: true, userPaused: false, auctionOperationInFlight: false, resyncRequired: false, resetInFlight: false }
), 'New leader did not reconcile an orphaned preserve-cursor pause');
assert(!leaderHelpers.shouldResumeCollectorPreserveCursor(
  { pausedPreserveCursor: true },
  { leader: true, userPaused: true, auctionOperationInFlight: false, resyncRequired: false, resetInFlight: false }
), 'Collector resumed despite the user pause setting');
assert(!leaderHelpers.shouldResumeCollectorPreserveCursor(
  { pausedPreserveCursor: true },
  { leader: true, userPaused: false, auctionOperationInFlight: true, resyncRequired: false, resetInFlight: false }
), 'Collector resumed during an active auction operation');
assert(!leaderHelpers.shouldResumeCollectorPreserveCursor(
  { pausedPreserveCursor: true },
  { leader: true, userPaused: false, auctionOperationInFlight: false, resyncRequired: false, resetInFlight: false, pauseTransitionInFlight: true }
), 'Collector reconciliation cancelled an in-flight user pause transition');
assert(!leaderHelpers.shouldResumeCollectorPreserveCursor(
  { pausedPreserveCursor: true },
  { leader: true, userPaused: false, auctionOperationInFlight: false, resyncRequired: false, resetInFlight: false, spinOperationInFlight: true }
), 'Collector reconciliation cancelled an in-flight stop-and-spin transition');
let clearState = leaderHelpers.reduceAuctionClearState({ inFlight: false, operationId: '' }, { type: 'AUCTION_CLEARING', clearOperationId: 'clear-new' });
assert(clearState.inFlight && clearState.operationId === 'clear-new', 'Auction clear did not enter in-flight state');
clearState = leaderHelpers.reduceAuctionClearState(clearState, { type: 'AUCTION_CLEAR_FAILED', clearOperationId: 'clear-old' });
assert(clearState.inFlight && clearState.operationId === 'clear-new', 'Old clear failure completed a newer operation');
clearState = leaderHelpers.reduceAuctionClearState(clearState, { type: 'AUCTION_CLEAR_FAILED', clearOperationId: 'clear-new' });
assert(!clearState.inFlight && !clearState.operationId, 'Matching clear failure did not unfreeze followers');
let resyncState = leaderHelpers.reduceAuctionResyncState(
  { clearInFlight: true, clearOperationId: 'clear-new', resyncOperationId: '', generation: 3 },
  { type: 'AUCTION_RESYNCED', operationId: 'resync-old', clearOperationId: 'clear-old', auctionGeneration: 4 }
);
assert(!resyncState.accepted && resyncState.clearOperationId === 'clear-new', 'Stale resync completed a newer clear operation');
resyncState = leaderHelpers.reduceAuctionResyncState(
  { clearInFlight: true, clearOperationId: 'clear-new', resyncOperationId: '', generation: 3 },
  { type: 'AUCTION_RESYNCED', operationId: 'resync-new', clearOperationId: 'clear-new', auctionGeneration: 4 }
);
assert(resyncState.accepted && !resyncState.clearInFlight && !resyncState.clearOperationId, 'Related authoritative resync did not finish its clear operation');
const operationClaim = { ownerTabId: 'A', leaderClaimId: 'claim-a', operationId: 'op', generation: 2 };
assert(leaderHelpers.isAdminOperationClaimAuthoritative(operationClaim, leaseA, 'A', 'claim-a', 'admin', true), 'Current leader operation claim was rejected');
assert(!leaderHelpers.isAdminOperationClaimAuthoritative(operationClaim, { ...leaseA, ownerTabId: 'B' }, 'A', 'claim-a', 'admin', true), 'Operation remained authoritative after lease loss');
assert(!leaderHelpers.canOAuthCallbackPersistSharedState('admin', false), 'Follower OAuth callback may write shared state');
assert(leaderHelpers.canOAuthCallbackPersistSharedState('admin', true), 'Leader OAuth callback may not write shared state');
assert(leaderHelpers.shouldReverifyAdminLeaseAfterPageShow({ persisted: true }), 'BFCache restore did not require lease verification');
assert(!leaderHelpers.shouldReverifyAdminLeaseAfterPageShow({ persisted: false }), 'Normal pageshow incorrectly forced BFCache recovery');
const mismatchStart = source.indexOf("error?.status === 409 && error?.proxyPayload?.code === 'AUCTION_GENERATION_MISMATCH'");
const mismatchEnd = source.indexOf('const current = getPendingDonationById(donationId);', mismatchStart);
const generationMismatchBranch = source.slice(mismatchStart, mismatchEnd);
assert(mismatchStart >= 0 && generationMismatchBranch.includes('await resyncAuctionGeneration'), 'HTTP 409 generation mismatch does not start resync');
assert(!generationMismatchBranch.includes("status: 'skipped'"), 'HTTP 409 permanently skipped a stale donation instead of resyncing');

const tabIdStart = source.indexOf('    function getOrCreateAdminTabId');
const tabIdEnd = source.indexOf('    function normalizeAdminLeaseValue', tabIdStart);
const tabIdHelpers = new Function('cryptoRandomUint32', 'ADMIN_TAB_ID_KEY', `${source.slice(tabIdStart, tabIdEnd)}; return { getOrCreateAdminTabId };`)(() => 1, 'pointauc_admin_tab_id');
const fakeSessionStorage = {
  value: 'admin-123-abc',
  getItem() { return this.value; },
  setItem(key, value) { this.value = value; }
};
assert(tabIdHelpers.getOrCreateAdminTabId(fakeSessionStorage) === 'admin-123-abc', 'Stable tabId was not restored from sessionStorage');
const oauthFollowerStart = source.indexOf('if (!canOAuthCallbackPersistSharedState(appViewMode, isAdminLeader))');
const oauthFollowerEnd = source.indexOf('const operationClaim = createAdminOperationClaim', oauthFollowerStart);
const oauthFollowerBranch = source.slice(oauthFollowerStart, oauthFollowerEnd);
assert(oauthFollowerBranch.includes("postAppChannelMessage('DONATIONALERTS_OAUTH_COMPLETED'"), 'Follower OAuth callback did not notify the leader');
assert(!oauthFollowerBranch.includes('accessToken'), 'Follower OAuth BroadcastChannel message exposes the token');
assert(!oauthFollowerBranch.includes('saveData()'), 'Follower OAuth callback writes shared state');
const oauthCallbackBlock = source.slice(source.indexOf('async function handleDonationAlertsOAuthCallback'), source.indexOf('async function finishDonationAlertsConnection'));
assert(!oauthCallbackBlock.includes('appViewMode = getAppViewMode()'), 'OAuth callback still changes view mode after leader election');

const donatePayStart = source.indexOf('    function markDonatePayDonationAccepted');
const donatePayEnd = source.indexOf('    function parseDonationDateMs', donatePayStart);
if (donatePayStart < 0 || donatePayEnd < 0) throw new Error('DonatePay acceptance helper block not found');
const seenDonationKeys = new Set();
const donationIntegrations = { donatepay: { lastSeenId: 10, lastSeenCreatedAt: '' } };
const pending = [];
const added = [];
const donatePayHelpers = new Function(
  'seenDonationKeys', 'donationIntegrations', 'donationsPending', 'donationsAdded', 'getDonationKey', 'getNumericDonationId', 'isDonationKnown',
  `${source.slice(donatePayStart, donatePayEnd)}
   return { shouldAcceptDonatePayDonation, markDonatePayDonationAccepted };`
)(
  seenDonationKeys,
  donationIntegrations,
  pending,
  added,
  (sourceName, externalId) => `${String(sourceName || '')}:${String(externalId || '')}`,
  externalId => Number(String(externalId || '').replace(/\D/g, '')) || 0,
  (sourceName, externalId) => pending.concat(added).some(item => item.source === sourceName && String(item.externalId) === String(externalId))
);
const duringClearDonation = { source: 'donatepay', externalId: '11', createdAt: '2026-07-13T00:00:00Z' };
assert(donatePayHelpers.shouldAcceptDonatePayDonation(duringClearDonation), 'New DonatePay event should be eligible before clear gate');
assert(!seenDonationKeys.has('donatepay:11'), 'DonatePay event was marked seen before pending accepted it');
assert(donationIntegrations.donatepay.lastSeenId === 10, 'DonatePay cursor advanced before pending accepted the event');
donatePayHelpers.markDonatePayDonationAccepted(duringClearDonation);
assert(seenDonationKeys.has('donatepay:11'), 'Accepted DonatePay event was not marked seen');
assert(donationIntegrations.donatepay.lastSeenId === 11, 'Accepted DonatePay event did not advance cursor');

const ackStart = source.indexOf('    function classifyServerDonationForAck');
const ackEnd = source.indexOf('    async function pollServerCollectorDonations', ackStart);
if (ackStart < 0 || ackEnd < 0) throw new Error('Server donation ack helper not found');
const { classifyServerDonationForAck } = new Function(`${source.slice(ackStart, ackEnd)}; return { classifyServerDonationForAck };`)();
const invalidAck = classifyServerDonationForAck({ id: 'server-invalid', source: '', externalId: '', amount: 0 }, false);
assert(!invalidAck.valid && invalidAck.ackImmediately && invalidAck.serverId === 'server-invalid', 'Invalid server donation was not scheduled for ack');
const unavailableAck = classifyServerDonationForAck({
  id: 'server-da-unavailable', source: 'donationalerts', externalId: 'da-unavailable', amount: 0,
  originalAmount: 50, originalCurrency: 'EUR', conversionStatus: 'unavailable'
}, false);
assert(unavailableAck.valid && !unavailableAck.ackImmediately, 'Unavailable DonationAlerts donation cannot enter pending exactly once');

const spinStart = source.indexOf('    function registerSpinRequest');
const spinEnd = source.indexOf('    function buildAuthoritativeSpinDescriptor', spinStart);
if (spinStart < 0 || spinEnd < 0) throw new Error('Spin request helper block not found');
const spinHelpers = new Function('cryptoRandomUint32', `${source.slice(spinStart, spinEnd)}; return {
  registerSpinRequest,
  createWheelSpinRequest,
  normalizeSpinCollectionAction,
  normalizeRecentSpinResults,
  findPersistedSpinRequestState
};`)(() => 1);
const spinRegistry = new Map();
const wheelEntries = [{ id: 'one', eliminated: false }, { id: 'two', eliminated: false }];
const beforeWheelEntries = JSON.stringify(wheelEntries);
const spinRequest = spinHelpers.createWheelSpinRequest('wheel-tab', 3, 1000);
assert(spinRequest.collectionAction === 'require_stopped', 'Wheel request did not require authoritative collection-state confirmation by default');
assert(spinHelpers.createWheelSpinRequest('wheel-tab', 3, 1000, 'stop_and_spin').collectionAction === 'stop_and_spin', 'Wheel stop-and-spin decision was lost');
assert(spinHelpers.normalizeSpinCollectionAction('spin_without_stopping') === 'require_stopped', 'Removed continue-without-stopping action is still accepted');
const firstSpinRegistration = spinHelpers.registerSpinRequest(spinRegistry, spinRequest, 3);
assert(firstSpinRegistration.accepted && firstSpinRegistration.value.status === 'processing', 'Current-generation wheel spin request was not reserved before async work');
const duplicateSpinRegistration = spinHelpers.registerSpinRequest(spinRegistry, spinRequest, 3);
assert(duplicateSpinRegistration.duplicate && duplicateSpinRegistration.value.status === 'processing', 'Duplicate spinRequestId was not attached to the original processing request');
assert(!spinHelpers.registerSpinRequest(new Map(), { ...spinRequest, spinRequestId: 'stale', auctionGeneration: 2 }, 3).accepted, 'Stale-generation spin request was accepted');
assert(JSON.stringify(wheelEntries) === beforeWheelEntries, 'Wheel request helper mutated auction entries');
const storedResults = spinHelpers.normalizeRecentSpinResults([
  { spinRequestId: 'spin-2', generation: 3 },
  { spinRequestId: 'spin-1', generation: 3 },
  { spinRequestId: 'spin-2', generation: 3 },
  { spinRequestId: 'old-generation', generation: 2 }
], 3, 10);
assert(storedResults.length === 2 && storedResults[0].spinRequestId === 'spin-2', 'Persisted spin idempotency history was not deduplicated by generation');
const persistedSpin = spinHelpers.findPersistedSpinRequestState({
  recentSpinResults: [{ spinRequestId: 'spin-result', generation: 3, victimId: 'one' }],
  pendingSpinOperation: { spinRequestId: 'spin-pending', generation: 3 }
}, 'spin-result', 3);
assert(persistedSpin.result?.victimId === 'one', 'Wheel timeout recovery could not find a persisted result');
assert(!spinHelpers.findPersistedSpinRequestState({ recentSpinResults: storedResults }, 'spin-2', 4).result, 'Wheel timeout recovery accepted a stale-generation result');
const allAuctionSpinResults = spinHelpers.normalizeRecentSpinResults(
  Array.from({ length: 20 }, (_, index) => ({ spinRequestId: `spin-history-${index}`, generation: 3 })),
  3
);
assert(allAuctionSpinResults.length === 20, 'Spin idempotency history was truncated inside the current auction');

const wheelAnimationStart = source.indexOf('    function shouldStartWheelSpinAnimation');
const wheelAnimationEnd = source.indexOf('    function cancelWheelSpinAnimation', wheelAnimationStart);
if (wheelAnimationStart < 0 || wheelAnimationEnd < 0) throw new Error('Wheel animation idempotency helper not found');
let wheelTargetCalculationCount = 0;
const wheelAnimationHelpers = new Function(
  'normalizeWheelAngleRad',
  'calculateReversePlTargetProbabilityState',
  `${source.slice(wheelAnimationStart, wheelAnimationEnd)}; return {
    shouldStartWheelSpinAnimation,
    createWheelSpinAcceptedVisualState,
    prepareWheelSpinRemovalState,
    canRequestWheelSpin
  };`
)(
  angle => {
    const numeric = Number(angle) || 0;
    const twoPi = Math.PI * 2;
    return ((numeric % twoPi) + twoPi) % twoPi;
  },
  (entries, victim) => {
    wheelTargetCalculationCount += 1;
    return {
      signature: `target:${victim.id}`,
      dropoutChances: new Map(entries.filter(entry => entry.id !== victim.id).map(entry => [entry.id, 1])),
      currentWinChances: new Map(),
      calculationMs: 1
    };
  }
);
const { shouldStartWheelSpinAnimation } = wheelAnimationHelpers;
assert(shouldStartWheelSpinAnimation('', 'spin-1'), 'First wheel animation was rejected');
assert(!shouldStartWheelSpinAnimation('spin-1', 'spin-1'), 'Duplicate SPIN_ACCEPTED restarted the same wheel animation');
assert(shouldStartWheelSpinAnimation('spin-1', 'spin-2'), 'A new spin ID could not replace the previous wheel animation');
const wheelAcceptedEntries = [
  { id: 'wheel-a', name: 'A', price: 1, eliminated: false },
  { id: 'wheel-b', name: 'B', price: 2, eliminated: false }
];
const wheelAcceptedProbabilityState = {
  signature: 'wheel-signature',
  dropoutChances: new Map([['wheel-a', 0.6], ['wheel-b', 0.4]]),
  currentWinChances: new Map([['wheel-a', 0.25], ['wheel-b', 0.75]]),
  calculationMs: 2
};
const wheelAcceptedVisualState = wheelAnimationHelpers.createWheelSpinAcceptedVisualState({
  spinRequestId: 'wheel-spin',
  spinId: 'wheel-operation',
  probabilityStateSignature: 'wheel-signature',
  finalAngle: Math.PI * 5
}, wheelAcceptedEntries, wheelAcceptedProbabilityState);
assert(
  wheelAcceptedVisualState?.spinRequestId === 'wheel-spin'
    && wheelAcceptedVisualState.operationId === 'wheel-operation'
    && wheelAcceptedVisualState.activeEntries.length === 2,
  'SPIN_ACCEPTED did not preserve the wheel operation and active entries'
);
wheelAcceptedEntries[0].name = 'changed-after-accept';
wheelAcceptedProbabilityState.dropoutChances.set('wheel-a', 0);
assert(
  wheelAcceptedVisualState.activeEntries[0].name === 'A'
    && wheelAcceptedVisualState.oldProbabilityState.dropoutChances.get('wheel-a') === 0.6,
  'SPIN_ACCEPTED visual snapshot still aliases mutable wheel state'
);
const wheelFinalRemovalState = wheelAnimationHelpers.prepareWheelSpinRemovalState(
  wheelAcceptedVisualState,
  {
    spinRequestId: 'wheel-spin',
    victimId: 'wheel-b',
    finalAngle: Math.PI,
    final: true
  }
);
assert(
  wheelFinalRemovalState?.victim.id === 'wheel-b'
    && wheelFinalRemovalState.isFinal
    && wheelFinalRemovalState.targetProbabilityState.signature === 'target:wheel-b',
  'Final two-participant wheel removal was not prepared from the accepted snapshot'
);
assert(wheelTargetCalculationCount === 1, 'Wheel target Reverse PL state was not calculated exactly once before animation');
wheelAcceptedVisualState.resultApplied = true;
assert(
  wheelAnimationHelpers.prepareWheelSpinRemovalState(
    wheelAcceptedVisualState,
    { spinRequestId: 'wheel-spin', victimId: 'wheel-b' }
  ) === null,
  'The same wheel result can be applied twice'
);
assert(
  wheelAnimationHelpers.canRequestWheelSpin('wheel', null, false, false)
    && !wheelAnimationHelpers.canRequestWheelSpin('wheel', null, false, true),
  'Wheel repeat-spin gate does not block the shrink phase'
);
const wheelResultStart = source.indexOf('    function applyWheelSpinResult');
const wheelResultEnd = source.indexOf('    function scheduleWheelSpinRequestTimeout', wheelResultStart);
const wheelResultSource = source.slice(wheelResultStart, wheelResultEnd);
const wheelResultAnimationStart = wheelResultSource.indexOf('animateReversePlSectorRemoval({');
const wheelResultCompletionStart = wheelResultSource.indexOf('onComplete: () => {', wheelResultAnimationStart);
const authoritativeWheelReload = wheelResultSource.indexOf('applyExternalStateUpdate({', wheelResultCompletionStart);
assert(
  wheelResultAnimationStart >= 0
    && wheelResultCompletionStart > wheelResultAnimationStart
    && authoritativeWheelReload > wheelResultCompletionStart,
  'SPIN_RESULT applies authoritative state before the wheel shrink animation completes'
);
assert(
  wheelResultSource.includes('isDelaying = true;')
    && wheelResultSource.includes('durationMs: 1000')
    && wheelResultSource.includes('onFrame: displayProbabilityState => drawWheel(displayProbabilityState)'),
  'Wheel SPIN_RESULT does not run the shared one-second shrink animation'
);
assert(
  !wheelResultSource.includes('eliminateEntryAtCurrentPlace(')
    && !wheelResultSource.includes('assignedPlace ='),
  'Wheel SPIN_RESULT mutates authoritative elimination or place state'
);
assert(
  wheelResultSource.includes('probabilityState: targetProbabilityState')
    && wheelResultSource.includes('wheelAngle: removalState.finalAngle'),
  'Wheel does not reuse target geometry and final angle while loading authoritative state'
);

const wheelButtonStart = source.indexOf("document.getElementById('btn-spin').addEventListener");
const wheelButtonEnd = source.indexOf("document.getElementById('spin-donations-modal').addEventListener", wheelButtonStart);
const wheelButtonBlock = source.slice(wheelButtonStart, wheelButtonEnd);
assert(wheelButtonBlock.indexOf('isDonationCollectionActive()') < wheelButtonBlock.indexOf("appViewMode === 'wheel'"), 'Wheel view still bypasses the active-donation confirmation');
assert(wheelButtonBlock.includes("requestSpinFromWheel('stop_and_spin')"), 'Wheel stop button does not delegate pause-and-spin to the leader');
assert(!source.includes('spin-without-stopping') && !source.includes("requestSpinFromWheel('spin_without_stopping')"), 'Continue-without-stopping control was not removed');
assert(!source.includes('Эта вкладка собирает данные') && !source.includes('Данные собирает другая вкладка'), 'Internal tab leadership notice is still visible');
assert(!source.includes('<strong>Локальное приложение.</strong>') && !source.includes('Токены донат-сервисов хранятся локально'), 'Removed token storage warnings are still visible');
assert(!source.includes('Как подключить?'), 'Redundant integration help remains visible');
assert(source.includes('id="openrouter-proxy-test-result"') && source.includes('Прокси работает') && source.includes('Проверка не пройдена:'), 'Proxy test has no visible success and failure states');
assert(source.includes('response.status === 202 && payload?.queued && payload?.requestId') && source.includes('pollLocalUpstreamJob(payload.requestId, options)'), 'Frontend does not poll queued external requests');
assert(source.includes('onPrivateSubscribe: ({ data }, callback) =>') && source.includes("fetchLocalApi('/centrifuge/subscribe'"), 'DonatePay private subscription still depends on a blocking subscribe request');
const proxyPresentationStart = source.indexOf('    function getOpenRouterProxyTestPresentation');
const proxyPresentationEnd = source.indexOf('    function renderAiSettings', proxyPresentationStart);
if (proxyPresentationStart < 0 || proxyPresentationEnd < 0) throw new Error('Proxy test presentation helper not found');
const { getOpenRouterProxyTestPresentation } = new Function(`${source.slice(proxyPresentationStart, proxyPresentationEnd)}; return { getOpenRouterProxyTestPresentation };`)();
const proxySuccess = getOpenRouterProxyTestPresentation({ proxyConfigured: true, testStatus: 'проверка OK (125 ms)' });
assert(proxySuccess.statusClass === 'connected' && proxySuccess.resultClass === 'success' && proxySuccess.resultText === 'Прокси работает · 125 ms', 'Successful proxy check is not shown clearly');
const proxyFailure = getOpenRouterProxyTestPresentation({ proxyConfigured: true, testStatus: 'ошибка: timeout' });
assert(proxyFailure.statusClass === 'error' && proxyFailure.resultClass === 'error' && proxyFailure.resultText === 'Проверка не пройдена: timeout', 'Failed proxy check is not shown clearly');
assert(source.includes('recoverWheelSpinAfterTimeout') && source.includes('findPersistedSpinRequestState'), 'Wheel timeout does not recover authoritative persisted spin state');
assert(source.includes('function deleteEntryById(entryId) {\n      if (!canMutateAuctionState())'), 'Entry deletion is not protected during authoritative spin');
const collectionPauseStart = source.indexOf('    async function performDonationCollectionPauseChange');
const collectionPauseEnd = source.indexOf('    function buildServerCollectorConfig', collectionPauseStart);
const collectionPauseBlock = source.slice(collectionPauseStart, collectionPauseEnd);
assert(collectionPauseBlock.indexOf('await pauseServerCollectorPreserveCursor()') < collectionPauseBlock.indexOf('donationCollectionPaused = true'), 'Ordinary collection pause still commits browser state before server confirmation');
assert(collectionPauseBlock.includes('donationCollectionPaused = previousPaused'), 'Collection pause/resume failure does not restore the previous browser state');
assert(collectionPauseBlock.includes('isAdminOperationStillAuthoritative(operationClaim)'), 'Collection pause/resume does not recheck leadership after await');
assert(collectionPauseBlock.includes('while (donationCollectionPauseChangePromise)'), 'Collection pause/resume changes are not serialized');
assert(collectionPauseBlock.includes('while (collectorPauseReconcilePromise)'), 'User pause/resume does not wait for an in-flight orphan-pause reconciliation');
assert(wheelButtonBlock.includes('const paused = await setDonationCollectionPaused(true);\n        if (paused) startSpinNow();'), 'Admin stop-and-spin starts even when collector pause was not confirmed');
const localSpinStart = source.indexOf('    async function startSpinNow');
const localSpinEnd = source.indexOf('    function closeSpinDonationsModal', localSpinStart);
const localSpinBlock = source.slice(localSpinStart, localSpinEnd);
assert(
  localSpinBlock.includes('isSpinning = true;')
    && localSpinBlock.includes("document.body.classList.add('is-spinning');")
    && localSpinBlock.includes("document.body.classList.remove('show-result');"),
  'Local spin does not lock admin controls'
);
assert(
  localSpinBlock.includes('isSpinning = false;')
    && localSpinBlock.includes("document.body.classList.remove('is-spinning');")
    && localSpinBlock.includes('saveData();'),
  'Local spin does not unlock admin controls'
);
const remoteSpinStart = source.indexOf('    async function handleRemoteSpinRequest');
const remoteSpinEnd = source.indexOf('    function shouldStartWheelSpinAnimation', remoteSpinStart);
const remoteSpinBlock = source.slice(remoteSpinStart, remoteSpinEnd);
assert(remoteSpinBlock.includes('await donationCollectionPauseChangePromise'), 'Remote spin does not wait for an in-flight collector pause/resume change');
assert(remoteSpinBlock.indexOf('registerSpinRequest(handledSpinRequests') < remoteSpinBlock.indexOf('await donationCollectionPauseChangePromise'), 'Remote spin request is not reserved before waiting for collection pause');
assert(remoteSpinBlock.includes('await collectorPauseReconcilePromise'), 'Remote spin does not wait for an in-flight orphan-pause reconciliation');
assert(remoteSpinBlock.indexOf('registerSpinRequest(handledSpinRequests') < remoteSpinBlock.indexOf('await collectorPauseReconcilePromise'), 'Remote spin request is not reserved before waiting for collector reconciliation');
assert(remoteSpinBlock.indexOf('await collectorPauseReconcilePromise') < remoteSpinBlock.indexOf('pauseDonationCollectionForRemoteSpin(operationClaim)'), 'Remote stop-and-spin starts server pause before collector reconciliation finishes');
const fullResetBlock = source.slice(source.indexOf('async function resetAllSiteData'), source.indexOf('function setActiveMainTab'));
assert(!fullResetBlock.includes('stopServerCollectorForReset'), 'Full reset still resets collector cursors before the irreversible server reset');
assert(fullResetBlock.includes('completeConfirmedFullReset(resetOperationId, confirmedResetEpoch)'), 'Confirmed server reset does not unconditionally clear browser state');
assert(source.includes('reconcileServerCollectorPauseAfterTakeover'), 'Leader takeover does not reconcile an orphaned preserve-cursor collector pause');
assert(source.includes("message.type === 'AUCTION_CLEARING') {\n            if (message.tabInstanceId !== adminTabInstanceId && isMessageFromCurrentAdminLeader(message))"), 'Auction clear start accepts messages from a former leader');
assert(source.includes("message.type === 'RESET_STARTED') {\n            if (message.tabInstanceId !== adminTabInstanceId && isMessageFromCurrentAdminLeader(message))"), 'Full reset start accepts messages from a former leader');

const externalUpdateStart = source.indexOf('    function applyExternalStateUpdate');
const externalUpdateEnd = source.indexOf('    function createDefaultDonationIntegrations', externalUpdateStart);
if (externalUpdateStart < 0 || externalUpdateEnd < 0) throw new Error('External state update helper not found');
function createExternalUpdateHarness({ viewMode = 'admin', leader = false, spinning = false, delaying = false } = {}) {
  const events = [];
  return new Function('events', `
    let appViewMode = ${JSON.stringify(viewMode)};
    let isAdminLeader = ${leader};
    let isSpinning = ${spinning};
    let isDelaying = ${delaying};
    let isApplyingRemoteState = false;
    let lastAppliedStateUpdateId = 'already-applied';
    let entries = [{ id: 'authoritative', price: 1, eliminated: false }];
    let shrinkAnimFrame = 11;
    let strikeActivationTimeout = 12;
    let pendingAuthoritativeSpinTimer = 13;
    let pendingWheelSpinTimeout = 14;
    let pendingWheelSpinRequest = { spinRequestId: 'stale-spin' };
    let pendingWheelSpinVisualState = { spinRequestId: 'stale-spin' };
    let shrinkingTarget = { id: 'stale' };
    let shrinkingTargetProbabilityState = { signature: 'stale' };
    const document = { body: { classList: { remove: value => events.push('class:' + value) } } };
    const cancelAnimationFrame = value => events.push('raf:' + value);
    const clearTimeout = value => events.push('timeout:' + value);
    const cancelWheelSpinAnimation = () => events.push('wheel-cancel');
    const clearSpinResultOverlay = options => {
      if (strikeActivationTimeout) clearTimeout(strikeActivationTimeout);
      strikeActivationTimeout = null;
      events.push('overlay-clear:' + String(options?.redraw));
    };
    const createReversePlStateSignature = () => 'authoritative-signature';
    const installReversePlProbabilityState = state => {
      events.push('probability:' + state.signature);
      return state;
    };
    const normalizeWheelAngleRad = value => Number(value) || 0;
    const loadData = () => events.push('load');
    const applyViewMode = () => events.push('view');
    const renderList = () => events.push('list');
    const renderIntegrationCards = () => events.push('integrations');
    const renderDonationCollectionToggle = () => events.push('donation-toggle');
    const refreshCenterCircleBackground = () => events.push('center');
    const restoreTimerState = () => events.push('timer');
    const resizeWheel = () => events.push('resize');
    const drawWheel = () => events.push('draw');
    const scheduleFitTimer = () => events.push('fit');
    const updateAdminLeadershipUi = () => events.push('leadership-ui');
    ${source.slice(externalUpdateStart, externalUpdateEnd)}
    return {
      applyExternalStateUpdate,
      getEvents: () => events.slice(),
      getState: () => ({ isSpinning, isDelaying, shrinkAnimFrame, strikeActivationTimeout, pendingAuthoritativeSpinTimer, pendingWheelSpinTimeout, pendingWheelSpinRequest, pendingWheelSpinVisualState, shrinkingTarget, shrinkingTargetProbabilityState, isApplyingRemoteState, lastAppliedStateUpdateId })
    };
  `)(events);
}
const leaderExternalHarness = createExternalUpdateHarness({ leader: true, spinning: true });
assert(!leaderExternalHarness.applyExternalStateUpdate({ force: true }), 'Forced external reload can overwrite the active leader');
assert(leaderExternalHarness.getEvents().length === 0, 'Forced external reload changed active leader runtime before returning');
const ordinaryExternalHarness = createExternalUpdateHarness({ spinning: true });
assert(!ordinaryExternalHarness.applyExternalStateUpdate(), 'Ordinary external update interrupted an active animation');
assert(ordinaryExternalHarness.getEvents().length === 0, 'Ordinary external update changed an active follower animation before returning');
const delayingWheelExternalHarness = createExternalUpdateHarness({ viewMode: 'wheel', delaying: true });
assert(!delayingWheelExternalHarness.applyExternalStateUpdate({ stateUpdateId: 'admin-result' }), 'STATE_UPDATED interrupted the wheel shrink animation');
assert(delayingWheelExternalHarness.getEvents().length === 0, 'STATE_UPDATED redrew wheel sectors before shrink completion');
const duplicateExternalHarness = createExternalUpdateHarness();
assert(!duplicateExternalHarness.applyExternalStateUpdate({ stateUpdateId: 'already-applied' }), 'Duplicate storage/BroadcastChannel update was rendered twice');
assert(duplicateExternalHarness.getEvents().length === 0, 'Duplicate state update touched follower UI before returning');
const forcedExternalHarness = createExternalUpdateHarness({ spinning: true, delaying: true });
assert(forcedExternalHarness.applyExternalStateUpdate({ force: true }), 'Forced follower reload did not apply authoritative state');
const forcedExternalState = forcedExternalHarness.getState();
const forcedExternalEvents = forcedExternalHarness.getEvents();
assert(!forcedExternalState.isSpinning && !forcedExternalState.isDelaying, 'Forced follower reload left spin flags active');
assert(
  forcedExternalState.shrinkAnimFrame === null
    && forcedExternalState.strikeActivationTimeout === null
    && forcedExternalState.pendingAuthoritativeSpinTimer === null
    && forcedExternalState.pendingWheelSpinTimeout === null
    && forcedExternalState.pendingWheelSpinRequest === null
    && forcedExternalState.pendingWheelSpinVisualState === null
    && forcedExternalState.shrinkingTarget === null
    && forcedExternalState.shrinkingTargetProbabilityState === null,
  'Forced follower reload left stale animation handles or state'
);
assert(forcedExternalEvents.includes('wheel-cancel'), 'Forced follower reload did not cancel the wheel animation');
assert(forcedExternalEvents.includes('raf:11'), 'Forced follower reload did not cancel the shrink animation');
assert(forcedExternalEvents.includes('timeout:13'), 'Forced follower reload did not cancel authoritative spin finalization');
assert(forcedExternalEvents.includes('timeout:14'), 'Forced follower reload did not cancel a stale wheel request timeout');
assert(forcedExternalEvents.includes('overlay-clear:false'), 'Forced follower reload did not clear the stale spin result overlay');
assert(forcedExternalEvents.filter(event => event === 'load').length === 1, 'Forced follower reload did not load authoritative shared state exactly once');
assert(forcedExternalEvents.indexOf('load') > forcedExternalEvents.indexOf('wheel-cancel'), 'Forced follower reload loaded state before cancelling stale animation work');
const targetReuseExternalHarness = createExternalUpdateHarness({ viewMode: 'wheel' });
assert(targetReuseExternalHarness.applyExternalStateUpdate({
  probabilityState: {
    signature: 'authoritative-signature',
    dropoutChances: new Map([['authoritative', 1]])
  },
  wheelAngle: Math.PI
}), 'Wheel completion did not apply authoritative admin state');
const targetReuseEvents = targetReuseExternalHarness.getEvents();
assert(
  targetReuseEvents.includes('probability:authoritative-signature')
    && targetReuseEvents.indexOf('probability:authoritative-signature') < targetReuseEvents.indexOf('draw'),
  'Wheel completion did not install target Reverse PL state before the authoritative redraw'
);

const spinOverlayStart = source.indexOf('    function cancelScheduledSpinResultClear');
const spinOverlayEnd = source.indexOf('    function scheduleClearSpinResult', spinOverlayStart);
if (spinOverlayStart < 0 || spinOverlayEnd < 0) throw new Error('Spin result overlay helpers not found');
const spinOverlayState = new Function(`
  const events = [];
  let spinResultClearTimeout = 21;
  let strikeActivationTimeout = 22;
  const clearTimeout = value => events.push('timeout:' + value);
  const document = {
    body: { classList: { remove: value => events.push('class:' + value) } },
    getElementById: id => ({
      replaceChildren: () => events.push('replace:' + id),
      set textContent(value) { events.push('text:' + id + ':' + value); }
    })
  };
  const drawWheel = () => events.push('draw');
  const renderWheelReadonlyEntriesList = () => events.push('readonly-list');
  ${source.slice(spinOverlayStart, spinOverlayEnd)}
  clearSpinResultOverlay({ redraw: false });
  return { events, spinResultClearTimeout, strikeActivationTimeout };
`)();
assert(spinOverlayState.spinResultClearTimeout === null, 'Spin result overlay cleanup left its clear timeout active');
assert(spinOverlayState.strikeActivationTimeout === null, 'Spin result overlay cleanup left the delayed strike activation active');
assert(spinOverlayState.events.includes('timeout:21') && spinOverlayState.events.includes('timeout:22'), 'Spin result overlay cleanup did not cancel both delayed callbacks');
assert(!spinOverlayState.events.includes('draw'), 'Non-redrawing spin overlay cleanup unexpectedly redrew the wheel');

async function runBootstrapCoordinatorTests() {
  const coordinatorStart = source.indexOf('    function normalizeBootstrapRole');
  const coordinatorEnd = source.indexOf('    function getCurrentBootstrapRole', coordinatorStart);
  if (coordinatorStart < 0 || coordinatorEnd < 0) throw new Error('Bootstrap coordinator helper block not found');
  const { createBootstrapRequestCoordinator } = new Function(
    `${source.slice(coordinatorStart, coordinatorEnd)}; return { createBootstrapRequestCoordinator };`
  )();

  const runFreshRole = async (role) => {
    let currentRole = role;
    const requests = [];
    const coordinator = createBootstrapRequestCoordinator(async (requestedRole, options) => {
      requests.push({ role: requestedRole, collector: requestedRole === 'leader', current: options.isCurrent() });
      return options.isCurrent();
    }, () => currentRole);
    await Promise.all([coordinator.request(role), coordinator.request(role)]);
    return requests;
  };

  const leaderRequests = await runFreshRole('leader');
  assert(leaderRequests.length === 1 && leaderRequests[0].collector, 'Fresh admin leader did not perform exactly one collector bootstrap');
  const followerRequests = await runFreshRole('follower');
  assert(followerRequests.length === 1 && !followerRequests[0].collector, 'Fresh admin follower bootstrap unexpectedly included collector config');
  const wheelRequests = await runFreshRole('wheel');
  assert(wheelRequests.length === 1 && !wheelRequests[0].collector, 'Fresh wheel bootstrap unexpectedly included collector config');

  let takeoverRole = 'follower';
  const takeoverRequests = [];
  const takeoverCoordinator = createBootstrapRequestCoordinator(async (role, options) => {
    takeoverRequests.push({ role, collector: role === 'leader' });
    return options.isCurrent();
  }, () => takeoverRole);
  await takeoverCoordinator.request('follower');
  takeoverRole = 'leader';
  await takeoverCoordinator.request('leader');
  await takeoverCoordinator.request('leader');
  assert(
    takeoverRequests.length === 2
      && takeoverRequests[0].role === 'follower'
      && takeoverRequests[1].role === 'leader'
      && takeoverRequests[1].collector,
    'Follower takeover did not produce exactly one additional leader bootstrap'
  );

  let inFlightRole = 'follower';
  let releaseFollower;
  const followerGate = new Promise(resolve => { releaseFollower = resolve; });
  const appliedRoles = [];
  const inFlightRequests = [];
  const inFlightCoordinator = createBootstrapRequestCoordinator(async (role, options) => {
    inFlightRequests.push(role);
    if (role === 'follower') await followerGate;
    if (options.isCurrent()) appliedRoles.push(role);
    return options.isCurrent();
  }, () => inFlightRole);
  const staleFollower = inFlightCoordinator.request('follower');
  await Promise.resolve();
  inFlightRole = 'leader';
  const currentLeader = inFlightCoordinator.request('leader');
  releaseFollower();
  await Promise.all([staleFollower, currentLeader]);
  assert(inFlightRequests.join(',') === 'follower,leader', 'Takeover did not serialize follower and leader bootstrap requests');
  assert(appliedRoles.join(',') === 'leader', 'Stale follower bootstrap response was applied after leader takeover');

  let rapidRole = 'leader';
  let releaseRapidFollower;
  const rapidFollowerGate = new Promise(resolve => { releaseRapidFollower = resolve; });
  const rapidRequests = [];
  const rapidApplied = [];
  const rapidCoordinator = createBootstrapRequestCoordinator(async (role, options) => {
    rapidRequests.push(role);
    if (role === 'follower') await rapidFollowerGate;
    if (options.isCurrent()) rapidApplied.push(role);
    return options.isCurrent();
  }, () => rapidRole);
  await rapidCoordinator.request('leader');
  rapidRole = 'follower';
  const rapidFollower = rapidCoordinator.request('follower');
  await Promise.resolve();
  rapidRole = 'leader';
  const rapidLeader = rapidCoordinator.request('leader', { leaderTakeover: true, force: true });
  releaseRapidFollower();
  await Promise.all([rapidFollower, rapidLeader]);
  assert(rapidRequests.join(',') === 'leader,follower,leader', 'Rapid leader-follower-leader transition skipped the forced takeover bootstrap');
  assert(rapidApplied.join(',') === 'leader,leader', 'Stale rapid follower bootstrap response became authoritative');

  const bootstrapFunction = source.slice(
    source.indexOf('    async function bootstrapLocalApp'),
    source.indexOf('    async function bootstrapAfterAdminElection')
  );
  assert(bootstrapFunction.includes("collector: leaderBootstrap ? buildServerCollectorConfig() : null"), 'Bootstrap request body is not role-aware');
  assert(bootstrapFunction.includes('if (!requestIsCurrent()) return false;'), 'Stale bootstrap responses are not rejected');
  const startupBlock = source.slice(source.lastIndexOf('    adminTabId = getOrCreateAdminTabId();'), source.lastIndexOf('  </script>'));
  assert(!startupBlock.includes('bootstrapLocalApp();'), 'Startup still calls bootstrapLocalApp unconditionally');
  assert(startupBlock.includes('bootstrapAfterAdminElection(donationAlertsOAuthHandled)'), 'Startup bootstrap does not wait for election/OAuth coordination');
  const afterElectionBlock = source.slice(
    source.indexOf('    async function bootstrapAfterAdminElection'),
    source.indexOf('    function setModalButtonLoading')
  );
  assert(afterElectionBlock.indexOf('await adminLeaderReadyPromise') < afterElectionBlock.indexOf('startAdminLeaderRuntime()'), 'Leader bootstrap can start before lease election completes');
  const bfcacheBlock = source.slice(
    source.indexOf('    function resetAdminElectionAfterBfCache'),
    source.indexOf('    function shouldReverifyAdminLeaseAfterPageShow')
  );
  assert(bfcacheBlock.includes('doesAdminLeaseBelongToTab'), 'BFCache restore does not reverify the persisted lease');
  assert(bfcacheBlock.includes('adminRoleBeforePageHide || getCurrentBootstrapRole()'), 'BFCache restore forgot the role held before pagehide');
  assert(bfcacheBlock.includes("applyExternalStateUpdate({ force: previousRole === 'leader' });"), 'Former BFCache leader does not force authoritative shared-state reload');
  assert(bfcacheBlock.includes("bfcacheRoleChange: true,\n            force: true"), 'Former BFCache leader does not force a follower bootstrap');
  const viewRestoreBlock = source.slice(
    source.indexOf('    function restoreViewAfterBfCache'),
    source.indexOf('    function setupAdminLeaderElection')
  );
  assert(viewRestoreBlock.includes("applyExternalStateUpdate({ force: true });"), 'Wheel BFCache restore does not force authoritative shared-state reload');
  assert(viewRestoreBlock.includes("requestBootstrapForRole('wheel', { bfcacheRestore: true, force: true })"), 'Wheel BFCache restore does not refresh server state');
  const electionSetupBlock = source.slice(
    source.indexOf('    function setupAdminLeaderElection'),
    source.indexOf('    function setupStateSync')
  );
  assert(
    electionSetupBlock.indexOf("window.addEventListener('pageshow'") < electionSetupBlock.indexOf("if (appViewMode !== 'admin')"),
    'Wheel view returns before registering its BFCache pageshow handler'
  );
  const pageHideBlock = source.slice(
    source.indexOf('    function rememberRoleAndReleaseAdminLease'),
    source.indexOf('    function resetAdminElectionAfterBfCache')
  );
  assert(pageHideBlock.indexOf('adminRoleBeforePageHide = getCurrentBootstrapRole()') < pageHideBlock.indexOf('releaseAdminLease();'), 'pagehide releases leadership before remembering the previous role');
  const leaderRuntimeBlock = source.slice(
    source.indexOf('    function startAdminLeaderRuntime'),
    source.indexOf('    function becomeAdminLeader')
  );
  assert(leaderRuntimeBlock.includes('force: leaderTakeover'), 'Repeated takeover does not force a fresh leader bootstrap');
  const collectionPauseBlock = source.slice(
    source.indexOf('    async function performDonationCollectionPauseChange'),
    source.indexOf('    async function setDonationCollectionPaused')
  );
  assert(!collectionPauseBlock.includes("if (!isAdminOperationStillAuthoritative(operationClaim)) {\n            if (serverPaused"), 'Stale pause operation can resume collector after losing leadership');
  assert(!collectionPauseBlock.includes("if (!isAdminOperationStillAuthoritative(operationClaim)) {\n          if (serverResumed"), 'Stale resume operation can pause collector after losing leadership');
  assert(source.includes("applyExternalStateUpdate({ stateUpdateId: message.stateUpdateId });"), 'BroadcastChannel state update does not carry its dedupe identifier');
  assert(source.includes("getStoredStateUpdateId(event.newValue)"), 'Storage state update does not carry its dedupe identifier');
  const recoveryBlock = source.slice(
    source.indexOf('    async function runDonatePayRecovery'),
    source.indexOf('    async function connectDonatePayRealtime')
  );
  assert(recoveryBlock.includes('auctionGeneration: currentAuctionGeneration'), 'DonatePay recovery request is not generation-aware');
  assert(recoveryBlock.includes('requestId: String(options.requestId || \'\')'), 'DonatePay recovery does not poll an idempotent request id');
  assert(recoveryBlock.includes('scheduleDonatePayRecoveryResultPoll(reason'), 'Queued DonatePay recovery result is never collected');
  const addPendingBlock = source.slice(
    source.indexOf('    function addDonationToPending'),
    source.indexOf('    function moveDonationToAdded')
  );
  assert(addPendingBlock.includes("normalized.source === 'donatepay'"), 'Server-delivered DonatePay donation does not advance the accepted cursor');
  assert(oauthViewHelpers.hasDonationAlertsOAuthAccessToken(), 'OAuth callback is not classified as admin before election');
}

runBootstrapCoordinatorTests()
  .then(() => console.log('AI frontend logic tests ok'))
  .catch(error => {
    console.error(error);
    process.exitCode = 1;
  });
