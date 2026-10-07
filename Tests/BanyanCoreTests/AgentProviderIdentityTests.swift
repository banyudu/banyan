import Foundation
import Testing
@testable import BanyanCore

@Test func providerIdentityAdaptersReadLiveStateAndReuseOneHelper() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("banyan-provider-contract-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try AgentProviderIdentity.claudeSource.write(to: root.appendingPathComponent("claude.mjs"), atomically: true, encoding: .utf8)
    try AgentProviderIdentity.openCodeSource.write(to: root.appendingPathComponent("opencode.mjs"), atomically: true, encoding: .utf8)
    let script = #"""
    import assert from 'node:assert/strict';
    import {watch,writeFileSync,readFileSync,existsSync,renameSync} from 'node:fs';
    import {register} from './claude.mjs';
    import openCode from './opencode.mjs';
    const handlers = {}, waiters = [], written = [];
    let helpers = 0, maxHelpers = 0, onReply, onHelper;
    register((name, fn) => { handlers[name] = fn });
    function engine(id, running = []) { return {
      env: {get: async key => key.endsWith('DIR') ? '/private/fixture' : '/private/banyanctl'},
      process: {run: async () => { helpers++; maxHelpers = Math.max(maxHelpers, helpers);
        const result = await new Promise(resolve => {waiters.push(resolve); onHelper?.(); onHelper = undefined}); helpers--; return result }},
      session: {id: async () => id, cwd: async () => '/tmp/project'},
      agent: {list: async () => running}, fs: {write: async (_, text) => {const reply = JSON.parse(text); written.push(reply); onReply?.(reply); onReply = undefined}}
    }}
    const next = async e => e;
    const tick = () => new Promise(resolve => setImmediate(resolve));
    let current = engine('00000000-0000-4000-8000-000000000001');
    const starts = [handlers['session.start'](current, {}, next)];
    for (let n = 0; n < 8; n++) {
      current = engine('00000000-0000-4000-8000-000000000002');
      starts.push(handlers['session.start'](current, {}, next));
    }
    await Promise.all(starts);
    assert.equal(helpers, 1); assert.equal(waiters.length, 1);
    async function ask(n) {
      const nonce = `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
      const reply = new Promise(resolve => {onReply = resolve});
      const renewed = new Promise(resolve => {onHelper = resolve});
      waiters.shift()({exitCode: 0, stdout: JSON.stringify({nonce, pid: 42, provider: 'claude'})});
      await Promise.all([reply, renewed]);
      assert.equal(helpers, 1); assert.equal(maxHelpers, 1);
      return written.at(-1);
    }
    assert.equal((await ask(1)).id, '00000000-0000-4000-8000-000000000002');
    await handlers['turn.start'](current, {turnId: 'pending'}, next);
    assert.equal((await ask(2)).ready, false);
    await handlers['session.start'](engine('00000000-0000-4000-8000-000000000003'), {}, next);
    assert.equal((await ask(3)).ready, false); // a switch does not hide another active turn
    await handlers['turn.complete'](current, {turnId: 'pending'}, next);
    assert.equal((await ask(4)).ready, true);
    await handlers['session.start'](engine('00000000-0000-4000-8000-000000000003', [{status: 'running'}]), {}, next);
    assert.equal((await ask(5)).ready, false);
    waiters.shift()({exitCode: 1}); await tick(); assert.equal(helpers, 0);

    process.env.BANYAN_AGENT_IDENTITY_DIR = process.cwd();
    let route = {name: 'session', params: {sessionID: 'ses_first'}}, statuses = {}, modal = false, questions = [];
    let duringStatus = () => {}, dispose;
    const api = { route: {get current() {return route}}, state: {ready: true, session: {
      get: id => ({id, directory: '/tmp/project'}), permission: () => [], question: () => questions}},
      client: {session: {status: async () => {duringStatus(); return {data: statuses}}}},
      mode: {current: () => 'base'}, ui: {dialog: {get open() {return modal}}},
      lifecycle: {onDispose: fn => {dispose = fn}}
    };
    await openCode.tui(api);
    async function openAsk(n) {
      const nonce = `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
      return await new Promise(resolve => {
        const finish = value => {clearTimeout(timer); observer.close(); resolve(value)};
        const read = () => {if (existsSync(nonce + '.json')) finish(JSON.parse(readFileSync(nonce + '.json')))};
        // Observe the real reply write, rather than hoping a number of ticks
        // flushes macOS's coalesced filesystem events. The deadline is the
        // production RPC deadline; unanswered/disabled queries still time out.
        const observer = watch(process.cwd(), read);
        const timer = setTimeout(() => finish(undefined), 2000);
        writeFileSync('request.tmp', JSON.stringify({nonce, pid: process.pid, provider: 'opencode'}));
        renameSync('request.tmp', 'request.json');
        read();
      });
    }
    assert.equal((await openAsk(11)).id, 'ses_first');
    route = {name: 'session', params: {sessionID: 'ses_switched'}};
    assert.equal((await openAsk(12)).id, 'ses_switched');
    statuses = {ses_background: {type: 'busy'}}; assert.equal((await openAsk(13)).ready, false);
    statuses = {}; questions = [{}]; assert.equal((await openAsk(14)).ready, false);
    questions = []; modal = true; assert.equal((await openAsk(15)).ready, false); modal = false;
    duringStatus = () => {route = {name: 'home'}};
    assert.equal(await openAsk(16), undefined); // never a mixed old/new route
    dispose(); assert.equal(await openAsk(17), undefined); // disabled adapter stays silent
    console.log('Provider contracts: live selection, busy/pending refusal, single helper, disposal PASS');
    """#
    try script.write(to: root.appendingPathComponent("contract.mjs"), atomically: true, encoding: .utf8)
    var environment = ProcessInfo.processInfo.environment
    for key in ["CLICOLOR_FORCE", "FORCE_COLOR", "GH_FORCE_TTY"] { environment.removeValue(forKey: key) }
    let result = try SubprocessRunner.run(arguments: ["/usr/bin/env", "node", "contract.mjs"], cwd: root.path,
        environment: environment, timeout: 15)
    #expect(result.terminationStatus == 0, "\(String(decoding: result.standardError, as: UTF8.self))")
}

@Test func providerIdentityRejectsStaleNoncePIDStartCWDAndBusyReplies() throws {
    #expect(AgentProviderIdentity.supportsAdapter(provider: .claude, version: "2.1.286 (Claude Code)"))
    #expect(AgentProviderIdentity.supportsAdapter(provider: .opencode, version: "1.18.34\n"))
    for provider in [CodingAgentProvider.claude, .opencode] {
        for version in ["0.0.0", "unavailable", "99.0.0", ""] {
            #expect(!AgentProviderIdentity.supportsAdapter(provider: provider, version: version))
        }
    }
    #if os(macOS)
    let identity = try #require(AgentProcessSample.read(pid: ProcessInfo.processInfo.processIdentifier)?.identity)
    #expect(AgentProcessSample.presence(of: identity) == .alive)
    let nonce = UUID().uuidString
    let base: [String: Any] = ["nonce": nonce, "pid": identity.pid, "provider": "claude",
        "id": "00000000-0000-4000-8000-000000000001", "cwd": "/tmp/project", "ready": true]
    for replacement: [String: Any] in [["nonce": UUID().uuidString], ["pid": 1], ["cwd": "/tmp/other"], ["ready": false], ["id": "bad"], ["provider": "opencode"]] {
        let answer = try JSONDecoder().decode(AgentProviderIdentity.Answer.self,
            from: JSONSerialization.data(withJSONObject: base.merging(replacement, uniquingKeysWith: { _, new in new })))
        #expect(throws: AgentFreezeError.self) {
            try AgentProviderIdentity.validate(answer, nonce: nonce, process: identity, provider: .claude, cwd: "/tmp/project")
        }
    }
    let answer = try JSONDecoder().decode(AgentProviderIdentity.Answer.self, from: JSONSerialization.data(withJSONObject: base))
    let reused = AgentProcessIdentity(pid: identity.pid, startSeconds: identity.startSeconds + 1, startMicroseconds: identity.startMicroseconds)
    #expect(AgentProcessSample.presence(of: reused) == .exited)
    #expect(throws: AgentFreezeError.self) {
        try AgentProviderIdentity.validate(answer, nonce: nonce, process: reused, provider: .claude, cwd: "/tmp/project")
    }
    #endif
}
