import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
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


async function workflowResult(operation, state, seed = null) {
    const cwd = fs.mkdtempSync(path.join(os.tmpdir(), 'agency-workflow-'));
    try {
        fs.writeFileSync(path.join(cwd, '.do-results.json'), stateSource(state), 'utf8');
        return await evaluateWorkflow({ operation, seed, cwd });
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

const GOLDENS = {
    cli: `{ step = "sync", skip = false, pattern = 'one-shot, instructions = "nodes/sync.md", requires = [], pattern_config = {} }`,
    cli_seed_empty: `[{ name = "sync", initial_status = 'pending }, { name = "research", initial_status = 'pending }, { name = "branch", initial_status = 'pending }, { name = "implement", initial_status = 'pending }, { name = "check", initial_status = 'pending }, { name = "docs", initial_status = 'pending }, { name = "fmt", initial_status = 'pending }, { name = "commit", initial_status = 'pending }, { name = "hickey-lowy", initial_status = 'pending }, { name = "police", initial_status = 'pending }, { name = "test", initial_status = 'pending }, { name = "create-pr", initial_status = 'pending }, { name = "ci", initial_status = 'pending }, { name = "evidence", initial_status = 'pending }, { name = "done", initial_status = 'pending }]`,
    cli_seed_followup: `[{ name = "sync", initial_status = 'completed }, { name = "research", initial_status = 'completed }, { name = "branch", initial_status = 'completed }, { name = "implement", initial_status = 'pending }, { name = "check", initial_status = 'pending }, { name = "docs", initial_status = 'pending }, { name = "fmt", initial_status = 'pending }, { name = "commit", initial_status = 'pending }, { name = "hickey-lowy", initial_status = 'pending }, { name = "police", initial_status = 'pending }, { name = "test", initial_status = 'pending }, { name = "create-pr", initial_status = 'pending }, { name = "ci", initial_status = 'pending }, { name = "evidence", initial_status = 'pending }, { name = "done", initial_status = 'pending }]`,
    cli_seed_minimal: `[{ name = "sync", initial_status = 'pending }, { name = "research", initial_status = 'pending }, { name = "branch", initial_status = 'pending }, { name = "implement", initial_status = 'pending }, { name = "check", initial_status = 'pending }, { name = "fmt", initial_status = 'pending }, { name = "commit", initial_status = 'pending }, { name = "test", initial_status = 'pending }, { name = "create-pr", initial_status = 'pending }, { name = "ci", initial_status = 'pending }, { name = "done", initial_status = 'pending }]`
};

function assert(name, actual, expected) {
    if (actual === expected) {
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
    assert(
        'shared runtime makes missing state actionable',
        missingState.stderr.includes('run do-driver init first'),
        true,
    );


    const res1 = await workflowResult('cli', TEST_STATE);
    assertResult('cli', res1);
    assert('cli', res1.stdout, GOLDENS.cli);

    const res2 = await workflowResult('cli_seed', TEST_STATE, '');
    assertResult('cli_seed ""', res2);
    assert('cli_seed ""', res2.stdout, GOLDENS.cli_seed_empty);

    const res3 = await workflowResult('cli_seed', TEST_STATE, 'followup');
    assertResult('cli_seed "followup"', res3);
    assert('cli_seed "followup"', res3.stdout, GOLDENS.cli_seed_followup);

    const invalidSeed = await workflowResult('cli_seed', TEST_STATE, "\u0000\n\"\\雪");
    assert('cli_seed rejects an unknown nonempty entry point', invalidSeed.exit !== 0, true);

    for (const status of ["failed", "completed"]) {
        const terminal = await workflowResult('cli', { ...TEST_STATE, status });
        assertResult(`cli respects ${status} workflow status`, terminal);
        assert(`cli respects ${status} workflow status`, terminal.stdout, `{ done = true }`);
    }

    const completedThroughCi = [
        "sync", "research", "branch", "implement", "check", "docs", "fmt",
        "commit", "hickey-lowy", "police", "test", "create-pr", "ci"
    ].map((name) => ({ name, status: "passed" }));
    const evidence = await workflowResult('cli', { ...TEST_STATE, steps: completedThroughCi });
    assertResult('cli reaches evidence', evidence);
    assert(
        'cli reaches evidence',
        evidence.stdout,
        `{ step = "evidence", skip = false, pattern = 'one-shot, instructions = "nodes/evidence.md", requires = [], pattern_config = {} }`
    );

    for (const status of ["pending", "running", "in_progress"]) {
        const resumed = await workflowResult('cli', { ...TEST_STATE, steps: [{ name: "ci", status }] });
        assertResult(`cli resumes ${status} step`, resumed);
        assert(`cli resumes ${status} step`, resumed.stdout.match(/step = "([^"]+)"/)?.[1], "ci");
    }

    const polishCli = await workflowResult('cli', { ...TEST_STATE, from: 'polish' });
    assertResult('cli polish', polishCli);
    assert(
        'cli renders structured pattern configuration',
        polishCli.stdout,
        `{ step = "hickey-lowy", skip = false, pattern = 'fanout-fix, instructions = "nodes/hickey-lowy.md", requires = ["diff", "research.context"], pattern_config = { cross_validate = true } }`,
    );

    const minimal = { ...TEST_STATE, minimal: true };
    const minimalSeed = await workflowResult('cli_seed', minimal, '');
    assertResult('cli_seed minimal', minimalSeed);
    assert('cli_seed minimal', minimalSeed.stdout, GOLDENS.cli_seed_minimal);

    const minimalPolishSeed = await workflowResult('cli_seed', minimal, 'polish');
    assertResult('cli_seed minimal polish', minimalPolishSeed);
    assert(
        'cli_seed minimal polish',
        minimalPolishSeed.stdout,
        `[{ name = "sync", initial_status = 'completed }, { name = "research", initial_status = 'completed }, { name = "branch", initial_status = 'completed }, { name = "implement", initial_status = 'completed }, { name = "check", initial_status = 'completed }, { name = "fmt", initial_status = 'completed }, { name = "commit", initial_status = 'completed }, { name = "test", initial_status = 'pending }, { name = "create-pr", initial_status = 'pending }, { name = "ci", initial_status = 'pending }, { name = "done", initial_status = 'pending }]`
    );
    const minimalPolishCli = await workflowResult('cli', { ...minimal, from: 'polish' });
    assertResult('minimal cli polish', minimalPolishCli);
    assert('minimal cli polish', minimalPolishCli.stdout.match(/step = "([^"]+)"/)?.[1], 'test');

    const minimalPath = [
        "sync", "research", "branch", "implement", "check", "fmt", "commit",
        "test", "create-pr", "ci", "done"
    ];
    let minimalState = { ...minimal, steps: [] };
    for (const name of minimalPath) {
        const result = await workflowResult('cli', minimalState);
        assertResult(`minimal cli ${name}`, result);
        const step = result.stdout.match(/step = "([^"]+)"/)?.[1];
        assert(`minimal cli ${name}`, step, name);
        if (!result.stdout.includes("skip = false")) {
            throw new Error(`minimal cli ${name} emitted a phantom skip: ${result.stdout}`);
        }
        minimalState = {
            ...minimalState,
            steps: [...minimalState.steps, { name, status: "passed" }]
        };
    }
    const minimalComplete = await workflowResult('cli', minimalState);
    assertResult('minimal cli complete', minimalComplete);
    assert('minimal cli complete', minimalComplete.stdout, `{ done = true }`);
}

run().catch((error) => {
    console.error(error instanceof Error ? error.message : error);
    process.exitCode = 1;
});
