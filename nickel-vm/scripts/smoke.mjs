import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { evaluateWorkflow } from './workflow-runtime.mjs';


const TEST_STATE = {
    active: "working",
    status: "running",
    steps: [],
    noVcs: false,
    minimal: false,
    review: false,
    forge: "github",
    supportsPrCreate: true,
    supportsPrComment: true,
    supportsIssueView: true,
    supportsPrChecks: true,
    task: "test"
};

function stateSource(state) {
    return JSON.stringify(state);
}


async function workflowResult(operation, state, seed) {
    const cwd = fs.mkdtempSync(path.join(os.tmpdir(), 'agency-workflow-'));
    try {
        fs.writeFileSync(path.join(cwd, '.do-results.json'), stateSource(state), 'utf8');
        const request = operation === 'cli'
            ? { operation, cwd }
            : { operation, seed, cwd };
        return await evaluateWorkflow(request);
    } finally {
        fs.rmSync(cwd, { recursive: true, force: true });
    }
}
function bridgeWorkflow(operation, cwd, seed) {
    const request = operation === 'cli'
        ? { operation, cwd }
        : { operation, seed, cwd };
    const bridge = fileURLToPath(new URL('./cli-bridge.mjs', import.meta.url));
    const result = spawnSync(process.execPath, [bridge], { input: JSON.stringify(request), encoding: 'utf8' });
    if (result.status !== 0) {
        throw new Error(`workflow bridge failed (exit ${result.status}): ${result.stderr}`);
    }
    return JSON.parse(result.stdout);
}
async function workflowParity(operation, state, seed) {
    const cwd = fs.mkdtempSync(path.join(os.tmpdir(), 'agency-workflow-'));
    try {
        fs.writeFileSync(path.join(cwd, '.do-results.json'), stateSource(state), 'utf8');
        const request = operation === 'cli' ? { operation, cwd } : { operation, seed, cwd };
        return { direct: await evaluateWorkflow(request), bridged: bridgeWorkflow(operation, cwd, seed) };
    } finally {
        fs.rmSync(cwd, { recursive: true, force: true });
    }
}


async function missingStateResult() {
    const cwd = fs.mkdtempSync(path.join(os.tmpdir(), 'agency-workflow-'));
    try {
        return await evaluateWorkflow({ operation: 'cli', cwd });
    } finally {
        fs.rmSync(cwd, { recursive: true, force: true });
    }
}


function assert(name, actual, expected) {
    if (actual === expected || JSON.stringify(actual) === JSON.stringify(expected)) {
        console.log(`${name} passed`);
    } else {
        console.error(`${name} failed`);
        console.error(`Expected: ${expected}`);
        console.error(`Actual:   ${actual}`);
        process.exitCode = 1;
        throw new Error(`smoke assertion failed: ${name}`);
    }
}

function assertResult(name, result) {
    if (result.exit !== 0) {
        throw new Error(`${name} evaluation failed (exit ${result.exit}): ${result.stderr || result.stdout}`);
    }
}

async function run() {
    console.log('Running Nickel VM smoke tests...');
    const missingState = await missingStateResult();
    assert('shared runtime reports missing state', missingState.exit, 1);
    assert('shared runtime failure carries null value', missingState.value, null);
    assert('shared runtime makes missing state actionable', missingState.stderr.includes('run do-driver init first'), true);

    const cliWithSeed = await evaluateWorkflow({ operation: 'cli', seed: 'default' });
    assert('cli rejects a seed', cliWithSeed.exit, 1);
    assert('cli rejection names seed', cliWithSeed.stderr.includes('cli does not accept a seed'), true);
    assert('cli rejection carries null value', cliWithSeed.value, null);

    const seedWithoutValue = await evaluateWorkflow({ operation: 'cli_seed' });
    assert('cli_seed rejects a missing seed', seedWithoutValue.exit, 1);
    assert('cli_seed missing seed rejection is actionable', seedWithoutValue.stderr.includes('cli_seed requires a string seed'), true);
    const seedWithNull = await evaluateWorkflow({ operation: 'cli_seed', seed: null });
    const cliParity = await workflowParity('cli', TEST_STATE);
    assertResult('direct cli', cliParity.direct);
    assertResult('bridged cli', cliParity.bridged);
    assert('bridge preserves direct cli value and rendering', [cliParity.bridged.value, cliParity.bridged.stdout], [cliParity.direct.value, cliParity.direct.stdout]);
    const seedParity = await workflowParity('cli_seed', TEST_STATE, '');
    assertResult('direct cli_seed', seedParity.direct);
    assertResult('bridged cli_seed', seedParity.bridged);
    assert('bridge preserves direct cli_seed value and rendering', [seedParity.bridged.value, seedParity.bridged.stdout], [seedParity.direct.value, seedParity.direct.stdout]);
    assert('cli_seed rejects a null seed', seedWithNull.exit, 1);
    assert('cli_seed null seed rejection is actionable', seedWithNull.stderr.includes('cli_seed requires a string seed'), true);

    const cli = await workflowResult('cli', TEST_STATE);
    assertResult('cli', cli);
    assert('cli carries semantic object', cli.value.step, 'sync');
    assert('cli carries semantic pattern config', cli.value.pattern_config, {});

    const seed = await workflowResult('cli_seed', TEST_STATE, '');
    assertResult('cli_seed', seed);
    assert('cli_seed carries array', Array.isArray(seed.value), true);
    assert('cli_seed carries ordered step names', seed.value.map(({ name }) => name).join(','), 'sync,research,branch,implement,check,docs,fmt,commit,hickey-lowy,police,test,create-pr,ci,evidence,done');

    const invalidSeed = await workflowResult('cli_seed', TEST_STATE, "\u0000\n\"\\雪");
    assert('cli_seed rejects unknown entry point', invalidSeed.exit !== 0, true);
    assert('cli_seed failure carries null value', invalidSeed.value, null);

    for (const status of ["failed", "completed"]) {
        const terminal = await workflowResult('cli', { ...TEST_STATE, status });
        assertResult(`cli terminal ${status}`, terminal);
        assert(`cli terminal ${status} carries done object`, terminal.value, { done: true });
    }

    const completedThroughCi = [
        "sync", "research", "branch", "implement", "check", "docs", "fmt",
        "commit", "hickey-lowy", "police", "test", "create-pr", "ci"
    ].map((name) => ({ name, status: "passed" }));
    const evidence = await workflowResult('cli', { ...TEST_STATE, steps: completedThroughCi });
    assertResult('cli reaches evidence', evidence);
    assert('cli reaches evidence semantically', evidence.value.step, 'evidence');

    const polishCli = await workflowResult('cli', { ...TEST_STATE, from: 'polish' });
    assertResult('cli polish', polishCli);
    assert('cli carries structured pattern configuration', polishCli.value.pattern_config, { cross_validate: true });

    const minimal = { ...TEST_STATE, minimal: true };
    const minimalSeed = await workflowResult('cli_seed', minimal, '');
    assertResult('cli_seed minimal', minimalSeed);
    assert('cli_seed minimal omits docs step', minimalSeed.value.some(({ name }) => name === 'docs'), false);

    const minimalPath = [
        "sync", "research", "branch", "implement", "check", "fmt", "commit",
        "test", "create-pr", "ci", "done"
    ];
    let minimalState = { ...minimal, steps: [] };
    for (const name of minimalPath) {
        const result = await workflowResult('cli', minimalState);
        assertResult(`minimal cli ${name}`, result);
        assert(`minimal cli ${name} semantic step`, result.value.step, name);
        assert(`minimal cli ${name} skip flag`, result.value.skip, false);
        minimalState = {
            ...minimalState,
            steps: [...minimalState.steps, { name, status: "passed" }]
        };
    }
    const minimalComplete = await workflowResult('cli', minimalState);
    assertResult('minimal cli complete', minimalComplete);
    assert('minimal cli completion carries done object', minimalComplete.value, { done: true });
}

run().catch((error) => {
    console.error(error instanceof Error ? error.message : error);
    process.exitCode = 1;
});
