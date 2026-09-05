//! Nickel WASM evaluator for the /do workflow tool.
//!
//! Exposes a single `eval_workflow` entry point that evaluates the workflow
//! tool contract (`skills/do/workflow.ncl`) against an in-memory state
//! document, entirely in-process — no system `nickel` binary involved.

use nickel_lang_core::{
    cache::{CacheHub, InputFormat, SourcePath},
    error::NullReporter,
    eval::{cache::CacheImpl, value::NickelValue, VmContext, VirtualMachine},
    pretty::{Allocator, Pretty},
};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use wasm_bindgen::prelude::*;

/// A workflow operation accepted by the WASM evaluator.
///
/// Serde rejects every operation other than the two workflow entry points at
/// the request boundary, before any Nickel source is evaluated.
#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkflowOperation {
    Cli,
    CliSeed,
}

/// Inputs for one in-process `/do` workflow evaluation.
///
/// `workflow_source`, `vocabulary_source`, and `state_source` are registered
/// as separate in-memory Nickel inputs. `seed` is optional because only
/// `cli_seed` consumes it.
#[derive(Deserialize)]
pub struct WorkflowRequest {
    pub workflow_source: String,
    pub vocabulary_source: String,
    pub state_source: String,
    pub operation: WorkflowOperation,
    pub seed: Option<String>,
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
    let request: WorkflowRequest = match serde_wasm_bindgen::from_value(req) {
        Ok(r) => r,
        Err(e) => return js_result(1, String::new(), format!("Request parsing failed: {}", e)),
    };
    serde_wasm_bindgen::to_value(&evaluate_workflow(request)).unwrap()
}

fn evaluate_workflow(request: WorkflowRequest) -> WorkflowResult {
    let invocation_expr = match request.operation {
        WorkflowOperation::Cli => "let workflow = import \"%inmem_src%:workflow.ncl\" in \
             let state = workflow.normalize_state (import \"%inmem_src%:.do-results.json\") in \
             std.serialize 'Json (workflow.cli state)"
            .to_owned(),
        WorkflowOperation::CliSeed => "let workflow = import \"%inmem_src%:workflow.ncl\" in \
                 let state = workflow.normalize_state (import \"%inmem_src%:.do-results.json\") in \
                 let seed = import \"%inmem_src%:seed.json\" in \
                 std.serialize 'Json (workflow.cli_seed seed state)"
            .to_owned(),
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
        request.workflow_source,
    );
    cache.sources.add_string(
        SourcePath::Path(PathBuf::from("workflow-manifest.json"), InputFormat::Json),
        request.vocabulary_source,
    );
    cache.sources.add_string(
        SourcePath::Path(PathBuf::from(".do-results.json"), InputFormat::Json),
        request.state_source,
    );
    let seed = request.seed.as_deref().unwrap_or("default");
    let seed_source = match serde_json::to_string(seed) {
        Ok(source) => source,
        Err(e) => {
            return WorkflowResult {
                exit: 1,
                stdout: String::new(),
                stderr: format!("Seed serialization failed: {:?}", e),
            }
        }
    };
    cache.sources.add_string(
        SourcePath::Path(PathBuf::from("seed.json"), InputFormat::Json),
        seed_source,
    );

    let mut vm_ctxt: VmContext<CacheHub, CacheImpl> =
        VmContext::new(cache, std::io::sink(), NullReporter {});
    let result = match vm_ctxt.prepare_eval(main_id) {
        Ok(prepared) => {
            let mut vm = VirtualMachine::new(&mut vm_ctxt);
            match vm.eval_full_closure(prepared.into()) {
                Ok(evaled) => match serialize_value(&evaled.value) {
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
    let allocator = Allocator::default();
    let doc = value.pretty(&allocator);
    let mut output = Vec::new();
    doc.render(usize::MAX, &mut output)
        .map_err(|error| format!("JSON wire rendering failed: {}", error))?;
    let serialized = String::from_utf8(output)
        .map_err(|error| format!("JSON wire was not valid UTF-8: {}", error))?;
    serde_json::from_str(&serialized)
        .map_err(|error| format!("Nickel JSON serialization returned an invalid string: {}", error))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    fn request(operation: WorkflowOperation, seed: Option<&str>) -> WorkflowRequest {
        WorkflowRequest {
            workflow_source: include_str!("../../skills/do/workflow.ncl").to_owned(),
            vocabulary_source: include_str!("../../skills/do/workflow-manifest.json").to_owned(),
            state_source: json!({
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
            operation,
            seed: seed.map(str::to_owned),
        }
    }

    fn structured_output(result: WorkflowResult) -> Value {
        assert_eq!(result.exit, 0, "{}", result.stderr);
        assert!(result.stderr.is_empty());
        serde_json::from_str(&result.stdout).expect("evaluator stdout must be JSON")
    }

    #[test]
    fn cli_returns_a_structured_next_step() {
        assert_eq!(
            structured_output(evaluate_workflow(request(WorkflowOperation::Cli, None))),
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
            structured_output(evaluate_workflow(request(WorkflowOperation::CliSeed, Some("")))),
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


fn js_result(exit: u32, stdout: String, stderr: String) -> JsValue {
    serde_wasm_bindgen::to_value(&WorkflowResult { exit, stdout, stderr }).unwrap()
}
