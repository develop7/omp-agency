import { evaluateWorkflow, workflowFailure } from "./workflow-runtime.mjs";
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

async function main() {
    try {
        const input = readStdin();
        if (!input) {
            throw new Error("Empty stdin");
        }
        const result = await evaluateWorkflow(input);
        process.stdout.write(`${JSON.stringify(result)}\n`);
    } catch (error) {
        process.stderr.write(`${JSON.stringify(workflowFailure(error))}\n`);
        process.exitCode = 1;
    }
}

main();
