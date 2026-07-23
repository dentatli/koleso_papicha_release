'use strict';

const fs = require('fs');
const path = require('path');

const source = fs.readFileSync(
  path.join(__dirname, '..', 'koleso_papich.html'),
  'utf8'
).replace(/\r\n?/g, '\n');
const coreStart = source.indexOf('    // Reverse Plackett–Luce numerical core.');
const coreEnd = source.indexOf('    // End Reverse Plackett–Luce numerical core.', coreStart);
if (coreStart < 0 || coreEnd < 0) throw new Error('Reverse Plackett–Luce numerical core not found');
const { calculateReversePlDropoutWeights } = new Function(`${source.slice(coreStart, coreEnd)}
  return { calculateReversePlDropoutWeights };
`)();

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function createSeededRandom(seed) {
  let state = seed >>> 0;
  return () => {
    state ^= state << 13;
    state ^= state >>> 17;
    state ^= state << 5;
    return (state >>> 0) / 4294967296;
  };
}

function sampleIndex(weights, random) {
  const value = random();
  let cumulative = 0;
  for (let index = 0; index < weights.length; index += 1) {
    cumulative += weights[index];
    if (value < cumulative) return index;
  }
  return weights.length - 1;
}

function createMetrics(participantCount) {
  return {
    places: Array.from({ length: participantCount }, () => new Uint32Array(participantCount)),
    rankSums: new Float64Array(participantCount)
  };
}

function recordRanking(metrics, ranking) {
  ranking.forEach((participant, rankIndex) => {
    metrics.places[participant][rankIndex] += 1;
    metrics.rankSums[participant] += rankIndex + 1;
  });
}

function simulateTopDown(weights, sampleCount, seed) {
  const random = createSeededRandom(seed);
  const metrics = createMetrics(weights.length);
  for (let sample = 0; sample < sampleCount; sample += 1) {
    const remaining = weights.map((weight, participant) => ({ weight, participant }));
    const ranking = [];
    while (remaining.length > 0) {
      const total = remaining.reduce((sum, item) => sum + item.weight, 0);
      const selected = sampleIndex(remaining.map(item => item.weight / total), random);
      ranking.push(remaining[selected].participant);
      remaining.splice(selected, 1);
    }
    recordRanking(metrics, ranking);
  }
  return metrics;
}

function simulateReverse(weights, sampleCount, seed) {
  const random = createSeededRandom(seed);
  const participantCount = weights.length;
  const fullMask = (1 << participantCount) - 1;
  const totalRate = weights.reduce((sum, weight) => sum + weight, 0);
  const probabilityCache = new Map();
  const metrics = createMetrics(participantCount);

  function getState(mask) {
    if (probabilityCache.has(mask)) return probabilityCache.get(mask);
    const participants = [];
    const activeRates = [];
    let activeRateSum = 0;
    for (let participant = 0; participant < participantCount; participant += 1) {
      if ((mask & (1 << participant)) === 0) continue;
      participants.push(participant);
      activeRates.push(weights[participant]);
      activeRateSum += weights[participant];
    }
    const probabilities = calculateReversePlDropoutWeights(
      activeRates,
      totalRate - activeRateSum,
      { quadraturePoints: 513 }
    );
    const state = { participants, probabilities };
    probabilityCache.set(mask, state);
    return state;
  }

  for (let sample = 0; sample < sampleCount; sample += 1) {
    let mask = fullMask;
    const ranking = new Array(participantCount);
    for (let rankIndex = participantCount - 1; rankIndex > 0; rankIndex -= 1) {
      const state = getState(mask);
      const selectedIndex = sampleIndex(state.probabilities, random);
      const participant = state.participants[selectedIndex];
      ranking[rankIndex] = participant;
      mask &= ~(1 << participant);
    }
    ranking[0] = getState(mask).participants[0];
    recordRanking(metrics, ranking);
  }
  return { metrics, cachedStates: probabilityCache.size };
}

function participantTopChance(metrics, participant, topCount, sampleCount) {
  let count = 0;
  for (let rank = 0; rank < Math.min(topCount, metrics.places.length); rank += 1) {
    count += metrics.places[participant][rank];
  }
  return count / sampleCount;
}

const longRun = process.argv.includes('--long');
const sampleCount = longRun ? 200000 : 20000;
const weights = [1, 1.4, 2, 2.7, 3.5, 4.6, 6, 7.8, 10, 13, 17, 23];
const topDown = simulateTopDown(weights, sampleCount, 0x13f00d);
const reverseResult = simulateReverse(weights, sampleCount, 0x5eed1234);
const reverse = reverseResult.metrics;
const cellTolerance = longRun ? 0.008 : 0.022;
const aggregateTolerance = longRun ? 0.008 : 0.022;
const meanRankTolerance = longRun ? 0.08 : 0.2;
let maxCellDifference = 0;
let maxWinnerDifference = 0;
let maxMeanRankDifference = 0;
let maxTop3Difference = 0;
let maxTop10Difference = 0;

for (let participant = 0; participant < weights.length; participant += 1) {
  for (let rank = 0; rank < weights.length; rank += 1) {
    const difference = Math.abs(
      topDown.places[participant][rank] / sampleCount
      - reverse.places[participant][rank] / sampleCount
    );
    maxCellDifference = Math.max(maxCellDifference, difference);
    assert(difference <= cellTolerance, `Participant/place matrix differs beyond noise: p=${participant}, rank=${rank + 1}`);
  }
  const winnerDifference = Math.abs(
    topDown.places[participant][0] / sampleCount
    - reverse.places[participant][0] / sampleCount
  );
  const meanRankDifference = Math.abs(
    topDown.rankSums[participant] / sampleCount
    - reverse.rankSums[participant] / sampleCount
  );
  const top3Difference = Math.abs(
    participantTopChance(topDown, participant, 3, sampleCount)
    - participantTopChance(reverse, participant, 3, sampleCount)
  );
  const top10Difference = Math.abs(
    participantTopChance(topDown, participant, 10, sampleCount)
    - participantTopChance(reverse, participant, 10, sampleCount)
  );
  maxWinnerDifference = Math.max(maxWinnerDifference, winnerDifference);
  maxMeanRankDifference = Math.max(maxMeanRankDifference, meanRankDifference);
  maxTop3Difference = Math.max(maxTop3Difference, top3Difference);
  maxTop10Difference = Math.max(maxTop10Difference, top10Difference);
  assert(winnerDifference <= aggregateTolerance, `Winner distribution differs beyond noise for participant ${participant}`);
  assert(meanRankDifference <= meanRankTolerance, `Mean rank differs beyond noise for participant ${participant}`);
  assert(top3Difference <= aggregateTolerance, `Top-3 distribution differs beyond noise for participant ${participant}`);
  assert(top10Difference <= aggregateTolerance, `Top-10 distribution differs beyond noise for participant ${participant}`);
}

console.log(JSON.stringify({
  mode: longRun ? 'long' : 'quick',
  samples: sampleCount,
  participants: weights.length,
  cachedReverseStates: reverseResult.cachedStates,
  maxWinnerDifference,
  maxMeanRankDifference,
  maxTop3Difference,
  maxTop10Difference,
  maxParticipantPlaceDifference: maxCellDifference
}, null, 2));
console.log('Reverse Plackett–Luce statistical equivalence test ok');
