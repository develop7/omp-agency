import { eval_workflow } from '../dist/nickel_vm.js';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const WORKFLOW_SOURCE = fs.readFileSync(path.join(REPO_ROOT, 'skills/do/workflow.ncl'), 'utf8');
const VOCABULARY_SOURCE = fs.readFileSync(path.join(REPO_ROOT, 'skills/do/workflow-manifest.json'), 'utf8');

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

function workflowResult(operation, state, seed = null) {
    return eval_workflow({
        workflow_source: WORKFLOW_SOURCE,
        vocabulary_source: VOCABULARY_SOURCE,
        state_source: stateSource(state),
        operation,
        seed
    });
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

function run() {
    console.log('Running Nickel VM smoke tests...');

    const res1 = workflowResult('cli', TEST_STATE);
    assertResult('cli', res1);
    assert('cli', res1.stdout, GOLDENS.cli);

    const res2 = workflowResult('cli_seed', TEST_STATE, '');
    assertResult('cli_seed ""', res2);
    assert('cli_seed ""', res2.stdout, GOLDENS.cli_seed_empty);

    const res3 = workflowResult('cli_seed', TEST_STATE, 'followup');
    assertResult('cli_seed "followup"', res3);
    assert('cli_seed "followup"', res3.stdout, GOLDENS.cli_seed_followup);

    const invalidSeed = workflowResult('cli_seed', TEST_STATE, "\u0000\n\"\\雪");
    assert('cli_seed rejects an unknown nonempty entry point', invalidSeed.exit !== 0, true);

    for (const status of ["failed", "completed"]) {
        const terminal = workflowResult('cli', { ...TEST_STATE, status });
        assertResult(`cli respects ${status} workflow status`, terminal);
        assert(`cli respects ${status} workflow status`, terminal.stdout, `{ done = true }`);
    }

    const completedThroughCi = [
        "sync", "research", "branch", "implement", "check", "docs", "fmt",
        "commit", "hickey-lowy", "police", "test", "create-pr", "ci"
    ].map((name) => ({ name, status: "passed" }));
    const evidence = workflowResult('cli', { ...TEST_STATE, steps: completedThroughCi });
    assertResult('cli reaches evidence', evidence);
    assert(
        'cli reaches evidence',
        evidence.stdout,
        `{ step = "evidence", skip = false, pattern = 'one-shot, instructions = "nodes/evidence.md", requires = [], pattern_config = {} }`
    );

    for (const status of ["pending", "running", "in_progress"]) {
        const resumed = workflowResult('cli', { ...TEST_STATE, steps: [{ name: "ci", status }] });
        assertResult(`cli resumes ${status} step`, resumed);
        assert(`cli resumes ${status} step`, resumed.stdout.match(/step = "([^"]+)"/)?.[1], "ci");
    }

    const minimal = { ...TEST_STATE, minimal: true };
    const minimalSeed = workflowResult('cli_seed', minimal, '');
    assertResult('cli_seed minimal', minimalSeed);
    assert('cli_seed minimal', minimalSeed.stdout, GOLDENS.cli_seed_minimal);

    const minimalPolishSeed = workflowResult('cli_seed', minimal, 'polish');
    assertResult('cli_seed minimal polish', minimalPolishSeed);
    assert(
        'cli_seed minimal polish',
        minimalPolishSeed.stdout,
        `[{ name = "sync", initial_status = 'completed }, { name = "research", initial_status = 'completed }, { name = "branch", initial_status = 'completed }, { name = "implement", initial_status = 'completed }, { name = "check", initial_status = 'completed }, { name = "fmt", initial_status = 'completed }, { name = "commit", initial_status = 'completed }, { name = "test", initial_status = 'pending }, { name = "create-pr", initial_status = 'pending }, { name = "ci", initial_status = 'pending }, { name = "done", initial_status = 'pending }]`
    );
    const minimalPolishCli = workflowResult('cli', { ...minimal, from: 'polish' });
    assertResult('minimal cli polish', minimalPolishCli);
    assert('minimal cli polish', minimalPolishCli.stdout.match(/step = "([^"]+)"/)?.[1], 'test');

    const minimalPath = [
        "sync", "research", "branch", "implement", "check", "fmt", "commit",
        "test", "create-pr", "ci", "done"
    ];
    let minimalState = { ...minimal, steps: [] };
    for (const name of minimalPath) {
        const result = workflowResult('cli', minimalState);
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
    const minimalComplete = workflowResult('cli', minimalState);
    assertResult('minimal cli complete', minimalComplete);
    assert('minimal cli complete', minimalComplete.stdout, `{ done = true }`);
}

try {
    run();
} catch (error) {
    console.error(error instanceof Error ? error.message : error);
    process.exitCode = 1;
}
