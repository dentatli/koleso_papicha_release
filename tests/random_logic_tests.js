'use strict';

const fs = require('fs');
const path = require('path');
const { performance } = require('perf_hooks');

const root = path.join(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'koleso_papich.html'), 'utf8').replace(/\r\n?/g, '\n');
const coreStart = source.indexOf('    // Reverse Plackett–Luce numerical core.');
const coreEnd = source.indexOf('    // End Reverse Plackett–Luce numerical core.', coreStart);
if (coreStart < 0 || coreEnd < 0) throw new Error('Reverse Plackett–Luce numerical core not found');

const helpers = new Function(`${source.slice(coreStart, coreEnd)}
  return {
    TWO_PI,
    normalizeReversePlRate,
    interpolateReversePlDropoutChances,
    calculateAmountWinChances,
    calculateReversePlDropoutWeights,
    calculateReversePlCurrentWinWeights,
    calculateReversePlDropoutChances,
    calculateReversePlCurrentWinChances,
    normalizeWheelAngleRad,
    buildWheelSpinPlan,
    getWheelSegmentByPointerOffset,
    getWheelSegmentAtAngle
  };
`)();

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function assertApprox(actual, expected, tolerance, message) {
  if (!Number.isFinite(actual) || Math.abs(actual - expected) > tolerance) {
    throw new Error(`${message}: expected ${expected}, got ${actual}`);
  }
}

function assertProbabilityMap(probabilities, expectedSize, message) {
  assert(probabilities.size === expectedSize, `${message}: wrong map size`);
  let sum = 0;
  for (const probability of probabilities.values()) {
    assert(Number.isFinite(probability), `${message}: probability is not finite`);
    assert(probability >= 0, `${message}: probability is negative`);
    sum += probability;
  }
  assertApprox(sum, 1, 1e-10, `${message}: probabilities do not sum to one`);
}

function createEntries(rates, prefix = 'entry') {
  return rates.map((price, index) => ({
    id: `${prefix}-${index}`,
    name: `${prefix} ${index}`,
    price,
    eliminated: false
  }));
}

function normalizeReferenceWeights(values) {
  const total = values.reduce((sum, value) => sum + value, 0);
  return values.map(value => value / total);
}

function buildSectorBounds(orderedEntries, weights) {
  const total = orderedEntries.reduce((sum, entry) => sum + Number(weights.get(entry.id) || 0), 0);
  let start = 0;
  const bounds = new Map();
  orderedEntries.forEach(entry => {
    const angle = (Number(weights.get(entry.id) || 0) / total) * helpers.TWO_PI;
    bounds.set(entry.id, { start, end: start + angle });
    start += angle;
  });
  return bounds;
}

function subsetIntegral(anchorRate, factorRates) {
  let result = 0;
  const subsetCount = 2 ** factorRates.length;
  for (let mask = 0; mask < subsetCount; mask += 1) {
    let denominator = anchorRate;
    let selectedCount = 0;
    for (let index = 0; index < factorRates.length; index += 1) {
      if ((mask & (2 ** index)) === 0) continue;
      denominator += factorRates[index];
      selectedCount += 1;
    }
    result += (selectedCount % 2 === 0 ? 1 : -1) * anchorRate / denominator;
  }
  return result;
}

function exactSmallDropoutWeights(rates, eliminatedRateSum) {
  const weights = rates.map((rate, index) => {
    const otherRates = rates.filter((unused, otherIndex) => otherIndex !== index);
    return subsetIntegral(rate + eliminatedRateSum, otherRates) * rate / (rate + eliminatedRateSum);
  });
  return normalizeReferenceWeights(weights);
}

function exactSmallCurrentWinWeights(rates, eliminatedRateSum) {
  const denominator = subsetIntegral(eliminatedRateSum, rates);
  const totalRate = eliminatedRateSum + rates.reduce((sum, rate) => sum + rate, 0);
  const weights = rates.map((rate, index) => {
    const otherRates = rates.filter((unused, otherIndex) => otherIndex !== index);
    const leaveOneOut = subsetIntegral(eliminatedRateSum, otherRates);
    return (rate / totalRate) * (leaveOneOut / denominator);
  });
  return normalizeReferenceWeights(weights);
}

const twoRates = helpers.calculateReversePlDropoutWeights([1, 3], 0);
assertApprox(twoRates[0], 3 / 4, 2e-8, 'Two-lot dropout chance for A is wrong');
assertApprox(twoRates[1], 1 / 4, 2e-8, 'Two-lot dropout chance for B is wrong');

const shrinkEntries = createEntries([1, 2, 3], 'shrink');
const shrinkVictim = shrinkEntries[1];
const oldShrinkWeights = helpers.calculateReversePlDropoutChances(shrinkEntries, []);
const targetShrinkEntries = shrinkEntries.map(entry => (
  entry.id === shrinkVictim.id ? { ...entry, eliminated: true } : entry
));
const targetShrinkWeights = helpers.calculateReversePlDropoutChances(
  targetShrinkEntries.filter(entry => !entry.eliminated),
  targetShrinkEntries.filter(entry => entry.eliminated)
);
const firstShrinkFrame = helpers.interpolateReversePlDropoutChances(
  shrinkEntries,
  oldShrinkWeights,
  targetShrinkWeights,
  0
);
const middleShrinkFrame = helpers.interpolateReversePlDropoutChances(
  shrinkEntries,
  oldShrinkWeights,
  targetShrinkWeights,
  0.4
);
const lastShrinkFrame = helpers.interpolateReversePlDropoutChances(
  shrinkEntries,
  oldShrinkWeights,
  targetShrinkWeights,
  1
);
shrinkEntries.forEach(entry => {
  assertApprox(
    firstShrinkFrame.get(entry.id),
    oldShrinkWeights.get(entry.id),
    1e-15,
    `First shrink frame changed old geometry for ${entry.id}`
  );
});
assertApprox(
  Array.from(middleShrinkFrame.values()).reduce((sum, weight) => sum + weight, 0),
  1,
  1e-15,
  'Intermediate shrink weights do not sum to one'
);
assertApprox(
  middleShrinkFrame.get(shrinkVictim.id),
  oldShrinkWeights.get(shrinkVictim.id) * 0.6,
  1e-15,
  'Victim weight does not shrink smoothly'
);
assertApprox(lastShrinkFrame.get(shrinkVictim.id), 0, 1e-15, 'Victim does not reach zero weight');
shrinkEntries.filter(entry => entry.id !== shrinkVictim.id).forEach(entry => {
  assertApprox(
    lastShrinkFrame.get(entry.id),
    targetShrinkWeights.get(entry.id),
    1e-15,
    `Last shrink frame differs from target Reverse PL geometry for ${entry.id}`
  );
});
const lastShrinkBounds = buildSectorBounds(shrinkEntries, lastShrinkFrame);
const committedShrinkBounds = buildSectorBounds(
  shrinkEntries.filter(entry => entry.id !== shrinkVictim.id),
  targetShrinkWeights
);
for (const entry of shrinkEntries.filter(item => item.id !== shrinkVictim.id)) {
  assertApprox(
    lastShrinkBounds.get(entry.id).start,
    committedShrinkBounds.get(entry.id).start,
    1e-15,
    `Sector start changes after shrink commit for ${entry.id}`
  );
  assertApprox(
    lastShrinkBounds.get(entry.id).end,
    committedShrinkBounds.get(entry.id).end,
    1e-15,
    `Sector end changes after shrink commit for ${entry.id}`
  );
}

const exactRates = [0.75, 2.5, 6, 11];
const exactEliminatedRateSum = 4.25;
const exactDropout = exactSmallDropoutWeights(exactRates, exactEliminatedRateSum);
const numericalDropout = helpers.calculateReversePlDropoutWeights(exactRates, exactEliminatedRateSum);
const exactCurrentWins = exactSmallCurrentWinWeights(exactRates, exactEliminatedRateSum);
const numericalCurrentWins = helpers.calculateReversePlCurrentWinWeights(exactRates, exactEliminatedRateSum);
exactRates.forEach((unused, index) => {
  assertApprox(
    numericalDropout[index],
    exactDropout[index],
    2e-7,
    `Numerical dropout integral differs from exact subset expansion at index ${index}`
  );
  assertApprox(
    numericalCurrentWins[index],
    exactCurrentWins[index],
    2e-7,
    `Numerical current-win integral differs from exact subset expansion at index ${index}`
  );
});

const equalWeights = helpers.calculateReversePlDropoutWeights([7, 7, 7, 7], 0);
equalWeights.forEach(probability => {
  assertApprox(probability, 1 / 4, 1e-10, 'Equal rates do not have equal dropout chances');
});

const singleDropout = helpers.calculateReversePlDropoutWeights([42], 100);
const singleWin = helpers.calculateReversePlCurrentWinWeights([42], 100);
assert(singleDropout[0] === 1, 'A single active lot does not have dropout chance 1');
assert(singleWin[0] === 1, 'A single active lot does not have win chance 1');

const zeroBeforePositive = helpers.calculateReversePlDropoutWeights([0, 5, -2, Number.NaN, Number.POSITIVE_INFINITY], 10);
assert(zeroBeforePositive[0] === 1 / 4, 'Zero lot A is not selected uniformly');
assert(zeroBeforePositive[1] === 0, 'Positive lot can drop out while zero lots remain');
assert(zeroBeforePositive[2] === 1 / 4, 'Negative rate was not normalized to zero');
assert(zeroBeforePositive[3] === 1 / 4, 'NaN rate was not normalized to zero');
assert(zeroBeforePositive[4] === 1 / 4, 'Infinity rate was not normalized to zero');

const allZeroDropout = helpers.calculateReversePlDropoutWeights([0, 0, 0], 0);
allZeroDropout.forEach(probability => {
  assert(probability === 1 / 3, 'All-zero dropout chances are not uniform');
});
const lowLevelAllZeroWins = helpers.calculateReversePlCurrentWinWeights([0, -1, Number.NaN], 10);
lowLevelAllZeroWins.forEach(probability => {
  assert(probability === 1 / 3, 'Low-level all-zero win chances are not uniform');
});
const lowLevelMixedWins = helpers.calculateReversePlCurrentWinWeights([0, 4, 0, 6], 10);
assert(lowLevelMixedWins[0] === 0 && lowLevelMixedWins[2] === 0, 'Low-level zero lot has a positive win chance');
assertApprox(lowLevelMixedWins[1] + lowLevelMixedWins[3], 1, 1e-10, 'Low-level mixed win chances do not sum to one');
const allZeroEntries = createEntries([0, Number.NaN, -5], 'zero');
const allZeroWins = helpers.calculateReversePlCurrentWinChances(allZeroEntries, []);
assertProbabilityMap(allZeroWins, 3, 'All-zero current win chances');
for (const probability of allZeroWins.values()) {
  assert(probability === 1 / 3, 'All-zero current win chances are not uniform');
}

const initialEntries = createEntries([1, 2, 3], 'initial');
const initialAuctionChances = helpers.calculateAmountWinChances(initialEntries);
const initialWheelChances = helpers.calculateReversePlCurrentWinChances(initialEntries, []);
assertProbabilityMap(initialAuctionChances, 3, 'Initial auction chances');
assertProbabilityMap(initialWheelChances, 3, 'Initial wheel chances');
initialEntries.forEach(entry => {
  assertApprox(
    initialWheelChances.get(entry.id),
    initialAuctionChances.get(entry.id),
    1e-14,
    'Wheel chance differs from auction chance before the first dropout'
  );
});

const activeAfterC = createEntries([1, 2], 'conditional');
const eliminatedC = [{ id: 'conditional-c', name: 'C', price: 3, eliminated: true }];
const conditionalWins = helpers.calculateReversePlCurrentWinChances(activeAfterC, eliminatedC);
assertProbabilityMap(conditionalWins, 3, 'Conditional win chances after C dropped out');
assertApprox(conditionalWins.get('conditional-0'), 4 / 9, 3e-8, 'Conditional chance A=4/9 is wrong');
assertApprox(conditionalWins.get('conditional-1'), 5 / 9, 3e-8, 'Conditional chance B=5/9 is wrong');
assert(conditionalWins.get('conditional-c') === 0, 'Eliminated lot has a non-zero current win chance');

const mixedWinEntries = createEntries([0, 4, 0, 6], 'mixed-win');
const mixedWins = helpers.calculateReversePlCurrentWinChances(mixedWinEntries, []);
assertProbabilityMap(mixedWins, 4, 'Mixed zero/positive current win chances');
assert(mixedWins.get('mixed-win-0') === 0 && mixedWins.get('mixed-win-2') === 0, 'Zero lot has a positive win chance');
assertApprox(mixedWins.get('mixed-win-1'), 0.4, 1e-14, 'Positive mixed win chance A is wrong');
assertApprox(mixedWins.get('mixed-win-3'), 0.6, 1e-14, 'Positive mixed win chance B is wrong');

const variedEntries = createEntries(
  Array.from({ length: 34 }, (_, index) => 10 ** (-4 + (index * 10) / 33)),
  'varied'
);
const variedActive = variedEntries.slice(0, 27);
const variedEliminated = variedEntries.slice(27).map(entry => ({ ...entry, eliminated: true }));
const variedDropout = helpers.calculateReversePlDropoutChances(variedActive, variedEliminated);
const variedWins = helpers.calculateReversePlCurrentWinChances(variedActive, variedEliminated);
assertProbabilityMap(variedDropout, variedActive.length, 'Varied 34-lot dropout chances');
assertProbabilityMap(variedWins, variedEntries.length, 'Varied 34-lot current win chances');

const segments = [
  { entry: { id: 'first' }, weight: 0.2 },
  { entry: { id: 'middle' }, weight: 0.3 },
  { entry: { id: 'last' }, weight: 0.5 }
];
assert(
  helpers.getWheelSegmentByPointerOffset(0.1 * helpers.TWO_PI, segments).id === 'first',
  'Pointer inside the first sector selected the wrong lot'
);
assert(
  helpers.getWheelSegmentByPointerOffset(0.35 * helpers.TWO_PI, segments).id === 'middle',
  'Pointer inside the middle sector selected the wrong lot'
);
assert(
  helpers.getWheelSegmentByPointerOffset(helpers.TWO_PI - 1e-12, segments).id === 'last',
  'Pointer just below 2π did not select the last sector'
);
assert(
  helpers.getWheelSegmentByPointerOffset(0.2 * helpers.TWO_PI, segments).id === 'middle',
  'First sector boundary is not handled as a half-open interval'
);
assert(
  helpers.getWheelSegmentByPointerOffset(0.5 * helpers.TWO_PI, segments).id === 'last',
  'Middle sector boundary is not handled as a half-open interval'
);

const durationPlans = [1000, 10000, 60000].map(duration => (
  helpers.buildWheelSpinPlan(1.2345, duration, 0.73123456789, 10)
));
durationPlans.forEach(plan => {
  assertApprox(plan.finalAngle, durationPlans[0].finalAngle, 1e-14, 'Final angle depends on duration');
  assert(
    helpers.getWheelSegmentAtAngle(plan.finalAngle, segments).id
      === helpers.getWheelSegmentAtAngle(durationPlans[0].finalAngle, segments).id,
    'Victim depends on duration'
  );
});
assert(new Set(durationPlans.map(plan => plan.durationMs)).size === 3, 'Spin durations were not preserved');

assert(!source.includes('Math.random('), 'Math.random is present in the application');
assert(source.includes('function cryptoRandomFloat53()'), '53-bit WebCrypto random helper is missing');
assert(source.includes('getRandomValues(new Uint32Array(2))'), '53-bit random value is not built from two Uint32 values');
assert(!source.includes('function buildSpinSeriesDropoutQueue'), 'Precomputed dropout queue builder is still present');
assert(!source.includes('function ensureSpinSeriesDropoutQueue'), 'Precomputed dropout queue initializer is still present');

const descriptorStart = source.indexOf('    function buildAuthoritativeSpinDescriptor');
const descriptorEnd = source.indexOf('    function scheduleAuthoritativeSpinFinalization', descriptorStart);
const descriptorSource = source.slice(descriptorStart, descriptorEnd);
assert(descriptorStart >= 0 && descriptorEnd > descriptorStart, 'Authoritative descriptor helper not found');
assert(!descriptorSource.includes('victimId'), 'Authoritative descriptor still preselects victimId');
assert(!descriptorSource.includes('winnerId'), 'Authoritative descriptor still stores a future winner');
assert(descriptorSource.includes('cryptoRandomFloat53()'), 'Authoritative spin does not use the 53-bit random angle');

const saveStart = source.indexOf('    function saveData()');
const saveEnd = source.indexOf('    function openResetSiteDataModal', saveStart);
const saveSource = source.slice(saveStart, saveEnd);
assert(!saveSource.includes('dropoutQueue'), 'Saved state still contains a future dropout queue');
assert(!saveSource.includes('finalWinnerId'), 'Saved state still contains a future winner');
assert(!saveSource.includes('spinSeries:'), 'Saved state still contains the legacy spin series');

const startSpinStart = source.indexOf('    async function startSpinNow()');
const startSpinEnd = source.indexOf('    function closeSpinDonationsModal', startSpinStart);
const startSpinSource = source.slice(startSpinStart, startSpinEnd);
assert(startSpinSource.includes('const victim = getCurrentSegment('), 'Direct spin does not determine the victim from the final angle');
assert(!startSpinSource.includes('ensureSpinSeriesDropoutQueue'), 'Direct spin still reads a precomputed victim');
const directAnimationStart = startSpinSource.indexOf('      function animate(timestamp)');
const directAnimationEnd = startSpinSource.lastIndexOf('      requestAnimationFrame(animate);');
const directAnimationSource = startSpinSource.slice(directAnimationStart, directAnimationEnd);
assert(directAnimationStart >= 0 && directAnimationEnd > directAnimationStart, 'Direct wheel animation body not found');
assert(!directAnimationSource.includes('ensureReversePlProbabilityState'), 'Direct animation can recalculate Reverse PL probabilities inside requestAnimationFrame');
assert(!directAnimationSource.includes('calculateReversePl'), 'Direct animation integrates Reverse PL probabilities inside requestAnimationFrame');
assert(directAnimationSource.includes('drawWheel(probabilityState)'), 'Direct animation does not reuse the prepared probability snapshot');

const remoteAnimationStart = source.indexOf('    function animateWheelSpinDescriptor');
const remoteAnimationEnd = source.indexOf('    function readPersistedSpinRequestState', remoteAnimationStart);
const remoteAnimationSource = source.slice(remoteAnimationStart, remoteAnimationEnd);
assert(remoteAnimationStart >= 0 && remoteAnimationEnd > remoteAnimationStart, 'Remote wheel animation body not found');
assert(!remoteAnimationSource.includes('ensureReversePlProbabilityState'), 'Remote animation can recalculate Reverse PL probabilities inside requestAnimationFrame');
assert(!remoteAnimationSource.includes('calculateReversePl'), 'Remote animation integrates Reverse PL probabilities inside requestAnimationFrame');
assert(remoteAnimationSource.includes('drawWheel(probabilityState)'), 'Remote animation does not reuse the prepared probability snapshot');

const shrinkAnimationStart = source.indexOf('      function animateShrink(timestamp)');
const shrinkAnimationEnd = source.indexOf('      // Сохраняем ID анимации', shrinkAnimationStart);
const shrinkAnimationSource = source.slice(shrinkAnimationStart, shrinkAnimationEnd);
assert(shrinkAnimationStart >= 0 && shrinkAnimationEnd > shrinkAnimationStart, 'Sector shrink animation body not found');
assert(!shrinkAnimationSource.includes('ensureReversePlProbabilityState'), 'Sector shrink animation can recalculate Reverse PL probabilities inside requestAnimationFrame');
assert(!shrinkAnimationSource.includes('calculateReversePl'), 'Sector shrink animation integrates Reverse PL probabilities inside requestAnimationFrame');
assert(
  shrinkAnimationSource.includes('buildReversePlDisplayProbabilityState(')
    && shrinkAnimationSource.includes('drawWheel(displayProbabilityState)'),
  'Sector shrink animation does not interpolate the prepared probability snapshots'
);
const finishSpinStart = source.indexOf('    function finishSpinWithPointerVictim');
const targetStatePreparation = source.indexOf(
  'targetProbabilityState = calculateReversePlTargetProbabilityState(entries, victimRef);',
  finishSpinStart
);
assert(
  finishSpinStart >= 0 && targetStatePreparation > finishSpinStart && targetStatePreparation < shrinkAnimationStart,
  'Target Reverse PL state is not prepared before the shrink animation'
);
const shrinkCommitStart = shrinkAnimationSource.indexOf('const elimination = eliminateEntryAtCurrentPlace(victimRef);');
const shrinkCommitEnd = shrinkAnimationSource.indexOf('rememberCompletedSpinOutcome(', shrinkCommitStart);
const shrinkCommitSource = shrinkAnimationSource.slice(shrinkCommitStart, shrinkCommitEnd);
assert(shrinkCommitStart >= 0 && shrinkCommitEnd > shrinkCommitStart, 'Shrink commit sequence not found');
assert(
  shrinkCommitSource.includes('installReversePlProbabilityState(targetProbabilityState);'),
  'Target Reverse PL state is not installed immediately after elimination'
);
const deferredShrinkRenderStart = shrinkAnimationSource.indexOf('setTimeout(() => {', shrinkCommitEnd);
const deferredShrinkRenderEnd = shrinkAnimationSource.indexOf('}, 0);', deferredShrinkRenderStart);
const deferredShrinkRenderSource = shrinkAnimationSource.slice(deferredShrinkRenderStart, deferredShrinkRenderEnd);
assert(
  deferredShrinkRenderStart >= 0 && deferredShrinkRenderEnd > deferredShrinkRenderStart,
  'Deferred post-shrink render block not found'
);
assert(
  !deferredShrinkRenderSource.includes('drawWheel('),
  'Shrink commit performs an extra deferred wheel redraw'
);

const eliminationStart = source.indexOf('    function eliminateEntryAtCurrentPlace');
const eliminationEnd = source.indexOf('    function rememberCompletedSpinOutcome', eliminationStart);
if (eliminationStart < 0 || eliminationEnd < 0) throw new Error('Place assignment helper not found');
const placementEntries = createEntries([1, 2, 3, 4], 'place');
const placementHarness = new Function('initialEntries', `
  let entries = initialEntries;
  function invalidateReversePlProbabilityCache() {}
  ${source.slice(eliminationStart, eliminationEnd)}
  return { eliminateEntryAtCurrentPlace, getEntries: () => entries };
`)(placementEntries);
placementHarness.eliminateEntryAtCurrentPlace(placementEntries[1]);
assert(placementEntries[1].assignedPlace === 4, 'First dropout did not receive n-th place');
placementHarness.eliminateEntryAtCurrentPlace(placementEntries[2]);
assert(placementEntries[2].assignedPlace === 3, 'Second dropout did not receive (n-1)-th place');
const reloadedPlacementEntries = JSON.parse(JSON.stringify(placementHarness.getEntries()));
const reloadedPlacementHarness = new Function('initialEntries', `
  let entries = initialEntries;
  function invalidateReversePlProbabilityCache() {}
  ${source.slice(eliminationStart, eliminationEnd)}
  return { eliminateEntryAtCurrentPlace };
`)(reloadedPlacementEntries);
const finalElimination = reloadedPlacementHarness.eliminateEntryAtCurrentPlace(reloadedPlacementEntries[3]);
assert(reloadedPlacementEntries[1].assignedPlace === 4, 'Reload changed the first assigned place');
assert(reloadedPlacementEntries[2].assignedPlace === 3, 'Reload changed the second assigned place');
assert(reloadedPlacementEntries[3].assignedPlace === 2, 'Penultimate dropout did not receive second place');
assert(finalElimination.winner.id === 'place-0' && finalElimination.winner.assignedPlace === 1, 'Remaining lot did not receive first place');

assert(source.includes('(entry.eliminated ? eliminated : active).push(pair);'), 'Probability cache signature does not include active/eliminated state');
assert(source.includes('probabilitySignature') && source.includes('probabilityState.dropoutChances'), 'Wheel geometry is not keyed by Reverse PL probabilities');
assert(source.includes('Legacy spinSeries/dropoutQueue/finalWinnerId fields are deliberately ignored.'), 'Legacy queue fields are not explicitly ignored on load');

const performanceResults = [];
for (const size of [34, 100, 500]) {
  const active = createEntries(
    Array.from({ length: size }, (_, index) => (
      10 ** (-3 + ((index * 37) % 101) * 6 / 100)
    )),
    `perf-${size}`
  );
  const eliminated = [
    { id: `perf-${size}-out-a`, price: 17, eliminated: true },
    { id: `perf-${size}-out-b`, price: 1300, eliminated: true }
  ];
  const startedAt = performance.now();
  const dropout = helpers.calculateReversePlDropoutChances(active, eliminated);
  const wins = helpers.calculateReversePlCurrentWinChances(active, eliminated);
  const elapsedMs = performance.now() - startedAt;
  assertProbabilityMap(dropout, size, `Performance ${size}-lot dropout chances`);
  assertProbabilityMap(wins, size + eliminated.length, `Performance ${size}-lot win chances`);
  performanceResults.push({ size, elapsedMs });
}

performanceResults.forEach(({ size, elapsedMs }) => {
  console.log(`Reverse PL performance: ${size} lots = ${elapsedMs.toFixed(2)} ms`);
});
console.log('Random and Reverse Plackett–Luce logic tests ok');
