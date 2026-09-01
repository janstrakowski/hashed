// Tests for `hb dap`, driven by @vscode/debugadapter-testsupport - the
// reference client for the protocol the adapter has to satisfy, maintained by
// the people who define it. That is the whole reason this directory has a
// package.json in an otherwise install-free repository (see CLAUDE.md).
//
// These assert against the protocol, not against an implementation detail: a
// client asks, the adapter answers, and what a real editor would then draw is
// what gets checked. Everything runs against the fixtures in fixtures/, not
// against examples/, so an example's value can change without breaking a
// debugger test that never cared about it.

const assert = require("assert");
const path = require("path");
const { DebugClient } = require("@vscode/debugadapter-testsupport");

const ROOT = path.dirname(__dirname);
const HB = path.join(ROOT, process.platform === "win32" ? "hb.exe" : "hb");
const FIXTURES = path.join(__dirname, "fixtures");

// Paths go to the adapter exactly as a client would send them - absolute, and
// with the platform's own separators.
const fixture = (name) => path.join(FIXTURES, name);

describe("hb dap", function () {
  let dc;

  beforeEach(async () => {
    dc = new DebugClient(HB, "dap", "hashedbuild");
    // The adapter is a plain executable with one argument; there is no
    // JavaScript wrapper between the client and it.
    await dc.start();
  });

  afterEach(async () => {
    await dc.stop();
  });

  // The handshake every session begins with. `initialize` has to answer with
  // capabilities and then send `initialized`, in that order, or a client never
  // sends its breakpoints.
  it("initializes and announces what it supports", async () => {
    const response = await dc.initializeRequest({
      adapterID: "hashedbuild",
      linesStartAt1: true,
      columnsStartAt1: true,
    });
    assert.strictEqual(response.success, true);
    assert.strictEqual(response.body.supportsConfigurationDoneRequest, true);
    await dc.waitForEvent("initialized");
  });

  // A launch stops immediately, before evaluating anything a client has not
  // had a chance to set breakpoints for. DAP calls that reason "entry".
  it("stops on entry, and says why", async () => {
    await dc.initializeRequest({ adapterID: "hashedbuild", linesStartAt1: true });
    await dc.launchRequest({ program: fixture("arith.hb") });
    const stopped = await dc.waitForEvent("stopped");
    assert.strictEqual(stopped.body.reason, "entry");
    assert.strictEqual(stopped.body.threadId, 1);
    assert.strictEqual(stopped.body.allThreadsStopped, true);
  });

  // The stop is *after* a node, so the event describes a value that now
  // exists rather than an expression about to run - the one place this
  // adapter differs from a statement-oriented one, and worth pinning.
  it("reports the value the stopped expression produced", async () => {
    await dc.initializeRequest({ adapterID: "hashedbuild", linesStartAt1: true });
    await dc.launchRequest({ program: fixture("arith.hb") });
    const stopped = await dc.waitForEvent("stopped");
    assert.match(stopped.body.description, /=>/);
  });

  // A breakpoint on a line an expression starts on is verified and fires; one
  // on a comment is refused rather than silently accepted, so a client can
  // grey it out.
  it("sets breakpoints, and only verifies lines that have an expression", async () => {
    await dc.initializeRequest({ adapterID: "hashedbuild", linesStartAt1: true });
    await dc.launchRequest({ program: fixture("arith.hb") });
    await dc.waitForEvent("stopped");

    const response = await dc.setBreakpointsRequest({
      source: { path: fixture("arith.hb") },
      breakpoints: [{ line: 7 }, { line: 1 }],
    });
    assert.strictEqual(response.body.breakpoints.length, 2);
    assert.strictEqual(response.body.breakpoints[0].verified, true, "line 7 holds an expression");
    assert.strictEqual(response.body.breakpoints[1].verified, false, "line 1 is a comment");
  });

  it("stops at a breakpoint when continued", async () => {
    await dc.initializeRequest({ adapterID: "hashedbuild", linesStartAt1: true });
    await dc.launchRequest({ program: fixture("arith.hb") });
    await dc.waitForEvent("stopped");
    await dc.setBreakpointsRequest({
      source: { path: fixture("arith.hb") },
      breakpoints: [{ line: 7 }],
    });

    await dc.continueRequest({ threadId: 1 });
    const stopped = await dc.waitForEvent("stopped");
    assert.strictEqual(stopped.body.reason, "breakpoint");

    const trace = await dc.stackTraceRequest({ threadId: 1 });
    assert.strictEqual(trace.body.stackFrames[0].line, 7);
  });

  // A line holds many expressions here, and every one of them completes on
  // that line - so an unguarded breakpoint check would stop once per node and
  // make `continue` look broken. It fires once per visit instead.
  it("fires a line breakpoint once per visit, not once per expression", async () => {
    await dc.initializeRequest({ adapterID: "hashedbuild", linesStartAt1: true });
    await dc.launchRequest({ program: fixture("wide.hb") });
    await dc.waitForEvent("stopped");
    await dc.setBreakpointsRequest({
      source: { path: fixture("wide.hb") },
      breakpoints: [{ line: 5 }], // eight nodes start here
    });

    await dc.continueRequest({ threadId: 1 });
    const first = await dc.waitForEvent("stopped");
    assert.strictEqual(first.body.reason, "breakpoint");

    // The next continue must reach the end of the program, not the same line
    // over and over.
    await dc.continueRequest({ threadId: 1 });
    const output = await dc.waitForEvent("output");
    assert.strictEqual(output.body.output.trim(), "24");
    await dc.waitForEvent("terminated");
  });

  // One task, so one thread - and it is named, because a client shows the
  // name rather than the id.
  it("reports the program as thread 1", async () => {
    await dc.initializeRequest({ adapterID: "hashedbuild", linesStartAt1: true });
    await dc.launchRequest({ program: fixture("arith.hb") });
    await dc.waitForEvent("stopped");

    const response = await dc.threadsRequest();
    assert.strictEqual(response.body.threads.length, 1);
    assert.strictEqual(response.body.threads[0].id, 1);
    assert.strictEqual(response.body.threads[0].name, "program");
  });

  // Inside a call there are two frames: the call, and the program under it.
  // The outer frame's line is where the call was made from, which is what
  // makes a stack trace readable.
  it("builds a stack out of the calls in flight", async () => {
    await dc.initializeRequest({ adapterID: "hashedbuild", linesStartAt1: true });
    await dc.launchRequest({ program: fixture("call.hb") });
    await dc.waitForEvent("stopped");
    await dc.setBreakpointsRequest({
      source: { path: fixture("call.hb") },
      breakpoints: [{ line: 6 }], // the body itself, so the call is still in flight
    });

    await dc.continueRequest({ threadId: 1 });
    await dc.waitForEvent("stopped");

    const trace = await dc.stackTraceRequest({ threadId: 1 });
    const names = trace.body.stackFrames.map((f) => f.name);
    assert.ok(names.length >= 2, `expected a call and the program, got ${JSON.stringify(names)}`);
    assert.strictEqual(names[names.length - 1], "<program>");
  });

  // Two scopes, and Locals holds the program's own names - not the builtins,
  // which are always in scope and never what someone is looking for.
  it("shows the result and the local bindings", async () => {
    await dc.initializeRequest({ adapterID: "hashedbuild", linesStartAt1: true });
    await dc.launchRequest({ program: fixture("locals.hb") });
    await dc.waitForEvent("stopped");
    await dc.setBreakpointsRequest({
      source: { path: fixture("locals.hb") },
      breakpoints: [{ line: 6 }],
    });
    await dc.continueRequest({ threadId: 1 });
    await dc.waitForEvent("stopped");

    const trace = await dc.stackTraceRequest({ threadId: 1 });
    const scopes = await dc.scopesRequest({ frameId: trace.body.stackFrames[0].id });
    const names = scopes.body.scopes.map((s) => s.name);
    assert.deepStrictEqual(names, ["Result", "Locals"]);

    const locals = scopes.body.scopes.find((s) => s.name === "Locals");
    const vars = await dc.variablesRequest({ variablesReference: locals.variablesReference });
    const bound = vars.body.variables.map((v) => v.name);
    assert.ok(bound.includes("width"), "expected width among " + JSON.stringify(bound));
    assert.ok(!bound.includes("loadfile"), "the builtins are not locals");

    const width = vars.body.variables.find((v) => v.name === "width");
    assert.strictEqual(width.value, "4");
    assert.strictEqual(width.type, "Integer");
  });

  // A Table is expandable: the client gets a reference back and can ask for
  // its entries, which is how a variables pane draws a tree.
  it("expands a Table into its entries", async () => {
    await dc.initializeRequest({ adapterID: "hashedbuild", linesStartAt1: true });
    await dc.launchRequest({ program: fixture("table.hb") });
    await dc.waitForEvent("stopped");
    await dc.setBreakpointsRequest({
      source: { path: fixture("table.hb") },
      breakpoints: [{ line: 6 }],
    });
    await dc.continueRequest({ threadId: 1 });
    await dc.waitForEvent("stopped");

    const trace = await dc.stackTraceRequest({ threadId: 1 });
    const scopes = await dc.scopesRequest({ frameId: trace.body.stackFrames[0].id });
    const locals = scopes.body.scopes.find((s) => s.name === "Locals");
    const vars = await dc.variablesRequest({ variablesReference: locals.variablesReference });

    const t = vars.body.variables.find((v) => v.name === "point");
    assert.strictEqual(t.type, "Table");
    assert.ok(t.variablesReference > 0, "a Table can be expanded");

    const entries = await dc.variablesRequest({ variablesReference: t.variablesReference });
    const keys = entries.body.variables.map((v) => v.name);
    assert.ok(keys.includes("x") && keys.includes("y"), JSON.stringify(keys));
  });

  // The console evaluates in the stopped scope, so it sees the program's own
  // names - which is the whole point of a watch expression.
  it("evaluates an expression in the stopped scope", async () => {
    await dc.initializeRequest({ adapterID: "hashedbuild", linesStartAt1: true });
    await dc.launchRequest({ program: fixture("locals.hb") });
    await dc.waitForEvent("stopped");
    await dc.setBreakpointsRequest({
      source: { path: fixture("locals.hb") },
      breakpoints: [{ line: 6 }],
    });
    await dc.continueRequest({ threadId: 1 });
    await dc.waitForEvent("stopped");

    const trace = await dc.stackTraceRequest({ threadId: 1 });
    const frameId = trace.body.stackFrames[0].id;

    const arith = await dc.evaluateRequest({ expression: "2 + 3", frameId });
    assert.strictEqual(arith.body.result, "5");

    const local = await dc.evaluateRequest({ expression: "width * 2", frameId });
    assert.strictEqual(local.body.result, "8", "the stopped scope's own names are visible");
  });

  // A program reaches only the directories the launch names, exactly as on the
  // command line (SPEC.md §9/§16) - a debug session is not a way around that.
  it("gives the program only the directories the launch config names", async () => {
    await dc.initializeRequest({ adapterID: "hashedbuild", linesStartAt1: true });
    await dc.launchRequest({
      program: fixture("reads.hb"),
      dirs: { here: FIXTURES },
    });
    await dc.waitForEvent("stopped");
    await dc.continueRequest({ threadId: 1 });

    const output = await dc.waitForEvent("output");
    assert.match(output.body.output, /payload/);
    await dc.waitForEvent("terminated");
  });

  // The names in `dirs` outlive the request that carried them, so they have
  // to be copied out of it. Borrowing them left ctx.dirs keyed on reused
  // memory - a garbled name in a variables pane, and a lookup that failed
  // only sometimes, which is the worst way for it to fail.
  it("keeps the launch config's directory names intact", async () => {
    await dc.initializeRequest({ adapterID: "hashedbuild", linesStartAt1: true });
    await dc.launchRequest({ program: fixture("reads.hb"), dirs: { here: FIXTURES } });
    await dc.waitForEvent("stopped");

    const trace = await dc.stackTraceRequest({ threadId: 1 });
    const frameId = trace.body.stackFrames[0].id;

    const named = await dc.evaluateRequest({ expression: "ctx.dirs.here", frameId });
    assert.strictEqual(named.success, true, "ctx.dirs.here must still be reachable by that name");
    assert.match(named.body.result, /^<directory: /);

    const all = await dc.evaluateRequest({ expression: "ctx.dirs", frameId });
    assert.match(all.body.result, /^\{here: /, "the key is the name the launch config used");
  });

  it("fails the launch when a program names a directory it was not given", async () => {
    await dc.initializeRequest({ adapterID: "hashedbuild", linesStartAt1: true });
    await dc.launchRequest({ program: fixture("reads.hb") }); // no dirs at all
    await dc.waitForEvent("stopped");
    await dc.continueRequest({ threadId: 1 });

    const stopped = await dc.waitForEvent("stopped");
    assert.strictEqual(stopped.body.reason, "exception", "a failure stops where it happened");
  });

  // Running off the end is a normal ending: the value goes to the console, and
  // the session terminates with a code.
  it("terminates with the program's value", async () => {
    await dc.initializeRequest({ adapterID: "hashedbuild", linesStartAt1: true });
    await dc.launchRequest({ program: fixture("arith.hb") });
    await dc.waitForEvent("stopped");
    await dc.continueRequest({ threadId: 1 });

    const output = await dc.waitForEvent("output");
    assert.strictEqual(output.body.output.trim(), "14");
    const exited = await dc.waitForEvent("exited");
    assert.strictEqual(exited.body.exitCode, 0);
    await dc.waitForEvent("terminated");
  });

  // Every failure in this language is fatal (§8), which is what DAP calls an
  // exception - so the run stops at the node that failed rather than unwinding
  // silently to the end.
  it("stops where a program fails", async () => {
    await dc.initializeRequest({ adapterID: "hashedbuild", linesStartAt1: true });
    await dc.launchRequest({ program: fixture("fails.hb") });
    await dc.waitForEvent("stopped");
    await dc.continueRequest({ threadId: 1 });

    const stopped = await dc.waitForEvent("stopped");
    assert.strictEqual(stopped.body.reason, "exception");
    assert.match(stopped.body.text, /boom/);
  });

  // `async` (SPEC.md §2) runs on real OS threads, so a session has more than
  // one thread to show, and they stop together.
  it("reports each async task as a thread", async () => {
    await dc.initializeRequest({ adapterID: "hashedbuild", linesStartAt1: true });
    await dc.launchRequest({ program: fixture("async.hb") });
    await dc.waitForEvent("stopped");
    // Line 6 is after both `async` expressions have been evaluated, so both
    // tasks exist by the time this is hit.
    await dc.setBreakpointsRequest({
      source: { path: fixture("async.hb") },
      breakpoints: [{ line: 6 }],
    });
    await dc.continueRequest({ threadId: 1 });
    await dc.waitForEvent("stopped");

    const threads = await dc.threadsRequest();
    assert.ok(threads.body.threads.length >= 2,
      `expected the program plus an async task, got ${JSON.stringify(threads.body.threads)}`);
  });
});
