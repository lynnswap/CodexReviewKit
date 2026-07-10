# CodexKit / CodexReviewKit 設計・API 監査(2026-07-10)

| 項目 | 内容 |
|---|---|
| 対象 | CodexKit `3f6216c`(CodexAppServerKit / CodexDataKit / CodexAppServerKitTesting)、CodexReviewKit `6c1b432` |
| 一次情報 | upstream codex `8347b8d`(/Users/kn/Dev/codex)、openai-python `2.43.0`(SDK ergonomics ベンチマーク) |
| 方法 | multi-agent 監査: 7 mapper(AppServerKit / DataKit / Testing / upstream protocol / openai-python / 消費側 workaround / CRK 構造)+ 3 cross 分析(coverage / conformance / DX)→ 重複統合(raw 130 → canonical 89)→ 領域別 adversarial 検証 |
| 検証ステータス | high+medium 53 件を検証: **CONFIRMED 50 / PLAUSIBLE 1 / REFUTED 2**。low 36 件は未検証(Appendix B) |

読み方: 各 finding は Appendix A に id 付きで詳細(証拠 file:line、検証トレース)を収録。本文はクラスタ単位の構造分析。パス表記は `CK:` = CodexKit(`dependencies/CodexKit`)、`CRK:` = 本 repo、`UP:` = upstream codex。

## 1. 結論

PR #16(2026-07-02)時点の 3 弱境界のうち 2.5 は解消済み:

1. **generation 境界 — 解消**。`withThreadEventGeneration` が turn/start・compact・review/start・resume の cursor 切替を所有し、`inferredCurrentGenerationEvents` は削除済み。owner レベルのテストで pin されている。
2. **observation multicast — 解消**。`ThreadEventPump` が model mutation を所有し、`CodexAsyncStreamRelay` が per-subscriber broadcast を行う。
3. **item identity — 形を変え残存**。`CodexMessageDelta.itemID` は依然 optional(upstream は required)で、fallback-ID/text-dedup 機構は実在しない `agent/message` decode が唯一の駆動源(→ `dk-optional-delta-id-workaround-layer`, `cov-dead-compat-notifications`)。

**現存する最大の欠陥は「upstream v2 終端契約の誤読」1 点に集約される。** この誤読が SDK 全層(router / turn sequences / DataKit phase)に染み出し、その代償として旗艦消費者である本 repo が SDK の高レベル review API(`progress` / `collect()` / `response`)を**一切使わず** raw events 上に終端分類を再実装している(`use-highlevel-surface-bypass`)。SDK の便利層を SDK 作者自身が使えないことが、この層の契約が誤っていることの最強の証拠である。

## 2. upstream 契約の一次事実(全て codex-rs 現物で確認済み)

| protocol 事実 | 根拠(UP: codex-rs) | CodexKit の現状 |
|---|---|---|
| turn の terminal は **`turn/completed` のみ**。結果は payload の `turn.status`(completed / interrupted / failed / inProgress) | `app-server-protocol/src/protocol/v2/turn.rs:30-35, 392-395` | `turn/failed`・`turn/cancelled` を decode(`CK:Sources/CodexAppServerKit/CodexAppServerNotificationRouter.swift:661,748`)— upstream 全履歴に不存在 |
| `interrupted` はユーザー中断の**正常終端**(error なし) | turn_processor の interrupt 経路 | `CodexTurnStatus.isFailure` が interrupted/cancelled を失敗扱い(`CK:Sources/CodexAppServerKit/CodexDomainTypes.swift:1878`) |
| `thread/closed` は **idle unload 通知(再開可)**。終端ではない | `app-server/src/request_processors/thread_lifecycle.rs:406-436` | router が全 subscriber を終端、DataKit は走行中 turn を `.completed` に捏造(`CK:Sources/CodexDataKit/CodexModel.swift:1258`) |
| `item/updated`・`agent/message` という notification は存在しない | `protocol/common.rs:1613-1710`(grep 0 件) | 両方 decode。`agent/message` が fallback-ID subsystem の唯一の駆動源 |
| client→server の login request は `account/login/start` / `account/login/cancel` のみ | `protocol/common.rs:1001-1008` | `account/login/complete` + `nativeWebAuthentication` は **invented**(`git log --all -S` 空) |
| `thread/rollback` は "will be removed soon" | protocol 定義の deprecation 注記 | review restart / `rollback(turnCount:)` / `.revertTranscript` の 3 public 挙動が依存 |
| `account/rateLimits/updated` は sparse な rolling update(merge 前提) | notification 定義の doc | 置換適用(merge owner 不在)で secondary/planType が消える |
| server→client request(userInput / permissions)は typed 応答必須 | `ToolRequestUserInputResponse` 等の serde | デフォルトハンドラの `{}` 応答は upstream 側 serde 失敗 → error ログ付き deny 降格 |

## 3. Owner map — SDK 側の弱境界(現状 → あるべき姿)

| 責務 | 現状 owner | 問題 | あるべき owner |
|---|---|---|---|
| turn 終端の意味論 | `CodexTurnStatus.isFailure` + 各層の独自解釈 | interrupted=失敗の誤読が collect/progress/DataKit phase に増殖 | `CodexTurnStatus` 1 箇所での 3 値終端(成功 / 中断 / 失敗) |
| thread lifecycle | router(closed=終端と誤読) | unload を終端化、subscriber 即終了、DataKit が成功を捏造 | router が closed を「unload・再購読可」として扱う |
| エラー型 | **不在** — package `JSONRPC.Error` が素通り | 型で catch 不能。`CodexAppServerError` の 3 case は dead。`error.data`(CodexErrorInfo)全破棄 | send boundary 1 箇所での public typed error へのマップ |
| 資源解放 | **不在** — deinit ゼロ | router history 無限成長、close() 忘れで codex 子プロセス孤児化 | terminal turn 後の履歴 prune + deinit backstop |
| fetch mutation 戦略(DataKit) | **不在** — insert/archive/revalidate/remove/refresh が各自判断 | `fix(data)` 9 連続の根。insert だけ `usesServerOwnedOrdering` を見ない非対称が現存 | 単一の per-mutation strategy 型 |
| wire fixture | **不在** — SDK tests / Testing target / CRK preview の 3 箇所で手書き | 実在しない `turn/failed`・status `"cancelled"` が fixture に混入済み | Testing target が typed emitter を提供 |

### CodexReviewKit 側 owner map(要点)

健全な境界(維持すべきもの):

- domain core(`CodexReviewKit` target)は transport 非依存(import scan で確認: Foundation/Observation/ObservationBridge/Network のみ)
- UI target は CodexAppServerKit を import しない。preview は `CodexAppServerTestRuntime`(transport 層)で fake し、本番 data flow を保存
- review event の generation/identity は `ReviewWorkerEventSource`(単調増加 subscription ID + attemptID gating)で構造的に所有 — PR #16 型の cursor dance をこの repo では解消済み
- MCP session lifecycle は `closeSession` 1 経路に集約。chat-log render は純粋な再投影 + document diff

弱い境界:

- **login/auth teardown が owner 不在**: `LiveCodexReviewStoreBackend` の 9 mutable fields を 7 つの exit path が手動 reset(`arch-login-state-no-owner`、repo 内で最弱)
- attemptID identity が 3 層で `"attempt-1"` に fallback し、lookup 経路の get-or-create が registry を clobber(`arch-attempt-id-fallback`)
- source/review の dual-thread identity を 3 層が独立に再導出(`use-dual-thread-identity`)
- `CodexReviewHost` + `DirectCodexReviewStoreBackend` はテスト専用の重複 production code(copy-drift 実在: `arch-host-target-test-only`)

## 4. DX 評価(openai-python の 17 契約をベンチマーク)

**CodexAppServerKit**: 層設計は優秀(transport actor → per-thread serial lane + overload retry → replay 付き router → 値型 domain surface)。寛容 decode(`.unknown` / `rawPayload` 保持)、-32001 限定の jittered retry、fail-fast init、再生可能 stream、tri-state config patch、transport 層 testing product はベンチマーク水準を満たす。弱いのは異常系一式:

- エラー: 消費者が型で catch できない(CRK に typed catch 0 件、`localizedDescription` 還元 ~30 箇所)
- タイムアウト: init handshake・全 request・`collect()` に deadline なし
- キャンセル: task cancel が `transportClosed` に化ける。同じ `CodexResponseStream` で iteration break(server 継続)と collect() 中 cancel(server 中断)の意味論が割れており、README 以外に文書なし
- `turn/interrupt` の正しさがエラーメッセージ文字列 parse(`" but found "` split)に依存

**CodexDataKit**: SwiftData アナロジーは object identity については誠実(fetch は identity 安定な live `@Observable` model を in-place mutate)だが、4 点で開発者を裏切る:

1. **ライブではない** — `@CodexQuery` は外部変更(CLI での thread 作成・rename・archive)を観測しない。upstream の `thread/*` notification の ingestion が無い
2. `#Predicate` は 5-key whitelist で、外すと **SwiftUI update() 内で `preconditionFailure`**(SwiftData は throw)
3. `isArchived` に触れない predicate に `archived == false` が**暗黙注入**される(文書化なし)
4. `includePendingChanges` の意味が SwiftData と別物で、公開 mutable フィールドがあるのに `save()` が無い

2 パッケージ分割自体は明快で、下方 interop(`container.appServer` / `CodexStartedReview.session`)も実際に使われている。ただし AppServerKit 側での mutation が DataKit fetch results に反映されない coherence 境界は未文書。

## 5. API 過不足

### 過剰(存在しない・無意味な API)

| API | 問題 | finding |
|---|---|---|
| `account/login/complete` + `nativeWebAuthentication` | upstream 全履歴に不存在。素の codex では native web-auth が無言で never engage。fork 前提なら明示が必要 | `cov-invented-login-complete` |
| `turn/failed`・`turn/cancelled`・`item/updated`・`agent/message` decode | v2 に不存在。public `.turnFailed` は永久に発火しない。`agent/message` が fallback-ID 機構を駆動。CRK preview が `item/updated` に依存し、invented semantics が外に漏れている | `cov-dead-compat-notifications` |
| `CodexTurnStatus.cancelled` | protocol が emit しない独自 case。CRK が分岐している | `cov-invented-turn-status`(low) |
| `CodexReviewSession.steer()` | upstream が review turn への steer をカテゴリカルに拒否(`activeTurnNotSteerable`)— 必ず失敗する public API | `conf-review-steer-always-rejected`(low) |
| `Permissions.profileSelection`(object 形) | upstream は plain string 期待。latent wire break | `conf-permissions-object-shape`(low) |

### 不足(消費側が代償を払っている)

| 欠落 | 消費側の代償 | finding |
|---|---|---|
| typed error taxonomy + `error.data` 保持 | typed catch 0 件、message 文字列 match、SDK 自身も interrupt 判定を文字列 parse | `dx-error-taxonomy-uncatchable`, `conf-error-payload-discarded` |
| timeout | ホスト側で手作りタイムアウト。wedged binary で起動永久ハング | `dx-no-timeout-story` |
| outbound raw JSON-RPC escape hatch | 週次で動く upstream の新 method を呼べない(send path は 1 本なので追加は安価) | `dx-no-raw-escape-hatch` |
| server→client request の typed surface + `serverRequest/resolved` | `{}` 応答は upstream 側 serde 失敗 → deny 降格。custom handler は abort 時に永久待ち | `cov-server-requests-untyped`, `conf-server-request-resolved-ignored` |
| identity での cancel | registry miss 時にセッション全体を resume してから cancel | `use-resume-to-cancel` |
| review 最終出力の所在の契約 | 3 段 fallback チェーン + 2 層での失敗合成(この領域だけで fix 5+ commits) | `use-review-output-location` |
| 死活監視 surface | `accountEvents` stream の throw を「サーバー死亡」のサイドチャネルとして利用 | `use-runtime-death-side-channel` |
| `deprecationNotice` / `error.willRetry` の typed 化 | thread/rollback 除去シグナルと transient-retry シグナルが不可視 | `cov-error-warning-untyped` |
| thread lifecycle notification の DataKit ingestion | MCP provider が read 毎に全 refresh + silent catch | `dk-query-not-live-external`, `use-mcp-refresh-fallback` |

### 適切に無いもの(問題なし)

`fs/*`、`mcpServer/*`、skills、plugins、exec/process、realtime、remoteControl 系 — 消費者に需要がなく workaround 圧力も観測されず。CRK production code に手書き JSON-RPC はゼロ(raw 文字列は preview/test transport に限定)。`review/start`・ReviewTarget・ReviewDelivery は upstream と正確に一致。v1 deprecated methods は正しく不採用。

## 6. 修正方針(優先順位付き)

### P1 — SDK の契約修正

| # | 修正 | 回復する invariant | findings |
|---|---|---|---|
| 1 | turn 終端の 3 値化: `isFailure` から interrupted/cancelled を外し、`collect()`/`respond()` は中断時に throw せず返す。progress の `.failed` 報告も分岐 | ユーザー中断は失敗ではない(upstream 契約) | `conf-interrupted-is-failure`, `dx-cancel-semantics-inconsistent` |
| 2 | `thread/closed` = unload: subscriber を終端しない、DataKit が `.completed` を捏造しない | thread の生死は server が所有し unload は状態遷移 | `ask-thread-closed-terminal`, `dk-closed-fabricates-completion` |
| 3 | send boundary 1 箇所で typed error 化(code + CodexErrorInfo + requestID)、CancellationError 透過、per-request timeout。interrupt 判定を `codexErrorInfo` の typed 判別へ | 失敗の分類は SDK が所有する | `dx-error-taxonomy-uncatchable`, `conf-error-payload-discarded`, `ask-cancel-collect-misreported`, `ask-interrupt-error-string-parsing`, `dx-no-timeout-story` |
| 4 | terminal turn 後の router history prune(replay 契約と両立する設計)+ deinit backstop | 接続寿命 = 資源上限 | `ask-router-history-unbounded`, `ask-process-leak-no-deinit` |
| 5 | invented login surface の決着(fork 前提の明示 or 撤去)。`thread/rollback` 依存の脱却計画(まず deprecationNotice の typed 化) | public API は実在する upstream 契約に裏付けられる | `cov-invented-login-complete`, `cov-rollback-deprecated` |

P1-1/2 が入ると、CRK 側 terminal-cascade 3 層(`use-terminal-cascade`)、`.closed→.failed` 変換(`arch-closed-maps-to-failed`)、high-level surface bypass(`use-highlevel-surface-bypass`)の削除条件が立つ。

### P2 — 再発防止の契約整合

| # | 修正 | findings |
|---|---|---|
| 6 | DataKit mutation 戦略の単一 owner 化 + `load()` の直列化 / generation token | `dk-mutation-strategy-scattering`, `dk-unserialized-fetch-loads` |
| 7 | dead decode 4 種の削除 + `CodexMessageDelta.itemID` required 化(fallback-ID subsystem ごと削除) | `cov-dead-compat-notifications`, `dk-optional-delta-id-workaround-layer` |
| 8 | Testing fake の契約一致: unstubbed fail-fast、thread/list の archived/sort 実装、server-request 注入 API、typed wire emitter | `test-unstubbed-method-silent-success`, `test-store-ignores-archived-and-sort`, `test-no-server-request-injection`, `test-handrolled-notification-schemas-drift` |
| 9 | predicate の throwing validation 化 + archived 暗黙注入の廃止(最低限、両方の文書化) | `dk-predicate-runtime-crash-contract`, `dk-implicit-archived-scope` |
| 10 | server request の typed surface + `serverRequest/resolved` 処理 | `cov-server-requests-untyped`, `conf-server-request-resolved-ignored` |

### P3 — 消費側の整理

| # | 修正 | 条件 |
|---|---|---|
| 11 | terminal-cascade / `.closed→.failed` / resume-to-cancel / observe 直列化の縮小 | P1-1,2 と SDK cancel API の後 |
| 12 | **今すぐ削除可能**: item-status 再導出 cascade(SDK `2a4d2f5` が所有済み — 検証で確定)、dead adapter branches、`CodexReviewHost` + `DirectCodexReviewStoreBackend` | 即時 |
| 13 | login teardown の owner 化(9 fields を単一 session 型へ)、`"attempt-1"` fallback 除去、ForTesting forwarder 3 層(~100 accessors)の直接 seam 化 | 即時 |

## 7. won't-fix(観測誤りとして反証済み)

- **`test-fake-close-clean-finish-hangs-subscribers`**(fake close() で subscriber がハング): fake の `close()` は package-scoped で消費者から到達不能。public 経路 `CodexAppServer.close()` は `router.stop()` が先に throwing finish するためハングは起きない。`finishNotificationStreams(throwing:)` は public(`CK:Sources/CodexAppServerKitTesting/CodexAppServerTestRuntime.swift:1000`)。残る clean/throwing 終端の非対称は low。
- **`use-item-status-rederivation`**(SDK が item status を finalize しない): 前提が誤り。CodexKit `2a4d2f5`(2026-07-01)が全 terminal 経路で `itemByApplyingTerminalLifecycleStatus` を適用済み(`CK:Sources/CodexDataKit/CodexModel.swift:1703-1740`)、exitCode ルールも SDK 側に同一実装(:1765-1773)。CRK 側 projection cascade(`CRK:Sources/ReviewChatLogUI/ReviewMonitorCodexChatLogProjection.swift:557-596`)は live workaround ではなく削除可能な残骸 → P3-12。

## 8. テストチェックリスト

- [ ] `turn/completed(status=interrupted)` で `collect()` が throw しない — sibling: `respond()`、`progress`、DataKit `chat.phase`
- [ ] `thread/closed` 後に同 thread を resume でき、subscriber が終端しない
- [ ] 実 wire 形状(`turn/completed` + status=failed + `turn.error`)で `chat.phase == .failed` を pin(fictional `turn/failed` テスト `CK:Tests/CodexDataKitTests/CodexDataKitTests.swift:8091` の置換)
- [ ] fake: unstubbed method で fail-fast
- [ ] fake: `thread/list` が archived・sortKey・sortDirection を尊重
- [ ] cancel 中の `respond()` が `CancellationError` を投げる
- [ ] 並行 `load()` の順序(A→B→A 完了で items/cursor が一致)
- [ ] `close()` なしの drop で子プロセスが reap される
- [ ] 長寿命接続で router history が prune される
- [ ] `serverRequest/resolved` で custom handler の待機が解放される

**観測性の欠落**: `error` notification の `willRetry`(唯一の transient-retry シグナル)と `deprecationNotice` が `.unknown` 経由で不可視。typed event 化を P2-10 に含める。

## 9. 監査の限界

- low 36 件(Appendix B)は adversarial 検証を通していない(レートリミット対応で検証対象を high+medium に絞った)。
- ReviewChatLogUI / ReviewUI の view 層は core state ファイル精読 + view skim に留まる。
- `TextTransitions`、`scripts/`、`Tools/` は対象外。

---

## Appendix A: 検証済み findings(high + medium、51 件)

各項目: 検証 verdict / 調整後 severity / 位置 / 内容 / 証拠。kind: bug = 実挙動の欠陥、protocol-mismatch = upstream 契約との不一致、api-design / usability = 設計判断、coverage-gap = API 過不足、test-gap = テスト欠落、workaround = 消費側補償、architecture = 構造。

### `arch-login-state-no-owner` — Login/auth session teardown invariant has no owner: 9 mutable fields reset by hand at 7 call sites in LiveCodexReviewStoreBackend

**CONFIRMED / high / architecture** — `CodexReviewKit:Sources/CodexReviewHost/LiveCodexReviewStoreBackend.swift:218`

Login-flow state (loginChallenge, loginBackend, loginAppServer, loginCodexHomeURL, loginActivation, isWaitingForLoginAccountUpdate, activeAuthenticationSession, authenticationTask, loginNotificationTask) is torn down by manually nil-ing/cancelling each field in 7 places with subtly different orderings and subsets (cancelAuthentication, startLogin catch, monitorAuthenticationSession catch, handleAuthenticationSessionCancelled, handleLoginCompletedNotification failure, finishCompletedLoginAfterAccountUpdate, takeLoginRuntimeForCleanup). Any new exit path must replicate the full reset or leak an isolated app-server process/temp CODEX_HOME. The strongest owner-absent signal in the repo; the 2127-line class also owns app-server lifecycle, MCP HTTP server, rate-limit refresh, and account-registry persistence.

- 証拠: LiveCodexReviewStoreBackend.swift:218-227 fields; reset copies :670-702, :915-940, :974-991, :1033-1062, :1300-1321, :1338-1384, :1559-1578 — same invariant, different order/subset.
- 検証時の訂正: Field count is 10, not 9 (finding omitted authNotificationTask :226, which is app-server-scoped rather than login-scoped, so 9 login-flow fields is defensible). Reset-site count: 7 clusters as claimed, plus an 8th partial subset reset inside startLogin at :885-888 the finding missed — strengthening, not weakening, the claim.
- 修正の方向: Extract a LoginSession type (challenge + runtime + web session + tasks) with a single terminate(reason:) as the only teardown path; the backend holds at most `var loginSession: LoginSession?`.

### `ask-cancel-collect-misreported` — Cancelling a task awaiting respond()/collect() surfaces transportClosed instead of CancellationError

**CONFIRMED / high / bug** — `CodexKit:Sources/CodexAppServerKit/CodexTurnSequences.swift:490`

On task cancellation AsyncThrowingStream returns nil (does not throw), so collect()'s for-loop exits without a terminal event and throws CodexAppServerError.transportClosed — misclassifying every user cancellation as a transport failure for respond(to:), CodexResponseStream.collect(), and waitForCancelledResponse (CodexDomainTypes.swift:2111). Consumer already works around it: AppServerCodexReviewBackend checks Task.isCancelled explicitly (:753) and its `catch is CancellationError` branch (:759) is unreachable.

- 証拠: CodexTurnSequences.swift:466-491 loop then `throw CodexAppServerError.transportClosed`; CodexDomainTypes.swift:1994-2008 collect() never converts loop-exit to CancellationError; consumer workaround CodexReviewKit:Sources/CodexReviewAppServer/AppServerCodexReviewBackend.swift:753-759.
- 失敗トレース: 1) Consumer awaits thread.respond(to:) = streamResponse().collect() (CodexThreadOperations.swift:74). 2) collect() (CodexDomainTypes.swift:1994-2008) awaits turn.result() → CodexResponseCollector.collect iterating turn.events (CodexTurnSequences.swift:468). 3) Consumer cancels the awaiting Task; onCancel fires the detached `Task { try? await turn.interrupt() }` (:2002-2007); the AsyncThrowingStream iterator returns nil per cancellation semantics. 4) The for-loop exits without .completed/.failed → `throw CodexAppServerError.transportClosed` (CodexTurnSequences.swift:490). 5) collect()'s catch runs handleFailure() then rethrows (:1999-2000) — caller receives .transportClosed for a user-initiated cancel; same shape for waitForCancelledResponse (CodexDomainTypes.swift:2111).
- 修正の方向: collect()/result() own the terminal contract: after loop exit without terminal, check Task.isCancelled and throw CancellationError (or typed .cancelled); reserve transportClosed for real transport termination.

### `ask-process-leak-no-deinit` — Dropping CodexAppServer without close() leaks the spawned codex child process

**CONFIRMED / high / bug** — `CodexKit:Sources/CodexAppServerKit/AppServerProcessTransport.swift:153`

Process termination is reachable only via close()/stdout-EOF (closeTransport); neither the transport nor CodexAppServer has a deinit backstop, and the child runs in its own process group (POSIX_SPAWN_SETPGROUP), so losing the last reference orphans a running `codex app-server` process. Repeated container recreation (login change, tests forgetting close()) accumulates orphans; reaping (reapIfExited) only runs inside terminateAndWait.

- 証拠: AppServerProcessTransport.swift:153-172 close()/closeTransport only termination paths; :662-663 setpgroup; grep deinit over Sources/CodexAppServerKit = zero hits; CodexAppServer.swift:216-223 close() is sole teardown.
- 検証時の訂正: Finding understates it: not only is there no deinit backstop, a router-side retain cycle (routerTask strongly captures the router at CodexAppServerNotificationRouter.swift:89-97 while the router stores it at :19) means the transport can never deallocate without close(), so the Swift objects leak too and any dealloc-based stdin-EOF fallback is unreachable.
- 失敗トレース: 1) CodexAppServer.init spawns codex app-server in its own process group (AppServerProcessTransport.swift:60-111, :662-663) and starts the router (CodexAppServer.swift:176-179). 2) router.start() creates the routerTask retain cycle (CodexAppServerNotificationRouter.swift:19,:89-97). 3) Consumer recreates its container (login change / test forgets close()) and drops the last CodexAppServer reference without calling close() (CodexAppServer.swift:220-223, the sole teardown). 4) No deinit exists anywhere in the target; terminateAndWait is never invoked; the router/client/transport chain stays resident and the codex child keeps running. 5) Each recreation adds one orphaned codex process plus one leaked actor graph.
- 修正の方向: Transport owns 'no reachable transport ⇒ no child process': add a deinit that signals the process group (synchronous kill + detached reap) or hold the pid in a terminator token independent of actor lifetime; at minimum log the leaked pid.

### `ask-router-history-unbounded` — Notification router event history grows without bound for the connection lifetime

**CONFIRMED / high / bug** — `CodexKit:Sources/CodexAppServerKit/CodexAppServerNotificationRouter.swift:20`

turnHistoryByTurnID, threadHistoryByThreadID and threadIDByTurnID are append-only with no eviction owner; every turn-scoped event (including full rawPayload Data) is stored twice, and RequestSerializer.lanes also only grows. History is load-bearing (replay for late subscribers, waitForCancelledResponse) but nothing prunes it after a turn is terminal, so a long-lived consumer app accretes memory proportional to every delta ever streamed.

- 証拠: CodexAppServerNotificationRouter.swift:20-22 dictionaries; :302 and :315 appends; grep shows no removeValue on any of the three maps. AppServerClient.swift:208-215 lane(for:) inserts, never removes.
- 失敗トレース: 1) Consumer keeps one CodexAppServer for app lifetime (CodexReviewHost pattern) and runs reviews continuously. 2) Every streamed notification with a turnId is decoded and appended to turnHistoryByTurnID (CodexAppServerNotificationRouter.swift:302) and, when threadId resolves, again to threadHistoryByThreadID via appendThreadEvent (:297,:314-315); item events carry full rawPayload Data (:904, :1400). 3) turn/completed arrives; isTerminalTurnEvent (:512-520) only triggers finishTurnSubscribers (:308-310); both history entries for the finished turn remain forever. 4) thread/closed (:333-335) likewise removes no history. 5) After N reviews × thousands of delta events each, resident memory holds two copies of every delta ever streamed plus one SerialLane per thread (AppServerClient.swift:208-215) until process exit.
- 修正の方向: Router owns retention: prune turn history at terminal+no-replay-consumers, and drop thread history behind the current generation cursor (beginThreadEventGeneration already knows the cutoff).

### `conf-interrupted-is-failure` — User-interrupted turns are classified as failures across every SDK layer (isFailure includes interrupted/cancelled), so collect()/progress/DataKit all misreport user cancels as errors

**CONFIRMED / high / protocol-mismatch** — `CodexKit:Sources/CodexAppServerKit/CodexDomainTypes.swift:1878`

Upstream, the only turn-terminal event is turn/completed and status=interrupted is a normal non-failure outcome (interrupt → status Interrupted, error None). CodexTurnStatus.isFailure returns true for .interrupted and .cancelled and every terminal path keys off it: CodexResponseCollector/respond() throw turnFailedWithResponse, turn/review progress sequences yield phase .failed, CodexModel.fail(with:"interrupted") marks the whole chat .failed on turnCompleted and again on refresh (CodexModel.swift:1145-1151, 2371-2376), with CodexDataPhase having no non-failure interrupted terminal. waitForCancelledResponse uses a third inconsistent mapping. Consumer proof: zero collect() call sites in CodexReviewKit; the backend re-splits interrupted/cancelled back out of the failure path (AppServerCodexReviewBackend.swift:623-633) and elsewhere guesses via `error is CancellationError`, missing server-side interrupts. Cross-ref use-terminal-cascade, use-highlevel-surface-bypass, cov-invented-turn-status.

- 証拠: CodexDomainTypes.swift:1878-1885 isFailure incl. interrupted/cancelled; CodexTurnSequences.swift:303-309,440-447,477-487; CodexModel.swift:1145-1151,2371-2376; CodexDomainTypes.swift:2088-2112 divergent waitForCancelledResponse; upstream turn.rs:28-36 TurnStatus, bespoke_event_handling.rs:1438-1460 interrupt → Interrupted/error None; consumer AppServerCodexReviewBackend.swift:626-631.
- 検証時の訂正: Citation nit: TurnStatus is turn.rs:29-35 (cited 28-36); DataKit refresh re-fail is CodexModel.swift:2368-2372 (cited 2371-2376). Substance accurate.
- 失敗トレース: (1) User cancels a running turn (CodexResponseStream.cancel() -> turn/interrupt, or any server-side interrupt); (2) upstream emits turn/completed {turn.status: "interrupted", error: null} (bespoke_event_handling.rs:1448-1459); (3) router decodes .completed(CodexResponse status .interrupted) (CodexAppServerNotificationRouter.swift:659-660, :1011-1026; "interrupted" -> .interrupted CodexDomainTypes.swift:1852-1853); (4) CodexResponseCollector.collect / CodexTurn.result: result.status?.isFailure == true because isFailure includes .interrupted (CodexDomainTypes.swift:1878-1885) -> throws CodexAppServerError.turnFailedWithResponse (CodexTurnSequences.swift:482-484) — a normal user cancel surfaces as a thrown turn failure; (5) progress sequences yield phase .failed(.turnFailedWithResponse) (CodexTurnSequences.swift:303-309, :440-447); (6) DataKit marks the whole chat .failed("interrupted") on turnCompleted (CodexModel.swift:1145-1151) and again on every refresh (:2368-2372), with no non-failure interrupted phase available (CodexDataPhase.swift:3-8); (7) consumer must compensate by re-splitting interrupted/cancelled out of the failure path (AppServerCodexReviewBackend.swift terminalFailureEvents ~:626-633).
- 修正の方向: The terminal-outcome type owns the distinction: replace isFailure-driven branching with a three-way outcome (completed | interrupted | failed(TurnError)) on CodexResponse/progress phases; collect() returns the response for any terminal status, throwing only for failed/errorMessage; DataKit lands interruption as loaded/idle with turn.status == .interrupted.

### `cov-invented-login-complete` — Native web-auth login path (account/login/complete + nativeWebAuthentication) is invented; upstream never had it in any revision

**CONFIRMED / high / protocol-mismatch** — `CodexKit:Sources/CodexAppServerKit/AppServerRequests.swift:2285`

CodexKit's public 3-step native login sends account/login/start with an extra nativeWebAuthentication:{callbackUrlScheme} field, decodes it back from the response, and completeLogin sends method account/login/complete. None of this exists upstream at HEAD 8347b8d and `git log --all -S` shows it never existed. Against a stock server: the extra field is silently ignored, the response never echoes nativeWebAuthentication, so the consumer's gate `completesLoginThroughCallback: nativeCallbackScheme != nil` is always false and the ASWebAuthenticationSession callback-completion feature silently never engages; completeLogin would fail method-not-found. Consumer ships real wiring and CodexKit's README documents it as standard API with no fork requirement noted. If a patched codex build is intentionally targeted, that dependency is undocumented and unpinned.

- 証拠: AppServerRequests.swift:2285 method, :2144-2162 NativeWebAuthentication + Params field; CodexAppServer.swift:799-812,855-862; upstream common.rs:1001-1013 no login/complete, account.rs:68-86,124-137 no nativeWebAuthentication; git log --all -S in /Users/kn/Dev/codex returns nothing; consumer LiveCodexReviewStoreBackend.swift:911,961; README.md:418-421.
- 検証時の訂正: Citation fix: the README documenting the flow is CodexKit Sources/CodexAppServerKit/README.md:414-421, not the top-level README.md:418-421 (top-level README has no login content, 94 lines). Method line is AppServerRequests.swift:2285 as cited.
- 失敗トレース: Against a stock codex app-server: (1) CodexAppServer.loginChatGPT(nativeWebAuthentication:) sends account/login/start with extra field nativeWebAuthentication:{callbackUrlScheme} (CodexAppServer.swift:799-812; AppServerRequests.swift:2162,2255); (2) upstream deserializes LoginAccountParams::Chatgpt which has no such field (account.rs:68-86) — extra field silently ignored, no deny_unknown_fields; (3) response is {type:"chatgpt", loginId, authUrl} only (account.rs:~125-137), so decodeIfPresent(nativeWebAuthentication) yields nil (AppServerRequests.swift:2207-2210) and CodexChatGPTLogin.nativeWebAuthentication == nil; (4) consumer gate completesLoginThroughCallback: nativeCallbackScheme != nil is always false (LiveCodexReviewStoreBackend.swift:911), so the ASWebAuthenticationSession callback-completion feature never engages, silently; (5) any caller that follows the README's documented step 3 and calls completeLogin sends method account/login/complete (AppServerRequests.swift:2285) which no codex revision has ever implemented -> JSON-RPC method-not-found at runtime.
- 修正の方向: Wire layer owns method-name truth: delete the invented surface, or document and pin the fork as the supported server and gate the API on a capability check — a nonexistent method must not be a public API's only completion path.

### `cov-rollback-deprecated` — Review restart, rollback(turnCount:) and revertTranscript are built on thread/rollback, which upstream marks 'will be removed soon'

**CONFIRMED / high / coverage-gap** — `CodexKit:Sources/CodexAppServerKit/CodexAppServer.swift:510`

Three public behaviors depend on thread/rollback: CodexThread.rollback(turnCount:), restartPreparedReview's mandatory rollback of the interrupted turn, and transcriptErrorHandlingPolicy .revertTranscript (CodexResponseStream.handleFailure). Upstream: 'DEPRECATED: thread/rollback will be removed soon.' The consumer's core review-recovery flow calls prepareReviewRestart/restartPreparedReview; when upstream removes the method, restart fails at runtime with method-not-found mid-recovery, after the turn was already interrupted. Compounding: deprecationNotice notifications are surfaced only as .unknown (cross-ref cov-error-warning-untyped), so the removal warning is invisible.

- 証拠: CodexAppServer.swift:505-513 rollback in restart; CodexThreadOperations.swift:335-339; CodexDomainTypes.swift:2127-2135,2185-2193 revert policy; AppServerRequests.swift:1469 method; upstream thread.rs:1045 deprecation, common.rs:616; consumer CodexReviewStoreReviews.swift:676,744.
- 修正の方向: Decide what restart/revert mean without rollback (upstream direction is fork/resume-based history editing), isolate the dependency behind one internal seam, and surface deprecationNotice as a typed event so consumers get the removal signal.

### `dx-error-taxonomy-uncatchable` — Public API throws package/private error types; CodexAppServerError taxonomy is mostly dead — consumers cannot catch anything by type

**CONFIRMED / high / api-design** — `CodexKit:Sources/CodexAppServerKit/JSONRPC.swift:33`

Every request rethrows package-scoped JSONRPC.Error unmapped (uncatchable by type); the most common first-run failure (codex not installed) throws private AppServerProcessTransportError; undecodable responses throw raw DecodingError. CodexAppServerError's serverBusy/retryLimitExceeded/malformedNotification have zero throw sites, .jsonRPC is thrown only for client-side login-URL validation with a fabricated -32602, and after overload retries the raw JSONRPC.Error is rethrown instead of .retryLimitExceeded. router.stop() also finishes all event streams with JSONRPC.Error.closed even on graceful close(), so long-lived for-await loops throw an untypeable error on normal shutdown. Consumer confirms: zero typed catches in CodexReviewKit, 30+ localizedDescription reductions — binary-missing, server-rejection and SDK decode bugs render identically.

- 証拠: JSONRPC.swift:3,33-48 package enum; AppServerClient.swift:115-134 rethrows unmapped; AppServerProcessTransport.swift:873 private error enum; CodexDomainTypes.swift:2839-2841 dead cases (grep: declaration-only); CodexAppServer.swift:1105-1133 only .jsonRPC sites; router stop CodexAppServerNotificationRouter.swift:168-172; consumer LiveCodexReviewStoreBackend.swift:511 et al.
- 検証時の訂正: Consumer localizedDescription count is 37 (finding said 30+ — consistent).
- 修正の方向: AppServerClient owns the transport→domain error boundary: map JSONRPC/transport/decode failures into public CodexAppServerError cases (spawnFailed, serverError(code:message:), invalidResponse, transportClosed) at the single send boundary, delete or wire the dead cases, and finish streams without error on graceful close.

### `dx-no-timeout-story` — No deadline/timeout anywhere: init handshake, every request, and collect() can hang forever with no dedicated timeout error

**CONFIRMED / high / api-design** — `CodexKit:Sources/CodexAppServerKit/AppServerClient.swift:89`

No timeout mechanism exists in CodexAppServerKit (grep-verified; the only Duration uses are shutdown grace and turn metadata). CodexAppServer.init awaits the initialize handshake with no deadline (wedged binary hangs app startup forever); every request parks a CheckedContinuation resolved only by response or transport close; collect()/turn streams finish only on a terminal turn event or close — the router finishes thread subscribers on thread/closed but not turn subscribers, so one missing turn/completed wedges collect() permanently. No TimeoutError type exists. The consumer compensates with hand-rolled timeout scaffolding (observation awaiter, worker drain, test wrappers).

- 証拠: AppServerClient.swift:89-137 no deadline; AppServerProcessTransport.swift:113-131 parked continuation; router :308-310 vs :333-335 asymmetry; CodexDomainTypes.swift:404-441 no deadline field; consumer ReviewObservationAwaiter.swift:40-56, CodexReviewStoreCancellation.swift:243-254, CodexReviewStoreReviews.swift:34-59.
- 修正の方向: AppServerClient owns per-request deadlines (optional Duration raced via structured concurrency, dedicated public timeout error distinct from transportClosed); Configuration owns the handshake deadline; streaming turns get an inter-event-gap deadline.

### `test-store-ignores-archived-and-sort` — Store-backed thread/list ignores archived, sortKey and sortDirection — parameters DataKit always sends and whose serialization is itself pinned by tests

**CONFIRMED / high / protocol-mismatch** — `CodexKit:Sources/CodexAppServerKitTesting/CodexAppServerTestRuntime.swift:706`

filteredThreadSnapshots filters only cwd/modelProviders/sourceKinds/searchTerm. With the store: archived:true and archived:false queries return identical membership with every thread stamped with the query's archived flag (fabricated scoping), and list order is store insertion order rather than the recency/created_at descending order DataKit explicitly trusts. Consumer previews already hand-stub thread/archive and track archived IDs themselves — the workaround signal that the store's mutation/scope owner is missing.

- 証拠: CodexAppServerTestRuntime.swift:706-754 (no archived/sortKey/sortDirection reference); Params carry them AppServerRequests.swift Thread.List.Params; DataKit pins them CodexAppServerKitTests.swift:592-618; archived stamped CodexAppServer.swift:657; upstream thread.rs:1077-1094; consumer workaround ReviewMonitorPreviewAppServerRuntime.swift:335-341.
- 検証時の訂正: The citation 'archived stamped CodexAppServer.swift:657' is imprecise: :657 only serializes query.archived into the request; the stamping owner is DataKit's CodexFetchRequest.swift:1134-1139, which sets isArchived from the query scope on every returned chat. List order is init-order with upsert-moved-to-front (recency-of-mutation), not strict insertion order, but it still ignores sortKey/sortDirection and the upstream created_at-descending default. Upstream cite is protocol/v2/thread.rs.
- 失敗トレース: 1) Test seeds store with threads T1,T2 and wires stubThreads (CodexAppServerTestRuntime.swift:569-585). 2) DataKit archive view issues thread/list with archived:true (CodexModelContext.swift:2395-2399 -> CodexAppServer.swift:657). 3) Store's listThreadResponse -> filteredThreadSnapshots ignores request.archived (CodexAppServerTestRuntime.swift:706-754) and returns T1,T2. 4) DataKit stamps both isArchived=true (CodexFetchRequest.swift:1139). 5) The archived:false query returns the identical membership stamped false — archived and non-archived views show the same threads, contradicting v2/thread.rs:1091-1094. Sort: a sortKey:created_at/desc request returns raw snapshotOrder (:68) regardless of the requested key/direction.
- 修正の方向: CodexAppServerTestThreadStore owns the full thread/list contract it advertises: honor archived scope, sort by requested key/direction with upstream defaults, and back archive/unarchive/delete mutations so consumers stop re-implementing them.

### `use-item-identity-text-dedup` — UI dedups review output and reasoning mirrors by normalized-text equality and re-parses rawPayload JSON to absorb unstable item identity

**CONFIRMED / high / workaround** — `CodexReviewKit:Sources/ReviewChatLogUI/ReviewMonitorCodexChatLogProjection.swift:624`

One logical entry reaches the consumer as multiple items with different IDs (review output as exitedReviewMode item AND assistant message; one reasoning entry under two payload kinds: agent_reasoning event mirror + reasoning item). The projection maintains three text-equality compensation mechanisms — ReviewOutputKey turn-scoped dedup, the PendingReasoningMirrors pairing state machine keyed by scopeID+trimmed text, and RawPayloadKind JSON-decoding of item.rawPayload because the typed API exposes no payload-kind discriminator. Recurrence: 7 of 11 commits touching the file fix this dedup/status area (45b64f1, 537a9e4, 4c79ed5...). The SDK independently does its own text-signature fallback resolution (CodexFallbackAgentMessageSignature) — the same identity invariant implemented twice at two layers with no owner (cross-ref dk-optional-delta-id-workaround-layer).

- 証拠: ReviewMonitorCodexChatLogProjection.swift:94-107,137-141,258-314 output dedup; :619-651 PendingReasoningMirrors; :316-323,653-674 RawPayloadKind rawPayload decode; SDK twin CodexModel.swift:53-58,926-945,1323-1332; git log --follow fix churn.
- 修正の方向: CodexDataKit owns canonical item identity: one persisted item per logical entry with stable itemID and a typed payloadKind discriminator; consumer text-matching and raw-JSON parsing then die.

### `use-terminal-cascade` — Three-layer terminal-status cascade in the consumer compensates for the SDK's missing cancelled-terminal contract

**CONFIRMED / high / workaround** — `CodexReviewKit:Sources/CodexReviewKit/Store/CodexReviewStoreReviews.swift:812`

Because CodexKit has no first-class cancelled terminal (interrupted classified as failure; cross-ref conf-interrupted-is-failure), the consumer rewrites terminal status at three layers: backend adapter re-derives .cancelled from interrupted/cancelled status; ReviewBackendEventSession emits a synthetic .cancelled on finish and ignores all later events via a finished flag (metrics.ignored instruments expected duplicate/late terminals); the store's completePendingCancellationIfNeeded is called at 7 sites and rewrites ANY backend terminal to cancelled while cancellationRequested is set. Expected: one typed terminal per turn from the SDK.

- 証拠: CodexReviewStoreReviews.swift:812 (also 685,702,706,729,735,843); ReviewBackendEventSession.swift:124-127 finished guard, :144-146 synthetic .cancelled; AppServerCodexReviewBackend.swift:627-633; SDK CodexDomainTypes.swift:1878-1882, router :661,:748.
- 検証時の訂正: completePendingCancellationIfNeeded has 6 call sites (CodexReviewStoreReviews.swift:685,702,706,729,735,812), not 7; 7 counts the definition at :843. Everything else accurate.
- 修正の方向: CodexAppServerKit owns terminal typing: review surfaces deliver exactly one typed terminal (completed|cancelled|failed) per turn, deriving cancelled from turn/completed+interrupted; consumer layers collapse to record-keeping.

### `arch-attempt-id-fallback` — attemptID identity is fabricated by "attempt-1" fallbacks and unknown attempts silently get a fresh registered event session that clobbers thread registries

**CONFIRMED / medium / bug** — `CodexReviewKit:Sources/CodexReviewAppServer/AppServerCodexReviewBackend.swift:349`

Attempt identity gates event consumption and session lookup, yet is defaulted in three layers (Run.init default, decode fallback, backendRun reconstruction all "attempt-1"). When cancelReview takes the backendRun fallback branch and the backend has no session for that attemptID, reviewEventSession(for:) silently creates AND registers a new session, overwriting activeReviewAttemptIDByThreadID and the canonical-threadID map for all associated threads — a get-or-create mutation on what callers treat as a lookup. Same fallback-identity pattern the prior CodexKit audit flagged, one layer up.

- 証拠: AppServerCodexReviewBackend.swift:349-358 get-or-create+register, :360-382 registry overwrite; CodexReviewTypes.swift:239,254 fallbacks; CodexReviewStoreReviews.swift:906 reconstruction fallback, :431-450 caller branch, :1027-1029 attemptID gate.
- 検証時の訂正: The registry-clobber harm is narrower than the wording implies: reaching the fallback branch with a live competing attempt on the same threadID requires a persisted record whose attemptID is nil while another attempt reuses that threadID (thread reuse exists — restartPreparedReview keeps interruptedRun.threadID :247 — but restarts persist real attemptIDs via applyBackendRun :237, so the collision needs legacy data). The unconditional facts stand: a cancel of a stale record fabricates identity and mutates registries via what every caller treats as a lookup.
- 失敗トレース: 1) Run record persisted with threadID set but attemptID nil (legacy schema; ReviewRunCore.swift:5 Optional, CodexReviewTypes.swift:254 decode fallback). 2) After relaunch, runtimeState has no activeRun, so cancelReview takes the backendRun branch (CodexReviewStoreReviews.swift:431) with fabricated attemptID "attempt-1" (:906). 3) backend.interruptReview → AppServerCodexReviewBackend.swift:187 reviewEventSession(for:) → no session for "attempt-1" → new AppServerReviewEventSession created and registered (:355-356). 4) registerReviewEventSession overwrites activeReviewAttemptIDByThreadID[threadID]="attempt-1" and canonical map for all associated threads (:373-380); any later thread-keyed lookup (finishReviewEventStream :447, metrics :324) resolves to the fabricated session instead of a real one. 5) The new session has no reviewSession, so cancelReviewTurn's session path returns nil (:736-738) and the code silently resume-and-cancels via appServer (:466-470) — a phantom session remains registered for a nonexistent attempt.
- 修正の方向: Backend owns attempt identity: interrupt/cleanup for an unknown attemptID is a no-op-with-log or explicit error, never a fabricated registered session; drop the "attempt-1" fallbacks and make attemptID non-optional at the store record so missing identity fails fast.

### `arch-closed-maps-to-failed` — Consumer maps CodexReviewEvent.closed (upstream idle-unload, resumable) to review failure

**CONFIRMED / medium / protocol-mismatch** — `CodexReviewKit:Sources/CodexReviewAppServer/AppServerCodexReviewBackend.swift:584`

AppServerTypedReviewEventAdapter maps .closed → [.failed("Review thread closed.")] and statusChanged(.notLoaded) → failed, turning an unload notification into a terminal user-visible failure. The SDK forwards .closed with no semantics and its progress sequence silently ends on it (cross-ref ask-thread-closed-terminal), so the consumer invents semantics. Harmless today only because the finished-flag terminal-cascade guard ignores post-terminal events; if .closed ever precedes the terminal (e.g. deferred deleteThread ordering changes), a successful review is recorded failed. The backend already has restart/resume machinery (prepareReviewRestart/resumeReview) that .closed bypasses.

- 証拠: AppServerCodexReviewBackend.swift:583-584, :574-575; restart machinery :201-257,466-470; upstream thread_lifecycle.rs:397-436; SDK pass-through CodexDomainTypes.swift:720,749-750; CodexTurnSequences.swift:329-331.
- 検証時の訂正: Minor: the post-terminal protection is BackendReviewEventMailbox.terminal (append guard in CodexReviewBackend.swift), not the ReviewBackendEventSession `finished` flag — that flag (ReviewBackendEventSession.swift:44,124) is only set by finish()/abandon(), not on terminal emit (receive() at :133-137 returns without setting finished). The protective effect is as described. Also, upstream ordering makes the latent bug hard to hit: unload requires the thread to be idle (turn already completed), so turn/completed reaches the mailbox first in the observed server code.
- 失敗トレース: Latent path (guarded today): 1) review turn completes → adapter emits .completed (AppServerCodexReviewBackend.swift:553-554,590-607) → mailbox.terminal=.finished (CodexReviewBackend.swift append). 2) app-server later unloads the idle review thread → thread/closed (thread_lifecycle.rs:429-434) → SDK forwards .closed (CodexDomainTypes.swift:749-750) → adapter converts to .failed("Review thread closed.") (AppServerCodexReviewBackend.swift:583-584) → dropped only by the mailbox terminal guard. If .closed ever reaches the mailbox before the terminal (guard removed, or ordering change), the completed review is recorded failed. The mapping itself (unload → user-visible failure) is the confirmed protocol mismatch.
- 修正の方向: Adapter classifies .closed as an interruption eligible for the existing restart path (or a distinct terminal reason), not a failure — ultimately fixed by the SDK modeling .closed as non-terminal unload.

### `arch-host-target-test-only` — CodexReviewHost + DirectCodexReviewStoreBackend are production code with only test callers, duplicating Live backend adaptation logic

**CONFIRMED / medium / architecture** — `CodexReviewKit:Sources/CodexReviewHost/CodexReviewHost.swift:45`

CodexReviewHost and its private DirectCodexReviewStoreBackend have no production callers (the app composes via CodexReviewStore.makeLiveStore); only CodexReviewHostTests use them. DirectCodexReviewStoreBackend re-implements the Live backend's snapshot/auth adaptation without persistence — two maintained copies already showing copy-drift: the dead ternary `selectedAccount == nil ? .signedOut : .signedOut` appears in both.

- 証拠: grep CodexReviewHost( → only CodexReviewHostTests.swift:101,116,150; app composition CodexReviewMonitorApp.swift:288; duplicated mappings CodexReviewHost.swift:81-101,246-291 vs LiveCodexReviewStoreBackend.swift:590-613,1102-1163,1641-1651; dead ternary CodexReviewHost.swift:155,160 and LiveCodexReviewStoreBackend.swift:697,1161.
- 修正の方向: Delete the class and test the store against a CodexReviewTesting fake of CodexReviewBackend, or promote it to the real headless composition root sharing mapping helpers with the Live backend — one owner for backend→store adaptation.

### `arch-testing-forwarder-chains` — ~100 ForTesting accessors mechanically forwarded through three layers (scroll view → chat-log target → transport VC)

**CONFIRMED / medium / test-gap** — `CodexReviewKit:Sources/ReviewChatLogUI/ReviewMonitorCodexChatLogTarget.swift:351`

ReviewMonitorCodexChatLogTarget devotes ~510 of its 861 lines to a DEBUG extension forwarding every test probe to logScrollView; ReviewMonitorTransportViewController repeats the list one layer up (~570 lines) prefixed with `log`. Every new leaf capability requires three mechanical wrapper edits — tests lack a direct seam to the leaf render surface, and the noise hides the two types' real contract (bind/clear/render).

- 証拠: ReviewMonitorCodexChatLogTarget.swift:351-861 (:373-379 example); ReviewMonitorTransportViewController.swift:205-771 (:247-257 same accessors re-wrapped).
- 検証時の訂正: Accessor count is slightly above the finding's "~100": 107 at the target layer and 124 at the VC layer (the VC adds a few of its own probes, e.g. placeholder state :235-245, that are not forwards). Line spans as cited.
- 修正の方向: Expose the leaf inspection object once (DEBUG-only Inspector at each level, or let tests reach the scroll view directly) so probes are defined in exactly one place.

### `ask-interrupt-error-string-parsing` — turn/interrupt correctness depends on parsing upstream error message strings, plus a fixed 5x50ms retry that also fires for already-finished turns

**CONFIRMED / medium / workaround** — `CodexKit:Sources/CodexAppServerKit/CodexThreadOperations.swift:513`

interruptCodexTurn discovers the active turn by splitting the server error message on " but found " (activeTurnID) and retries on lowercase substrings "no active turn"+"interrupt", sending turnId:"" as a deliberate mismatch probe. These match today's exact format! strings (which already differ between upstream call sites) and are not a contract — any rewording silently breaks cancel. Upstream returns the same 'no active turn' error for both not-yet-activated and already-terminal turns, so cancelling a just-finished turn burns ~250ms of retries then throws an untypeable JSONRPC.Error instead of being treated as already-cancelled. The post-loop `throw CancellationError()` (:496) is unreachable. Root cause is an upstream affordance gap (no structured code / active-turn query); cross-ref conf-error-payload-discarded.

- 証拠: CodexThreadOperations.swift:465-532 retry loop, activeTurnID parse, isExpectedTurnNotActive; upstream /Users/kn/Dev/codex/codex-rs/app-server/src/request_processors/turn_processor.rs:904,1364-1373 differing message shapes and :1371 terminal-turn same-error path.
- 検証時の訂正: One evidence claim is wrong: `turnId:""` is not a 'deliberate mismatch probe'. Upstream treats empty turn_id as a startup interrupt (turn_processor.rs:1352,:1358,:1389) that bypasses the active-turn check and interrupts whatever is running, succeeding without error; CodexKit only sends "" when turnID is nil (CodexThreadOperations.swift:507-510, e.g. cancelActiveTurn(expectedTurnID: nil) :233-243). The ' but found ' discovery fires only when a non-empty stale turnID is sent. Core finding (string coupling, wasted retry on terminal turns, unreachable :496) stands.
- 失敗トレース: 1) Turn finishes; UI cancel races it: CodexResponseStream.cancel() → interruptCodexTurn (CodexThreadOperations.swift:466). 2) Server replies invalid_request 'no active turn to interrupt' (turn_processor.rs:1370-1373). 3) isExpectedTurnNotActive matches (:524-532) → sleep 50ms, retry; repeats 5 times (~250ms+ RPC latency) (:472-481,:499-500). 4) Attempt 5: retry gate fails; message has no ' but found ' so activeTurnID is nil → `throw error` (:482-485) — the untypeable package JSONRPC.Error surfaces for what is semantically an already-cancelled success. Separately, any upstream rewording of these format! strings silently breaks both the retry match and active-turn redirect.
- 修正の方向: Consult router history (hasTerminalTurnEvent) before retrying so locally-known-terminal turns are idempotent successful cancels; resolve the active turn via thread/read instead of the error probe; push upstream for structured error codes, and key retry/redirect on typed error data once error.data is carried through.

### `ask-thread-closed-terminal` — thread/closed (idle unload, resumable) is treated as the terminal thread event, permanently finishing subscribers and ending review sequences without a result

**CONFIRMED / medium / protocol-mismatch** — `CodexKit:Sources/CodexAppServerKit/CodexAppServerNotificationRouter.swift:333`

Upstream emits thread/closed when an idle, subscriber-less thread is unloaded from memory — resumable, not terminal. The router finishes all thread subscribers on .closed and isTerminalThreadEvent is true only for .closed; new subscribers finish immediately while .closed is in the current generation. CodexReviewProgressSequence returns nil on .closed without ever yielding a terminal phase, CodexReviewEventSequence reports .closed as terminal, and CodexResponseCollector throws .transportClosed when a stream ends without turn/completed even though the transport is fine. Consumers are forced to invent semantics (see arch-closed-maps-to-failed) and passive thread.events observers see their loop end on server GC of an idle thread.

- 証拠: Router :333-335 finishThreadSubscribers on .closed, :522-527 isTerminalThreadEvent; CodexTurnSequences.swift:155-157,:238-239,:329-331,:344-345,:490; upstream /Users/kn/Dev/codex/codex-rs/app-server/src/request_processors/thread_lifecycle.rs:397-435 idle-unload emits ThreadClosedNotification{thread_id} only.
- 失敗トレース: 1) Consumer holds a passive `for await event in thread.events` observer (CodexThreadOperations.swift:9-27) on a thread that goes idle with no server-side subscribers. 2) Upstream unloads it and emits thread/closed (thread_lifecycle.rs:397-435) — thread still resumable via thread/resume (common.rs:488). 3) Router decodes .closed (CodexAppServerNotificationRouter.swift:822-823) and permanently finishes every thread subscriber (:333-335). 4) Any new subscriber for that thread finishes immediately because .closed sits in the current generation (:378-381,:388-392,:522-527). 5) A CodexReviewProgressSequence consumer's loop ends with no terminal phase ever yielded (CodexTurnSequences.swift:329-331), so the review appears to vanish rather than remain resumable — SDK invents terminal-ness the protocol does not promise.
- 修正の方向: Router owns thread-stream lifetime: model .closed as a non-terminal 'unloaded' state (subscribers stay open or finish with a distinct reason), give 'ended without terminal event' its own error instead of transportClosed, and keep terminal-ness tied to connection close and explicit archive/delete.

### `conf-command-delta-clobbers-item` — commandExecution/fileChange output deltas replace the transcript item, wiping command text and prior output during streaming

**CONFIRMED / medium / bug** — `CodexKit:Sources/CodexAppServerKit/CodexAppServerNotificationRouter.swift:887`

itemUpdate builds a CodexThreadItem with content .command(.init(command: "", output: <this delta only>)) and CodexTranscriptAccumulator.upsert does items[index] = item, wholesale-replacing the item/started item (which carried the real command/cwd) — transcript consumers see the command string vanish and output show only the LAST delta chunk instead of the concatenation upstream guarantees. item/completed later restores the item, so corruption is transient but visible for the whole command runtime. CodexDataKit independently compensates with accumulatesOutputDeltas merge logic — the recurrence signal that the merge invariant has no owner in the shared accumulator. Cross-ref ask-delta-random-item-identity (identity half of the same function).

- 証拠: CodexAppServerNotificationRouter.swift:887-905; CodexTurnSequences.swift:667-668 replace-on-upsert; upstream concatenation contract app-server README:1399, item.rs:1400-1408; compensator CodexModel.swift:1193-1197.
- 検証時の訂正: Citation nit: upstream README's explicit 'concatenate delta values' sentence at :1399 is in the agentMessage section; for commandExecution the chunk-append semantics follow from README:697-705 (zero or more outputDelta chunks for the same item id) rather than an explicit concatenation sentence. Does not change the conclusion: showing only the last chunk and erasing command/cwd is wrong under either reading.
- 失敗トレース: (1) Server: item/started with commandExecution item {id: "item_1", command: "cargo test", cwd: "/repo"} -> accumulator stores full item (router :753-757; CodexTurnSequences.swift:670-672); (2) server streams item/commandExecution/outputDelta {itemId: "item_1", delta: "chunk A"} -> router itemUpdate builds CodexThreadItem(id: "item_1", content: .command(command: "", output: "chunk A")) (router :887-905); (3) upsert finds index for "item_1" and executes items[index] = item (CodexTurnSequences.swift:667-668) — command text and cwd vanish from the transcript, output shows only "chunk A"; (4) next delta {delta: "chunk B"} replaces again -> output shows only "chunk B", never "chunk Achunk B"; (5) any CodexThreadTranscriptSequence / CodexReviewProgressSequence / CodexResponseStream snapshot consumer renders the corrupted item for the entire command runtime until item/completed's aggregatedOutput restores it. CodexDataKit consumers are shielded only by the per-layer compensator (CodexModel.swift:1193-1197).
- 修正の方向: Transcript accumulator owns item-merge semantics: typed partial updates (append output, never replace command/cwd/status) in one place consumed by both the accumulator and DataKit, deleting per-layer compensators.

### `conf-error-payload-discarded` — CodexErrorInfo and JSON-RPC error.data are dropped everywhere, forcing string-matching on error messages

**CONFIRMED / medium / coverage-gap** — `CodexKit:Sources/CodexAppServerKit/AppServerRequests.swift:1140`

Upstream TurnError = {message, codexErrorInfo?, additionalDetails?} with a rich enum (contextWindowExceeded, usageLimitExceeded, activeTurnNotSteerable{turnKind}, ...), and steer/interrupt failures serialize the full TurnError into JSON-RPC error.data. CodexKit decodes only {message} and the transport discards error.data entirely. Consequences: consumers cannot distinguish error classes without parsing prose; CodexKit itself must string-match upstream error text for interrupt retry/redirect (cross-ref ask-interrupt-error-string-parsing); `error` notifications' structured payload is invisible (cross-ref cov-error-warning-untyped).

- 証拠: AppServerRequests.swift:1140-1147 message-only; AppServerProcessTransport.swift:251-258 data never touched; upstream thread_data.rs:266-275 TurnError, shared.rs:63-111 CodexErrorInfo, turn_processor.rs:910-941 TurnError in error.data.
- 検証時の訂正: Citation nits: CodexErrorInfo enum body is shared.rs:~92-133 (cited 63-111 — that range covers the doc comment/TurnError vicinity); TurnError-into-error.data is turn_processor.rs:921-951 (cited 910-941, same code block); the file is app-server/src/request_processors/turn_processor.rs. Substance accurate.
- 修正の方向: Transport carries error.data through JSONRPC.Error; decode TurnError/CodexErrorInfo once (with .other catch-all) so flow control and consumer UX key off typed codes.

### `conf-ratelimits-replace-not-merge` — account/rateLimits/updated is replace-applied instead of merged into the last snapshot

**CONFIRMED / medium / protocol-mismatch** — `CodexKit:Sources/CodexAppServerKit/CodexAppServer.swift:1166`

Upstream documents the notification as a sparse rolling update ('merge available values into the most recent read response... does not clear a previously observed value'). CodexAppServer.accountEvent builds a brand-new CodexRateLimits from only the notification, so an update carrying only primary clears secondary and planType for consumers treating the event as current state; no merge owner is exposed. The read response also silently drops rateLimitResetCredits, credits, limitName, individualLimit.

- 証拠: CodexAppServer.swift:1166-1182; AppServerRequests.swift:1839-1884 partial decode; upstream account.rs:505-515 sparse-merge doc, :289-295 dropped fields.
- 検証時の訂正: Citation nits: the sparse-merge doc is account.rs:495-506 (cited 505-515); of the dropped fields, rateLimitResetCredits is at account.rs:~294 in GetAccountRateLimitsResponse while limitName/credits/individualLimit (plus rateLimitReachedType, not listed in the finding) are RateLimitSnapshot fields at account.rs:516-529 (finding cited :289-295 for all). Substance accurate.
- 失敗トレース: (1) Client reads full snapshot: primary+secondary windows and planType populated; (2) server later emits account/rateLimits/updated carrying only {limitId: "codex", primary: {...}} — legal per the sparse-update contract (account.rs:495-506, all RateLimitSnapshot fields Optional :516-529); (3) CodexAppServer.accountEvent decodes it and constructs a brand-new CodexRateLimits from only that payload (CodexAppServer.swift:1166-1182); (4) a consumer treating .rateLimitsUpdated as current state (the natural reading of an event named 'updated' with no partial-delta typing) now observes secondary == nil and planType == nil — previously observed values read as cleared, violating the upstream 'does not clear a previously observed value' contract; no SDK API exposes the previous snapshot to merge against.
- 修正の方向: CodexAppServer holds the last snapshot and emits merged state (or explicitly types the event as a partial delta) so 'absent field' can never read as 'cleared value'.

### `conf-server-request-resolved-ignored` — serverRequest/resolved is never handled, so aborted server requests leave client handlers hanging

**CONFIRMED / medium / coverage-gap** — `CodexKit:Sources/CodexAppServerKit/CodexAppServerNotificationRouter.swift:824`

Upstream aborts pending server→client requests on turn start/complete/interrupt and announces it via serverRequest/resolved {threadId, requestId}. CodexKit routes it to .unknown and nothing correlates it with in-flight serverRequestHandler invocations: a custom handler awaiting user input waits forever (its Task in AppServerProcessTransport.respond is never cancelled) and its late answer is silently ignored server-side. Invisible with the default auto-decline handler, inherited by any consumer implementing interactive approvals. Cross-ref cov-server-requests-untyped.

- 証拠: Router decodeThreadEvent default → .unknown (CodexAppServerNotificationRouter.swift:824-826); unmanaged handler tasks AppServerProcessTransport.swift:234-245,289-313; upstream v2/notification.rs:50-56 ServerRequestResolvedNotification, abort sites bespoke_event_handling.rs:154,184,1048.
- 検証時の訂正: Citation nit: ServerRequestResolvedNotification is at v2/notification.rs:52-57 (finding cited :50-56); abort call sites are :154, :184, :1047-1049. Substance accurate.
- 修正の方向: Transport (owner of server-request lifecycle) tracks in-flight server requests by id, observes serverRequest/resolved, and cancels the corresponding handler task / exposes cancellation to the handler API.

### `cov-dead-compat-notifications` — Router decodes four notifications that do not exist upstream (turn/failed, turn/cancelled, item/updated, agent/message); dead paths drive live machinery and consumer fixtures

**CONFIRMED / medium / protocol-mismatch** — `CodexKit:Sources/CodexAppServerKit/CodexAppServerNotificationRouter.swift:661`

None of these methods exist in upstream v2 ServerNotification (common.rs:1613-1710; grep: 0 hits). Consequences: (1) public .turnFailed can never fire — real failures arrive only as turn/completed status=failed, so consumers switching on .turnFailed see nothing, and generation-boundary logic carries dead .turnFailed branches (:567-570); (2) the agent/message path is the sole producer of the fallback-ID system (CodexAgentMessageFallbackID, upsert(replacingFallbackID:), CodexModel text-signature dedup) — dead protocol surface driving live complexity; (3) consumer previews are built on item/updated (ReviewMonitorPreviewAppServerRuntime.swift:563) and deprecated item/fileChange/outputDelta (:632), and SDK tests feed agent/message and turn/failed fixtures, so fakes exercise flows no real server produces. Cross-ref: test-fictional-turn-failed-pins-phase-contract, dk-optional-delta-id-workaround-layer, conf-interrupted-is-failure.

- 証拠: Router :661-662,:668,:698-706,:748-751,:758-762,:788-796 dead method cases; upstream /Users/kn/Dev/codex/codex-rs/app-server-protocol/src/protocol/common.rs:1613-1717 has only TurnStarted/TurnCompleted for turn lifecycle; grep for the four quoted method strings in app-server-protocol/src returns nothing; fallback machinery CodexDomainTypes.swift:2234-2249, CodexTurnSequences.swift:647-693; fixtures CodexAppServerKitTests.swift:3541,3575,3662, CodexDataKitTests.swift:8091.
- 検証時の訂正: One sub-claim is imprecise: agent/message is not the SOLE producer of the fallback-ID system. Fallback IDs are also minted by item/agentMessage/delta events whose itemID is absent (router AgentMessageDeltaPayload.itemID optional, CodexAppServerNotificationRouter.swift:1084-1096; CodexTurnSequences.swift:675-689 append(delta,fallbackItemID:)). agent/message is the sole producer of .message events that drive upsert(replacingFallbackID:) resolution. The thrust survives because upstream requires item_id on agent-message deltas (item.rs:1333-1338 AgentMessageDeltaNotification.item_id: String, non-optional), so the delta-side fallback path is equally dead against a real v2 server. Also minor: dead .turnFailed generation-boundary branches are at router :485, :549, :574-575 (finding cited :567-570).
- 失敗トレース: Consumer switches on public CodexThreadEvent.turnFailed (e.g. CodexReviewKit:Sources/CodexReviewAppServer expects failure events): (1) real server fails a turn -> emits only turn/completed with turn.status=failed (upstream common.rs:1636 TurnCompleted is the only turn-terminal notification; TurnStatus turn.rs:29-35); (2) CodexKit router decodes it as .turnCompleted(response) (CodexAppServerNotificationRouter.swift:746-747), never .turnFailed (:748-752 requires method turn/failed|turn/cancelled which no server sends, grep 0 in app-server-protocol/src); (3) the consumer's .turnFailed branch never executes; failure must be re-derived from response.status/errorMessage. Meanwhile SDK tests and previews pass because their fakes emit the nonexistent methods (CodexAppServerKitTests.swift:3541; ReviewMonitorPreviewAppServerRuntime.swift:562), so fakes diverge from any real server.
- 修正の方向: Router owns the wire-method surface: delete nonexistent-method branches (or synthesize .turnFailed from turn/completed+failed so the typed event means what it says), make delta itemId required, delete the fallback-ID machinery they feed, and migrate preview/test fixtures to real v2 notifications.

### `cov-error-warning-untyped` — error/warning/deprecationNotice/configWarning are specially routed but never typed; turn/completed decode failure degrades to synthetic success

**CONFIRMED / medium / coverage-gap** — `CodexKit:Sources/CodexAppServerKit/CodexAppServerNotificationRouter.swift:556`

The router has a bespoke routing list for exactly these four methods, but decodeThreadEvent/decodeTurnEvent have no cases for them, so they surface only as .unknown — consumers drop them (AppServerCodexReviewBackend unknownEvents returns []), making 'model retrying' (ErrorNotification.will_retry, the only transient-retry signal) and deprecation warnings (incl. thread/rollback removal) invisible; willRetry is not decoded anywhere. Since v2 ErrorNotification always carries threadId/turnId, the unscoped broadcast branch (:274-286) is unreachable. Related leniency: turnResult() decodes turn/completed with try? — an undecodable payload yields a CodexResponse with empty turnID/nil status that CodexResponseCollector treats as success; TurnError.codex_error_info/additional_details are dropped (cross-ref conf-error-payload-discarded).

- 証拠: Router :556-563 isUnscopedDiagnosticNotification, :274-286 broadcast, decode switches :657-731,:743-827 no cases → .unknown; :1011-1026 turnResult try?; upstream notification.rs:41-48 ErrorNotification, thread_data.rs:270-276 TurnError; consumer AppServerCodexReviewBackend.swift:585-586,645-650.
- 検証時の訂正: One sub-claim is overbroad: the unscoped broadcast branch (:274-286) is unreachable only for the "error" method (ErrorNotification.thread_id/turn_id required, notification.rs:41-48). It IS reachable and load-bearing for warning (thread_id: Option<String>, notification.rs:21-26), deprecationNotice (no thread_id field at all, notification.rs:11-16), and configWarning. The rest of the finding stands as stated.
- 修正の方向: Add typed .errorReported(message:willRetry:) and warning-family events owned by the router (routing infra already exists), and make turn/completed decode failure loud instead of synthesizing empty success.

### `cov-server-requests-untyped` — Server-initiated requests have no typed surface and the default handler answers protocol-invalid {} for requestUserInput/permissions

**CONFIRMED / medium / protocol-mismatch** — `CodexKit:Sources/CodexAppServerKit/CodexAppServer.swift:128`

defaultServerRequestHandler declines only the two commandExecution/fileChange approvals; every other server request gets emptyResult() = {}. Upstream requires `answers` on ToolRequestUserInputResponse and `permissions` on PermissionsRequestApprovalResponse — {} fails serde, upstream error!-logs and substitutes empty answers/grant, so every such reply is a logged contract violation degrading to deny. No typed params or decision enums exist even for the approvals the SDK special-cases; item/tool/requestUserInput, item/permissions/requestApproval, mcpServer/elicitation/request have zero CodexKit references, yet Configuration docs claim support for these flows and experimentalApi:true keeps experimental requests in play. Cross-ref conf-server-request-resolved-ignored (stale-request cancellation) and test-no-server-request-injection.

- 証拠: CodexAppServer.swift:128-138 default handler {} fallback, :98-102 doc claim; CodexAppServerRequest.swift:4-34 raw-only shape; upstream item.rs:1644-1646 (answers required), permissions.rs:769-777 (permissions required), bespoke_event_handling.rs:1618-1623,1816-1824 malformed-response handling; request list common.rs:1462-1493.
- 失敗トレース: (1) Server sends item/tool/requestUserInput (common.rs:1475-1478) to a CodexKit host using the default configuration; (2) defaultServerRequestHandler hits the default: branch and returns .emptyResult() = {} (CodexAppServer.swift:136-137); (3) transport writes {"id":n,"result":{}} (AppServerProcessTransport.swift:289-296, :315-328); (4) server deserializes ToolRequestUserInputResponse from {} -> serde error because answers is required (item.rs:1644-1646) -> error!("failed to deserialize ToolRequestUserInputResponse") and substitutes answers: {} (bespoke_event_handling.rs:1617-1623). Every such exchange is a logged contract violation degrading to an empty/deny answer; same for item/permissions/requestApproval via permissions.rs:769-777 and bespoke_event_handling.rs:1817-1824.
- 修正の方向: The default handler owns 'safe decline' for all interactive requests: enumerate known methods with valid decline-shaped responses and answer unknown methods with a JSON-RPC error; add typed request cases + decision enums, keeping raw only as escape hatch.

### `dk-closed-fabricates-completion` — .closed unload notification terminalizes running turns as .completed, fabricating success in the DataKit model

**CONFIRMED / medium / protocol-mismatch** — `CodexKit:Sources/CodexDataKit/CodexModel.swift:1258`

thread/closed says nothing about turn outcomes (unload only, resumable), yet CodexChat.apply(.closed) sets status .notLoaded and force-marks every non-terminal turn and its items .completed with a synthesized completedAt; same fabrication via terminalTurnStatus for statusChanged(.idle/.notLoaded) (:1692-1701). Mid-turn unload records a success that never happened until a later snapshot contradicts it. Cross-ref ask-thread-closed-terminal (router half of the same protocol misreading).

- 証拠: CodexModel.swift:1258-1264 `case .closed: setStatus(.notLoaded); terminalizeActiveTurns(status: .completed, ...)`; :1692-1701 mapping; upstream thread.rs:1467-1469 ThreadClosedNotification{thread_id} only.
- 検証時の訂正: One premise is imprecise: upstream never unloads mid-turn — the unload loop skips while AgentStatus::Running (thread_lifecycle.rs:351-354), so 'mid-turn unload' does not happen server-side. The fabrication is reachable only when the client model still holds a non-terminal turn at .closed/.idle time (missed or out-of-order turn/completed, resumed stale state); the statusChanged(.idle/.notLoaded) mapping at :1692-1701 is the more reachable path. The mismatch itself (assigning a terminal .completed outcome to a pure unload/status notification) is confirmed.
- 失敗トレース: 1) Client model holds turn T with status inProgress (e.g. terminal turn/completed event missed after resubscribe, or resumed thread seeded with a stale running turn). 2) Server unloads the idle thread and broadcasts thread/closed {threadId} (thread_lifecycle.rs:429-434). 3) Router decodes it to .closed (CodexAppServerNotificationRouter.swift:822-823). 4) CodexChat.apply hits case .closed (CodexModel.swift:1258-1264) -> terminalizeActiveTurns(status: .completed) (:1669-1690) sets T.status = .completed and stamps its items completedAt = now (:1703-1733). 5) T's true upstream outcome may be Interrupted or Failed (v2/turn.rs:30-35); the model now records a success the server never declared, until a later snapshot contradicts it.
- 修正の方向: Event-application layer leaves non-terminal statuses untouched on unload (or introduces explicit .unknown/.interruptedByUnload) and lets the next authoritative snapshot decide; terminal statuses only from server-declared terminal events.

### `dk-implicit-archived-scope` — Predicates that don't mention isArchived silently get archived == false injected

**CONFIRMED / medium / api-design** — `CodexKit:Sources/CodexDataKit/CodexThreadQueryPlan.swift:308`

CodexThreadServerFilter.init injects archived=false whenever the lowered predicate's archive scope is unscoped (both derived-filter and no-filter paths), and plan.matches() applies the injected scope locally too — so a #Predicate matching archived chats silently excludes them, invisible at compile time and undocumented. SwiftData evaluates predicates literally; the convenience descriptors already spell isArchived == false explicitly, making the injection a second hidden source of the same semantics.

- 証拠: CodexThreadQueryPlan.swift:300-315 unscoped → archived=false, :293-296 fallback defaultChatFilter, :124-126 matches applies it; contrast explicit CodexFetchRequest.swift:381-385.
- 修正の方向: Evaluate predicates literally (unscoped ⇒ both scopes) keeping default-scoping only for the nil-predicate default, or make the implicit scope an explicit documented descriptor property.

### `dk-mutation-strategy-scattering` — No single owner for the local-apply vs server-refresh decision in fetched-results mutations — the recurring-fix magnet

**CONFIRMED / medium / architecture** — `CodexKit:Sources/CodexDataKit/CodexFetchRequest.swift:818`

Each registration handler re-derives 'apply locally or refetch' with a different guard set: insert checks only membershipRequiresServerRefresh; archive/revalidate add usesServerOwnedOrdering; remove special-cases fetchOffset > 0; workspace refresh filters before deciding; paged revalidation and insert offset/limit constraints live elsewhere. Concrete asymmetry: insert skips the usesServerOwnedOrdering check its siblings enforce, so under server-owned ordering a new chat is prepended locally (sortedItems deliberately doesn't sort recencyAt plans) — wrong for .forward order until next refresh. The four recent fixes (c58c47b, b141853, f350209, 33cd29e) all patched this guard area.

- 証拠: CodexFetchRequest.swift:818-827 insert path, :829-851 archive, :887-911 remove, :913-957 workspace, :1116-1132 paged, :1037-1042 canInsertLiveModel, :1066-1076 two guard properties; CodexModelContext.swift:2442-2446 recencyAt skip.
- 検証時の訂正: The commit-history claim is imprecise: c58c47b, 33cd29e, f350209 patched predicate lowering/local-semantics in CodexThreadQueryPlan.swift and b141853 patched sort signatures — i.e. the inputs feeding these guards (isComplete -> membershipRequiresServerRefresh, matches()), not the registration-handler guard lines themselves. Same responsibility neighborhood, different layer.
- 修正の方向: CodexThreadQueryPlan exposes a single mutationStrategy(for:) covering membership, ordering, offset and pagination; handlers become thin executors — one place decides when local state can be trusted.

### `dk-optional-delta-id-workaround-layer` — Fallback agent-message identity machinery in DataKit compensates for AppServerKit's optional delta itemID (upstream requires item_id)

**CONFIRMED / medium / workaround** — `CodexKit:Sources/CodexDataKit/CodexModel.swift:1926`

Upstream AgentMessageDeltaNotification.item_id is required but CodexMessageDelta.itemID is String?, so DataKit maintains a compensation subsystem: scoped fallback IDs, promotedMessageDeltaKeyByFallbackKey, promoteFallbackMessageDeltaItem, text-equality signature matching (CodexFallbackAgentMessageSignature) in three separate places, plus itemsByReplacingFallbackAgentMessageItems. Text-equality matching is semantically unsound (identical messages in one turn alias) and every new merge path must remember it — the drift class that produced 2bfef6e/25c178a/503ec9a. Cross-ref cov-dead-compat-notifications (the dead agent/message path is the only producer of nil IDs).

- 証拠: upstream item.rs:1333-1338 item_id: String required; CodexKit:Sources/CodexAppServerKit/CodexDomainTypes.swift:2222-2231 itemID: String?; CodexModel.swift:53-59,967-1012,1427-1447,1926-2005,2280-2303 compensation sites.
- 修正の方向: AppServerKit decode boundary makes delta item IDs non-optional per the wire contract (fail fast on absent id), then delete the fallback-ID/text-signature layer from DataKit — item identity is assigned once, at the protocol boundary.

### `dk-predicate-runtime-crash-contract` — Unsupported predicate/sort shapes crash at runtime with preconditionFailure, including inside SwiftUI view update

**CONFIRMED / medium / api-design** — `CodexKit:Sources/CodexDataKit/CodexThreadQueryPlan.swift:831`

The #Predicate/SortDescriptor surface accepts any model key path at compile time, but lowering supports only 5 predicate keys and 5 sort paths; everything else hits preconditionFailure in descriptor init, section descriptors, validation, and lowering. CodexQuery.update() computes querySignature (which lowers the predicate) on every SwiftUI update, so e.g. `#Predicate { $0.createdAt > date }` crashes during render. SwiftData throws for unsupported predicates; here 'compiles so it works' is a crash, there is no throwing validation API, and the supported grammar is undocumented (README understates as 'not silently treated as app-server sorts'). Fail-fast was deliberate (269f0f9) but has no discoverable contract.

- 証拠: CodexThreadQueryPlan.swift:831-838,953,973,984,995,1006,1046,1205,1220 preconditions; CodexFetchRequest.swift:43-54,111-118,193-198; CodexQuery.swift:142-152 signature per update(); DataKit README.md:74-79.
- 修正の方向: Give the contract an owner: document the supported grammar, and expose a throwing validate(descriptor:)/typed filter-sort enums so dynamic construction gets an error path instead of a render-time crash.

### `dk-query-not-live-external` — @CodexQuery/fetchedResults never observe server-side thread-list changes — the SwiftData-style 'live query' expectation does not hold

**CONFIRMED / medium / api-design** — `CodexKit:Sources/CodexDataKit/CodexModelContext.swift:2147`

Fetched-results updates fire only from context-initiated actions; CodexModelContext subscribes to no app-server-level notifications (thread/started, thread/name/updated, thread/archived, thread/deleted exist upstream), so threads created/renamed/archived/deleted by another client, the codex CLI, or even a dropped-down AppServerKit call on the same container never appear/disappear until an explicit performFetch/refresh. The README's SwiftData framing, the 'fetched results controller' naming, and the documented appServer drop-down hatch all imply live membership that is not provided, and nothing documents the staleness contract.

- 証拠: CodexModelContext.swift:2147-2262 registration fan-out from context-initiated paths only; grep notificationStream/liveEvents over CodexDataKit = 0; upstream common.rs:1616-1624 lifecycle notifications; DataKit README.md:171-177 documents appServer hatch without staleness caveat.
- 修正の方向: Context owns a server-notification ingestion path (thread lifecycle → registry apply + fan-out) making fetched results genuinely live; short of that, README/API must state that query results only track context-local mutations.

### `dk-single-observation-slot` — One-observation-per-chat contract makes rebinding racy; slot is held by in-flight registrations with no awaitable release

**CONFIRMED / medium / usability** — `CodexKit:Sources/CodexDataKit/CodexModelContext.swift:804`

observe() throws chatObservationAlreadyActive if a registration exists; registration is inserted before the async startObservation completes and cancellation is only possible via the handle returned at the end — so cancel-old-then-observe-new (typical view rebinding) races and throws, since 'cancelled' does not synchronously mean 'slot free'. Updates are already multicast, so the single-slot restriction is an internal lifecycle constraint leaking into public API; no NSFetchedResultsController/SwiftData analogue imposes it. Consumer workaround exists (see use-observe-serialization).

- 証拠: CodexModelContext.swift:804-810 throw, :812-827 slot registered before await; consumer CodexReviewKit:Sources/ReviewChatLogUI/ReviewMonitorCodexChatLogTarget.swift:157-166.
- 検証時の訂正: One nuance: 'cancelled does not synchronously mean slot free' is true only for the in-flight-registration case (Task cancellation); cancelling a fully-established CodexChatObservation handle synchronously releases the slot via releaseChatObservation (CodexModelContext.swift:972-981). The consumer workaround targets exactly the in-flight case, so the finding's substance stands.
- 修正の方向: CodexModelContext owns observation sharing: observe() joins (refcounts) the existing ActiveChatObservation returning a new handle, tearing the pump down when the last handle cancels — or make cancellation synchronously release the slot.

### `dk-sortdescriptor-mirror-reflection` — Sort signature depends on Mirror reflection into Foundation SortDescriptor internals with silent nil fallback

**CONFIRMED / medium / workaround** — `CodexKit:Sources/CodexDataKit/CodexFetchRequest.swift:78`

comparisonSignature extracts the private 'comparison' child of SortDescriptor via Mirror + String(describing:). If Foundation renames the property or changes the description, it silently returns nil/unstable strings, collapsing comparator distinctions in CodexSortPlanSignature — CodexQuery.update() then reuses the wrong CodexFetchedResults (stale ordering, no error; the failure class b141853 just fixed for key paths). Silent misbehavior contradicts the crash-loudly stance used everywhere else in the file.

- 証拠: CodexFetchRequest.swift:78-84 Mirror extraction; CodexThreadQueryPlan.swift:174-184 signature includes comparison: String?; commit b141853 precedent.
- 検証時の訂正: Minor precision: String(describing:) of the comparison child is itself layout-dependent even when the label survives; and the collapse today affects only comparator distinctions (path/order are extracted separately), so blast radius is descriptors that differ only in custom comparators.
- 修正の方向: Restrict supported SortDescriptor forms to (keyPath, order) and drop the reflection, or fail fast when the 'comparison' child is absent — signature equality must imply query equivalence without depending on undocumented Foundation layout.

### `dk-unserialized-fetch-loads` — Concurrent load() calls on one CodexFetchedResults interleave; pagination window collapses on mutation-triggered reloads

**CONFIRMED / medium / bug** — `CodexKit:Sources/CodexDataKit/CodexFetchRequest.swift:683`

performFetch/refresh/loadNextPage/refreshAfterMutation/backfill all funnel into load() with mid-flight awaits and no serialization or generation token: a registration-triggered refresh can interleave with a suspended loadNextPage, giving last-writer-wins items with a nextCursor from the losing load (items/cursor disagreement, A→B→A-completed sequences). Additionally, any included-chat revalidation while paged (nextCursor != nil or offset > 0) reloads page 1 non-appending, discarding pages the user scrolled through — NSFetchedResultsController never resets its window this way.

- 証拠: CodexFetchRequest.swift:661-681 no guards, :683-722 load() assigns cursors/items after suspension (:707), :1116-1132 refreshAfterPagedRevalidationIfNeeded non-appending reload.
- 失敗トレース: Interleave: 1) Paged results (fetchLimit=50, recencyAt reverse), page 1 loaded, nextCursor=C1 (:707). 2) User scrolls -> loadNextPage() (:671-681) -> load(cursor:C1, appending:true), phase=.loading (:689), suspends at fetchPage (:693). 3) MainActor reentrancy: user archives a chat -> CodexModelContext.archiveChatInRegisteredResults (CodexModelContext.swift:2154-2163) -> CodexFetchedResults.archive (:829-851); requiresServerRefreshAfterMutation is true for recencyAt ordering (:1066-1068; CodexThreadQueryPlan.swift:116-118) -> refreshAfterMutation (:1108-1114) -> load(appending:false) completes: items = fresh page 1, nextCursor = C1' (:707-715). 4) Step-2 load resumes with the stale-C1 response: append(page.items, to: items) (:698, :750, :761-771) welds stale page-2 rows onto the fresh page-1 list, then overwrites nextCursor with the stale response's C2 (:707). Result: items mix two membership generations and nextCursor belongs to the losing load (A->B->A-completed). Collapse: user on page 3 (nextCursor != nil) + any included-chat revalidation -> refreshAfterPagedRevalidationIfNeeded (:1116-1132) -> non-appending page-1 reload -> scrolled pages discarded.
- 修正の方向: CodexFetchedResults owns load serialization (in-flight task/generation counter; coalesce refreshes, queue-or-cancel appends) so items/cursors/phase always describe one completed load; page-window preservation belongs to the same owner.

### `dx-cancel-semantics-inconsistent` — Two different cancellation semantics on CodexResponseStream: task-cancel during collect() interrupts the server turn (unstructured, failure-swallowed), early break does not

**CONFIRMED / medium / usability** — `CodexKit:Sources/CodexAppServerKit/CodexDomainTypes.swift:2002`

Breaking out of iteration (or dropping the sequence) only unsubscribes — server keeps working — documented nowhere on the type; cancelling the task awaiting collect() fires an unstructured detached `Task { try? await turn.interrupt() }` that DOES stop the work, swallows its failure via try?, and can outlive/race server.close(). Since respond(to:) is streamResponse().collect(), plain respond() silently inherits interrupt-on-cancel while iteration does not — the same type answers 'does cancel stop the work' differently per method. Only the README mentions the collect() behavior. Cross-ref ask-cancel-collect-misreported (error type on the same path).

- 証拠: CodexDomainTypes.swift:1994-2008 detached interrupt, no doc; CodexThreadOperations.swift:23-25,74; router :105-107,138-140 unsubscribe-only; README.md:102-103.
- 修正の方向: One documented cancellation contract on CodexResponseStream: either task-cancel is pure stop-listening (explicit cancel() to interrupt) or interrupt-on-cancel is structural (withTaskCancellationHandler awaiting the interrupt, surfacing failures) — documented on the type.

### `dx-no-raw-escape-hatch` — No outbound raw JSON-RPC escape hatch: consumers cannot call any upstream method the SDK has not typed yet

**CONFIRMED / medium / api-design** — `CodexKit:Sources/CodexAppServerKit/README.md:486`

JSON-RPC and AppServerAPI DTOs are package-internal by design and there is no public (method, params) send. Inbound forward-compat is good (CodexRawNotification), but outbound is fully closed: upstream ships weekly with methods CodexKit doesn't type, so a consumer needing one new call must fork or wait. There is exactly one send path (retry + serial lanes), so a raw send decorating it would be cheap and could not drift.

- 証拠: README.md:484-487 policy; AppServerClient.swift:6 package actor; CodexAppServer.swift:146-148 package appServerClient; grep public send-like API = none; inbound hatch CodexDomainTypes.swift:2502-2519.
- 修正の方向: CodexAppServer exposes a public sendRaw(method:params:) → Data routed through AppServerClient.send (same retry/lane/error mapping).

### `test-fictional-turn-failed-pins-phase-contract` — The only test pinning chat.phase == .failed drives it via a 'turn/failed' notification that does not exist upstream; the production-reachable failure path is unpinned

**CONFIRMED / medium / test-gap** — `CodexKit:Tests/CodexDataKitTests/CodexDataKitTests.swift:8091`

The test emits method turn/failed with a top-level error object — a wire event no real server sends — exercising the production-unreachable .turnFailed branch, while the reachable path (turn/completed + status failed + turn.error.message → fail(with:)) has no direct phase assertion (the revert-policy test asserts only rollback/read counts). If the fictional routes are removed to match upstream (cross-ref cov-dead-compat-notifications), this test breaks and reveals no pin exists for the real shape.

- 証拠: CodexDataKitTests.swift:8090-8101 emitServerNotificationJSON(method: "turn/failed") + phase assertion; upstream common.rs:1614-1660 TurnCompleted only, turn.rs:30-35; reachable path CodexModel.swift:1142-1151; revert test without phase assertion CodexDataKitTests.swift:6267-6281.
- 検証時の訂正: Severity adjusted high -> medium: this is a regression-risk test gap (removing the dead routes breaks the only failed-phase pin and leaves the real turn/completed+failed shape unpinned), not wrong behavior a consumer hits today.
- 修正の方向: Pin the failure-phase contract via the upstream-real shape (turn/completed, status failed, turn.error.message) and remove the fictional emission together with the router's dead routes.

### `test-handrolled-notification-schemas-drift` — Notification wire schemas are hand-rolled in at least three places with visible drift; package-scoped AppServerAPI blocks consumers from typed payloads

**CONFIRMED / medium / workaround** — `CodexKit:Tests/CodexDataKitTests/CodexDataKitTests.swift:10258`

Because the Testing target offers only emitServerNotification(method:params:) and raw JSON, every fixture author re-encodes the wire schema: ~15 private param structs in CodexDataKitTests, 6 more in the consumer's preview runtime, and a third private encoder in the Testing target itself; AppServerAPI/AppServerJSONValue are package-scoped so consumers can't reuse the SDK's wire types. Drift is live: the preview runtime emits turn.status "cancelled" (absent from upstream TurnStatus, round-trips only via the invented CodexTurnStatus.cancelled) and a DataKit test emits nonexistent turn/failed. Nothing validates fixtures against the protocol — fixtures define their own dialect and tests pin it.

- 証拠: CodexDataKitTests.swift:10258-10430 param structs; ReviewMonitorPreviewAppServerRuntime.swift:733-815 and :715-724 status "cancelled"; Testing encoder CodexAppServerTestRuntime.swift:767-842; package scope AppServerRequests.swift:3,162; upstream turn.rs:30-35; invented status CodexDomainTypes.swift:1841,1854.
- 検証時の訂正: Minor: the 'cancelled' status emission is at ReviewMonitorPreviewAppServerRuntime.swift:717-727 (cited :715-724), and the DataKit param structs start at :10204 (cited :10258, which is the first Encodable notification struct). Substance unchanged.
- 修正の方向: Testing target owns typed notification builders (emitTurnCompleted, emitItemUpdated, emitThreadClosed, ...) built on the same package AppServerAPI types the router decodes — single wire-schema owner, delete every mirror.

### `test-no-server-request-injection` — Testing target cannot inject server-initiated requests, so approval flows (public API) are untestable against the fake

**CONFIRMED / medium / coverage-gap** — `CodexKit:Sources/CodexAppServerKitTesting/CodexAppServerTestRuntime.swift:402`

CodexAppServerRequestHandler is public production API, but JSONRPC.Transport doesn't model server requests (they are internal to AppServerProcessTransport), the fake has zero references to CodexAppServerRequest, and CodexAppServer.testing(transport:) accepts no handler. The only coverage is a shell-script process test at the transport layer; no app developer can deterministically test their approval handler, decision encoding, or UI flow. Cross-ref cov-server-requests-untyped.

- 証拠: CodexAppServerRequest.swift:74 public typealias; real dispatch AppServerProcessTransport.swift:234-245,289-313; JSONRPC.swift:26-31 protocol without server requests; CodexAppServer.swift:210-214 testing(); only test CodexAppServerKitTests.swift:100-161.
- 検証時の訂正: One premise weakened: no consumer in CodexReviewKit currently uses the approval-handler API at all, so 'no app developer can deterministically test their approval handler' is a prospective gap for the public API, not an observed consumer workaround in this workspace.
- 修正の方向: Add server-request delivery to JSONRPC.Transport (or a companion protocol) so the fake exposes emitServerRequest(...) returning the handler's response.

### `test-process-crash-recovery-untested` — Process crash/EOF recovery and in-flight-cancel response drop are untested anywhere in the SDK

**CONFIRMED / medium / coverage-gap** — `CodexKit:Sources/CodexAppServerKit/AppServerProcessTransport.swift:208`

Untested: stdout EOF → closeTransport → pending requests resumed .closed and streams finished throwing; cancelPendingResponse dropping late responses; SIGTERM→SIGKILL escalation and process-tree reaping; malformed stdout JSON silently dropped. Downstream, no SDK test covers DataKit observations/fetched results when the router's stream throws .closed — finishNotificationStreams(throwing:) exists in the Testing target but is used only by the consumer repo. Crash recovery is a recurring-fix hot spot with no pins.

- 証拠: AppServerProcessTransport.swift:208-217,354-356,362-373,700-717,219-232; grep finishNotificationStreams over CodexKit/Tests = nothing (consumer-only usage CodexReviewHostTests.swift:1610,1686); process tests limited to CodexAppServerKitTests.swift:100-168.
- 修正の方向: Pin the transport's terminal contract with a shell-script process exiting mid-request (pending send fails .closed, streams finish throwing), and pin DataKit observation behavior on stream error via finishNotificationStreams(throwing:).

### `test-unstubbed-method-silent-success` — Unstubbed requests silently succeed with '{}', fabricating success for every EmptyResponse-typed mutation

**CONFIRMED / medium / api-design** — `CodexKit:Sources/CodexAppServerKitTesting/CodexAppServerTestRuntime.swift:1109`

send falls through to encoding EmptyResponse() when no queued response or handler matches. thread/archive, thread/delete, thread/name/set, turn/interrupt, config/batchWrite, logout, etc. 'succeed' with no stub while the store is unchanged; a typo'd enqueue method is silently absorbed; required-field responses instead surface a DecodingError that reads like an SDK bug rather than 'missing stub'. A fake should fail fast on unintentional requests.

- 証拠: CodexAppServerTestRuntime.swift:1106-1109 fall-through; Thread.Start.Response non-optional threadID (AppServerRequests.swift); store registers only start/list/resume/read/turns-list (:569-585).
- 修正の方向: Throw a distinct unstubbedMethod(method:) error on fall-through, with an opt-in lenient mode for previews — silent divergence becomes immediate test feedback.

### `use-dual-thread-identity` — Source-vs-review thread identity is re-mapped independently at three consumer layers

**CONFIRMED / medium / workaround** — `CodexReviewKit:Sources/CodexReviewAppServer/AppServerCodexReviewBackend.swift:22`

A review spans two thread IDs; CodexKit exposes associatedThreadIDs/cleanupThreadIDs but no canonical 'which chat does this review belong to'. The backend keeps three dictionaries to route events/cancellations; the store matches run records by comparing both threadID and reviewThreadID strings; the MCP provider picks reviewThreadID ?? threadID. Each layer re-derives the mapping; drift between them is the bug class the prior generation/identity findings predicted.

- 証拠: AppServerCodexReviewBackend.swift:22-28,360-410; CodexReviewStoreOrderQueries.swift:94-108; CodexReviewMCPServer.swift:174; SDK identity CodexDomainTypes.swift:836-870.
- 検証時の訂正: The claim 'no canonical which-chat mapping' is overstated: CodexReviewIdentity.sourceThreadID/activeTurnThreadID (CodexDomainTypes.swift:639-646) are exactly that accessor pair. The verified gap is narrower — review identity does not flow through the string-typed Run/event plane the consumers operate on, so the three layers re-derive it from raw strings. Also the cited SDK lines 836-870 are CodexReviewSession's mirrors; CodexReviewIdentity itself is at :621-676.
- 修正の方向: CodexReviewIdentity exposes the canonical presentation thread ID and events carry review identity, so consumers key everything off one value.

### `use-full-reprojection` — Granular CodexChatUpdate payloads are discarded; every delta triggers full chat re-projection

**CONFIRMED / medium / usability** — `CodexReviewKit:Sources/ReviewChatLogUI/ReviewMonitorCodexChatLogSourceProjection.swift:54`

Typed granular updates are used only as a boolean 'allow incremental render' hint; the consumer re-renders the whole chat.items array through the dedup/projection pipeline on every update, re-deriving diffs via UTF16 text comparison. DX evidence that item identity/ordering in updates isn't trustworthy for targeted apply (consistent with dk-update-id-discontinuity), and a per-delta O(items) cost on hot streaming paths.

- 証拠: ReviewMonitorCodexChatLogSourceProjection.swift:54-101; downstream diffing ReviewMonitorLogProjection.swift:5-100.
- 修正の方向: Once CodexDataKit guarantees stable IDs and ordered updates, apply updates targetedly; until then this is the rational consumer response — fix belongs SDK-side.

### `use-highlevel-surface-bypass` — Consumer bypasses every high-level SDK review surface (progress/collect/response) and rebuilds them over raw events

**CONFIRMED / medium / api-design** — `CodexReviewKit:Sources/CodexReviewAppServer/AppServerCodexReviewBackend.swift:752`

CodexReviewSession offers progress, collect(), messages, logEntries — none used by the app. The adapter iterates raw session.events and re-implements terminal classification, transcript-output extraction, and cancel semantics, because the high-level surfaces classify interrupted as failure and end silently on .closed (cross-ref conf-interrupted-is-failure, ask-thread-closed-terminal). When the SDK's flagship consumer cannot use its convenience layer, that layer's contract is wrong — the strongest DX evidence in the repo.

- 証拠: AppServerCodexReviewBackend.swift:752-756 raw events only, :590-614 own terminalEvents/reviewCompletionText; avoided surfaces CodexDomainTypes.swift:893-900, CodexTurnSequences.swift:303-309,482-484.
- 修正の方向: Fix the high-level surfaces' semantics (cancelled≠failed, .closed≠silent end) so the convenience layer is adoptable; the adapter then shrinks to a thin mapping.

### `use-mcp-refresh-fallback` — MCP log provider does a full model refresh per read with silent catch → 'unavailable' fallback

**CONFIRMED / medium / workaround** — `CodexReviewKit:Sources/CodexReviewMCPServer/CodexReviewMCPServer.swift:167`

To serve review_read/await the provider must refresh(chat, includeTurns: true) on every call (poll-style refetch because the model context doesn't reflect the live review thread), swallow refresh errors returning nil, and fall back to an empty ReviewMCPLogProjection.unavailable. Every MCP read pays a full thread fetch; failures degrade silently. Cross-ref dk-query-not-live-external.

- 証拠: CodexReviewMCPServer.swift:178-187 refresh + catch { return nil } + guard; fallback :153; ReviewMCPLogProjection.swift:38-51.
- 修正の方向: SDK owns freshness: model context guarantees live review turns are reflected (observation-driven) or exposes a direct transcript-snapshot read by CodexReviewIdentity; the silent fallback becomes an explicit error path.

### `use-observe-serialization` — Consumer serializes chat rebinds by awaiting previous task teardown to dodge chatObservationAlreadyActive

**CONFIRMED / medium / workaround** — `CodexReviewKit:Sources/ReviewChatLogUI/ReviewMonitorCodexChatLogTarget.swift:159`

Because observe() enforces one observation per chat with fire-and-forget cancel (cross-ref dk-single-observation-slot), the consumer must keep the cancelled task referenced and `await previousTask?.value` before re-observing the same chat, per its own apologetic comment — single-consumer, non-idempotent observation lifecycle pushed onto UI code.

- 証拠: ReviewMonitorCodexChatLogTarget.swift:159-163 comment + await, :91-93 kept reference; SDK CodexModelContext.swift:804-809, CodexChatObservation.swift:22-32.
- 修正の方向: CodexDataKit owns observation lifecycle: broadcast (multi-observer) updates or an awaitable/idempotent cancel-and-reobserve, removing consumer-side task sequencing.

### `use-resume-to-cancel` — Cancelling a review without a live handle requires resuming the whole session first

**CONFIRMED / medium / workaround** — `CodexReviewKit:Sources/CodexReviewAppServer/AppServerCodexReviewBackend.swift:466`

CodexKit exposes cancel only on live handles; turn/interrupt is package-only. When the in-memory registry misses (post-restart/cleanup), the consumer calls appServer.resumeReview(identity) — constructing a full session with event thread — solely to call .cancel(). The adjacent reviewEventSession(for:) fallback even manufactures an empty session whose cancelReview returns nil, silently routing here.

- 証拠: AppServerCodexReviewBackend.swift:466-470 resume-then-cancel, :349-358 manufactured session; SDK CodexThreadOperations.swift:448-466 package interrupt() only.
- 修正の方向: CodexAppServerKit exposes public cancel-by-identity (interruptTurn(threadID:turnID:) or cancel(CodexReviewIdentity)); the resume-to-cancel dance and manufactured-session fallback both die.

### `use-review-output-location` — 'Review completed without review output' failure synthesized at two layers with a triple fallback chain for where the output lives

**CONFIRMED / medium / workaround** — `CodexReviewKit:Sources/CodexReviewAppServer/AppServerCodexReviewBackend.swift:610`

CodexResponse gives no contract for where a review's final output lives. The backend probes transcript.reviewOutputText ?? finalAnswer ?? transcript.finalAnswer and synthesizes a failure when empty; the store repeats the same synthesis independently for stream-finished-without-terminal and empty-finalReview; the MCP projection adds a fourth fallback (finalReview ?? lastAssistantMessageText). 5+ fix commits circle this question (8e3ec41, 6e34054, cf78964, e7eac9e, 1ef636f).

- 証拠: AppServerCodexReviewBackend.swift:610-614 fallback chain, :602-604 synthesized failure; same string CodexReviewStoreReviews.swift:688,709,856-863; MCP ReviewMCPLogProjection.swift:91-94.
- 修正の方向: CodexAppServerKit guarantees a single review-output field on the terminal CodexResponse for review turns (finalizedTranscript already merges exitedReviewMode text — finish that ownership).

### `use-runtime-death-side-channel` — App-server death is detected via accountEvents stream error, tearing down the whole runtime from a side channel

**CONFIRMED / medium / workaround** — `CodexReviewKit:Sources/CodexReviewHost/LiveCodexReviewStoreBackend.swift:1186`

CodexAppServer has no lifecycle/health surface, so the host keeps an accountEvents() subscription alive partly so its throw becomes the 'server died' signal, then runs full runtime teardown from that catch block. If account notifications were consumed elsewhere or the stream ended benignly, death detection silently changes behavior.

- 証拠: LiveCodexReviewStoreBackend.swift:1184-1188 catch → markRuntimeFailedAfterNotificationStreamError, teardown :1200-1229; SDK public surface (CodexAppServer.swift:220-867) has close() but no state/termination signal.
- 修正の方向: CodexAppServerKit exposes a lifecycle surface (state AsyncStream or terminated continuation) so hosts subscribe to death explicitly.

### `use-subscription-generation-guards` — Store worker builds its own subscription-ID generations to filter stale backend events across restarts

**PLAUSIBLE / medium / workaround** — `CodexReviewKit:Sources/CodexReviewKit/Store/CodexReviewStoreReviews.swift:582`

Because a superseded attempt's mailbox stream doesn't terminate when a review is restarted after a network outage, the worker maintains monotonic subscription IDs (ReviewWorkerEventSource) and double-guards every input by subscriptionID and attemptID equality. The generation-boundary invariant the prior audit flagged inside CodexKit is reproduced consumer-side: switching generations is again the call-site's cursor dance rather than a producer-owned boundary.

- 証拠: CodexReviewStoreReviews.swift:582-585,596,609 guards, :1027-1029 shouldConsumeEvent, :1176-1280 generation counter.
- 検証時の訂正: Superseded mailboxes do terminate (abandon()/fail() at CodexReviewBackend.swift:100-115); the actual gap is that supersession is signalled as a plain .finished indistinguishable from normal completion, forcing the worker to pre-emptively unsubscribe and filter by generation instead of reacting to a typed supersede terminal.
- 修正の方向: Backend attempt streams (ultimately SDK review sessions) terminate deterministically when superseded/abandoned so consumers subscribe to exactly one live generation instead of filtering.

### `use-review-marker-duplication` — Consumer duplicates the SDK-private 'review-marker:' semantic-ID constants for snapshot items — incompletely

**CONFIRMED / low / workaround** — `CodexReviewKit:Sources/ReviewChatLogUI/ReviewMonitorCodexChatLogProjection.swift:785`

CodexDataKit's private semanticID maps enteredReviewMode/exitedReviewMode to review-marker: constants and prefixes other kinds with kind.rawValue. Snapshot items bypass the model, so the consumer re-implements the marker constants verbatim — but without the kind-prefix branch, so snapshot-derived and model-derived block IDs diverge for non-marker items. Two unversioned copies of one identity invariant across a repo boundary.

- 証拠: ReviewMonitorCodexChatLogProjection.swift:785-794; SDK private twin CodexModel.swift:512-526 incl. kind-prefix branch.
- 検証時の訂正: Severity: the incomplete copy is only exercised by test/preview-style snapshot renders today; no production call site feeds CodexThreadSnapshotLogItem, so the ID divergence is latent rather than user-visible. The two-unversioned-copies maintenance hazard stands.
- 修正の方向: CodexDataKit exposes the semantic/model item ID mapping publicly (or model-normalized projections of CodexThreadSnapshot), making the consumer copy deletable.


## Appendix B: 未検証 low findings(36 件)

- `arch-dead-adapter-branches` [workaround] Dead workaround residue in the review event adapter/session: write-only cancel state, no-op branches, never-incremented metrics, ignored expectedTurnID — `CodexReviewKit:Sources/CodexReviewAppServer/AppServerCodexReviewBackend.swift:635`
  - Vestiges of the cancel/terminal workarounds: itemEvents guards `item.kind.rawValue != "enteredReviewMode"` yet both branches return []; unknownStatusEvents/unknownEvents unconditionally return []; activeStreamSubscriptionIDForTesting returns nil and detach(subscriptionID:) is a no-op; cancelReview(expectedTurnID:) ignores its parameter so the caller's expected-turn guard (:459-464) is unenforced; ReviewBackendEventSession.cancellationRequestedMessage is written by requestCancellation/clearCancellationRequest/finish but never read (making the backend's round-trip a no-op ritual); metrics buffered/commandTimeoutWarnings are never incremented yet logged as meaningful. Dead branches conceal where real semantics were meant to live.
- `arch-settings-snapshot-mirrors` [architecture] Settings snapshot kept in three places: SettingsStore (owner), SettingsService bookkeeping, and a per-backend mirror used only for seeding — `CodexReviewKit:Sources/CodexReviewHost/LiveCodexReviewStoreBackend.swift:228`
  - Each backend caches its own settings snapshot updated on every read/write (Live, Direct, Preview backends), whose only consumer is initialSettingsSnapshot for store seeding; one store exists per backend, so the third copy is a mirror that can drift from SettingsStore between refreshes (failed refresh leaves the backend cache at the previous value).
- `arch-sidebar-order-ui-owned` [architecture] User drag-reorder of sidebar chats/groups lives only in an in-memory VC overlay; membership/order ownership split between FRC and view layer — `CodexReviewKit:Sources/ReviewUI/Sidebar/CodexChats/ReviewMonitorCodexSidebarOutline.swift:140`
  - Base membership/order comes from the fetched-results controller sorted by recencyAt; drag-and-drop mutates only ReviewMonitorCodexSidebarPresentationOrder (applied per render, pruned to live sections) and applyResolvedDrop never persists — user-intent ordering is semantic state in a UI wrapper that vanishes on VC recreation and silently re-merges under FRC updates. Session-scoped ordering, if intended, is undocumented; otherwise the order lacks a persistence owner.
- `arch-silent-persistence-writes` [workaround] Account registry and shared-auth writes on the success path are wrapped in try?, silently dropping persistence failures — `CodexReviewKit:Sources/CodexReviewHost/LiveCodexReviewStoreBackend.swift:1136`
  - applyAuthSnapshot persists accounts and shared auth with try?; rate-limit cache writes likewise. If CODEX_HOME is unwritable, in-memory auth and the on-disk registry diverge with no signal — on next launch accounts vanish or an old account reactivates. Conflicts with the fail-fast posture: persistence failure of the account source of truth is not normal flow.
- `arch-store-preview-default` [api-design] CodexReviewStore.init defaults its backend to PreviewCodexReviewStoreBackend — a fake as the silent default of the core initializer — `CodexReviewKit:Sources/CodexReviewKit/Store/CodexReviewStore.swift:28`
  - Any composition path that forgets to pass a backend compiles and yields a store whose start() transitions to .failed("Embedded server is unavailable in preview mode.") at runtime instead of failing at the composition boundary. Explicit factories already exist; the default adds only a silent-misuse path (mitigated by package visibility).
- `arch-stringly-source-flag` [api-design] Rate-limit refresh uses a stringly-typed source parameter as a control-flow flag triggering account validation — `CodexReviewKit:Sources/CodexReviewHost/LiveCodexReviewStoreBackend.swift:1492`
  - refreshRateLimits branches `if source == "saved-auth-isolated-runtime"` to run validateRateLimitBackendAccount; callers pass three magic strings. A typo or new caller silently skips the auth-identity validation guarding against refreshing rate limits for the wrong account — correctness keyed off a log label.
- `arch-transport-vc-duplicate-binding` [architecture] Chat binding state (boundChatID/boundModelContext) duplicated in TransportViewController and ChatLogTarget with parallel guards — `CodexReviewKit:Sources/ReviewUI/Detail/ReviewMonitorTransportViewController.swift:14`
  - Both layers keep their own copy of which chat is bound with identical guard expressions that must mutate in lockstep; the DEBUG helper bindLogRenderTargetForTesting already hand-synchronizes both. Drift produces a silently stale pane (outer layer thinks bound, inner cleared).
- `ask-blocking-pipe-writes` [bug] Synchronous FileHandle writes to the child's stdin run on the actor executor and can block a cooperative thread — `CodexKit:Sources/CodexAppServerKit/AppServerProcessTransport.swift:120`
  - send()/notify()/respond(to:) call stdin.fileHandleForWriting.write(contentsOf:) inside the transport actor. If the codex process stops draining stdin and the 64KB pipe buffer fills, the blocking write wedges the cooperative-pool thread and the actor (all sends, close(), notification fan-out) indefinitely — a hung host app rather than an error. Needs a wedged child to manifest.
- `ask-clientversion-default-mismatch` [api-design] Two different clientVersion defaults: Configuration says "1", AppServerClient.initialize says "2" — `CodexKit:Sources/CodexAppServerKit/CodexAppServer.swift:114`
  - Configuration.init defaults clientVersion to "1" (what every public init path sends) while AppServerClient.initialize's own default parameter is "2". Two sources of truth for the handshake value; which is current is ambiguous and the value silently differs by entry point. Cross-ref dx-config-chain-undocumented.
- `ask-codexhome-doc-mismatch` [usability] defaultCodexHomeURL doc promises Application Support for container apps, but code returns $HOME/.codex whenever HOME is set on macOS — `CodexKit:Sources/CodexAppServerKit/CodexAppServer.swift:71`
  - Doc/README describe CODEX_HOME → ~/.codex for CLI runs → Application Support for container environments, but the #if os(macOS) branch returns $HOME/.codex whenever HOME is non-empty — true for every macOS process. Sandboxed apps get <container>/.codex; the Application Support branch is effectively unreachable on macOS. Compile-time os(macOS) cannot express the documented runtime distinction.
- `ask-delta-random-item-identity` [bug] Command/file/tool progress deltas without itemId mint a fresh random item identity per delta — `CodexKit:Sources/CodexAppServerKit/CodexAppServerNotificationRouter.swift:892`
  - itemUpdate(from:kind:) uses `payload.itemID ?? UUID().uuidString`; an id-less delta becomes a distinct CodexThreadItem per notification (transcript spam, no merge owner). Agent-message deltas got a proper identity owner (fallback-ID promotion) but command/file/tool deltas did not. Dormant against v2 (item_id required upstream), but as written it fabricates identity instead of failing fast or degrading to .unknown. Cross-ref conf-command-delta-clobbers-item (content clobbering in the same function).
- `ask-readme-boundary-drift` [usability] README 'Boundary' list materially under-states the public surface — `CodexKit:Sources/CodexAppServerKit/README.md:489`
  - The public-boundary list (~26 types) omits a large fraction of the actual public API (CodexReviewDelivery — used in documented signatures — CodexThreadSnapshot family, item content types, CodexAppServerError, CodexJSONValue, etc.; CodexDomainTypes.swift alone has 493 public occurrences). The list is the discoverability contract and has drifted; 'what am I allowed to depend on' gets a false answer.
- `ask-review-session-unfiltered-transcripts` [api-design] CodexReviewSession.messages/transcriptUpdates are not filtered to the review turn while events/logEntries/progress are — `CodexKit:Sources/CodexAppServerKit/CodexDomainTypes.swift:878`
  - events/logEntries/progress filter through reviewEventMatches with terminalTurnID, but messages and transcriptUpdates delegate to eventThread with no turn filter — for inline reviews on a shared thread, concurrent turns' messages/items leak into two of the five sibling sequences. The inconsistency is the trap: consumers assume shared scope.
- `conf-batchwrite-okoverridden-invisible` [coverage-gap] config write result okOverridden is indistinguishable from ok; overriddenMetadata dropped — `CodexKit:Sources/CodexAppServerKit/AppServerRequests.swift:1704`
  - Upstream ConfigWriteResponse distinguishes ok vs okOverridden (write landed but masked by a higher-precedence layer) with overriddenMetadata.effectiveValue. CodexKit decodes status as a bare String, updateConfiguration discards the response entirely, and config/read decodes only 4 keys with no origins/layers — a consumer writing into a masked layer believes the new value is live and cannot detect masking on read either.
- `conf-model-service-tier-order` [protocol-mismatch] CodexModel decode sorts service tiers lexicographically and merges the deprecated additionalSpeedTiers field — `CodexKit:Sources/CodexAppServerKit/CodexDomainTypes.swift:2695`
  - supportedServiceTiers = Array(Set(additionalSpeedTiers + serviceTiers ids)).sorted() — keeps consuming the deprecated field and destroys server-provided ordering by lexicographic sort (the mistake CodexKit correctly avoids for supportedReasoningEfforts). ModelServiceTier name/description are dropped, so UIs can only show raw ids.
- `conf-permissions-object-shape` [protocol-mismatch] Permissions.profileSelection encodes an object where upstream expects a plain profile-id string — `CodexKit:Sources/CodexAppServerKit/AppServerRequests.swift:387`
  - Upstream thread/start.permissions (and resume) is Option<String>. CodexKit's Permissions enum can also encode {type:"profile", id} via .profileSelection (reachable through package CodexThreadPermissions.profileSelection), which serde would reject as -32602. The public .profile(id:) path conforms; the object arm is a latent wire break with no public producer.
- `conf-review-steer-always-rejected` [api-design] CodexReviewSession publicly exposes steer() although upstream categorically rejects steering review turns — `CodexKit:Sources/CodexAppServerKit/CodexDomainTypes.swift:919`
  - turn/steer on a review turn always fails upstream with activeTurnNotSteerable{turnKind: review}. CodexReviewSession.steer(with:) forwards to turn/steer — an API call that can never succeed, whose doc promises 'sends additional input to the running review turn', and whose typed error info is dropped (cross-ref conf-error-payload-discarded) leaving only an opaque message string.
- `conf-service-tier-tristate-collapsed` [protocol-mismatch] Double-option serviceTier tri-state is unexpressible (nil always means omit, never clear) — `CodexKit:Sources/CodexAppServerKit/AppServerRequests.swift:1299`
  - Upstream serviceTier on turn/start, thread/start/resume/fork is Option<Option<String>> (omitted = unchanged, explicit null = clear). CodexKit models plain String? with synthesized Codable that omits nil — a consumer can set or leave unchanged but never clear. Other double-option fields upstream are not implemented by CodexKit, so the gap is confined to serviceTier.
- `cov-experimental-capability-hardcoded` [api-design] experimentalApi capability is hardcoded on with no public control, and public listTurns rides an experimental method — `CodexKit:Sources/CodexAppServerKit/AppServerRequests.swift:233`
  - Initialize.Capabilities defaults experimentalAPI=true and Params.init uses .init() unconditionally; Configuration exposes no capabilities knob. Every consumer is silently opted into upstream's unstable experimental surface (the flag also changes which server→client requests may arrive). Public stable-looking CodexThread.listTurns() is backed by experimental thread/turns/list — it works only because of the hardcoded flag and can break without semver signal. optOutNotificationMethods is likewise unrepresentable.
- `cov-invented-turn-status` [api-design] CodexTurnStatus invents a .cancelled case and alias decodings the v2 protocol never emits — `CodexKit:Sources/CodexAppServerKit/CodexDomainTypes.swift:1836`
  - Upstream TurnStatus is exactly {completed, interrupted, failed, inProgress}; CodexTurnStatus adds .cancelled plus tolerant aliases ('started','succeeded','failure','aborted',...). .cancelled is unreachable from the wire, yet the consumer branches on it, encoding a belief that cancel-vs-interrupt is a server distinction. The alias table is a second protocol-vocabulary source: a future upstream status would be absorbed or misclassified instead of surfacing as .unknown. Smaller instance: CodexThreadItem.Kind invents .diagnostic/.error while upstream's real hookPrompt variant has no typed kind. Cross-ref conf-interrupted-is-failure, test-handrolled-notification-schemas-drift.
- `dk-fetchlimit-window-drift` [bug] Live-insert window logic lets items exceed fetchLimit via an unexplained loadedCount>fetchLimit growth branch — `CodexKit:Sources/CodexDataKit/CodexFetchRequest.swift:1044`
  - loadedWindowItems grows the window when `insertedModel && (loadedCount < fetchLimit || loadedCount > fetchLimit)` — `!=` written as two comparisons. Once loadedCount exceeds fetchLimit (reachable via includePendingChanges merges without re-clamping), every further insert grows it again, so fetchLimit is not an upper bound — SwiftData's fetchLimit is a hard cap. The condition's shape suggests the >-branch was not a deliberate contract.
- `dk-model-field-mutability` [api-design] Server-owned model fields are publicly mutable with no persistence path — mutations are silently clobbered — `CodexKit:Sources/CodexDataKit/CodexModel.swift:393`
  - CodexItem.kind/content/rawPayload, CodexTurn.status/errorDescription/itemsLoadState/usage, CodexChat.phase/lastErrorDescription and CodexFetchedResults.phase/lastErrorDescription are `public var` while every other server-derived field is private(set). There is no save(); the next snapshot/event merge overwrites app writes — worse, writing chat.phase/results.phase can corrupt the loading state machine DataKit itself reads back.
- `dk-model-for-workspace-name-mismatch` [api-design] model(for:) has placeholder-registering semantics for threads but lookup-only semantics for workspaces/groups — `CodexKit:Sources/CodexDataKit/CodexModelContext.swift:361`
  - model(for: CodexThreadID) is non-optional and registers a placeholder; model(for: CodexWorkspaceID/CodexWorkspaceGroupID) are byte-for-byte identical to registeredModel(for:) — optional pure lookups. Same name, opposite contracts; README documents only the thread pair.
- `dk-refetch-per-revalidation-server-ordering` [architecture] Server-owned ordering turns every chat metadata change into a full listThreads round trip per registered results — `CodexKit:Sources/CodexDataKit/CodexFetchRequest.swift:857`
  - With recencyAt/empty sort, usesServerOwnedOrdering makes revalidate/archive/remove always full non-appending refreshAfterMutation, and apply(event) revalidates on any ChatFetchedResultState delta (at least every turn start/completion of every chat, including background). The consumer's default sidebar descriptor is exactly this shape, so each change triggers listThreads per registered results. Local paths are worse: searchableText membership or offset>0 uses fetchAllThreadSnapshots which pages the entire thread history per scope.
- `dk-relay-unbounded-buffering` [bug] Update/transaction relays buffer unboundedly per consumer; a stalled consumer accumulates every delta — `CodexKit:Sources/CodexDataKit/CodexAsyncStreamRelay.swift:20`
  - makeStream uses bufferingPolicy .unbounded; CodexChatUpdate streams carry per-token itemTextAppended events, so a consumer holding an iterator without draining grows its buffer without limit for the life of the observation. Updates are documented as invalidation hints over an observable current value, so superseded buffered updates have no value.
- `dk-subscribe-after-read-gap` [usability] updates stream starts buffering at first iteration, so the documented read-then-subscribe pattern is safe only without suspension in between — `CodexKit:Sources/CodexDataKit/CodexModelContext.swift:287`
  - ObservationUpdates.makeAsyncIterator creates the stream lazily, so the README pattern (render chat once, then for-await updates) is race-free only if no await occurs between observe() returning and iteration; any suspension silently drops updates emitted in the gap — stale UI until the next event, no resynchronized marker. The current AppKit consumer happens to stay synchronous, so the contract is implicit and fragile.
- `dk-update-id-discontinuity` [api-design] CodexChatUpdate carries raw itemID strings whose identity changes on promotion; updates can reference ids never inserted — `CodexKit:Sources/CodexDataKit/CodexModel.swift:2001`
  - Updates carry raw server itemID, not the stable CodexChatItemID. promoteFallbackMessageDeltaItem emits .itemUpdated under the NEW id with no .itemRemoved for the old or .itemInserted for the new; replaceItemAcrossTurns conversely emits remove+insert. A consumer keying by update ids sees updates for never-inserted ids and dangling fallback ids. The typed-id API shape invites correlation the identity model can't support; the stable CodexItem.id exists but isn't what updates carry.
- `dx-config-chain-undocumented` [usability] Executable resolution chain (3 env vars + PATH + hardcoded app paths) is undocumented — `CodexKit:Sources/CodexAppServerKit/AppServerProcessTransport.swift:942`
  - Actual resolution: explicit executable arg > CODEX_APP_SERVER_CODEX_EXECUTABLE > CODEX_REVIEW_CODEX_EXECUTABLE > CODEX_EXECUTABLE > 'codex', searched against PATH plus hardcoded fallbacks (/Applications/Codex.app/Contents/Resources, homebrew paths). The public doc says only 'When nil, the default transport command is used' and the README documents only codexHome — debugging 'wrong codex picked up' requires reading package-internal source. Cross-ref ask-clientversion-default-mismatch for the related handshake-default drift.
- `dx-no-compat-policy` [api-design] No compatibility policy, no deprecation annotations, no runtime version — tolerant decoding is a hope, not a contract — `CodexKit:README.md:1`
  - Decode tolerance is genuinely strong (.unknown catch-alls, rawPayload retention), but nothing states the rules: no README section on what ships in minors, nothing saying 'new enum cases are non-breaking — handle .unknown', zero @available(deprecated) usages, no runtime-inspectable version. Cheap artifact that converts the .unknown convention into an enforceable contract before a second consumer appears.
- `dx-request-id-not-exposed` [api-design] JSON-RPC request ids are logged but never attached to errors or results — no correlation handle for app logs — `CodexKit:Sources/CodexAppServerKit/AppServerClient.swift:160`
  - The client allocates monotonically increasing request ids and logs them at debug level, but responseError carries only (code, message), CodexAppServerError carries no id, and typed results carry no envelope — correlating a UI failure with server/SDK log lines requires timestamp reconstruction. Cheap to add since ids already flow through the single send path.
- `test-fake-cancel-in-flight-returns-success` [protocol-mismatch] Fake send never throws CancellationError for a cancelled in-flight request; the real transport throws and drops the response — `CodexKit:Sources/CodexAppServerKitTesting/CodexAppServerTestRuntime.swift:1094`
  - When a task awaiting fake send() is cancelled at a gate, cancelWaiter resumes normally and send() returns the queued response as success; the real transport resumes the pending continuation with CancellationError and discards the response. The 'plain unshielded request cancelled in flight throws and its response is never observed' contract cannot be expressed against the fake, which inverts the outcome to success. SDK-internal sites are shielded (Task.detached), limiting current impact.
- `test-store-invented-error-code` [protocol-mismatch] Test thread store returns invented error code -32004 for missing threads; the real server has no such code — `CodexKit:Sources/CodexAppServerKitTesting/CodexAppServerTestRuntime.swift:126`
  - resumeThreadResponse/readThreadResponse/listThreadTurnsResponse throw responseError(code: -32004); upstream codes are -32600/-32601/-32602/-32603/-32001 — no -32004. Error-classification logic validated against the fake pins a code the real server never emits.
- `use-cleanup-nested-array` [api-design] cleanupReview's [[CodexThreadID]] parameter forces awkward array-wrapping at the call site — `CodexKit:Sources/CodexAppServerKit/CodexAppServer.swift:564`
  - The public signature takes additionalCleanupThreadIDs: [[CodexThreadID]] (an internal detail of orderedReviewCleanupThreadIDs leaking into the API). The consumer wraps its flat list in a single-element outer array, which reads like a bug and invites flattening mistakes.
- `use-empty-turnid-sentinel` [workaround] nilIfEmpty defenses against SDK-synthesized empty-string turn IDs — `CodexReviewKit:Sources/CodexReviewAppServer/AppServerCodexReviewBackend.swift:779`
  - CodexKit's router fabricates CodexTurnID(rawValue: "") when a notification lacks turn context, so consumers treat empty string as nil at every identity boundary: appServerReviewIdentity, reviewThreadID comparisons, MCP guards, and ReviewBackendEventSession filters. An Optional-typed SDK contract deletes all of these.
- `use-listed-chat-status-absence` [usability] Sidebar treats absent chat.status as 'finished' by documented convention, replicated at three UI sites — `CodexReviewKit:Sources/ReviewUI/Sidebar/CodexChats/ReviewMonitorCodexSidebarOutline.swift:117`
  - CodexChat.status is nil for listed-but-unloaded chats, so the filter classifies anything not actively running as finished per its own comment; the convention is copied in the row view and context menu. Exists because the SDK list surface can't distinguish 'unknown' from 'idle' — a chat whose status hasn't loaded yet presents as finished.
- `use-test-polling` [test-gap] Test suites poll with yield/sleep loops because the observation pipeline has no drain signal — `CodexReviewKit:Tests/ReviewUITests/ReviewUITests.swift:5414`
  - waitForCondition spins on Task.yield() under a 2s timeout at ~40 call sites; MCP HTTP tests use a 50ms sleep loop. There is no way to await 'all pending CodexChatUpdate/fetched-results transactions applied', so every model-driven UI assertion is time-based, importing load-proportional flakiness. Test-side face of the observation-updates gap.
