import { eval_workflow } from '../dist/nickel_vm.js';
import fs from 'node:fs';

const MAX_STDIN_BYTES = 10 * 1024 * 1024;

function readStdin() {
    const chunks = [];
    const chunk = Buffer.allocUnsafe(64 * 1024);
    let total = 0;
    let bytesRead;
    do {
        bytesRead = fs.readSync(0, chunk, 0, chunk.length, null);
        total += bytesRead;
        if (total > MAX_STDIN_BYTES) {
            throw new Error(`stdin exceeds ${MAX_STDIN_BYTES} byte limit`);
        }
        if (bytesRead > 0) {
            chunks.push(Buffer.from(chunk.subarray(0, bytesRead)));
        }
    } while (bytesRead > 0);
    return Buffer.concat(chunks).toString('utf8');
}
function failure(error) {
    return {
        exit: 1,
        stdout: '',
        stderr: error instanceof Error ? error.stack || error.message : String(error)
    };
}

function main() {
    try {
        const input = readStdin();
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
