#!/usr/bin/env node

// Run a manual, isolated Codex App Server spike. This is intentionally not a
// production Banyan code path and requires an already authenticated `codex`.
//
// Example:
//   node scripts/codex-app-server-spike.mjs --output /tmp/codex-app-server-spike.json

import assert from "node:assert/strict";
import { execFile, spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const DEFAULT_THREAD_COUNTS = [1, 2, 4];
const REQUEST_TIMEOUT_MS = 90_000;
const IDLE_UNLOAD_TIMEOUT_MS = 32 * 60_000;

function parseArguments(argv) {
    const options = { output: null, threadCounts: DEFAULT_THREAD_COUNTS, idleUnload: false };
    for (let index = 0; index < argv.length; index += 1) {
        const argument = argv[index];
        if (argument === "--output") {
            options.output = argv[++index];
        } else if (argument === "--thread-counts") {
            options.threadCounts = argv[++index].split(",").map(Number);
        } else if (argument === "--idle-unload") {
            options.idleUnload = true;
        } else if (argument === "--help") {
            console.log("Usage: node scripts/codex-app-server-spike.mjs [--output PATH] [--thread-counts 1,2,4] [--idle-unload]");
            process.exit(0);
        } else {
            throw new Error(`Unknown argument: ${argument}`);
        }
    }
    if (options.threadCounts.some((count) => !Number.isInteger(count) || count < 1)) {
        throw new Error("--thread-counts must be a comma-separated list of positive integers");
    }
    return options;
}

function delay(milliseconds) {
    return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function command(executable, args) {
    const { stdout } = await execFileAsync(executable, args, { encoding: "utf8" });
    return stdout.trim();
}

async function processTreeRSS(rootPID) {
    const { stdout } = await execFileAsync("ps", ["-axo", "pid=,ppid=,rss="], { encoding: "utf8" });
    const processes = stdout
        .trim()
        .split("\n")
        .filter(Boolean)
        .map((line) => line.trim().split(/\s+/).map(Number))
        .map(([pid, parentPID, rssKiB]) => ({ pid, parentPID, rssKiB }));
    const descendants = new Set([rootPID]);
    let changed = true;
    while (changed) {
        changed = false;
        for (const process of processes) {
            if (descendants.has(process.parentPID) && !descendants.has(process.pid)) {
                descendants.add(process.pid);
                changed = true;
            }
        }
    }
    const selected = processes.filter((process) => descendants.has(process.pid));
    return {
        pids: selected.map((process) => process.pid).sort((left, right) => left - right),
        rssKiB: selected.reduce((total, process) => total + process.rssKiB, 0),
    };
}

function waitForExit(child, timeout = 10_000) {
    return new Promise((resolve) => {
        const timer = setTimeout(resolve, timeout);
        child.once("exit", () => {
            clearTimeout(timer);
            resolve();
        });
    });
}

async function stopChild(child) {
    if (child.exitCode !== null || child.killed) return;
    child.kill("SIGTERM");
    await waitForExit(child);
}

class JsonLineTransport {
    constructor(child) {
        this.child = child;
        this.handlers = [];
        this.buffer = "";
        child.stdout.setEncoding("utf8");
        child.stdout.on("data", (chunk) => this.consume(chunk));
    }

    consume(chunk) {
        this.buffer += chunk;
        let newline = this.buffer.indexOf("\n");
        while (newline >= 0) {
            const line = this.buffer.slice(0, newline);
            this.buffer = this.buffer.slice(newline + 1);
            if (line.trim()) this.emit(JSON.parse(line));
            newline = this.buffer.indexOf("\n");
        }
    }

    onMessage(handler) {
        this.handlers.push(handler);
    }

    emit(message) {
        for (const handler of this.handlers) handler(message);
    }

    send(message) {
        this.child.stdin.write(`${JSON.stringify(message)}\n`);
    }
}

class AppServerClient {
    constructor(transport) {
        this.transport = transport;
        this.nextID = 1;
        this.pending = new Map();
        this.eventWaiters = [];
        this.events = [];
        this.approvalRequests = [];
        this.approvalDecision = () => "decline";
        transport.onMessage((message) => this.receive(message));
    }

    receive(message) {
        if (message.method) {
            this.events.push(message);
            this.resolveEventWaiters(message);
            if (message.method === "item/commandExecution/requestApproval") {
                this.approvalRequests.push(message);
                this.transport.send({
                    id: message.id,
                    result: { decision: this.approvalDecision(message.params) },
                });
            }
            return;
        }
        const pending = this.pending.get(message.id);
        if (!pending) return;
        this.pending.delete(message.id);
        if (message.error) {
            pending.reject(new Error(`${pending.method}: ${message.error.message}`));
        } else {
            pending.resolve(message.result);
        }
    }

    request(method, params = {}) {
        const id = this.nextID++;
        this.transport.send({ method, id, params });
        return new Promise((resolve, reject) => {
            const timeout = setTimeout(() => {
                this.pending.delete(id);
                reject(new Error(`${method} timed out after ${REQUEST_TIMEOUT_MS}ms`));
            }, REQUEST_TIMEOUT_MS);
            this.pending.set(id, {
                method,
                resolve: (result) => {
                    clearTimeout(timeout);
                    resolve(result);
                },
                reject: (error) => {
                    clearTimeout(timeout);
                    reject(error);
                },
            });
        });
    }

    notify(method, params = {}) {
        this.transport.send({ method, params });
    }

    setApprovalDecision(handler) {
        this.approvalDecision = handler;
    }

    async initialize() {
        const initialized = await this.request("initialize", {
            clientInfo: {
                name: "banyan_app_server_spike",
                title: "Banyan App Server Spike",
                version: "1.0.0",
            },
        });
        this.notify("initialized");
        return initialized;
    }

    async waitForEvent(predicate, timeout = REQUEST_TIMEOUT_MS) {
        const existing = this.events.find(predicate);
        if (existing) return existing;
        return new Promise((resolve, reject) => {
            const waiter = { predicate, resolve, reject, timer: null };
            waiter.timer = setTimeout(() => {
                this.eventWaiters = this.eventWaiters.filter((candidate) => candidate !== waiter);
                reject(new Error(`event timed out after ${timeout}ms`));
            }, timeout);
            this.eventWaiters.push(waiter);
        });
    }

    resolveEventWaiters(event) {
        const resolved = this.eventWaiters.filter((waiter) => waiter.predicate(event));
        this.eventWaiters = this.eventWaiters.filter((waiter) => !resolved.includes(waiter));
        for (const waiter of resolved) {
            clearTimeout(waiter.timer);
            waiter.resolve(event);
        }
    }

    async startTurn(threadID, text) {
        const startIndex = this.events.length;
        const result = await this.request("turn/start", {
            threadId: threadID,
            input: [{ type: "text", text }],
        });
        const turnID = result.turn.id;
        try {
            await this.waitForEvent(
                (event) => event.method === "turn/completed"
                    && event.params.threadId === threadID
                    && event.params.turn.id === turnID
                    && this.events.indexOf(event) >= startIndex,
            );
        } catch (error) {
            const recentMethods = this.events
                .slice(startIndex)
                .map((event) => event.method)
                .join(", ");
            throw new Error(`${error.message} for ${threadID}/${turnID}; events: ${recentMethods}`);
        }
        return turnID;
    }
}

async function startAppServer() {
    const child = spawn("codex", ["app-server", "--listen", "stdio://"], {
        stdio: ["pipe", "pipe", "pipe"],
    });
    const transport = new JsonLineTransport(child);
    const client = new AppServerClient(transport);
    try {
        await client.initialize();
        return { child, client };
    } catch (error) {
        await stopChild(child);
        throw error;
    }
}

async function measureIdleTUIProcesses(threadCounts) {
    const measurements = [];
    const processes = [];
    try {
        for (const count of threadCounts) {
            while (processes.length < count) {
                // `script` allocates a PTY so Codex starts its real terminal UI,
                // rather than treating its stdin as a non-interactive pipe.
                processes.push(spawn("script", ["-q", "/dev/null", "codex"], {
                    stdio: "ignore",
                }));
            }
            await delay(3_000);
            const trees = await Promise.all(processes.map((child) => processTreeRSS(child.pid)));
            measurements.push({
                sessions: count,
                rssKiB: trees.reduce((total, tree) => total + tree.rssKiB, 0),
                processTrees: trees,
            });
        }
    } finally {
        await Promise.all(processes.map(stopChild));
    }
    return measurements;
}

async function deleteThreads(threadIDs) {
    const { child, client } = await startAppServer();
    try {
        for (const threadID of threadIDs) {
            await client.request("thread/delete", { threadId: threadID });
        }
    } finally {
        await stopChild(child);
    }
}

async function runIdleUnload() {
    const startedAt = new Date();
    const startedAtMs = Date.now();
    const runRoot = mkdtempSync(join(tmpdir(), "banyan-codex-app-server-idle-unload-"));
    const workingDirectory = join(runRoot, "thread");
    mkdirSync(workingDirectory);
    const { child, client } = await startAppServer();
    try {
        const started = await client.request("thread/start", {
            cwd: workingDirectory,
            approvalPolicy: "never",
            sandbox: "read-only",
        });
        const threadID = started.thread.id;
        const unsubscribe = await client.request("thread/unsubscribe", { threadId: threadID });
        const closed = await client.waitForEvent(
            (event) => event.method === "thread/closed" && event.params.threadId === threadID,
            IDLE_UNLOAD_TIMEOUT_MS,
        );
        return {
            command: ["node", "scripts/codex-app-server-spike.mjs", "--idle-unload"],
            startedAt: startedAt.toISOString(),
            codexVersion: await command("codex", ["--version"]),
            transport: "stdio JSONL",
            gracePeriodTest: "waited for thread/closed after the last thread subscription was removed",
            thread: { cwd: started.cwd, approvalPolicy: started.approvalPolicy, sandbox: started.sandbox },
            unsubscribe,
            closed,
            finishedAt: new Date().toISOString(),
            elapsedMs: Date.now() - startedAtMs,
        };
    } finally {
        await stopChild(child);
    }
}

async function run(options) {
    const runRoot = mkdtempSync(join(tmpdir(), "banyan-codex-app-server-spike-"));
    const workingDirectories = Array.from(
        { length: Math.max(...options.threadCounts) },
        (_, index) => {
            const directory = join(runRoot, `thread-${index + 1}`);
            mkdirSync(directory);
            return directory;
        },
    );
    const result = {
        command: ["node", "scripts/codex-app-server-spike.mjs", "--thread-counts", options.threadCounts.join(",")],
        startedAt: new Date().toISOString(),
        codexVersion: await command("codex", ["--version"]),
        transport: "stdio JSONL",
        temporaryWorkingDirectories: workingDirectories,
        threadCounts: options.threadCounts,
        appServerRSS: [],
        tuiRSS: [],
        lifecycle: {},
        threadSettings: [],
        cleanup: { deletedThreadIDs: [] },
    };
    let server;
    let threadIDs = [];
    const recoveryThreadIDs = [];
    try {
        server = await startAppServer();
        result.appServerPID = server.child.pid;
        result.initialize = await command("sw_vers", ["-productVersion"]);
        result.appServerRSS.push({ threads: 0, ...(await processTreeRSS(server.child.pid)) });

        for (let index = 0; index < workingDirectories.length; index += 1) {
            const start = await server.client.request("thread/start", {
                cwd: workingDirectories[index],
                approvalPolicy: index === 0 ? "untrusted" : "never",
                // The current 0.146.x wire schema uses kebab-case values.
                // Do not copy the older camelCase names from stale examples.
                sandbox: index === 0 ? "workspace-write" : "read-only",
            });
            threadIDs.push(start.thread.id);
            assert.equal(start.cwd, workingDirectories[index], "thread/start must retain its requested cwd");
            assert.equal(
                start.approvalPolicy,
                index === 0 ? "untrusted" : "never",
                "thread/start must retain its requested approval policy",
            );
            result.threadSettings.push({
                threadID: start.thread.id,
                cwd: start.cwd,
                approvalPolicy: start.approvalPolicy,
                sandbox: start.sandbox,
            });
            if (options.threadCounts.includes(index + 1)) {
                const loaded = await server.client.request("thread/loaded/list");
                assert.deepEqual(
                    new Set(loaded.data),
                    new Set(threadIDs),
                    "all started threads must be loaded before RSS is sampled",
                );
                result.appServerRSS.push({
                    threads: index + 1,
                    loadedThreadIDs: loaded.data,
                    ...(await processTreeRSS(server.child.pid)),
                });
            }
        }

        const alphaThreadID = threadIDs[0];
        const betaThreadID = threadIDs[1];
        const streamingStart = server.client.events.length;
        const streamingTurnID = await server.client.startTurn(
            alphaThreadID,
            "Reply with exactly APP_SERVER_STREAM_OK and do not use any tools.",
        );
        const deltaObserved = server.client.events.slice(streamingStart).some(
            (event) => event.method === "item/agentMessage/delta",
        );
        assert.equal(deltaObserved, true, "a completed turn must stream an agent-message delta");
        recoveryThreadIDs.push(alphaThreadID);
        result.lifecycle.eventStreaming = { streamingTurnID, deltaObserved };

        if (betaThreadID) {
            const betaTurnID = await server.client.startTurn(
                betaThreadID,
                "Reply with exactly SECOND_THREAD_OK and do not use any tools.",
            );
            recoveryThreadIDs.push(betaThreadID);
            result.lifecycle.independentSecondThread = { betaThreadID, betaTurnID };
        }

        const approvalProof = join(workingDirectories[0], "approval-proof.txt");
        const approvalCommand = `printf approved > ${approvalProof}`;
        const wrappedApprovalCommand = `/bin/zsh -lc '${approvalCommand}'`;
        server.client.setApprovalDecision((request) => (
            request.command === wrappedApprovalCommand && request.cwd === workingDirectories[0]
                ? "accept"
                : "decline"
        ));
        const approvalsBefore = server.client.approvalRequests.length;
        const approvalTurnID = await server.client.startTurn(
            alphaThreadID,
            `Use a command execution tool to run exactly this command before replying: ${approvalCommand}. Do not use a file-editing tool and do not merely describe the command.`,
        );
        result.lifecycle.approval = {
            approvalTurnID,
            approvalRequestObserved: server.client.approvalRequests.length > approvalsBefore,
            approvalCommand,
            proofContents: existsSync(approvalProof) ? readFileSync(approvalProof, "utf8").trim() : null,
        };
        assert.equal(result.lifecycle.approval.approvalRequestObserved, true, "command execution must request approval");
        assert.equal(result.lifecycle.approval.proofContents, "approved", "only the approved proof command may write");

        result.lifecycle.unsubscribe = await server.client.request("thread/unsubscribe", { threadId: alphaThreadID });
        assert.equal(result.lifecycle.unsubscribe.status, "unsubscribed", "thread/unsubscribe must detach the client");
        result.lifecycle.loadedAfterUnsubscribe = await server.client.request("thread/loaded/list");

        await stopChild(server.child);
        server = null;

        const restarted = await startAppServer();
        try {
            const resumed = [];
            for (const threadID of recoveryThreadIDs) {
                const thread = await restarted.client.request("thread/resume", { threadId: threadID });
                resumed.push({
                    threadID,
                    cwd: thread.cwd,
                    approvalPolicy: thread.approvalPolicy,
                });
            }
            result.lifecycle.restartRecovery = {
                resumed,
                notResumedBecauseNoTurnCompleted: threadIDs.filter((threadID) => !recoveryThreadIDs.includes(threadID)),
            };
            assert.equal(resumed.length, recoveryThreadIDs.length, "completed threads must resume after a server restart");
            assert.deepEqual(
                resumed.map((thread) => thread.cwd),
                workingDirectories.slice(0, recoveryThreadIDs.length),
                "resumed threads must retain their working directories",
            );
        } finally {
            await stopChild(restarted.child);
        }

        result.tuiRSS = await measureIdleTUIProcesses(options.threadCounts);
        await deleteThreads(recoveryThreadIDs);
        result.cleanup.deletedThreadIDs = recoveryThreadIDs;
        threadIDs = [];
        result.finishedAt = new Date().toISOString();
        return result;
    } finally {
        if (server) await stopChild(server.child);
        if (threadIDs.length > 0) {
            try {
                await deleteThreads(threadIDs);
                result.cleanup.deletedThreadIDs = threadIDs;
            } catch (error) {
                result.cleanup.error = String(error);
            }
        }
    }
}

try {
    const options = parseArguments(process.argv.slice(2));
    const result = options.idleUnload ? await runIdleUnload() : await run(options);
    const json = `${JSON.stringify(result, null, 2)}\n`;
    if (options.output) writeFileSync(options.output, json);
    process.stdout.write(json);
} catch (error) {
    console.error(error.stack || error);
    process.exitCode = 1;
}
