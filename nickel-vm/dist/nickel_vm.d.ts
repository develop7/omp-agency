/* tslint:disable */
/* eslint-disable */

/**
 * Evaluate one `/do` workflow request against in-memory source documents.
 *
 * The returned JavaScript object always has `exit`, `stdout`, and `stderr`
 * fields. Successful `stdout` is the workflow's JSON serialization. Request
 * decoding and Nickel evaluation failures use a non-zero exit status and
 * diagnostic stderr text.
 */
export function eval_workflow(req: any): any;
