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

// The sequence every real client uses, and therefore the one every test here
// uses: initialize, wait for `initialized`, set breakpoints while the run is
// parked, then `configurationDone` - which is what lets the program go.
//
// Configuring *after* launching, which is what these tests used to do, hid two
// bugs at once, because no client does that: breakpoints sent before a run
// existed were dropped, and `setExceptionBreakpoints` was answered with an
// error a client can abandon the session over.
async function session(dc, { program, dirs, breakpoints = [], stopOnEntry = false, overrideAttributes = false }) {
  await dc.initializeRequest({
    adapterID: "hashedbuild",
    linesStartAt1: true,
    columnsStartAt1: true,
  });
  await dc.waitForEvent("initialized");
  await dc.launchRequest({ program, dirs, stopOnEntry, overrideAttributes });
  if (breakpoints.length) {
    await dc.setBreakpointsRequest({
      source: { path: program },
      breakpoints: breakpoints.map((line) => ({ line })),
    });
  }
  await dc.setExceptionBreakpointsRequest({ filters: [] });
  await dc.configurationDoneRequest();
}

// Where a run is stopped, as a client would ask: the top frame and its scopes.
async function whereIsIt(dc) {
  const trace = await dc.stackTraceRequest({ threadId: 1 });
  const frame = trace.body.stackFrames[0];
  const scopes = await dc.scopesRequest({ frameId: frame.id });
  return { frame, frames: trace.body.stackFrames, scopes: scopes.body.scopes };
}

async function scopeVariables(dc, scopes, name) {
  const scope = scopes.find((s) => s.name === name);
  if (!scope || !scope.variablesReference) return [];
  const vars = await dc.variablesRequest({ variablesReference: scope.variablesReference });
  return vars.body.variables;
}

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

  // A program with nothing to stop for runs. It does not park on its first
  // expression waiting to be told to go: that expression is a name lookup or a
  // literal, and stopping there tells nobody anything.
  it("runs to the end when nothing asks it to stop", async () => {
    await session(dc, { program: fixture("arith.hb") });
    const output = await dc.waitForEvent("output");
    assert.strictEqual(output.body.output.trim(), "14");
    const exited = await dc.waitForEvent("exited");
    assert.strictEqual(exited.body.exitCode, 0);
    await dc.waitForEvent("terminated");
  });

  it("stops on entry when the launch config asks for it", async () => {
    await session(dc, { program: fixture("arith.hb"), stopOnEntry: true });
    const stopped = await dc.waitForEvent("stopped");
    assert.strictEqual(stopped.body.reason, "entry");
    assert.strictEqual(stopped.body.threadId, 1);
    assert.strictEqual(stopped.body.allThreadsStopped, true);
  });

  // A breakpoint stops on the way *in*: the line has been reached and nothing
  // of it has run, which is what a breakpoint means everywhere else and the
  // only point at which what the line does can still be headed off. There is
  // no value yet, so there is no Result scope to show one in.
  it("stops before the line it breaks on", async () => {
    await session(dc, { program: fixture("arith.hb"), breakpoints: [7] });
    const stopped = await dc.waitForEvent("stopped");
    assert.strictEqual(stopped.body.reason, "breakpoint");
    assert.match(stopped.body.description, /^-> 2 \+ 3 \* 4$/);

    const { frame, scopes } = await whereIsIt(dc);
    assert.strictEqual(frame.line, 7);
    assert.deepStrictEqual(scopes.map((s) => s.name), ["Locals"]);
  });

  // ... and one Step Over runs the whole expression and stops on its way out,
  // which is where the value is. It is the *whole line's* value: line 7 of
  // arith.hb is `2 + 3 * 4`, and stopping on the `2` would be true and
  // useless. Step Over is measured in evaluation depth, not call frames, so
  // it skips the sub-expression rather than merely a call.
  it("steps over the line it broke on, and lands on its value", async () => {
    await session(dc, { program: fixture("arith.hb"), breakpoints: [7] });
    await dc.waitForEvent("stopped");

    await dc.nextRequest({ threadId: 1 });
    const stopped = await dc.waitForEvent("stopped");
    assert.match(stopped.body.description, /2 \+ 3 \* 4 => 14/);

    const { frame, scopes } = await whereIsIt(dc);
    assert.strictEqual(frame.line, 7);
    const result = scopes.find((s) => s.name === "Result");
    assert.ok(result, "a Result scope holds the value once there is one");
  });

  // Breakpoints arrive before there is a run to put them on - that is when a
  // client sends them - so they are held and applied at launch, and the gutter
  // is corrected afterwards with a `breakpoint` event.
  it("verifies a breakpoint once the run exists, and refuses a comment", async () => {
    await dc.initializeRequest({ adapterID: "hashedbuild", linesStartAt1: true });
    await dc.waitForEvent("initialized");

    const set = await dc.setBreakpointsRequest({
      source: { path: fixture("arith.hb") },
      breakpoints: [{ line: 7 }, { line: 1 }],
    });
    assert.strictEqual(set.body.breakpoints.length, 2);
    assert.ok(set.body.breakpoints[0].id > 0, "each needs an id to be corrected by");

    await dc.launchRequest({ program: fixture("arith.hb") });

    const corrections = [await dc.waitForEvent("breakpoint"), await dc.waitForEvent("breakpoint")];
    const byId = Object.fromEntries(corrections.map((e) => [e.body.breakpoint.id, e.body.breakpoint]));
    assert.strictEqual(byId[set.body.breakpoints[0].id].verified, true, "line 7 holds an expression");
    assert.strictEqual(byId[set.body.breakpoints[1].id].verified, false, "line 1 is a comment");
  });

  // The rule that keeps a breakpoint honest: if the adapter says a line is
  // verified, breaking on it must actually stop. Every line of a multi-line
  // expression, one session each - which is how the Table_Entry case was
  // found. `.int_div = 7 / 2` is a node, the widest one on its line, and
  // `eval` is never called on one: the old rule picked it, reported the
  // breakpoint verified, and then never fired it.
  it("stops on every line it says is verified", async () => {
    const program = fixture("multiline.hb");
    const total = require("fs").readFileSync(program, "utf8").split("\n").length;

    for (let line = 1; line <= total; line++) {
      const client = new DebugClient(HB, "dap", "hashedbuild");
      await client.start();
      try {
        await client.initializeRequest({ adapterID: "hashedbuild", linesStartAt1: true });
        await client.waitForEvent("initialized");
        await client.launchRequest({ program });
        const set = await client.setBreakpointsRequest({
          source: { path: program },
          breakpoints: [{ line }],
        });
        if (!set.body.breakpoints[0].verified) continue;

        await client.configurationDoneRequest();
        const stopped = await client.waitForEvent("stopped");
        assert.strictEqual(
          stopped.body.reason, "breakpoint",
          `line ${line} verified but stopped for ${stopped.body.reason}`,
        );
      } finally {
        await client.stop();
      }
    }
  });

  // Lines 8-11 of multiline.hb hold expressions; line 12 is a lone `}` and
  // line 1 a comment. A breakpoint is a line, so what makes it verifiable is
  // an expression *starting* there - line 8 is the `{` of a Table that ends
  // four lines later, and breaking on it means breaking on the Table.
  it("verifies the lines an expression starts on, and no others", async () => {
    const program = fixture("multiline.hb");
    await dc.initializeRequest({ adapterID: "hashedbuild", linesStartAt1: true });
    await dc.waitForEvent("initialized");
    await dc.launchRequest({ program });

    const lines = [1, 8, 9, 10, 11, 12];
    const set = await dc.setBreakpointsRequest({
      source: { path: program },
      breakpoints: lines.map((line) => ({ line })),
    });
    const verified = Object.fromEntries(
      lines.map((line, i) => [line, set.body.breakpoints[i].verified]),
    );
    assert.deepStrictEqual(verified, {
      1: false,  // a comment
      8: true,   // the `{` - the Table starts here
      9: true,
      10: true,
      11: true,
      12: false, // a lone `}` - nothing starts here
    });
  });

  // A breakpoint on the line an outer expression starts fires once, not once
  // for the outer expression and again for each one nested inside it that
  // happens to start on the same line.
  it("fires once on a line that opens a multi-line expression", async () => {
    await session(dc, { program: fixture("multiline.hb"), breakpoints: [8] });
    const stopped = await dc.waitForEvent("stopped");
    assert.strictEqual(stopped.body.reason, "breakpoint");

    await dc.continueRequest({ threadId: 1 });
    const output = await dc.waitForEvent("output");
    assert.strictEqual(output.body.output.trim(), "{int_div: 3, doubled: 8, negation: -3}");
    await dc.waitForEvent("terminated");
  });

  // A client sends one setBreakpoints per file it holds breakpoints in - not
  // one for the file being debugged. A breakpoint left in some other file
  // therefore arrives here too, and must not touch this run: it used to
  // replace the running program's breakpoints outright, so a session with a
  // stale breakpoint on line 10 of another file stopped on line 10 of *this*
  // one, wherever that landed.
  it("ignores breakpoints belonging to another file", async () => {
    const program = fixture("arith.hb");
    await dc.initializeRequest({ adapterID: "hashedbuild", linesStartAt1: true });
    await dc.waitForEvent("initialized");
    await dc.launchRequest({ program });

    await dc.setBreakpointsRequest({
      source: { path: program },
      breakpoints: [{ line: 7 }],
    });
    const elsewhere = await dc.setBreakpointsRequest({
      source: { path: fixture("multiline.hb") },
      breakpoints: [{ line: 9 }],
    });
    assert.strictEqual(
      elsewhere.body.breakpoints[0].verified, false,
      "a breakpoint in a file this session is not running can never be hit",
    );

    await dc.configurationDoneRequest();
    const stopped = await dc.waitForEvent("stopped");
    assert.strictEqual(stopped.body.reason, "breakpoint");
    const { frame } = await whereIsIt(dc);
    assert.strictEqual(frame.line, 7, "line 7 of arith.hb, not line 9 of the other file");
  });

  // What a step lands on, in order. Two things are being pinned here at once:
  // a Table entry is a step of its own - `eval` never runs on one, but someone
  // walking a Table expects to pass through `.int_div = 7 / 2` on the way to
  // its value - and a literal is not, because `7 => 7` says nothing that
  // reading the line does not. So `7 / 2` is one step, as "literal divided by
  // literal" ought to be.
  it("steps through entries and expressions, and not through literals", async () => {
    await session(dc, { program: fixture("multiline.hb"), breakpoints: [9] });
    const stopped = await dc.waitForEvent("stopped");
    assert.strictEqual(stopped.body.description, "-> .int_div = 7 / 2");

    const seen = [];
    for (let i = 0; i < 5; i++) {
      await dc.stepInRequest({ threadId: 1 });
      seen.push((await dc.waitForEvent("stopped")).body.description);
    }
    assert.deepStrictEqual(seen, [
      "-> 7 / 2",
      "7 / 2 => 3",
      ".int_div = 7 / 2 => 3",
      "-> .doubled = 4 + 4",
      "-> 4 + 4",
    ]);
  });

  // Root wraps the program's one expression and has exactly its span, so
  // stopping at both is pressing F11 twice to see the same text. And a
  // program that *is* a literal still has to stop somewhere: skipping both
  // would leave `stopOnEntry` with nowhere to go.
  it("does not stop twice on the program's own expression", async () => {
    await session(dc, { program: fixture("multiline.hb"), stopOnEntry: true });
    const first = await dc.waitForEvent("stopped");
    assert.match(first.body.description, /^-> \{ \.int_div/);

    await dc.stepInRequest({ threadId: 1 });
    const second = await dc.waitForEvent("stopped");
    assert.strictEqual(second.body.description, "-> .int_div = 7 / 2", "the next step is inside it");
  });

  // A frame is a *range*, and a client that gets only one end of it guesses
  // at the other: VS Code highlighted `7` for a run stopped on `7 / 2`, and
  // the whole Table for one stopped on the `{`.
  it("locates a frame at both ends of the expression", async () => {
    await session(dc, { program: fixture("multiline.hb"), breakpoints: [9] });
    await dc.waitForEvent("stopped");

    const { frame } = await whereIsIt(dc);
    assert.strictEqual(frame.line, 9);
    assert.strictEqual(frame.endLine, 9);
    // `  .int_div = 7 / 2,` - the entry runs from column 3 to just past the 2.
    assert.strictEqual(frame.column, 3);
    assert.strictEqual(frame.endColumn, 19);
  });

  // Two clients, two orders. VS Code launches first and configures after;
  // DAP's own recommended order - and nvim-dap - sends `configurationDone`
  // before `launch`. The run is parked either way, so whichever of the two
  // arrives second is what lets it go; getting that wrong means a client that
  // waits forever for a `stopped` nothing will ever send.
  it("starts the run when configurationDone arrives before launch", async () => {
    await dc.initializeRequest({ adapterID: "hashedbuild", linesStartAt1: true });
    await dc.waitForEvent("initialized");
    await dc.setBreakpointsRequest({
      source: { path: fixture("arith.hb") },
      breakpoints: [{ line: 7 }],
    });
    await dc.configurationDoneRequest();
    await dc.launchRequest({ program: fixture("arith.hb") });

    const stopped = await dc.waitForEvent("stopped");
    assert.strictEqual(stopped.body.reason, "breakpoint");
    await dc.continueRequest({ threadId: 1 });
    await dc.waitForEvent("terminated");
  });

  // A line holds many expressions here, and an enclosing one finishes long
  // after the line it starts on - so a breakpoint fires once, on the widest
  // expression contained in the line, and `continue` reaches the end.
  it("fires a line breakpoint once, not once per expression", async () => {
    await session(dc, { program: fixture("wide.hb"), breakpoints: [5] });
    const first = await dc.waitForEvent("stopped");
    assert.strictEqual(first.body.reason, "breakpoint");

    await dc.continueRequest({ threadId: 1 });
    const output = await dc.waitForEvent("output");
    assert.strictEqual(output.body.output.trim(), "24");
    await dc.waitForEvent("terminated");
  });

  it("reports the program as thread 1", async () => {
    await session(dc, { program: fixture("arith.hb"), stopOnEntry: true });
    await dc.waitForEvent("stopped");

    const response = await dc.threadsRequest();
    assert.strictEqual(response.body.threads.length, 1);
    assert.strictEqual(response.body.threads[0].id, 1);
    assert.strictEqual(response.body.threads[0].name, "program");
  });

  // Inside a call there are two frames: the call, and the program under it.
  it("builds a stack out of the calls in flight", async () => {
    await session(dc, { program: fixture("call.hb"), breakpoints: [6] });
    await dc.waitForEvent("stopped");

    const { frames } = await whereIsIt(dc);
    const names = frames.map((f) => f.name);
    assert.ok(names.length >= 2, `expected a call and the program, got ${JSON.stringify(names)}`);
    assert.strictEqual(names[names.length - 1], "<program>");
  });

  // Locals holds the program's own names - not the builtins, which are always
  // in scope and never what anyone is looking for.
  it("shows the result and the local bindings", async () => {
    await session(dc, { program: fixture("locals.hb"), breakpoints: [6] });
    await dc.waitForEvent("stopped");
    // Past the breakpoint's own Enter stop, to where the value is.
    await dc.nextRequest({ threadId: 1 });
    await dc.waitForEvent("stopped");

    const { scopes } = await whereIsIt(dc);
    assert.deepStrictEqual(scopes.map((s) => s.name), ["Result", "Locals"]);

    const locals = await scopeVariables(dc, scopes, "Locals");
    const names = locals.map((v) => v.name);
    assert.ok(names.includes("width"), "expected width among " + JSON.stringify(names));
    assert.ok(!names.includes("loadfile"), "the builtins are not locals");

    const width = locals.find((v) => v.name === "width");
    assert.strictEqual(width.value, "4");
    assert.strictEqual(width.type, "Integer");
  });

  it("expands a Table into its entries", async () => {
    await session(dc, { program: fixture("table.hb"), breakpoints: [6] });
    await dc.waitForEvent("stopped");

    const { scopes } = await whereIsIt(dc);
    const locals = await scopeVariables(dc, scopes, "Locals");
    const t = locals.find((v) => v.name === "point");
    assert.strictEqual(t.type, "Table");
    assert.ok(t.variablesReference > 0, "a Table can be expanded");

    const entries = await dc.variablesRequest({ variablesReference: t.variablesReference });
    const keys = entries.body.variables.map((v) => v.name);
    assert.ok(keys.includes("x") && keys.includes("y"), JSON.stringify(keys));
  });

  it("evaluates an expression in the stopped scope", async () => {
    await session(dc, { program: fixture("locals.hb"), breakpoints: [6] });
    await dc.waitForEvent("stopped");
    const { frame } = await whereIsIt(dc);

    const arith = await dc.evaluateRequest({ expression: "2 + 3", frameId: frame.id });
    assert.strictEqual(arith.body.result, "5");

    const local = await dc.evaluateRequest({ expression: "width * 2", frameId: frame.id });
    assert.strictEqual(local.body.result, "8", "the stopped scope's own names are visible");
  });

  // A program that declares its own inputs (SPEC.md §17) needs no
  // configuration at all: `program` is the whole launch config.
  it("runs a program that declares its own directories, with no config", async () => {
    await session(dc, { program: fixture("reads.hb") });
    const output = await dc.waitForEvent("output");
    assert.match(output.body.output, /payload/);
    await dc.waitForEvent("terminated");
  });

  // Saying it twice is the same conflict the command line has, and is refused
  // the same way - a debug session is not a way around what a file says about
  // itself.
  it("refuses a launch config that contradicts the program's attributes", async () => {
    await dc.initializeRequest({ adapterID: "hashedbuild", linesStartAt1: true });
    await dc.waitForEvent("initialized");
    const launched = await dc.launchRequest({
      program: fixture("reads.hb"),
      dirs: { here: FIXTURES },
    }).catch((e) => e);
    assert.ok(launched instanceof Error || launched.success === false,
      "a config that sets what the file already declares must be refused");
  });

  it("lets a launch config override the attributes when it says so", async () => {
    await session(dc, {
      program: fixture("reads.hb"),
      dirs: { here: FIXTURES },
      overrideAttributes: true,
    });
    const output = await dc.waitForEvent("output");
    assert.match(output.body.output, /payload/);
    await dc.waitForEvent("terminated");
  });

  // The names in `dirs` outlive the request that carried them, so they have to
  // be copied out of it. Borrowing them left ctx.dirs keyed on reused memory -
  // a garbled name in a variables pane, and a lookup that failed only
  // sometimes, which is the worst way for it to fail.
  it("keeps the launch config's directory names intact", async () => {
    await session(dc, { program: fixture("reads.hb"), stopOnEntry: true });
    await dc.waitForEvent("stopped");
    const { frame } = await whereIsIt(dc);

    const named = await dc.evaluateRequest({ expression: "ctx.dirs.here", frameId: frame.id });
    assert.strictEqual(named.success, true, "ctx.dirs.here must still be reachable by that name");
    assert.match(named.body.result, /^<directory: /);

    const all = await dc.evaluateRequest({ expression: "ctx.dirs", frameId: frame.id });
    assert.match(all.body.result, /^\{here: /, "the key is the name the launch config used");
  });

  it("fails where a program names a directory it was not given", async () => {
    // `here` removed by an overriding config, so the program asks for a handle
    // that is not there - the same failure as running it without one.
    await session(dc, {
      program: fixture("reads.hb"),
      dirs: { here: "" },
      overrideAttributes: true,
    });
    const stopped = await dc.waitForEvent("stopped");
    assert.strictEqual(stopped.body.reason, "exception", "a failure stops where it happened");
  });

  // Every failure in this language is fatal (§8), which is what DAP calls an
  // exception - so the run stops at the node that failed rather than unwinding
  // silently to the end.
  it("stops where a program fails", async () => {
    await session(dc, { program: fixture("fails.hb") });
    const stopped = await dc.waitForEvent("stopped");
    assert.strictEqual(stopped.body.reason, "exception");
    assert.match(stopped.body.text, /boom/);
  });

  // `async` (SPEC.md §2) runs on real OS threads, so a session has more than
  // one thread to report, and they stop together.
  it("reports each async task as a thread", async () => {
    await session(dc, { program: fixture("async.hb"), breakpoints: [6] });
    await dc.waitForEvent("stopped");

    const threads = await dc.threadsRequest();
    assert.ok(threads.body.threads.length >= 2,
      `expected the program plus an async task, got ${JSON.stringify(threads.body.threads)}`);
  });
});
