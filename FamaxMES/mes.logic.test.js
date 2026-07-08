// Self-check for the two bits of real MES logic that live inside the Vue pages:
//   1. daily-reset SO number: next number = max(today's running numbers) + 1, 5-padded
//   2. JO_Number -> so_number: first 3 "/"-segments (SO/ddmmyy/NNNNN)
// Run: node FamaxMES/mes.logic.test.js
const assert = require('assert');

function nextSoNumber(ddmmyy, existing) {
    const prefix = `SO/${ddmmyy}/`;
    let max = 0;
    existing.forEach(sn => {
        const m = String(sn).match(new RegExp('^SO/' + ddmmyy + '/(\\d+)'));
        if (m) max = Math.max(max, parseInt(m[1], 10));
    });
    return prefix + String(max + 1).padStart(5, '0');
}
const soOf = jo => String(jo).split('/').slice(0, 3).join('/');

// first order of the day
assert.strictEqual(nextSoNumber('070726', []), 'SO/070726/00001');
// increments past the max, ignores other days
assert.strictEqual(
    nextSoNumber('070726', ['SO/070726/00001', 'SO/070726/00002', 'SO/060726/00009']),
    'SO/070726/00003');
// non-sequential max still wins
assert.strictEqual(nextSoNumber('070726', ['SO/070726/00005']), 'SO/070726/00006');

// JO number -> owning SO number (item suffix stripped)
assert.strictEqual(soOf('SO/070726/00001/1'), 'SO/070726/00001');
assert.strictEqual(soOf('SO/070726/00042/3'), 'SO/070726/00042');

console.log('mes.logic.test.js: all assertions passed');
