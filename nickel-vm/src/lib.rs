//! Nickel WASM evaluator for the /do workflow tool.
//!
//! Exposes a single `eval_workflow` entry point that evaluates the workflow
//! tool contract (`skills/do/workflow.ncl`) against an in-memory state
//! document, entirely in-process — no system `nickel` binary involved.

use nickel_lang_core::{
    cache::{CacheHub, InputFormat, SourcePath},
    error::NullReporter,
    eval::{cache::CacheImpl, value::NickelValue, VmContext, VirtualMachine},
    serialize::{to_string, ExportFormat},
};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use wasm_bindgen::prelude::*;

/// Inputs for one in-process `/do` workflow evaluation.
///
/// Each variant registers the same in-memory workflow sources, while the
/// operation-specific fields are decoded at the WASM request boundary.
#[derive(Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case", deny_unknown_fields)]
pub enum WorkflowRequest {
    Cli {
        workflow_source: String,
        vocabulary_source: String,
        state_source: String,
    },
    CliSeed {
        workflow_source: String,
        vocabulary_source: String,
        state_source: String,
        seed: String,
    },
}

/// The exit status and captured streams returned by the WASM evaluator.
///
/// On success `stdout` contains a JSON document serialized by the evaluated
/// Nickel expression. Its structure remains owned by the workflow and its
/// consumer; this evaluator only transports it.
#[derive(Serialize)]
pub struct WorkflowResult {
    pub exit: u32,
    pub stdout: String,
    pub stderr: String,
}

/// Evaluate one `/do` workflow request against in-memory source documents.
///
/// The returned JavaScript object always has `exit`, `stdout`, and `stderr`
/// fields. Successful `stdout` is the workflow's JSON serialization. Request
/// decoding and Nickel evaluation failures use a non-zero exit status and
/// diagnostic stderr text.
#[wasm_bindgen]
pub fn eval_workflow(req: JsValue) -> JsValue {
    let result = serde_wasm_bindgen::from_value(req)
        .map(evaluate_workflow)
        .unwrap_or_else(|error| {
            WorkflowResult {
                exit: 1,
                stdout: String::new(),
                stderr: format!("Request parsing failed: {}", error),
            }
        });
    serde_wasm_bindgen::to_value(&result).unwrap()
}

fn evaluate_workflow(request: WorkflowRequest) -> WorkflowResult {
    let (workflow_source, vocabulary_source, state_source, invocation_expr, seed_source) =
        match request {
            WorkflowRequest::Cli {
                workflow_source,
                vocabulary_source,
                state_source,
            } => (
                workflow_source,
                vocabulary_source,
                state_source,
                "let workflow = import \"%inmem_src%:workflow.ncl\" in \
                 let state = workflow.normalize_state (import \"%inmem_src%:.do-results.json\") in \
                 workflow.cli state"
                    .to_owned(),
                None,
            ),
            WorkflowRequest::CliSeed {
                workflow_source,
                vocabulary_source,
                state_source,
                seed,
            } => {
                let seed_source = match serde_json::to_string(&seed) {
                    Ok(source) => source,
                    Err(e) => {
                        return WorkflowResult {
                            exit: 1,
                            stdout: String::new(),
                            stderr: format!("Seed serialization failed: {:?}", e),
                        }
                    }
                };
                (
                    workflow_source,
                    vocabulary_source,
                    state_source,
                    "let workflow = import \"%inmem_src%:workflow.ncl\" in \
                     let state = workflow.normalize_state (import \"%inmem_src%:.do-results.json\") in \
                     let seed = import \"%inmem_src%:seed.json\" in \
                     workflow.cli_seed seed state"
                        .to_owned(),
                    Some(seed_source),
                )
            }
        };

    let mut cache = CacheHub::new();
    if let Err(e) = cache.load_stdlib() {
        return WorkflowResult {
            exit: 1,
            stdout: String::new(),
            stderr: format!("Stdlib load failed: {:?}", e),
        };
    }

    // Nickel's resolver recognizes the `%inmem_src%:` prefix and strips it
    // before looking up these SourcePath::Path entries. This keeps the workflow,
    // vocabulary, and state as separate inputs without merging state into the
    // workflow record.
    let main_id = cache.sources.add_string(
        SourcePath::Path(PathBuf::from("main.ncl"), InputFormat::Nickel),
        invocation_expr,
    );
    cache.sources.add_string(
        SourcePath::Path(PathBuf::from("workflow.ncl"), InputFormat::Nickel),
        workflow_source,
    );
    cache.sources.add_string(
        SourcePath::Path(PathBuf::from("workflow-manifest.json"), InputFormat::Json),
        vocabulary_source,
    );
    cache.sources.add_string(
        SourcePath::Path(PathBuf::from(".do-results.json"), InputFormat::Json),
        state_source,
    );
    if let Some(seed_source) = seed_source {
        cache.sources.add_string(
            SourcePath::Path(PathBuf::from("seed.json"), InputFormat::Json),
            seed_source,
        );
    }

    let mut vm_ctxt: VmContext<CacheHub, CacheImpl> =
        VmContext::new(cache, std::io::sink(), NullReporter {});
    let result = match vm_ctxt.prepare_eval(main_id) {
        Ok(prepared) => {
            let mut vm = VirtualMachine::new(&mut vm_ctxt);
            match vm.eval_full(prepared) {
                Ok(evaled) => match serialize_value(&evaled) {
                    Ok(stdout) => WorkflowResult {
                        exit: 0,
                        stdout,
                        stderr: String::new(),
                    },
                    Err(stderr) => WorkflowResult {
                        exit: 1,
                        stdout: String::new(),
                        stderr,
                    },
                },
                Err(e) => WorkflowResult {
                    exit: 1,
                    stdout: String::new(),
                    stderr: format!("{:?}", e),
                },
            }
        }
        Err(e) => WorkflowResult {
            exit: 1,
            stdout: String::new(),
            stderr: format!("{:?}", e),
        },
    };
    result
}

fn serialize_value(value: &NickelValue) -> Result<String, String> {
    to_string(ExportFormat::Json, value)
        .map_err(|error| format!("JSON wire serialization failed: {:?}", error))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    fn workflow_sources() -> (String, String, String) {
        (
            include_str!("../../skills/do/workflow.ncl").to_owned(),
            include_str!("../../skills/do/workflow-manifest.json").to_owned(),
            json!({
                "active": "working",
                "status": "running",
                "steps": [],
                "noVcs": false,
                "minimal": false,
                "review": false,
                "forge": "github",
                "supportsPrCreate": true,
                "supportsPrComment": true,
                "supportsIssueView": true,
                "supportsPrChecks": true,
                "task": "test",
            })
            .to_string(),
        )
    }

    fn cli_request() -> WorkflowRequest {
        let (workflow_source, vocabulary_source, state_source) = workflow_sources();
        WorkflowRequest::Cli {
            workflow_source,
            vocabulary_source,
            state_source,
        }
    }

    fn cli_seed_request(seed: &str) -> WorkflowRequest {
        let (workflow_source, vocabulary_source, state_source) = workflow_sources();
        WorkflowRequest::CliSeed {
            workflow_source,
            vocabulary_source,
            state_source,
            seed: seed.to_owned(),
        }
    }

    fn structured_output(result: WorkflowResult) -> Value {
        assert_eq!(result.exit, 0, "{}", result.stderr);
        assert!(result.stderr.is_empty());
        serde_json::from_str(&result.stdout).expect("evaluator stdout must be JSON")
    }

    #[test]
    fn wasm_request_rejects_contradictory_seed_states() {
        assert!(serde_json::from_value::<WorkflowRequest>(json!({
            "workflow_source": "workflow",
            "vocabulary_source": "{}",
            "state_source": "{}",
            "operation": "cli",
            "seed": "default",
        }))
        .is_err());
        assert!(serde_json::from_value::<WorkflowRequest>(json!({
            "workflow_source": "workflow",
            "vocabulary_source": "{}",
            "state_source": "{}",
            "operation": "cli_seed",
        }))
        .is_err());
        assert!(serde_json::from_value::<WorkflowRequest>(json!({
            "workflow_source": "workflow",
            "vocabulary_source": "{}",
            "state_source": "{}",
            "operation": "cli_seed",
            "seed": null,
        }))
        .is_err());

        assert!(matches!(
            serde_json::from_value::<WorkflowRequest>(json!({
                "workflow_source": "workflow",
                "vocabulary_source": "{}",
                "state_source": "{}",
                "operation": "cli_seed",
                "seed": "",
            })),
            Ok(WorkflowRequest::CliSeed { seed, .. }) if seed.is_empty()
        ));
    }

    #[test]
    fn cli_returns_a_structured_next_step() {
        assert_eq!(
            structured_output(evaluate_workflow(cli_request())),
            json!({
                "step": "sync",
                "skip": false,
                "pattern": "one-shot",
                "instructions": "nodes/sync.md",
                "requires": [],
                "pattern_config": {},
            })
        );
    }

    #[test]
    fn cli_seed_returns_a_structured_step_list() {
        assert_eq!(
            structured_output(evaluate_workflow(cli_seed_request(""))),
            json!([
                {"name": "sync", "initial_status": "pending"},
                {"name": "research", "initial_status": "pending"},
                {"name": "branch", "initial_status": "pending"},
                {"name": "implement", "initial_status": "pending"},
                {"name": "check", "initial_status": "pending"},
                {"name": "docs", "initial_status": "pending"},
                {"name": "fmt", "initial_status": "pending"},
                {"name": "commit", "initial_status": "pending"},
                {"name": "hickey-lowy", "initial_status": "pending"},
                {"name": "police", "initial_status": "pending"},
                {"name": "test", "initial_status": "pending"},
                {"name": "create-pr", "initial_status": "pending"},
                {"name": "ci", "initial_status": "pending"},
                {"name": "evidence", "initial_status": "pending"},
                {"name": "done", "initial_status": "pending"},
            ])
        );
    }
}


