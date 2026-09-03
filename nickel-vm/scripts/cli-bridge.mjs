import { eval_workflow } from '../dist/nickel_vm.js';
import fs from 'node:fs';

function failure(error) {
    return {
        exit: 1,
        stdout: '',
        stderr: error instanceof Error ? error.stack || error.message : String(error)
    };
}

function main() {
    try {
        const input = fs.readFileSync(0, 'utf8');
        if (!input) {
            throw new Error('Empty stdin');
        }

        const request = JSON.parse(input);
        const result = eval_workflow(request);
        process.stdout.write(`${JSON.stringify(result)}\n`);
    } catch (error) {
        process.stderr.write(`${JSON.stringify(failure(error))}\n`);
        process.exitCode = 1;
    }
}

main();
