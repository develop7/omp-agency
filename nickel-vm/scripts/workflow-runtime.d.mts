export type WorkflowRequest =
  | {
      operation: "cli";
      /** Non-empty workflow state JSON text read by the caller from the ledger. */
      state_source: string;
      /** Working directory used only for the workflow-asset fallback. */
      cwd?: string;
    }
  | {
      operation: "cli_seed";
      seed: string;
      /** Non-empty workflow state JSON text read by the caller from the ledger. */
      state_source: string;
      /** Working directory used only for the workflow-asset fallback. */
      cwd?: string;
    };

/** Public result envelope. `stdout` retains legacy Nickel rendering; `value` carries validated JSON semantics on success and null on failure. */
export type WorkflowResult = {
  exit: number;
  stdout: string;
  stderr: string;
  value: unknown | null;
};

/**
 * Evaluate a /do workflow from its operation, seed, supplied state text, and
 * asset working directory.
 */
export function evaluateWorkflow(request: WorkflowRequest | string): Promise<WorkflowResult>;

/** Convert a runtime or framing error into the workflow result protocol. */
export function workflowFailure(error: unknown): WorkflowResult;
