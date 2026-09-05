export type WorkflowRequest =
  | {
      operation: "cli";
      cwd?: string;
    }
  | {
      operation: "cli_seed";
      seed: string;
      cwd?: string;
    };

/** Public result envelope. `stdout` is rendered in the legacy Nickel-text workflow protocol. */
export type WorkflowResult = {
  exit: number;
  stdout: string;
  stderr: string;
};

/** Evaluate a /do workflow from its operation, seed, and working directory. */
export function evaluateWorkflow(request: WorkflowRequest | string): Promise<WorkflowResult>;

/** Convert a runtime or framing error into the workflow result protocol. */
export function workflowFailure(error: unknown): WorkflowResult;
