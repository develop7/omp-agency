import { eval_workflow } from '../dist/nickel_vm.js';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const WORKFLOW_SOURCE = fs.readFileSync(path.join(REPO_ROOT, 'skills/do/workflow.ncl'), 'utf8');

const TEST_STATE = JSON.stringify({
    active: true,
    status: "running",
    steps: [],
    noVcs: false,
    minimal: false,
    review: false,
    forge: "github",
    has_evidence: false,
    supportsPrCreate: true,
    supportsPrComment: true,
    supportsIssueView: true,
    supportsPrChecks: true,
    task: "test"
});

const GOLDENS = {
    cli: `{ step = "sync", skip = false, pattern = 'one-shot, instructions = "nodes/sync.md", requires = [], pattern_config = {} }`,
    cli_seed_empty: `[{ name = "sync", initial_status = 'pending }, { name = "research", initial_status = 'pending }, { name = "branch", initial_status = 'pending }, { name = "implement", initial_status = 'pending }, { name = "check", initial_status = 'pending }, { name = "docs", initial_status = 'pending }, { name = "fmt", initial_status = 'pending }, { name = "commit", initial_status = 'pending }, { name = "hickey-lowy", initial_status = 'pending }, { name = "police", initial_status = 'pending }, { name = "test", initial_status = 'pending }, { name = "create-pr", initial_status = 'pending }, { name = "ci", initial_status = 'pending }, { name = "evidence", initial_status = 'pending }, { name = "done", initial_status = 'pending }]`,
    cli_seed_followup: `[{ name = "sync", initial_status = 'completed }, { name = "research", initial_status = 'completed }, { name = "branch", initial_status = 'completed }, { name = "implement", initial_status = 'pending }, { name = "check", initial_status = 'pending }, { name = "docs", initial_status = 'pending }, { name = "fmt", initial_status = 'pending }, { name = "commit", initial_status = 'pending }, { name = "hickey-lowy", initial_status = 'pending }, { name = "police", initial_status = 'pending }, { name = "test", initial_status = 'pending }, { name = "create-pr", initial_status = 'pending }, { name = "ci", initial_status = 'pending }, { name = "evidence", initial_status = 'pending }, { name = "done", initial_status = 'pending }]`
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

    const res1 = eval_workflow({
        workflow_source: WORKFLOW_SOURCE,
        state_source: TEST_STATE,
        operation: 'cli',
        seed: null
    });
    assertResult('cli', res1);
    assert('cli', res1.stdout, GOLDENS.cli);

    const res2 = eval_workflow({
        workflow_source: WORKFLOW_SOURCE,
        state_source: TEST_STATE,
        operation: 'cli_seed',
        seed: ''
    });
    assertResult('cli_seed ""', res2);
    assert('cli_seed ""', res2.stdout, GOLDENS.cli_seed_empty);

    const res3 = eval_workflow({
        workflow_source: WORKFLOW_SOURCE,
        state_source: TEST_STATE,
        operation: 'cli_seed',
        seed: 'followup'
    });
    assertResult('cli_seed "followup"', res3);
    assert('cli_seed "followup"', res3.stdout, GOLDENS.cli_seed_followup);

    console.log('All smoke tests passed!');
}

try {
    run();
} catch (error) {
    console.error(error instanceof Error ? error.message : error);
    process.exitCode = 1;
}
