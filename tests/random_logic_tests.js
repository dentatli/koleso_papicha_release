const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'koleso_papich.html'), 'utf8');

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const start = source.indexOf('    function getEntryAmount');
const end = source.indexOf('    function ensureSpinSeriesDropoutQueue', start);
if (start < 0 || end < 0) throw new Error('Random selection helpers not found');
const helperSource = source.slice(start, end);

function createHarness(randomValues = [], queue = [], winnerId = null, stateEntries = [], initialEntryKey = '') {
  const values = [...randomValues];
  return new Function(
    'cryptoRandomFloat',
    'cryptoRandomInt',
    'spinSeriesInitialCount',
    'POINTAUC_VISUAL_MIN_AMOUNT',
    'POINTAUC_VISUAL_MIN_MODIFIER',
    'POINTAUC_VISUAL_MAX_MODIFIER',
    'entries',
    'spinSeriesDropoutQueue',
    'spinSeriesFinalWinnerId',
    'spinSeriesInitialEntryKey',
    `${helperSource}; return {
      getWeightedCandidatesByAmount,
      pickWeightedEntryByAmount,
      calculateAmountWinChances,
      buildSpinSeriesDropoutQueue,
      validateSpinSeriesQueue
    };`
  )(
    () => values.length ? values.shift() : 0,
    (min) => min,
    0,
    1,
    0.55,
    1,
    stateEntries,
    queue,
    winnerId,
    initialEntryKey
  );
}

const boundaryHarness = createHarness([0, 0.25]);
const positiveAfterZero = boundaryHarness.pickWeightedEntryByAmount([
  { id: 'zero', price: 0 },
  { id: 'positive', price: 1 }
]);
assert(positiveAfterZero.id === 'positive', 'A zero-weight lot won at the lower random boundary');
const exactBoundary = boundaryHarness.pickWeightedEntryByAmount([
  { id: 'one', price: 1 },
  { id: 'three', price: 3 }
]);
assert(exactBoundary.id === 'three', 'An exact cumulative boundary selected the previous lot');

const weightedEntries = [
  { id: 'a', price: 1, eliminated: false },
  { id: 'b', price: 3, eliminated: false },
  { id: 'c', price: 2, eliminated: false }
];
const weightedHarness = createHarness([0.75, 0.2, 0.5]);
const weightedSeries = weightedHarness.buildSpinSeriesDropoutQueue(weightedEntries);
assert(weightedSeries.queue.join(',') === 'b,a,c', 'Weighted dropout queue changed for deterministic random input');
assert(weightedSeries.finalWinnerId === 'c', 'Precomputed winner is not the last remaining lot');
assert(new Set(weightedSeries.queue).size === weightedEntries.length, 'Precomputed queue contains duplicates or omissions');

const weightedChances = weightedHarness.calculateAmountWinChances(weightedEntries);
assert(weightedChances.get('a') === 1 / 6, 'Normal weighted chance for lot A changed');
assert(weightedChances.get('b') === 3 / 6, 'Normal weighted chance for lot B changed');
assert(weightedChances.get('c') === 2 / 6, 'Normal weighted chance for lot C changed');

const zeroEntries = [
  { id: 'zero-a', price: 0, eliminated: false },
  { id: 'zero-b', price: 0, eliminated: false },
  { id: 'zero-c', price: 0, eliminated: false }
];
const zeroHarness = createHarness([0.9, 0.1, 0.4]);
const zeroSeries = zeroHarness.buildSpinSeriesDropoutQueue(zeroEntries);
assert(zeroSeries.queue.join(',') === 'zero-b,zero-a,zero-c', 'All-zero lots are not selected uniformly');
assert(zeroSeries.finalWinnerId === 'zero-c', 'All-zero precomputed winner changed');
const zeroChances = zeroHarness.calculateAmountWinChances(zeroEntries);
for (const entry of zeroEntries) {
  assert(zeroChances.get(entry.id) === 1 / 3, 'All-zero lots no longer have equal winning chances');
}

const restoredHarness = createHarness([], JSON.parse(JSON.stringify(weightedSeries.queue)), weightedSeries.finalWinnerId, weightedEntries, weightedSeries.initialEntryKey);
assert(restoredHarness.validateSpinSeriesQueue(weightedEntries), 'A valid precomputed queue did not survive serialization and reload');
const invalidRestoredHarness = createHarness([], ['a', 'a', 'c'], weightedSeries.finalWinnerId, weightedEntries, weightedSeries.initialEntryKey);
assert(!invalidRestoredHarness.validateSpinSeriesQueue(weightedEntries), 'A duplicated restored queue was accepted');

assert(source.includes('if (randomValue < acc) return entry;'), 'Strict weighted boundary comparison is missing');
console.log('Random logic tests ok');
