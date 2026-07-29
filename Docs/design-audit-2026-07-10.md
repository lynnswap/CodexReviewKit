# CodexKit / CodexReviewKit 設計・API 監査（2026-07-10）

| 項目 | 内容 |
|---|---|
| 対象 | CodexKit `3f6216c`（CodexAppServerKit / CodexDataKit / CodexAppServerKitTesting）、CodexReviewKit `6c1b432` |
| 一次情報 | upstream codex `8347b8d`（固定 worktree: `/Users/kn/Dev/checkout/codex-8347b8d`）、CodexKit `3f6216c`（`/Users/kn/Dev/checkout/CodexKit`） |
| 方法 | owner map → protocol / lifecycle / identity invariant → static trace。初期 mapper の raw 130 件を canonical 89 件へ統合し、初期 high+medium 53 件を adversarial に再検証 |
| 検証ステータス | 初期 high+medium 53 件と追加 low 1 件を再判定: **CONFIRMED 49 / PLAUSIBLE 1 / REFUTED・NOT ADOPTED 4**。採用 50 件は Appendix A（high 10 / medium 33 / low 7）、low 35 件は未検証のまま Appendix B |

読み方: 本文はクラスタ単位の判断、Appendix A は id 付きの証拠と failure trace である。パス表記は `CK:` = CodexKit、`CRK:` = 本 repo、`UP:` = upstream codex。severity は実装の存在ではなく、確認できた到達性と利用者影響で再評価した。

## 1. 結論

PR #16（2026-07-02）で問題だった generation 境界と observation multicast は解消済みである。`withThreadEventGeneration` が SDK の generation 切替を所有する。CRK では review worker pipeline が stale-event rejection を共同所有し、`ReviewWorkerEventSource` は subscription generation と pre-enqueue guard、`consumeReviewEvents` / `ReviewNetworkRecoveryLoopState` は attemptID と post-enqueue guard を担う。

現状は単一の「upstream v2 終端契約の誤読」には集約できない。確認できた弱境界は次の 4 群である。

1. **turn outcome の分類** — upstream の server-side interrupt は `turn/completed(status=interrupted, error=nil)` だが、`CodexTurnStatus.isFailure` が `interrupted` を failure に畳み、collector / progress / DataKit に伝播する。これは最も広い cross-layer cluster である。
2. **resource lifecycle** — router が自身を保持する Task cycle、`close()` が Task completion を await しない構造、router history と serializer lane の無期限保持に、単一 close/retention owner がない。
3. **wire boundary** — invented login method、server request への protocol-invalid `{}` 応答、request/transport/decode error の public 型への不完全な写像、現行 v2 で emit されない compatibility route が同居する。
4. **DataKit / Testing policy owner** — mutation ごとの local-apply/refetch 判断、同時 `load()`、fake の list semantics、手書き wire fixture が別々の source of truth を持つ。

CRK は raw JSON-RPC を再実装していない。public typed surface の `CodexReviewSession.events` と `cancel()` を使い、terminal aggregate の `progress` / `collect()` / `response` は使っていない（`use-highlevel-surface-bypass`）。これは aggregate 層の outcome/output 契約に摩擦がある証拠だが、SDK の高水準 API 全体が利用不能という証拠ではない。

`thread/closed` cluster は production P1 から外す。upstream 一般では、最後の subscription が unsubscribe または server が存続する multi-connection transport の disconnect で除去され、thread が inactive/idle になると unload する。running thread は unload しない。persisted thread は resume できるが ephemeral thread は unload 後に resume できない。CodexKit の stdio transport は unsubscribe を送らず、last connection close で app-server 自体が終了するため、pinned baseline の live connection から `.closed` は通常観測不能である。

## 2. upstream 契約の一次事実

| protocol 事実 | 根拠（UP: `codex-rs`） | CodexKit への含意 |
|---|---|---|
| 現行 v2 の turn terminal notification は `turn/completed`。結果は `turn.status`（completed / interrupted / failed / inProgress） | `app-server-protocol/src/protocol/v2/turn.rs:29-35`、`app-server/README.md` の turn lifecycle | `interrupted` と `failed` を別 outcome に保つ必要がある。Swift aggregate が return / typed outcome / throw のどれを選ぶかは SDK 契約として別途決める |
| server-side interrupt は `status=interrupted, error=nil` で完了する | `app-server/src/bespoke_event_handling.rs:1438-1459` | `isFailure` への単純集約は情報を失う。caller Task cancellation は `CancellationError` として別に扱う |
| `thread/closed` は最後の subscription が unsubscribe（または server が存続する multi-connection disconnect）で除去された後の inactive/idle unload。running 中は unload しない。persisted thread だけが後で resume 可能 | `app-server/README.md:140-162,455-477`、`thread_state.rs:542-564`、`thread_processor.rs:2607-2619`、`thread_lifecycle.rs:55-60,351-354,406-436`、`app-server/src/lib.rs:718-719,996-1016,1156-1166` | CodexKit stdio は unsubscribe を送らず、last connection close で server が終了するため `.closed` は通常観測不能。injected/future `.closed` で generation を終えること自体は整合し、turn outcome 合成だけが誤り |
| `turn/failed` と `item/updated` は一時期 schema に存在したが、現行 baseline ではなく実装から emit された証拠もない。`turn/cancelled` と `agent/message` は exact method history も確認できない | upstream history `a010c1b7fcce` → `ce35cb16b279`、現行 `protocol/common.rs` | 削除は compatibility policy を決めてから行う。fallback identity は `agent/message` だけでなく itemID 欠損 delta でも駆動するが、現行 valid v2 wire は itemID required |
| client→server login request は `account/login/start` / `account/login/cancel`。stock flow の完了は server notification `account/login/completed` | `app-server-protocol/src/protocol/common.rs:1001-1013,1705-1708`、`account.rs:68-86,124-137` | client request `account/login/complete` + `nativeWebAuthentication` は stock codex との契約にない |
| `thread/rollback` は “will be removed soon” と明記 | protocol definition の deprecation 注記 | fork/resume が replacement だとは一次情報から断定できない。依存を一箇所へ隔離し、移行仕様を upstream と確定する |
| `account/rateLimits/updated` は sparse rolling update | `app-server-protocol/src/protocol/v2/account.rs:508-515` | snapshot 置換ではなく merge owner が必要 |
| server→client request は method ごとの typed response を要求し、abort は `serverRequest/resolved` で通知される | request/response serde、`protocol/v2/notification.rs:52-57` | default `{}` と resolved 無視は request lifecycle contract を破る |

## 3. Owner map

### CodexKit

| 責務 | 現状 | 破られた invariant | 推奨 owner |
|---|---|---|---|
| turn outcome | `CodexTurnStatus.isFailure` と各 sequence / DataKit の分岐 | completed / interrupted / failed と caller cancellation が保存されず、unknown/nil/nonterminal status の扱いも暗黙 | public terminal-outcome 型。completed / interrupted / failed に加え、unknown・nil・terminal notification 内の inProgress は typed invalid-terminal outcome として fail loud |
| request error boundary | public `CodexAppServerError` は一部で使うが、request/transport/decode error は package/private/raw 型が多い | consumer が server rejection / spawn / invalid response を安定した型で分岐できない | transport が error envelope/data を保持し、client が requestID と request/decode mapping、public start/factory が spawn/scaffold mapping を所有 |
| connection close | router → Task → router の strong cycle。stop は cancel するが completion を await しない | close 完了後に Task / transport / process が停止した証明がない | 単一 async close authority が I/O stop、Task cancel、Task completion await を所有。独立した synchronous process-terminator token を deinit backstop にする |
| replay retention | router history と serializer lane が append-only | connection lifetime が memory upper bound になる一方、late/repeated `result()` は terminal replay に依存 | raw deltasを finalized snapshotへ compactし、その snapshotも handle lifetime または documented TTL/LRU + typed expiryで bound。無期限 late resultを保証するなら外部永続 ownerが必要。laneはin-flight完了後に除去 |
| thread unload | router は current thread generation を finish（整合）するが reason は型に出さず、DataKit/CRK は turn outcome を合成 | generation end と turn success/failure は別契約 | router は必要なら typed unload reason を公開し、DataKit/adapter は outcome を合成しない。persisted resume は新 generation |
| fetch mutation policy | insert/archive/revalidate/remove/refresh が個別判断 | 同じ membership/order invariant に複数 strategy がある | query plan から導出する単一 per-mutation strategy |
| wire fixture | SDK tests / Testing target / CRK preview が手書き | fake dialect が production protocol を上書きする | Testing target の method-specific typed builders。現行 method だけを既定で提供 |

### CodexReviewKit

維持すべき owner:

- domain core は transport 非依存で、UI target も CodexAppServerKit を import しない。
- preview は `CodexAppServerTestRuntime` で transport を fake 化し、本番 data flow を通す。
- review worker pipeline が generation boundary を所有する。`ReviewWorkerEventSource` の subscription generation / pre-enqueue guard と、consumer/recovery state の attemptID / post-enqueue guard はどちらも削除対象ではない。
- MCP session close は `closeSession`、chat-log render は純粋 projection + document diff に集約されている。

弱い owner:

- login flow の 9 state values を 8 cluster が異なる subset で協調し、app-server-scoped `authNotificationTask` は別責務として隣接する（`arch-login-state-no-owner`）。
- `attemptID` の `"attempt-1"` default は source of truth を増やすが、review run は memory-only で production 作成経路は UUID を設定する。現状は collision bug ではなく latent migration/API hazard（`arch-attempt-id-fallback`）。
- SDK は `CodexReviewIdentity.sourceThreadID` / `activeTurnThreadID` を持つが、CRK の Run/event plane が String に type-erase し、3 層で再導出する（`use-dual-thread-identity`）。
- 未使用なのは `CodexReviewHost` **class** と `DirectCodexReviewStoreBackend` であり、production composition を持つ `CodexReviewHost` target 全体ではない（`arch-host-target-test-only`）。

## 4. Consumer-action based DX 評価

外部 SDK の点数や「17 契約」は証拠表を作っていないため評価根拠にしない。ここでは、CRK が public API だけで start / observe / cancel / close / recover を完遂できるかで評価する。

**CodexAppServerKit** は transport actor、per-thread serial lane、overload retry、replay router、`.unknown` + raw payload 保持を備え、正常系の層分離は明快である。弱いのは境界失敗時の consumer action である。

- request/transport/decode error の一部が public taxonomy に入らず、CRK は `localizedDescription` へ 37 箇所で還元している。一方、turn failure、collector の transport close、restart、login validation には `CodexAppServerError` が実際に使われているため「型で何も catch できない」は誤り。
- initialize handshake と request response に deadline がない。valid な review は長時間無イベントになり得て heartbeat もないため、inter-event-gap timeout は導入しない。optional handshake/per-request deadline と caller-specified overall turn deadlineを分ける。
- caller Task cancellation が event iteration 中に起き、stream が terminal event なしで nil 終了した経路だけ `.transportClosed` へ化け得る。turn/start request 自体の cancellation は `CancellationError` を保つ。
- stale/no-active `turn/interrupt` error は plain `invalid_request(message)` で structured data を持たない。`CodexErrorInfo` を保存するだけでは string parse は消えず、upstream の structured interrupt error または別の typed affordance が必要である。

**CodexDataKit** は identity-stable な `@Observable` model を in-place 更新する。一方、API 名から想起される契約との差は明文化が必要である。

1. `@CodexQuery` は外部 process による thread list 変更を自動 ingest しない。これは「live query」の範囲を server event にまで広げるかという product contract の不足である。
2. unsupported predicate/sort は query construction / SwiftUI update 経路で `preconditionFailure` になる。SwiftData の explicit `ModelContext.fetch` には throwing path があるため、少なくとも explicit load では validation error を返せる surface が望ましい。
3. `isArchived` を含まない predicate に `archived == false` を暗黙注入する。
4. `includePendingChanges` と public mutable server-owned fields の意味が、保存 API 不在のまま不明瞭である。

## 5. API 過不足

### stock upstream と整合しない surface

| surface | 判断 | finding |
|---|---|---|
| `account/login/complete` + `nativeWebAuthentication` | stock codex に存在しない。fork 契約なら capability と binary pin を明記し、そうでなければ撤去 | `cov-invented-login-complete` |
| current-v2 で emit されない notification/status | `turn/failed` / `item/updated` には短命な historical schema があるため、単純な「全履歴に不存在」ではない。互換期間を決め、Testing の既定 fixture から invented dialect を除く | `cov-dead-compat-notifications` |

### consumer story から確認できる不足

| 欠落 | 消費側の代償 | finding |
|---|---|---|
| stable public request/transport/decode error + `error.data` / requestID | message parse、failure category の type erase | `dx-error-taxonomy-uncatchable`, `conf-error-payload-discarded` |
| optional handshake / request / overall-turn deadline | wedged binary/request を caller が分類して打ち切れない | `dx-no-timeout-story` |
| server→client request の method-specific response + resolved lifecycle | default `{}` が decode failure、abort 後 handler が残る | `cov-server-requests-untyped`, `conf-server-request-resolved-ignored` |
| explicit connection termination surface | typed notification stream failureを runtime termination signal と兼用 | `use-runtime-death-side-channel` |
| typed warning / deprecation / retry projection | raw `.unknown(CodexRawNotification)` を読めば見えるが、typed progress と CRK adapter では落ちる | `cov-error-warning-untyped` |
| external-change freshness contract | MCP read は on-demand snapshot ownerとして refresh するが、projection 不在と refresh failure が同じ nil になる | `dk-query-not-live-external`, `use-mcp-refresh-fallback` |

`CodexTranscript.reviewOutputText` は README と実装に既にある primary review-output contract である。CRK の `reviewOutputText ?? finalAnswer ?? transcript.finalAnswer` は SDK 欠落への補償ではなく、削除可能な consumer-side redundancy（`use-review-output-location`）。outbound raw JSON-RPC escape hatch は consumer story と method lane/capability/experimental gating の設計がないため、今回の不足には数えない（§7）。

### 適切に無いもの

`fs/*`、`mcpServer/*`、skills、plugins、exec/process、realtime、remoteControl 系には CRK の需要や workaround pressure がない。CRK production code に手書き JSON-RPC はなく、raw JSON は preview/test transport に限定される。`review/start` の request method・ReviewTarget・ReviewDelivery は一致するが、upstream required の `reviewThreadId` を CodexKit response DTO が optional に弱めている点は別の low-level contract gap である。

## 6. 修正方針

### P1 — public contract と lifecycle owner

| # | 修正 | 回復する invariant | findings |
|---|---|---|---|
| 1 | public terminal-outcome 型を `completed / interrupted / failed / invalidTerminalStatus(rawStatus,response)` として定義し、collector / progress / DataKit / CRK adapter を同じ exhaustive mapping へ接続する。unknown、nil、terminal notification内のinProgressをoutput有無からsuccess/failureへ推測しない。caller Task cancellationは`CancellationError`、server interruptはtyped outcomeとして区別する | wire の分類情報を convenience/adapter layer が失わず、未知状態を誤分類しない | `conf-interrupted-is-failure`, `ask-cancel-collect-misreported`, `dx-cancel-semantics-inconsistent`, `use-highlevel-surface-bypass` |
| 2 | transport が JSON-RPC error envelope/data を保持し、`AppServerClient` が requestID と request/decode errorを写像、public start/factory が spawn/scaffold errorを写像する。optional handshake/request deadlineを各 ownerに置き、overall turn deadlineは caller policy。interrupt parse 撤去は structured server affordanceを upstream と合意 | consumer が failure category ごとの次 action を選べる | `dx-error-taxonomy-uncatchable`, `conf-error-payload-discarded`, `ask-interrupt-error-string-parsing`, `dx-no-timeout-story` |
| 3 | router Task の strong edge を切り、単一 `close()` が producer/I/O stop → Task cancel → Task completion await → handle release を完了する。process group は独立 terminator tokenを deinit backstopにする。raw history は finalized snapshotへ compactし、snapshot自体も turn-handle lifetimeまたは documented TTL/LRU + typed `resultExpired` で evictする。無期限 repeated late resultを要求するなら外部 persistenceへ移す | close 後にTask/transport/processが残らず、replay契約を保ったままconnection memoryがbounded | `ask-process-leak-no-deinit`, `ask-router-history-unbounded` |
| 4 | invented login surface を撤去または fork capability として pin。server request は method-specific default decline と `serverRequest/resolved` cleanup を実装 | public API と wire method、request lifecycle が一致する | `cov-invented-login-complete`, `cov-server-requests-untyped`, `conf-server-request-resolved-ignored` |
| 5 | current `commandExecution/outputDelta` は append merge、feature-gated current `fileChange/patchUpdated` は structured snapshot replace/mergeとして既存 item metadataを保つ。legacy `fileChange/outputDelta` は compatibility policyへ隔離する。rate-limit sparse updateはlast snapshotへmerge | delta/snapshot update の semantic owner が item を壊さない | `conf-command-delta-clobbers-item`, `conf-ratelimits-replace-not-merge` |

`thread/closed` による thread-generation completion 自体は P1 ではない。DataKit/CRK の outcome synthesis は今削除できる。将来 unsubscribe surface または multi-connection unload を扱うとき、typed end reason、persisted resume の新 generation、ephemeral unload の非 resumable 性を contract test で固定する。

### P2 — DataKit / Testing の再発防止

| # | 修正 | findings |
|---|---|---|
| 6 | DataKit mutation strategy を query plan 由来の単一 owner にし、`load()` を serial task または generation token で latest-wins にする | `dk-mutation-strategy-scattering`, `dk-unserialized-fetch-loads` |
| 7 | current-v2 と historical compatibility policy を決める。Testing の default builders は現行 method（例: `emitTurnCompleted`、`emitCommandExecutionOutputDelta`、`emitFileChangePatchUpdated`、server request）だけを提供し、legacy builderは明示namespaceへ隔離 | `cov-dead-compat-notifications`, `test-fictional-turn-failed-pins-phase-contract`, `test-handrolled-notification-schemas-drift` |
| 8 | fake を fail-fast にし、thread/list の archived/sort と実 transport の cancellation を実装する。server-request injection は in-memory fake から test 可能にする | `test-unstubbed-method-silent-success`, `test-store-ignores-archived-and-sort`, `test-fake-cancel-in-flight-returns-success`, `test-no-server-request-injection` |
| 9 | predicate/sort validation を throwing construction/load surfaceへ移し、archived default と external-change freshness scope を文書化する | `dk-predicate-runtime-crash-contract`, `dk-implicit-archived-scope`, `dk-query-not-live-external` |
| 10 | warning/deprecation/retry と connection termination を typed lifecycle/event surfaceへ投影する。raw payload は diagnostic escape として保持する | `cov-error-warning-untyped`, `use-runtime-death-side-channel` |

### P3 — CodexReviewKit の整理

| # | 修正 | 条件 |
|---|---|---|
| 11 | login state を単一 `LoginSession` owner に集約し、全 exit path が同じ async terminate completion を待つ | 即時 |
| 12 | adapter 境界で `reviewOutputText` の欠損を一度だけ typed failure にし、成功側の `Completion.finalReview` を non-optional にする。3段 fallbackと store/MCP の重複検査、item-status再導出、未使用 `CodexReviewHost` class + `DirectCodexReviewStoreBackend` を削除 | 即時。class 削除は target 削除を意味しない |
| 13 | core に CRK domain の review-thread identity（source / active-turn pair）を置き、adapter が `CodexReviewIdentity` から一度だけ写像する。String 再導出を削除し、transport 非依存を保つ。presentation dedup は typed item kind + turn relation で行い、distinct semantic items を persistence で一つに潰さない | 即時に型設計、既存 decoder contract の確認後に移行 |
| 14 | `"attempt-1"` default を削除する。queued Run の nil は許しても、threadID を持つ backend Run の復元では attemptID を必須にして fail fast。resume-to-cancel は到達する consumer story を先に証明し、必要なら cancel-by-identity 後に削除。observe serialization は awaitable rebind 後に削除 | attempt default は即時、他は各 contract 後 |

backend adapter は P1-1 の public outcome を exhaustively mapし、現行の interrupted→cancelled repair と unknown/nil/running + output→completed 推測を削除する。一方、store の `completePendingCancellationIfNeeded` は「product の cancellation request が backend terminal と競合したとき cancellation wins」という別 invariant を所有し、SDK修正後も残す。`ReviewBackendEventSession` の terminal は backend abstraction の契約であり、SDK event と同一視して全削除しない。

## 7. 反証・今回採用しない提案

- **REFUTED — `test-fake-close-clean-finish-hangs-subscribers`**: fake の `close()` は package-scoped で consumer から到達不能。public `CodexAppServer.close()` は先に `router.stop()` で stream を finish する。clean/throwing 終端の非対称は low の設計課題だが、報告された hang trace は成立しない。
- **REFUTED — `use-item-status-rederivation`**: CodexKit `2a4d2f5` が全 terminal 経路で `itemByApplyingTerminalLifecycleStatus` を適用済み。CRK projection の再導出は live workaround ではなく削除可能な残骸である。
- **REFUTED — `use-subscription-generation-guards`**: review worker pipeline が責務を分担している。`ReviewWorkerEventSource` は subscription generation と pre-enqueue guard、`consumeReviewEvents` / `ReviewNetworkRecoveryLoopState` は attemptID と post-enqueue guard を所有し、tests も pin する。これは owner 不在ではない。supersede reason の typed 化は追加 DX になり得るが、guard の削除理由にはならない。
- **NOT ADOPTED — `dx-no-raw-escape-hatch`**: raw send の不存在は事実だが、CRK の consumer storyがなく、upstream request は method-specific serialization lane、capability、experimental gatingを持つ。単純な `sendRaw(method:params:)` はそれらを迂回するため、現時点の不足・「安価な追加」とは判定しない。

## 8. テストチェックリスト

- [ ] server-side `turn/completed(status=interrupted,error=nil)` が typed interrupted outcome になり、failed と区別される — sibling: collector / progress / DataKit phase
- [ ] terminal notification の unknown / nil / inProgress status は typed `invalidTerminalStatus` になり、CRK adapter も output text の存在だけで `.completed` を合成しない
- [ ] caller Task cancellation が turn/start request 中と event iteration 中の双方で `CancellationError` になり、server-side interrupted と区別される
- [ ] current wire `turn/completed(status=failed,turn.error)` で `chat.phase == .failed` を pinし、fictional `turn/failed` fixture を置換する
- [ ] explicit close が router/producer Task completion と child-process reap を awaitし、二重 close も同じ completionへ収束する
- [ ] long-lived connection で raw history・finalized snapshot・serializer lane が retention policyどおり解放され、期限内の repeated late `result()` と期限後の typed `resultExpired` が一致する
- [ ] command output delta は command/cwd と既存 output を保って appendされ、feature enabled 時の fileChange patchUpdated は item metadata を保って structured snapshot を適用する
- [ ] login の success / cancel / web-session error / account-update error / runtime death / explicit close の全 exit path が fields、tasks、temporary runtime を解放する
- [ ] fake は unstubbed method で fail-fast し、thread/list の archived/sort と in-flight cancellation（cancelled waiterは `CancellationError`、late responseは破棄）を production と一致させる
- [ ] `serverRequest/resolved` が pending handler を解放し、requestUserInput/permissions/DynamicToolCall/MCP elicitation の既定 decline が valid wire shape になる
- [ ] 並行 `load()` の A→B→A completion で items/cursor が選択した latest-wins contract と一致する
- [ ] injected `.closed` / `.notLoaded` は turn success/failure を合成しない。将来 unsubscribe/multi-connection transport を実装する場合、persisted resume の新 generationと ephemeral unload の非 resumable 性を integration test で pinする
- [ ] stale old-attempt event は `ReviewWorkerEventSource` の pre-enqueue guard と consumer/recovery state の attemptID + post-enqueue guardで捨てられる（既存 regression を維持）
- [ ] review output は adapter 境界で `reviewOutputText` を一度だけ採用する。欠損は一度だけ typed failure、成功 completion は non-optional とし、final assistant message は distinct semantic item として保持する
- [ ] inline / detached review の source/active-turn identity pair が adapter → store → MCP を通して保存される
- [ ] threadID を持つ backend Run の attemptID 欠損は `"attempt-1"` を作らず fail fast する
- [ ] in-flight observation registration の cancel/rebind が awaitable completion で同期する
- [ ] CRK login teardown・review output・item status cleanup の削除後も product cancellation-wins arbitration が維持される

**観測性**: `error.willRetry` と `deprecationNotice` は raw `.unknown` から読めるが、typed progress / CRK adapter では失われる。connection termination、retry、deprecation をそれぞれ意味のある lifecycle/event 境界へ投影する。

## 9. 監査の限界

- Appendix B の low 35 件は adversarial 検証を通しておらず、本文の確定判断には使わない。
- ReviewChatLogUI / ReviewUI は core state と projection を精読したが、全 view path の runtime probe は行っていない。
- `thread/closed` の current unreachability は CodexKit stdio と upstream shutdown の static trace に基づく。将来 unsubscribe または server が存続する multi-connection transport を使う場合は再監査が必要。
- `TextTransitions`、`scripts/`、`Tools/` は対象外。

---

## Appendix A: 検証済み findings（再評価後、50 件）

各項目: 検証 verdict / 調整後 severity / 位置 / 内容 / 証拠。kind: bug = 実挙動の欠陥、protocol-mismatch = upstream 契約との不一致、api-design / usability = 設計判断、coverage-gap = API 過不足、test-gap = テスト欠落、workaround = 消費側補償、architecture = 構造。

### `arch-login-state-no-owner` — Login/auth session teardown invariant has no owner: 9 login-state values are coordinated across 8 reset clusters

**CONFIRMED / high / architecture** — `CodexReviewKit:Sources/CodexReviewHost/LiveCodexReviewStoreBackend.swift:218`

Login-flow state (`loginChallenge`, `loginBackend`, `loginAppServer`, `loginCodexHomeURL`, `loginActivation`, `isWaitingForLoginAccountUpdate`, `activeAuthenticationSession`, `authenticationTask`, `loginNotificationTask`) is coordinated by manually nil-ing/cancelling different subsets across 8 clusters: the 7 complete/exit paths originally identified plus the partial reset in `startLogin`. `loginActivation` participates in the state machine but is not reset like the other fields; `authNotificationTask` is a tenth nearby field but is app-server-scoped. `PendingLoginRuntimeCleanup` already groups part of runtime cleanup, yet does not own the whole login session or all exit paths. Any new exit path must reproduce ordering and ownership or retain an isolated app-server process / temporary CODEX_HOME.

- 証拠: LiveCodexReviewStoreBackend.swift:218-227 fields; reset clusters :670-702, :885-888, :915-940, :974-991, :1033-1062, :1300-1321, :1338-1384, :1559-1578 — same invariant, different order/subset.
- 修正の方向: Extract a LoginSession type (challenge + runtime + web session + tasks) with a single terminate(reason:) as the only teardown path; the backend holds at most `var loginSession: LoginSession?`.

### `ask-cancel-collect-misreported` — Task cancellation during event iteration can surface transportClosed instead of CancellationError

**CONFIRMED / high / bug** — `CodexKit:Sources/CodexAppServerKit/CodexTurnSequences.swift:490`

When caller cancellation happens after the turn exists and while `collect()` is iterating `turn.events`, the `AsyncThrowingStream` iterator can return nil. The collector then reaches its unconditional `CodexAppServerError.transportClosed`, losing the caller-cancellation category. Cancellation during the earlier turn/start request still propagates `CancellationError`; the defect is not every cancellation path. CRK checks `Task.isCancelled` around its typed event loop because terminal-less iteration and server-side interruption need separate handling.

- 証拠: CodexTurnSequences.swift:466-491 loop then `throw CodexAppServerError.transportClosed`; CodexDomainTypes.swift:1994-2008 collect() never converts loop-exit to CancellationError; consumer workaround CodexReviewKit:Sources/CodexReviewAppServer/AppServerCodexReviewBackend.swift:753-759.
- 失敗トレース: 1) Consumer awaits `thread.respond(to:)` = `streamResponse().collect()` (CodexThreadOperations.swift:74). 2) `collect()` awaits `turn.result()`, whose collector iterates `turn.events` (CodexTurnSequences.swift:468). 3) Caller cancels after iteration began; the cancellation handler starts an ownerless unstructured `Task { try? await turn.interrupt() }` and the iterator can return nil. 4) The loop exits without `.completed` / `.failed` and line 490 throws `.transportClosed`. 5) Caller receives transport failure for this cancellation path; `waitForCancelledResponse` has the same terminal-less-loop shape.
- 修正の方向: A shared stream-exit classifier used by collector/result and `waitForCancelledResponse` owns the distinction: caller Task cancelled → `CancellationError`; observed transport termination → `transportClosed`; neither but terminal missing → typed invalid stream end. Do not use a typed server `.cancelled` outcome for caller Task cancellation.

### `ask-process-leak-no-deinit` — Dropping CodexAppServer without close() leaks the spawned codex child process

**CONFIRMED / high / bug** — `CodexKit:Sources/CodexAppServerKit/AppServerProcessTransport.swift:153`

Process termination is reachable only via `close()` / stdout EOF (`closeTransport`). In addition, the router stores `routerTask` while that Task strongly captures the router, forming `router → task → router → client → transport`. Dropping the public server without explicit close therefore does not make the transport unreachable; neither object deallocation nor stdin-EOF can provide cleanup. The child runs in its own process group and reaping is only performed by `terminateAndWait`.

- 証拠: AppServerProcessTransport.swift:153-172 close/closeTransport; :662-663 process group; CodexAppServerNotificationRouter.swift:19,84-97 stored Task and strong capture; :168-171 stop cancels without awaiting; CodexAppServer.swift:216-223 explicit close.
- 失敗トレース: 1) CodexAppServer.init spawns codex app-server in its own process group (AppServerProcessTransport.swift:60-111, :662-663) and starts the router (CodexAppServer.swift:176-179). 2) router.start() creates the routerTask retain cycle (CodexAppServerNotificationRouter.swift:19,:89-97). 3) Consumer recreates its container (login change / test forgets close()) and drops the last CodexAppServer reference without calling close() (CodexAppServer.swift:220-223, the sole teardown). 4) No deinit exists anywhere in the target; terminateAndWait is never invoked; the router/client/transport chain stays resident and the codex child keeps running. 5) Each recreation adds one orphaned codex process plus one leaked actor graph.
- 修正の方向: Primary owner is explicit async close: break the Task strong edge, signal producer/I/O stop, cancel the stored Task, and await its completion before releasing client/transport. Separately keep the pid/process-group capability in a synchronous terminator token independent of the actor graph and use its deinit only as a best-effort signal/log backstop. deinit must not own async reap completion.

### `ask-router-history-unbounded` — Notification router event history grows without bound for the connection lifetime

**CONFIRMED / high / bug** — `CodexKit:Sources/CodexAppServerKit/CodexAppServerNotificationRouter.swift:20`

turnHistoryByTurnID, threadHistoryByThreadID and threadIDByTurnID are append-only with no eviction owner; every turn-scoped event (including full rawPayload Data) is stored twice, and RequestSerializer.lanes also only grows. History is load-bearing (replay for late subscribers, waitForCancelledResponse) but nothing prunes it after a turn is terminal, so a long-lived consumer app accretes memory proportional to every delta ever streamed.

- 証拠: CodexAppServerNotificationRouter.swift:20-22 dictionaries; :302 and :315 appends; grep shows no removeValue on any of the three maps. AppServerClient.swift:208-215 lane(for:) inserts, never removes.
- 失敗トレース: 1) Consumer keeps one CodexAppServer for app lifetime (CodexReviewHost pattern) and runs reviews continuously. 2) Every streamed notification with a turnId is decoded and appended to turnHistoryByTurnID (CodexAppServerNotificationRouter.swift:302) and, when threadId resolves, again to threadHistoryByThreadID via appendThreadEvent (:297,:314-315); item events carry full rawPayload Data (:904, :1400). 3) turn/completed arrives; isTerminalTurnEvent (:512-520) only triggers finishTurnSubscribers (:308-310); both history entries for the finished turn remain forever. 4) thread/closed (:333-335) likewise removes no history. 5) After N reviews × thousands of delta events each, resident memory holds two copies of every delta ever streamed plus one SerialLane per thread (AppServerClient.swift:208-215) until process exit.
- 修正の方向: Router owns retention without breaking late/repeated replay. At terminal, compact raw deltas into a finalized response/transcript/terminal snapshot, then bound snapshot count by turn-handle lifetime or documented TTL/LRU with typed `resultExpired`. If indefinite repeated `result()` is a requirement, move finalized results to an external persistence owner rather than keeping them in connection memory. Remove serializer lanes after in-flight work completes.

### `conf-interrupted-is-failure` — Collector, progress, and DataKit classify server-side interrupted outcomes as failures

**CONFIRMED / high / protocol-mismatch** — `CodexKit:Sources/CodexAppServerKit/CodexDomainTypes.swift:1878`

Upstream emits one turn-terminal method, `turn/completed`, and server-side interrupt completes as status `interrupted` with no `TurnError`. `CodexTurnStatus.isFailure` nevertheless returns true for `.interrupted` and the aggregate layers key off it: collector/respond throw `turnFailedWithResponse`, progress yields `.failed`, and DataKit marks the chat failed on the event and on refresh. `waitForCancelledResponse` already distinguishes `.interrupted/.cancelled` and returns normally, demonstrating that the inconsistency is limited to the collector/progress/DataKit paths rather than every SDK layer. Whether another Swift aggregate returns `CodexResponse`, a typed outcome, or a typed interruption is an API choice.

- 証拠: CodexDomainTypes.swift:1878-1885 `isFailure`,2088-2112 contrasting cancellation wait; CodexTurnSequences.swift:303-309,440-447,477-487; CodexModel.swift:1145-1151,2368-2372; upstream turn.rs:29-35 and bespoke_event_handling.rs:1438-1459; consumer AppServerCodexReviewBackend.swift:626-631.
- 失敗トレース: (1) Explicit `CodexResponseStream.cancel()` or another server-side interrupt leads to `turn/completed {status:"interrupted", error:null}`. (2) Router decodes `.completed(response.status=.interrupted)`. (3) Collector/result checks `isFailure` and throws `turnFailedWithResponse`; progress yields `.failed`. (4) DataKit marks the chat failed on the event and refresh. (5) CRK's adapter re-splits the interrupted status. This trace is distinct from cancelling the caller Task that awaits collect.
- 修正の方向: A public terminal-outcome type owns `completed | interrupted | failed(TurnError) | invalidTerminalStatus(rawStatus,response)`. Collector/progress/DataKit switch exhaustively over it; unknown/nil/inProgress terminal payloads fail loud without guessed classification, and caller Task cancellation remains `CancellationError`. Choose the aggregate return/throw shape at an API design gate.

### `cov-invented-login-complete` — Native web-auth login path (account/login/complete + nativeWebAuthentication) is invented; upstream never had it in any revision

**CONFIRMED / high / protocol-mismatch** — `CodexKit:Sources/CodexAppServerKit/AppServerRequests.swift:2285`

CodexKit's public 3-step native login sends account/login/start with an extra nativeWebAuthentication:{callbackUrlScheme} field, decodes it back from the response, and completeLogin sends method account/login/complete. None of this exists upstream at HEAD 8347b8d and `git log --all -S` shows it never existed. Stock codex completes the flow by emitting `account/login/completed`; there is no client completion request. Against a stock server, the extra field is silently ignored and the response never echoes nativeWebAuthentication, so the consumer's ASWebAuthenticationSession callback-completion gate never engages; the unknown completion request fails as `invalid_request` (-32600) on this baseline. If a patched codex build is intentionally targeted, that dependency is undocumented and unpinned.

- 証拠: AppServerRequests.swift:2285 method, :2144-2162 `NativeWebAuthentication` + Params; CodexAppServer.swift:799-812,855-862; upstream common.rs:1001-1013 and account.rs:68-86,124-137; upstream history `git log --all -S`; consumer LiveCodexReviewStoreBackend.swift:911,961; `Sources/CodexAppServerKit/README.md:414-421`.
- 失敗トレース: Against a stock codex app-server: (1) CodexAppServer.loginChatGPT(nativeWebAuthentication:) sends account/login/start with extra field nativeWebAuthentication:{callbackUrlScheme} (CodexAppServer.swift:799-812; AppServerRequests.swift:2162,2255); (2) upstream deserializes LoginAccountParams::Chatgpt which has no such field (account.rs:68-86) — extra field silently ignored; (3) response is {type:"chatgpt", loginId, authUrl} only, so native callback data decodes nil; (4) consumer callback-completion gate remains false; (5) `completeLogin` sends unknown `account/login/complete`, which pinned app-server maps to `invalid_request` (-32600) in message_processor.rs:91-99/error_code.rs:3-6.
- 修正の方向: Wire layer owns method-name truth: delete the invented surface, or document and pin the fork as the supported server and gate the API on a capability check — a nonexistent method must not be a public API's only completion path.

### `cov-rollback-deprecated` — Review restart, rollback(turnCount:) and revertTranscript are built on thread/rollback, which upstream marks 'will be removed soon'

**CONFIRMED / high / coverage-gap** — `CodexKit:Sources/CodexAppServerKit/CodexAppServer.swift:510`

Three public behaviors depend on thread/rollback: CodexThread.rollback(turnCount:), restartPreparedReview's mandatory rollback of the interrupted turn, and transcriptErrorHandlingPolicy .revertTranscript (CodexResponseStream.handleFailure). Upstream: 'DEPRECATED: thread/rollback will be removed soon.' The consumer's core review-recovery flow calls prepareReviewRestart/restartPreparedReview; when upstream removes the method, restart will fail at runtime mid-recovery after the turn was already interrupted. The future error code is not yet a contract. `deprecationNotice` is retained only as raw `.unknown`; typed progress and CRK's adapter do not surface it.

- 証拠: CodexAppServer.swift:505-513 rollback in restart; CodexThreadOperations.swift:335-339; CodexDomainTypes.swift:2127-2135,2185-2193 revert policy; AppServerRequests.swift:1469 method; upstream thread.rs:1045 deprecation, common.rs:616; consumer CodexReviewStoreReviews.swift:676,744.
- 修正の方向: Isolate rollback behind one internal seam and define restart/revert semantics when it disappears. Fork/resume-based editing is a candidate inference, not a documented replacement; confirm the migration contract with upstream. Surface `deprecationNotice` as a typed event so consumers see the removal signal.

### `dx-error-taxonomy-uncatchable` — Request/transport/decode failures often escape the public error taxonomy

**CONFIRMED / high / api-design** — `CodexKit:Sources/CodexAppServerKit/JSONRPC.swift:33`

Requests rethrow package-scoped `JSONRPC.Error`, process launch can throw private `AppServerProcessTransportError`, and response decode can throw raw `DecodingError`. Several `CodexAppServerError` cases have no throw site, and overload retry exhaustion rethrows the raw JSON-RPC error. Graceful `router.stop()` also finishes event streams with `JSONRPC.Error.closed`. This does not make the entire public error type dead: turn failures, collector transport close, restart, and login validation do use `CodexAppServerError`. The actual gap is that request rejection, spawn failure, invalid response, and graceful/abnormal termination cannot be exhaustively discriminated by public type.

- 証拠: JSONRPC.swift:3,33-48 package enum; AppServerClient.swift:115-134; AppServerProcessTransport.swift:873 private error; CodexDomainTypes.swift:2839-2841; CodexAppServer.swift:1105-1133; router stop CodexAppServerNotificationRouter.swift:168-172; CRK has 37 `localizedDescription` reductions.
- 修正の方向: Split ownership by information availability: transport preserves JSON-RPC envelope/data and terminal reason; AppServerClient maps request/decode failures and attaches requestID; public start/factory maps private spawn/scaffold failures before a client exists. Delete or wire dead cases, and define graceful stream finish separately from abnormal close.

### `dx-no-timeout-story` — No handshake/request/overall-turn deadline surface or dedicated timeout error

**CONFIRMED / high / api-design** — `CodexKit:Sources/CodexAppServerKit/AppServerClient.swift:89`

CodexAppServerKit has no initialize-handshake or request-response deadline. `CodexAppServer.init` can wait indefinitely for initialize, and each request continuation is resolved only by a response, cancellation, or transport close. Aggregate turn waits also have no caller-supplied overall deadline. Existing CRK timeouts are different contracts: product terminal wait, MCP long-poll/re-await, runtime shutdown drain, and retry backoff; they are not compensators for one missing SDK timer.

- 証拠: AppServerClient.swift:89-137; AppServerProcessTransport.swift:113-131; CodexDomainTypes.swift:404-441. CRK contracts: ReviewObservationAwaiter.swift:40-56, CodexReviewStoreCancellation.swift:243-254, CodexReviewStoreReviews.swift:34-59. CodexKit README notes valid long quiet reviews and upstream exposes no heartbeat.
- 修正の方向: Configuration owns an optional handshake deadline; AppServerClient owns optional per-request response deadlines; aggregate turn APIs accept a caller-specified overall deadline. Do not add an inter-event-gap deadline without a heartbeat contract.

### `test-store-ignores-archived-and-sort` — Store-backed thread/list ignores archived, sortKey and sortDirection — parameters DataKit always sends and whose serialization is itself pinned by tests

**CONFIRMED / high / protocol-mismatch** — `CodexKit:Sources/CodexAppServerKitTesting/CodexAppServerTestRuntime.swift:706`

`filteredThreadSnapshots` filters only cwd/modelProviders/sourceKinds/searchTerm. With the store, archived:true and archived:false queries return identical membership and DataKit stamps each returned model with the query scope. Ordering is initial snapshot order with upserted items moved to the front, not the requested sortKey/sortDirection nor necessarily upstream's default created_at descending. Consumer previews hand-stub thread/archive and track archived IDs themselves.

- 証拠: CodexAppServerTestRuntime.swift:68,706-754; request serialization CodexAppServer.swift:657; DataKit stamping CodexFetchRequest.swift:1134-1139; upstream `app-server-protocol/src/protocol/v2/thread.rs:1077-1094`; consumer workaround ReviewMonitorPreviewAppServerRuntime.swift:335-341.
- 失敗トレース: 1) Test seeds store with threads T1,T2 and wires stubThreads (CodexAppServerTestRuntime.swift:569-585). 2) DataKit archive view issues thread/list with archived:true (CodexModelContext.swift:2395-2399 -> CodexAppServer.swift:657). 3) Store's listThreadResponse -> filteredThreadSnapshots ignores request.archived (CodexAppServerTestRuntime.swift:706-754) and returns T1,T2. 4) DataKit stamps both isArchived=true (CodexFetchRequest.swift:1139). 5) The archived:false query returns the identical membership stamped false — archived and non-archived views show the same threads, contradicting v2/thread.rs:1091-1094. Sort: a sortKey:created_at/desc request returns raw snapshotOrder (:68) regardless of the requested key/direction.
- 修正の方向: CodexAppServerTestThreadStore owns the full thread/list contract it advertises: honor archived scope, sort by requested key/direction with upstream defaults, and back archive/unarchive/delete mutations so consumers stop re-implementing them.

### `use-item-identity-text-dedup` — UI uses normalized text and raw payload kind to choose a presentation among distinct transcript items

**CONFIRMED / medium / workaround** — `CodexReviewKit:Sources/ReviewChatLogUI/ReviewMonitorCodexChatLogProjection.swift:624`

Upstream intentionally emits `exitedReviewMode` and then a final `agentMessage`; they are distinct semantic items even when their text matches. DataKit must preserve both. CRK chooses a less repetitive UI presentation using `ReviewOutputKey`, a `PendingReasoningMirrors` pairing state machine keyed by scopeID + trimmed text, and `RawPayloadKind` decoded from `item.rawPayload` because the typed model lacks the discriminator needed by that presentation policy. The churn is real, but the root is not “one persisted logical item lacks a stable ID.” SDK fallback-message identity is a separate compatibility subsystem for invalid/missing item IDs.

- 証拠: ReviewMonitorCodexChatLogProjection.swift:94-107,137-141,258-314 output dedup; :619-651 PendingReasoningMirrors; :316-323,653-674 RawPayloadKind rawPayload decode; SDK twin CodexModel.swift:53-58,926-945,1323-1332; git log --follow fix churn.
- 修正の方向: Preserve both semantic items in DataKit. Expose typed item kind and turn/review relation so the UI projection can choose a presentation without raw JSON or text equality; dedup remains presentation-owned.

### `use-terminal-cascade` — SDK outcome adaptation and product cancellation arbitration are conflated as one workaround cluster

**CONFIRMED / medium / workaround** — `CodexReviewKit:Sources/CodexReviewKit/Store/CodexReviewStoreReviews.swift:812`

The backend adapter reclassifies CodexKit's `interrupted/cancelled` status as CRK `.cancelled`; that part compensates for `conf-interrupted-is-failure`. Two adjacent mechanisms have different owners and must not be deleted with it: `ReviewBackendEventSession` provides exactly one terminal for the backend abstraction, and the store's `completePendingCancellationIfNeeded` enforces product policy that an accepted cancellation request wins a race with a backend terminal. The latter is called at 6 sites.

- 証拠: CodexReviewStoreReviews.swift:685,702,706,729,735,812 calls and :843 definition; ReviewBackendEventSession.swift:124-127,144-146; AppServerCodexReviewBackend.swift:627-633; SDK CodexDomainTypes.swift:1878-1882.
- 修正の方向: After CodexKit exposes a typed interrupted outcome, delete only the adapter's status repair. Keep the backend's single-terminal contract and the store's cancellation-wins arbitration unless their product requirements change.

### `arch-attempt-id-fallback` — "attempt-1" defaults create a latent second source of attempt identity

**CONFIRMED / low / api-design** — `CodexReviewKit:Sources/CodexReviewAppServer/AppServerCodexReviewBackend.swift:349`

Attempt identity gates event consumption and session lookup, yet three construction/decoding paths can default it to `"attempt-1"`. `reviewEventSession(for:)` is get-or-create and registration mutates the thread→attempt maps. Those facts create a latent collision hazard if a legacy/migrated record without identity is ever restored beside a live attempt. However, current review runs are memory-only, production Run creation supplies a UUID, and `applyBackendRun` stores threadID and attemptID together. No relaunch/persistence decode path into the store was found, so the original stale-record collision trace is not a current production bug. Get-or-create can also be intentional for runtime restoration.

- 証拠: AppServerCodexReviewBackend.swift:349-382 get-or-create/registration; CodexReviewTypes.swift:239,254 defaults; CodexReviewStoreReviews.swift:234-242 `applyBackendRun`, :906 reconstruction, :1027-1029 gate; CodexReviewStore.swift:11 memory-only state.
- 修正の方向: Remove the sentinel now. A queued Run may have no backend identity, but reconstruction of a backend Run with threadID requires a real attemptID and fails fast if it is absent. Keep get-or-create restoration semantics separate; do not turn every unknown attempt into no-op.

### `arch-closed-maps-to-failed` — Adapter contains a latent `.closed` / `.notLoaded` to failure mapping

**CONFIRMED / low / protocol-mismatch** — `CodexReviewKit:Sources/CodexReviewAppServer/AppServerCodexReviewBackend.swift:584`

`AppServerTypedReviewEventAdapter` maps `.closed` and `statusChanged(.notLoaded)` to a user-visible failure. The mapping is semantically wrong for an unload/status event, but no current user-visible failure trace was established: CodexKit does not send unsubscribe, upstream does not unload a running turn, and when unload occurs after a terminal event `BackendReviewEventMailbox.terminal` drops the later failure. This is latent cleanup, not a confirmed production failure.

- 証拠: AppServerCodexReviewBackend.swift:574-575,583-584; BackendReviewEventMailbox append guard in CodexReviewBackend.swift; ReviewBackendEventSession.swift:44,124,133-137; upstream thread_lifecycle.rs:351-354,406-436.
- 修正の方向: Remove success/failure synthesis from `.closed` / `.notLoaded`. Model unload/generation end separately; persisted resume starts a new generation, while ephemeral unload is not resumable. Do not reclassify unload as cancellation/interruption.

### `arch-host-target-test-only` — CodexReviewHost class + DirectCodexReviewStoreBackend have only test callers and duplicate Live adaptation

**CONFIRMED / medium / architecture** — `CodexReviewKit:Sources/CodexReviewHost/CodexReviewHost.swift:45`

CodexReviewHost and its private DirectCodexReviewStoreBackend have no production callers (the app composes via CodexReviewStore.makeLiveStore); only CodexReviewHostTests use them. DirectCodexReviewStoreBackend re-implements the Live backend's snapshot/auth adaptation without persistence — two maintained copies already showing copy-drift: the dead ternary `selectedAccount == nil ? .signedOut : .signedOut` appears in both.

- 証拠: grep CodexReviewHost( → only CodexReviewHostTests.swift:101,116,150; app composition CodexReviewMonitorApp.swift:288; duplicated mappings CodexReviewHost.swift:81-101,246-291 vs LiveCodexReviewStoreBackend.swift:590-613,1102-1163,1641-1651; dead ternary CodexReviewHost.swift:155,160 and LiveCodexReviewStoreBackend.swift:697,1161.
- 修正の方向: Delete the unused class and its private backend, then test the store against a CodexReviewTesting fake of `CodexReviewBackend`; alternatively promote the class to a real headless composition root. This finding does not justify deleting the `CodexReviewHost` target, which contains the production Live backend.

### `arch-testing-forwarder-chains` — 107/124 ForTesting accessors are mechanically forwarded through UI layers

**CONFIRMED / medium / test-gap** — `CodexReviewKit:Sources/ReviewChatLogUI/ReviewMonitorCodexChatLogTarget.swift:351`

ReviewMonitorCodexChatLogTarget exposes 107 testing accessors, largely forwarding probes to `logScrollView`; ReviewMonitorTransportViewController exposes 124, including its own probes plus another forwarding layer. Every new leaf capability requires mechanical wrapper edits and hides the real bind/clear/render contract.

- 証拠: ReviewMonitorCodexChatLogTarget.swift:351-861; ReviewMonitorTransportViewController.swift:205-771, including its own placeholder probes at :235-245.
- 修正の方向: Expose the leaf inspection object once (DEBUG-only Inspector at each level, or let tests reach the scroll view directly) so probes are defined in exactly one place.

### `ask-interrupt-error-string-parsing` — turn/interrupt correctness depends on parsing upstream error message strings, plus a fixed 5x50ms retry that also fires for already-finished turns

**CONFIRMED / medium / workaround** — `CodexKit:Sources/CodexAppServerKit/CodexThreadOperations.swift:513`

`interruptCodexTurn` discovers a conflicting active turn by splitting a plain server error message on `" but found "` and retries messages containing `"no active turn"` + `"interrupt"`. When turnID is nil, CodexKit sends `""`; upstream treats that as a startup interrupt which bypasses the expected-turn check, not as a mismatch probe. The string discovery path is used only for a non-empty stale turnID. Upstream returns plain `invalid_request(message)` with no structured `error.data` for stale/no-active cases, so preserving existing `CodexErrorInfo` alone cannot remove the parse. A just-finished turn also triggers the fixed 5×50ms retry and then rethrows.

- 証拠: CodexThreadOperations.swift:465-532; upstream `app-server/src/request_processors/turn_processor.rs:904,1352,1358,1364-1373,1389`.
- 失敗トレース: 1) Turn finishes; UI cancel races it: CodexResponseStream.cancel() → interruptCodexTurn (CodexThreadOperations.swift:466). 2) Server replies invalid_request 'no active turn to interrupt' (turn_processor.rs:1370-1373). 3) isExpectedTurnNotActive matches (:524-532) → sleep 50ms, retry; repeats 5 times (~250ms+ RPC latency) (:472-481,:499-500). 4) Attempt 5: retry gate fails; message has no ' but found ' so activeTurnID is nil → `throw error` (:482-485) — the untypeable package JSONRPC.Error surfaces for what is semantically an already-cancelled success. Separately, any upstream rewording of these format! strings silently breaks both the retry match and active-turn redirect.
- 修正の方向: Short-circuit locally known terminal turns as idempotent cancellation, but do not infer unknown server state from absence of history. Ask upstream for structured stale/no-active/active-turn identity data or a typed cancel-by-identity affordance; only then delete message parsing.

### `ask-thread-closed-terminal` — Router ends the current thread generation on unload without exposing a typed end reason

**CONFIRMED / low / api-design** — `CodexKit:Sources/CodexAppServerKit/CodexAppServerNotificationRouter.swift:333`

The router finishes thread subscribers on `.closed` and records it as the current generation's terminal thread event. That is compatible with upstream unload: no further events arrive for that loaded generation. The API-design gap is that review progress/event consumers get an undifferentiated end rather than a typed unload/generation-end reason; the router itself does not synthesize turn completion/failure. On the pinned CodexKit stdio baseline, no unsubscribe is sent and last connection close terminates the app-server, so an observable `.closed` is normally unreachable. `CodexResponseCollector` reads a turn stream and is not directly ended by `.closed`.

- 証拠: Router :333-335,522-527; CodexTurnSequences.swift:155-157,238-239,329-331,344-345; CodexAppServer.swift:368-382; CodexThreadOperations.swift:391-399; AppServerProcessTransport.swift:969-974; upstream README:140-162,455-477, thread_state.rs:542-564, thread_processor.rs:2607-2619, thread_lifecycle.rs:55-60,351-354,406-436, lib.rs:718-719,996-1016,1156-1166.
- 修正の方向: Keep generation completion semantics. Add a typed `unloaded/generationEnded` reason only if consumers need to distinguish it from connection termination; never turn it into turn success/failure. Persisted resume starts a fresh generation, while ephemeral unload is not resumable.

### `conf-command-delta-clobbers-item` — command output and current fileChange patch updates replace the transcript item with partial content

**CONFIRMED / medium / bug** — `CodexKit:Sources/CodexAppServerKit/CodexAppServerNotificationRouter.swift:887`

For current `item/commandExecution/outputDelta`, `itemUpdate` builds content with an empty command and only the latest delta; `CodexTranscriptAccumulator.upsert` replaces the `item/started` snapshot that carried command/cwd and prior output. Current `item/fileChange/patchUpdated` is emitted from `EventMsg::PatchApplyUpdated` only when the under-development `apply_patch_streaming_events` feature is enabled (default false); when reached, the same helper constructs a partial item and replaces existing metadata rather than applying the structured snapshot. Deprecated `item/fileChange/outputDelta` is compatibility-only. The medium severity is supported by the normally reachable command path alone.

- 証拠: CodexAppServerNotificationRouter.swift:773-780,887-905; CodexTurnSequences.swift:667-668; upstream event_mapping.rs:417-423 and README:1418 patchUpdated, apply_patch.rs:85-95 and features/src/lib.rs:949-953 feature gate/default, README:1411-1414 command delta, :1416-1419 legacy file delta; compensator CodexModel.swift:1193-1197.
- 失敗トレース: (1) Server: item/started with commandExecution item {id: "item_1", command: "cargo test", cwd: "/repo"} -> accumulator stores full item (router :753-757; CodexTurnSequences.swift:670-672); (2) server streams item/commandExecution/outputDelta {itemId: "item_1", delta: "chunk A"} -> router itemUpdate builds CodexThreadItem(id: "item_1", content: .command(command: "", output: "chunk A")) (router :887-905); (3) upsert finds index for "item_1" and executes items[index] = item (CodexTurnSequences.swift:667-668) — command text and cwd vanish from the transcript, output shows only "chunk A"; (4) next delta {delta: "chunk B"} replaces again -> output shows only "chunk B", never "chunk Achunk B"; (5) any CodexThreadTranscriptSequence / CodexReviewProgressSequence / CodexResponseStream snapshot consumer renders the corrupted item for the entire command runtime until item/completed's aggregatedOutput restores it. CodexDataKit consumers are shielded only by the per-layer compensator (CodexModel.swift:1193-1197).
- 修正の方向: Transcript accumulator owns method-specific update semantics: append command output; apply fileChange patch snapshots while preserving item identity/metadata; keep legacy text delta separate. DataKit consumes the same update operation instead of re-implementing it.

### `conf-error-payload-discarded` — Structured JSON-RPC error data is not preserved across the public request boundary

**CONFIRMED / medium / coverage-gap** — `CodexKit:Sources/CodexAppServerKit/AppServerRequests.swift:1140`

Upstream `TurnError` includes `codexErrorInfo` and `additionalDetails`, and several request failures serialize structured data that distinguishes context-window, usage-limit, steerability, and related categories. CodexKit decodes only message in its request DTO and the transport does not preserve JSON-RPC `error.data`, so those categories cannot reach a public typed error. The interrupt retry/redirect is a separate upstream gap: current stale/no-active interrupt responses are plain `invalid_request(message)` with no structured data, so preserving data alone will not remove that string parse. Error notifications remain raw-readable via `.unknown` but are not typed.

- 証拠: AppServerRequests.swift:1140-1147 message-only; AppServerProcessTransport.swift:251-258 data not preserved; upstream thread_data.rs:266-275 `TurnError`, shared.rs:92-133 `CodexErrorInfo`, `app-server/src/request_processors/turn_processor.rs:921-951` error.data serialization.
- 修正の方向: Preserve `error.data` in the transport and decode known `TurnError/CodexErrorInfo` values with an unknown/raw catch-all at the public error boundary. Separately request structured interrupt error data or a typed cancel affordance upstream.

### `conf-ratelimits-replace-not-merge` — account/rateLimits/updated is replace-applied instead of merged into the last snapshot

**CONFIRMED / medium / protocol-mismatch** — `CodexKit:Sources/CodexAppServerKit/CodexAppServer.swift:1166`

Upstream documents the notification as a sparse rolling update ('merge available values into the most recent read response... does not clear a previously observed value'). CodexAppServer.accountEvent builds a brand-new CodexRateLimits from only the notification, so an update carrying only primary clears secondary and planType for consumers treating the event as current state; no merge owner is exposed. The read response also silently drops rateLimitResetCredits, credits, limitName, individualLimit.

- 証拠: CodexAppServer.swift:1166-1182; AppServerRequests.swift:1839-1884; upstream account.rs:508-515 sparse merge, :294 `rateLimitResetCredits`, :520-529 `limitName` / `credits` / `individualLimit` / `rateLimitReachedType`.
- 失敗トレース: (1) Client reads full snapshot: primary+secondary windows and planType populated; (2) server emits a legal sparse update with only primary (account.rs:508-515; optional fields :520-529); (3) CodexAppServer constructs a brand-new CodexRateLimits from that payload; (4) consumer now observes secondary/planType nil although absence must not clear prior values.
- 修正の方向: CodexAppServer holds the last snapshot and emits merged state (or explicitly types the event as a partial delta) so 'absent field' can never read as 'cleared value'.

### `conf-server-request-resolved-ignored` — serverRequest/resolved is never handled, so aborted server requests leave client handlers hanging

**CONFIRMED / medium / coverage-gap** — `CodexKit:Sources/CodexAppServerKit/CodexAppServerNotificationRouter.swift:824`

Upstream aborts pending server→client requests on turn start/complete/interrupt and announces it via serverRequest/resolved {threadId, requestId}. CodexKit routes it to .unknown and nothing correlates it with in-flight serverRequestHandler invocations: a custom handler awaiting user input waits forever (its Task in AppServerProcessTransport.respond is never cancelled) and its late answer is silently ignored server-side. Invisible with the default auto-decline handler, inherited by any consumer implementing interactive approvals. Cross-ref cov-server-requests-untyped.

- 証拠: Router default `.unknown` at CodexAppServerNotificationRouter.swift:824-826; handler tasks AppServerProcessTransport.swift:234-245,289-313; upstream v2/notification.rs:52-57; abort sites bespoke_event_handling.rs:154,184,1047-1049.
- 修正の方向: Transport (owner of server-request lifecycle) tracks in-flight server requests by id, observes serverRequest/resolved, and cancels the corresponding handler task / exposes cancellation to the handler API.

### `cov-dead-compat-notifications` — Router keeps current-dead and historical compatibility notification routes without an explicit policy

**CONFIRMED / medium / protocol-mismatch** — `CodexKit:Sources/CodexAppServerKit/CodexAppServerNotificationRouter.swift:661`

The pinned v2 baseline emits none of `turn/failed`, `turn/cancelled`, `item/updated`, or `agent/message`; real failures arrive through `turn/completed(status=failed)`. History is nuanced: `turn/failed` and `item/updated` briefly existed in the protocol schema around upstream `a010c1b7fcce` and were removed in `ce35cb16b279`, with no implementation emission found; the other two exact methods were not found. The router nevertheless exposes `.turnFailed` branches and current tests/previews emit these methods. Fallback IDs are minted both by `.message` compatibility events and by agent-message deltas missing itemID; the former performs fallback promotion. Current valid v2 requires delta itemID, so both inputs are compatibility behavior rather than normal-wire identity.

- 証拠: Router :485,549,574-575,661-662,668,698-706,748-751,758-762,788-796; current protocol common.rs:1613-1710; historical commits `a010c1b7fcce` / `ce35cb16b279`; optional delta decode router :1084-1096; fallback append/promotion CodexTurnSequences.swift:647-693; upstream item.rs:1333-1338; fixtures CodexAppServerKitTests.swift:3541,3575,3662 and CodexDataKitTests.swift:8091.
- 失敗トレース: (1) Real failure emits `turn/completed(status=failed)` (upstream common.rs:1631; turn.rs:29-35). (2) Router decodes `.turnCompleted`, never `.turnFailed`, whose branch requires current-dead methods. (3) Consumer must derive failure from response status/error. SDK tests/previews can still pass against their compatibility dialect.
- 修正の方向: Publish a compatibility window. Default router/testing semantics follow current v2; historical methods, if retained, live in an explicit legacy namespace with removal tests. Do not synthesize a second terminal wire event. Make current-v2 delta itemID required and migrate fixtures to `turn/completed` and current item-specific deltas.

### `cov-error-warning-untyped` — error/warning/deprecationNotice/configWarning are specially routed but never typed; turn/completed decode failure degrades to synthetic success

**CONFIRMED / medium / coverage-gap** — `CodexKit:Sources/CodexAppServerKit/CodexAppServerNotificationRouter.swift:556`

The router specially routes these four methods but has no typed cases, so they surface as `.unknown(CodexRawNotification)`. They are therefore available to a raw-aware consumer, not globally invisible; typed progress and CRK's adapter drop them. The unscoped broadcast branch is unreachable for `error` because it requires threadID/turnID, but it is load-bearing for `warning` (optional threadID), `deprecationNotice` (no threadID), and config warnings. Related leniency remains: `turnResult()` uses `try?`; an undecodable `turn/completed` becomes an empty/nil-status response that the collector can treat as success.

- 証拠: Router :274-286,556-563,657-731,743-827,1011-1026; upstream notification.rs:11-16,21-26,41-48; consumer AppServerCodexReviewBackend.swift:585-586,645-650.
- 修正の方向: Add typed .errorReported(message:willRetry:) and warning-family events owned by the router (routing infra already exists), and make turn/completed decode failure loud instead of synthesizing empty success.

### `cov-server-requests-untyped` — Server-initiated requests have no typed surface and the default handler answers protocol-invalid {} for requestUserInput/permissions

**CONFIRMED / medium / protocol-mismatch** — `CodexKit:Sources/CodexAppServerKit/CodexAppServer.swift:128`

`defaultServerRequestHandler` declines commandExecution/fileChange approvals with known shapes; every other request gets `{}`. Upstream requires method-specific fields for requestUserInput and permissions, so `{}` fails serde and is logged before the server substitutes a deny/empty result. Dynamic tool calls and MCP elicitation also require method-specific lifecycle decisions. Unknown methods should receive a JSON-RPC error, not a fabricated success object. No typed params/decision enums exist for this public handler surface.

- 証拠: CodexAppServer.swift:128-138 default handler {} fallback, :98-102 doc claim; CodexAppServerRequest.swift:4-34 raw-only shape; upstream item.rs:1644-1646 (answers required), permissions.rs:769-777 (permissions required), bespoke_event_handling.rs:1618-1623,1816-1824 malformed-response handling; request list common.rs:1462-1493.
- 失敗トレース: (1) Server sends item/tool/requestUserInput (common.rs:1475-1478) to a CodexKit host using the default configuration; (2) defaultServerRequestHandler hits the default: branch and returns .emptyResult() = {} (CodexAppServer.swift:136-137); (3) transport writes {"id":n,"result":{}} (AppServerProcessTransport.swift:289-296, :315-328); (4) server deserializes ToolRequestUserInputResponse from {} -> serde error because answers is required (item.rs:1644-1646) -> error!("failed to deserialize ToolRequestUserInputResponse") and substitutes answers: {} (bespoke_event_handling.rs:1617-1623). Every such exchange is a logged contract violation degrading to an empty/deny answer; same for item/permissions/requestApproval via permissions.rs:769-777 and bespoke_event_handling.rs:1817-1824.
- 修正の方向: The default handler owns 'safe decline' for all interactive requests: enumerate known methods with valid decline-shaped responses and answer unknown methods with a JSON-RPC error; add typed request cases + decision enums, keeping raw only as escape hatch.

### `dk-closed-fabricates-completion` — DataKit can synthesize `.completed` from unload/status events in stale-state paths

**CONFIRMED / low / protocol-mismatch** — `CodexKit:Sources/CodexDataKit/CodexModel.swift:1258`

`thread/closed` and thread status do not declare a turn outcome, yet `CodexChat.apply(.closed)` and `terminalTurnStatus` for `.idle/.notLoaded` can mark locally non-terminal turns/items `.completed` with synthesized timestamps. Upstream never unloads a running thread, and `.closed` is not normally reachable in the pinned CodexKit. The branch matters only if the local model is stale/non-terminal because a terminal event was missed or reordered; it is a latent fabrication path, not a mid-turn server trace.

- 証拠: CodexModel.swift:1258-1264,1669-1701,1703-1733; upstream thread.rs:1467-1469 and thread_lifecycle.rs:351-354.
- 修正の方向: Event-application layer leaves non-terminal statuses untouched on unload (or introduces explicit .unknown/.interruptedByUnload) and lets the next authoritative snapshot decide; terminal statuses only from server-declared terminal events.

### `dk-implicit-archived-scope` — Predicates that don't mention isArchived silently get archived == false injected

**CONFIRMED / medium / api-design** — `CodexKit:Sources/CodexDataKit/CodexThreadQueryPlan.swift:308`

CodexThreadServerFilter.init injects archived=false whenever the lowered predicate's archive scope is unscoped (both derived-filter and no-filter paths), and plan.matches() applies the injected scope locally too — so a #Predicate matching archived chats silently excludes them, invisible at compile time and undocumented. SwiftData evaluates predicates literally; the convenience descriptors already spell isArchived == false explicitly, making the injection a second hidden source of the same semantics.

- 証拠: CodexThreadQueryPlan.swift:300-315 unscoped → archived=false, :293-296 fallback defaultChatFilter, :124-126 matches applies it; contrast explicit CodexFetchRequest.swift:381-385.
- 修正の方向: Evaluate predicates literally (unscoped ⇒ both scopes) keeping default-scoping only for the nil-predicate default, or make the implicit scope an explicit documented descriptor property.

### `dk-mutation-strategy-scattering` — No single owner for the local-apply vs server-refresh decision in fetched-results mutations — the recurring-fix magnet

**CONFIRMED / medium / architecture** — `CodexKit:Sources/CodexDataKit/CodexFetchRequest.swift:818`

Each registration handler re-derives “apply locally or refetch” with a different guard set: insert checks only membershipRequiresServerRefresh; archive/revalidate add usesServerOwnedOrdering; remove special-cases fetchOffset; workspace refresh filters before deciding; paged revalidation and offset/limit constraints live elsewhere. Concrete asymmetry: insert skips the server-owned-ordering check its siblings enforce. Recent commits patched the same responsibility neighborhood—predicate lowering/local semantics (`c58c47b`, `33cd29e`, `f350209`) and sort signatures (`b141853`)—rather than these exact guard lines, which still signals that mutation strategy lacks one owner.

- 証拠: CodexFetchRequest.swift:818-827,829-851,887-957,1037-1042,1066-1076,1116-1132; CodexModelContext.swift:2442-2446; commit diffs `c58c47b`, `33cd29e`, `f350209`, `b141853`.
- 修正の方向: CodexThreadQueryPlan exposes a single mutationStrategy(for:) covering membership, ordering, offset and pagination; handlers become thin executors — one place decides when local state can be trusted.

### `dk-optional-delta-id-workaround-layer` — Fallback agent-message identity machinery in DataKit compensates for AppServerKit's optional delta itemID (upstream requires item_id)

**CONFIRMED / medium / workaround** — `CodexKit:Sources/CodexDataKit/CodexModel.swift:1926`

Upstream `AgentMessageDeltaNotification.item_id` is required but `CodexMessageDelta.itemID` is optional, so DataKit maintains scoped fallback IDs, promotion maps, and text-signature matching across several merge paths. Nil-ID fallback can be driven both by compatibility `.message` events and by malformed/legacy agent-message deltas whose itemID is absent; the latter is not valid current v2 wire. Text equality can alias identical messages in one turn, and each merge path must remember the promotion rule.

- 証拠: upstream item.rs:1333-1338 item_id: String required; CodexKit:Sources/CodexAppServerKit/CodexDomainTypes.swift:2222-2231 itemID: String?; CodexModel.swift:53-59,967-1012,1427-1447,1926-2005,2280-2303 compensation sites.
- 修正の方向: AppServerKit decode boundary makes delta item IDs non-optional per the wire contract (fail fast on absent id), then delete the fallback-ID/text-signature layer from DataKit — item identity is assigned once, at the protocol boundary.

### `dk-predicate-runtime-crash-contract` — Unsupported predicate/sort shapes crash at runtime with preconditionFailure, including inside SwiftUI view update

**CONFIRMED / medium / api-design** — `CodexKit:Sources/CodexDataKit/CodexThreadQueryPlan.swift:831`

The `#Predicate` / `SortDescriptor` surface accepts any model key path at compile time, but lowering supports only 5 predicate keys and 5 sort paths; unsupported shapes hit `preconditionFailure` in descriptor construction, section descriptors, validation, or lowering. `CodexQuery.update()` computes the signature on SwiftUI update, so a dynamic unsupported descriptor can crash during render. By comparison, SwiftData's explicit `ModelContext.fetch` surface is throwing and its error model includes unsupported predicate/sort failures; this audit does not assert the exact behavior of SwiftData's `@Query.update`. CodexDataKit has no throwing validation surface and does not document its supported grammar.

- 証拠: CodexThreadQueryPlan.swift:831-838,953,973,984,995,1006,1046,1205,1220 preconditions; CodexFetchRequest.swift:43-54,111-118,193-198; CodexQuery.swift:142-152 signature per update(); DataKit README.md:74-79.
- 修正の方向: Give the contract an owner: document the supported grammar, and expose a throwing validate(descriptor:)/typed filter-sort enums so dynamic construction gets an error path instead of a render-time crash.

### `dk-query-not-live-external` — @CodexQuery/fetchedResults do not automatically ingest external server-side thread-list changes

**CONFIRMED / medium / api-design** — `CodexKit:Sources/CodexDataKit/CodexModelContext.swift:2147`

Fetched-results updates fire only from context-initiated actions; CodexModelContext subscribes to no app-server-level notifications (thread/started, thread/name/updated, thread/archived, thread/deleted exist upstream), so threads created/renamed/archived/deleted by another client, the codex CLI, or even a dropped-down AppServerKit call on the same container never appear/disappear until an explicit performFetch/refresh. The README's SwiftData framing, the 'fetched results controller' naming, and the documented appServer drop-down hatch all imply live membership that is not provided, and nothing documents the staleness contract.

- 証拠: CodexModelContext.swift:2147-2262 registration fan-out from context-initiated paths only; grep notificationStream/liveEvents over CodexDataKit = 0; upstream common.rs:1616-1624 lifecycle notifications; DataKit README.md:171-177 documents appServer hatch without staleness caveat.
- 修正の方向: Context owns a server-notification ingestion path (thread lifecycle → registry apply + fan-out) making fetched results genuinely live; short of that, README/API must state that query results only track context-local mutations.

### `dk-single-observation-slot` — One-observation-per-chat contract makes rebinding racy; slot is held by in-flight registrations with no awaitable release

**CONFIRMED / medium / usability** — `CodexKit:Sources/CodexDataKit/CodexModelContext.swift:804`

`observe()` throws `chatObservationAlreadyActive` if a registration exists, and registration is inserted before asynchronous `startObservation` completes. Cancellation of that in-flight registration is Task cancellation with no awaitable “slot released” completion, so rapid rebind can race. Once a `CodexChatObservation` handle is fully established, its `cancel()` synchronously calls `releaseChatObservation`; that path is not racy. Updates are multicast, so the in-flight single-slot lifecycle still leaks into UI code (see `use-observe-serialization`).

- 証拠: CodexModelContext.swift:804-827 registration; :972-981 established-handle release; consumer ReviewMonitorCodexChatLogTarget.swift:157-166.
- 修正の方向: CodexModelContext owns observation sharing: observe() joins (refcounts) the existing ActiveChatObservation returning a new handle, tearing the pump down when the last handle cancels — or make cancellation synchronously release the slot.

### `dk-sortdescriptor-mirror-reflection` — Sort signature depends on Mirror reflection into Foundation SortDescriptor internals with silent nil fallback

**CONFIRMED / medium / workaround** — `CodexKit:Sources/CodexDataKit/CodexFetchRequest.swift:78`

`comparisonSignature` extracts the private `comparison` child of `SortDescriptor` via `Mirror` + `String(describing:)`. Both label and description depend on undocumented layout. On CodexKit's macOS 15.4 floor, Foundation already exposes public `SortDescriptor.keyPath`, `stringComparator`, and `order`; `String.StandardComparator` is Equatable/Hashable/Codable. The current collision risk is therefore specifically standard-string-comparator distinctions that the implementation reads through reflection instead of the public property.

- 証拠: CodexFetchRequest.swift:78-84; CodexThreadQueryPlan.swift:174-184; CodexKit Package.swift macOS 15.4; Xcode 26.6 / macOS 26.5 SDK `Foundation.swiftinterface` exposes `keyPath` and `stringComparator` from macOS 14 and `String.StandardComparator` conformance; commit `b141853`.
- 修正の方向: Build the signature and validation from public `keyPath`, `stringComparator`, and `order`; delete Mirror. Reject only genuinely unsupported descriptor forms through the documented validation surface.

### `dk-unserialized-fetch-loads` — Concurrent load() calls on one CodexFetchedResults interleave; pagination window collapses on mutation-triggered reloads

**CONFIRMED / medium / bug** — `CodexKit:Sources/CodexDataKit/CodexFetchRequest.swift:683`

`performFetch` / refresh / loadNextPage / mutation refresh / backfill funnel into `load()` with suspension points and no serialization or generation token. A mutation-triggered refresh can interleave with a suspended page append, producing items and cursor from different generations. Paged revalidation also reloads page 1 non-appending and discards the currently loaded window; whether to preserve or reset that window is an undocumented query contract, not something inferred from another framework.

- 証拠: CodexFetchRequest.swift:661-681 no guards, :683-722 load() assigns cursors/items after suspension (:707), :1116-1132 refreshAfterPagedRevalidationIfNeeded non-appending reload.
- 失敗トレース: Interleave: 1) Paged results (fetchLimit=50, recencyAt reverse), page 1 loaded, nextCursor=C1 (:707). 2) User scrolls -> loadNextPage() (:671-681) -> load(cursor:C1, appending:true), phase=.loading (:689), suspends at fetchPage (:693). 3) MainActor reentrancy: user archives a chat -> CodexModelContext.archiveChatInRegisteredResults (CodexModelContext.swift:2154-2163) -> CodexFetchedResults.archive (:829-851); requiresServerRefreshAfterMutation is true for recencyAt ordering (:1066-1068; CodexThreadQueryPlan.swift:116-118) -> refreshAfterMutation (:1108-1114) -> load(appending:false) completes: items = fresh page 1, nextCursor = C1' (:707-715). 4) Step-2 load resumes with the stale-C1 response: append(page.items, to: items) (:698, :750, :761-771) welds stale page-2 rows onto the fresh page-1 list, then overwrites nextCursor with the stale response's C2 (:707). Result: items mix two membership generations and nextCursor belongs to the losing load (A->B->A-completed). Collapse: user on page 3 (nextCursor != nil) + any included-chat revalidation -> refreshAfterPagedRevalidationIfNeeded (:1116-1132) -> non-appending page-1 reload -> scrolled pages discarded.
- 修正の方向: CodexFetchedResults owns load serialization (in-flight task/generation counter; coalesce refreshes, queue-or-cancel appends) so items/cursors/phase always describe one completed load; page-window preservation belongs to the same owner.

### `dx-cancel-semantics-inconsistent` — Two different cancellation semantics on CodexResponseStream: task-cancel during collect() interrupts the server turn (unstructured, failure-swallowed), early break does not

**CONFIRMED / medium / usability** — `CodexKit:Sources/CodexAppServerKit/CodexDomainTypes.swift:2002`

Breaking out of iteration (or dropping the sequence) only unsubscribes, so server work continues. Cancelling the Task awaiting `collect()` starts an ownerless unstructured `Task { try? await turn.interrupt() }`; it is not `Task.detached`, but no lifecycle owner awaits or observes it. The interrupt failure is swallowed and the Task can race server close. Since `respond(to:)` is `streamResponse().collect()`, aggregate use inherits interrupt-on-cancel while sequence iteration does not.

- 証拠: CodexDomainTypes.swift:1994-2008 unstructured interrupt; CodexThreadOperations.swift:23-25,74; router :105-107,138-140; README.md:102-103.
- 修正の方向: Choose one documented contract: caller cancellation either stops listening only, or also requests server interrupt. The synchronous `onCancel` handler can only signal a stored cancellation authority; the operation path must await the interrupt Task/completion and arbitrate its failure before returning. Do not attempt to await or throw from `onCancel` itself.

### `test-fictional-turn-failed-pins-phase-contract` — The only test pinning chat.phase == .failed drives it via a 'turn/failed' notification that does not exist upstream; the production-reachable failure path is unpinned

**CONFIRMED / medium / test-gap** — `CodexKit:Tests/CodexDataKitTests/CodexDataKitTests.swift:8091`

The test emits method turn/failed with a top-level error object — a wire event no real server sends — exercising the production-unreachable .turnFailed branch, while the reachable path (turn/completed + status failed + turn.error.message → fail(with:)) has no direct phase assertion (the revert-policy test asserts only rollback/read counts). If the fictional routes are removed to match upstream (cross-ref cov-dead-compat-notifications), this test breaks and reveals no pin exists for the real shape.

- 証拠: CodexDataKitTests.swift:8090-8101 emits `turn/failed`; upstream server notification enum common.rs:1613-1710 and concrete `TurnCompleted` at :1631; turn.rs:30-35; reachable path CodexModel.swift:1142-1151; revert test without phase assertion CodexDataKitTests.swift:6267-6281.
- 修正の方向: Pin the failure-phase contract via the upstream-real shape (turn/completed, status failed, turn.error.message) and remove the fictional emission together with the router's dead routes.

### `test-handrolled-notification-schemas-drift` — Notification wire schemas are hand-rolled in at least three places with visible drift; package-scoped AppServerAPI blocks consumers from typed payloads

**CONFIRMED / medium / workaround** — `CodexKit:Tests/CodexDataKitTests/CodexDataKitTests.swift:10258`

Because the Testing target offers only emitServerNotification(method:params:) and raw JSON, every fixture author re-encodes the wire schema: ~15 private param structs in CodexDataKitTests, 6 more in the consumer's preview runtime, and a third private encoder in the Testing target itself; AppServerAPI/AppServerJSONValue are package-scoped so consumers can't reuse the SDK's wire types. Drift is live: the preview runtime emits turn.status "cancelled" (absent from upstream TurnStatus, round-trips only via the invented CodexTurnStatus.cancelled) and a DataKit test emits nonexistent turn/failed. Nothing validates fixtures against the protocol — fixtures define their own dialect and tests pin it.

- 証拠: CodexDataKitTests.swift:10204-10430; ReviewMonitorPreviewAppServerRuntime.swift:717-727,733-815; Testing encoder CodexAppServerTestRuntime.swift:767-842; package scope AppServerRequests.swift:3,162; upstream turn.rs:30-35.
- 修正の方向: Testing target owns method-specific builders for current wire methods (`emitTurnCompleted`, `emitCommandExecutionOutputDelta`, `emitFileChangePatchUpdated`, `emitThreadStatusChanged`, server requests) using the same package DTOs as the router. Do not institutionalize dead `emitItemUpdated` / `emitTurnFailed`; legacy file output delta belongs to explicit compatibility tests.

### `test-no-server-request-injection` — Testing target cannot inject server-initiated requests, so approval flows (public API) are untestable against the fake

**CONFIRMED / medium / coverage-gap** — `CodexKit:Sources/CodexAppServerKitTesting/CodexAppServerTestRuntime.swift:402`

`CodexAppServerRequestHandler` is public, but `JSONRPC.Transport` does not model server requests, the in-memory fake has no `CodexAppServerRequest`, and `CodexAppServer.testing(transport:)` accepts no handler. A shell-backed process test covers the real transport, so the capability is not wholly untestable; it is not deterministically testable through the in-memory fake. CRK currently has no production approval-handler consumer, making this a public-surface coverage gap rather than an observed CRK workaround.

- 証拠: CodexAppServerRequest.swift:74 public typealias; real dispatch AppServerProcessTransport.swift:234-245,289-313; JSONRPC.swift:26-31 protocol without server requests; CodexAppServer.swift:210-214 testing(); only test CodexAppServerKitTests.swift:100-161.
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

### `test-fake-cancel-in-flight-returns-success` — In-memory fake returns success when an equivalent real in-flight request throws CancellationError

**CONFIRMED / low / protocol-mismatch** — `CodexKit:Sources/CodexAppServerKitTesting/CodexAppServerTestRuntime.swift:1094`

When a Task awaiting fake `send()` is cancelled at a test gate, `cancelWaiter` resumes normally and the queued response is returned as success. The real process transport resumes the pending continuation with `CancellationError` and discards a late response. SDK-internal request sites that use cancellation shielding limit current impact, but a transport contract test written against the fake observes the opposite outcome.

- 証拠: CodexAppServerTestRuntime.swift:1080-1109 fake gate/cancel path; AppServerProcessTransport.swift:113-130,354-356 real pending-response cancellation/drop; shielded SDK request sites use `Task.detached`.
- 修正の方向: Make fake cancellation resume the waiter with `CancellationError` and discard its queued/late response. Pin the same contract against both in-memory and process transports.

### `use-dual-thread-identity` — Source-vs-review thread identity is re-mapped independently at three consumer layers

**CONFIRMED / medium / workaround** — `CodexReviewKit:Sources/CodexReviewAppServer/AppServerCodexReviewBackend.swift:22`

CodexKit already defines the canonical pair `CodexReviewIdentity.sourceThreadID` and `activeTurnThreadID`, plus associated/cleanup IDs. The gap is in CRK: its Run/event plane type-erases that identity into optional strings. The backend then keeps routing dictionaries, the store compares both raw IDs, and MCP chooses `reviewThreadID ?? threadID`. Three consumer layers reconstruct a mapping the SDK type already owns.

- 証拠: AppServerCodexReviewBackend.swift:22-28,360-410; CodexReviewStoreOrderQueries.swift:94-108; CodexReviewMCPServer.swift:174; SDK `CodexReviewIdentity` CodexDomainTypes.swift:621-676.
- 修正の方向: Define a CRK domain identity preserving the source/active-turn pair and map `CodexReviewIdentity` into it once at the adapter boundary. Carry that value through Run/event contracts without importing CodexAppServerKit into the core.

### `use-full-reprojection` — Granular CodexChatUpdate payloads are discarded; every delta triggers full chat re-projection

**CONFIRMED / medium / usability** — `CodexReviewKit:Sources/ReviewChatLogUI/ReviewMonitorCodexChatLogSourceProjection.swift:54`

Typed granular updates are used only as a boolean “allow incremental render” hint; the consumer re-renders the whole `chat.items` array through the projection pipeline on every update and re-derives diffs via UTF-16 text comparison. The per-delta O(items) work is confirmed. Current evidence does not establish whether this is forced by an SDK identity/ordering defect or is simply the consumer's conservative implementation; the related update-ID hypothesis remains unverified in Appendix B.

- 証拠: ReviewMonitorCodexChatLogSourceProjection.swift:54-101; downstream diffing ReviewMonitorLogProjection.swift:5-100.
- 修正の方向: First identify which current update cases have a sufficient typed identity/order contract, then apply those targetedly in CRK. Escalate to an SDK contract change only for cases where that proof fails.

### `use-highlevel-surface-bypass` — Consumer uses typed events but bypasses terminal aggregate convenience surfaces

**CONFIRMED / medium / api-design** — `CodexReviewKit:Sources/CodexReviewAppServer/AppServerCodexReviewBackend.swift:752`

`CodexReviewSession` offers parallel public consumption styles: typed `events`, `progress`, `collect()`, messages, and log entries. CRK uses typed `session.events` and `cancel()`, not raw JSON-RPC, while implementing its own terminal mapping and output selection instead of using the aggregate surfaces. The confirmed reason is interrupted-vs-failed classification and CRK-specific backend/product policy; `.closed` is only a latent contributor. This is evidence that terminal aggregation needs a clearer contract, not that every high-level review API is unusable.

- 証拠: AppServerCodexReviewBackend.swift:723-763 typed session events/cancel path, :590-614 terminal/output mapping; CodexDomainTypes.swift:893-900; CodexTurnSequences.swift:303-309,482-484.
- 修正の方向: Define aggregate outcome semantics and review-output contract, then reevaluate which adapter logic becomes a thin mapping. Keep CRK product cancellation arbitration at its current owner.

### `use-mcp-refresh-fallback` — MCP refresh failure and projection absence collapse to the same unavailable result

**CONFIRMED / medium / usability** — `CodexReviewKit:Sources/CodexReviewMCPServer/CodexReviewMCPServer.swift:167`

The MCP projection intentionally retains no live observation token, so architecture docs make on-demand refresh the snapshot owner. Refreshing on each read is therefore not itself a workaround or owner violation. The defect is error collapse: projection absence and refresh failure both become nil and then `.unavailable`, so a caller cannot distinguish “no log yet” from “snapshot refresh failed.”

- 証拠: CodexReviewMCPServer.swift:153,178-187; ReviewMCPLogProjection.swift:38-51; `Docs/architecture.md:177-179` on-demand snapshot contract.
- 修正の方向: Keep on-demand refresh, but return a typed refresh failure separately from the intentional `.unavailable` projection. A live observation is optional only if the architecture changes its ownership contract.

### `use-observe-serialization` — Consumer serializes chat rebinds by awaiting previous task teardown to dodge chatObservationAlreadyActive

**CONFIRMED / medium / workaround** — `CodexReviewKit:Sources/ReviewChatLogUI/ReviewMonitorCodexChatLogTarget.swift:159`

Because an in-flight `observe()` registration holds the one-per-chat slot until its Task unwinds, the consumer retains the previous Task, cancels it, and `await`s `previousTask.value` before re-observing the same chat. A fully established observation handle releases synchronously; this workaround targets only the in-flight registration window.

- 証拠: ReviewMonitorCodexChatLogTarget.swift:159-163 comment + await, :91-93 kept reference; SDK CodexModelContext.swift:804-809, CodexChatObservation.swift:22-32.
- 修正の方向: CodexDataKit owns observation lifecycle: broadcast (multi-observer) updates or an awaitable/idempotent cancel-and-reobserve, removing consumer-side task sequencing.

### `use-resume-to-cancel` — A registry-miss fallback resumes a review session solely to cancel, but production reachability is unproven

**PLAUSIBLE / low / usability** — `CodexReviewKit:Sources/CodexReviewAppServer/AppServerCodexReviewBackend.swift:466`

CodexKit exposes cancel only on live handles and package-scopes direct turn interrupt. The fallback branch in CRK calls `appServer.resumeReview(identity)` solely to obtain `.cancel()`, so the architectural pressure is visible. A production trigger was not established: active runs register a session, restart-wait cancellation can complete locally, and normal cleanup follows terminal completion. The original “post-restart/cleanup” failure story is therefore unsupported.

- 証拠: AppServerCodexReviewBackend.swift:466-470 resume-then-cancel, :349-358 manufactured session; SDK CodexThreadOperations.swift:448-466 package interrupt() only.
- 修正の方向: First add a targeted test or runtime trace that reaches the registry-miss branch. If restoration/cancellation is a real consumer story, expose cancel-by-identity and remove resume-to-cancel; otherwise delete the unreachable fallback instead of expanding SDK API.

### `use-review-output-location` — Consumer duplicates the existing `reviewOutputText` contract with fallback and failure synthesis

**CONFIRMED / medium / workaround** — `CodexReviewKit:Sources/CodexReviewAppServer/AppServerCodexReviewBackend.swift:610`

CodexKit already documents `CodexTranscript.reviewOutputText` as review output derived from `exitedReviewMode`, and `CodexResponseAccumulator.finalized` fills the terminal response accordingly. CRK nevertheless probes `reviewOutputText ?? finalAnswer ?? transcript.finalAnswer`, synthesizes an empty-output failure in backend and store, and MCP adds `finalReview ?? lastAssistantMessageText`. The churn is confirmed consumer-side redundancy, not a missing SDK field contract.

- 証拠: CodexAppServerKit README:293-299; CodexDomainTypes.swift:1364-1370; response finalization path; CRK AppServerCodexReviewBackend.swift:602-614; CodexReviewStoreReviews.swift:688,709,856-863; ReviewMCPLogProjection.swift:91-94.
- 修正の方向: At the adapter boundary, treat missing/empty `reviewOutputText` as one typed completion failure and make successful `Completion.finalReview` non-optional. Delete downstream duplicate checks/fallbacks. Keep “stream ended without terminal” as a separate transport/backend failure.

### `use-runtime-death-side-channel` — App-server death is detected via accountEvents stream error, tearing down the whole runtime from a side channel

**CONFIRMED / medium / workaround** — `CodexReviewKit:Sources/CodexReviewHost/LiveCodexReviewStoreBackend.swift:1186`

CodexAppServer has no explicit lifecycle/termination surface, so the host uses failure of a typed `accountEvents()` notification stream as the runtime-death signal and tears down from that catch. Notification streams are multicast, so another consumer does not steal the signal; graceful shutdown also cancels the auth notification Task before close. The narrow gap is semantic: an account-domain stream failure doubles as connection termination rather than exposing termination directly.

- 証拠: LiveCodexReviewStoreBackend.swift:1184-1188 catch → markRuntimeFailedAfterNotificationStreamError, teardown :1200-1229; SDK public surface (CodexAppServer.swift:220-867) has close() but no state/termination signal.
- 修正の方向: Expose one connection lifecycle/termination completion shared by all retaining handles. Keep notification streams domain-scoped and define whether graceful close finishes or throws independently.

### `use-review-marker-duplication` — Consumer duplicates the SDK-private 'review-marker:' semantic-ID constants for snapshot items — incompletely

**CONFIRMED / low / workaround** — `CodexReviewKit:Sources/ReviewChatLogUI/ReviewMonitorCodexChatLogProjection.swift:785`

CodexDataKit's private semanticID maps entered/exited review markers to `review-marker:` constants and prefixes other kinds. Snapshot items bypass the model, so CRK re-implements the marker constants without the general kind-prefix branch. No production call site feeds `CodexThreadSnapshotLogItem`; the divergence is currently limited to test/preview snapshot rendering, but two unversioned copies remain a maintenance hazard.

- 証拠: ReviewMonitorCodexChatLogProjection.swift:785-794; SDK private twin CodexModel.swift:512-526 incl. kind-prefix branch.
- 修正の方向: Delete the unused snapshot-render overload and duplicated mapping first. Expose a public normalization/mapping API only if a production snapshot consumer is introduced.


## Appendix B: 未検証 low findings(35 件)

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
- `conf-model-service-tier-order` [coverage-gap] CodexModel decode sorts service tiers lexicographically, merges the compatibility field, and drops tier metadata — `CodexKit:Sources/CodexAppServerKit/CodexDomainTypes.swift:2695`
  - `supportedServiceTiers = Array(Set(additionalSpeedTiers + serviceTiers ids)).sorted()` keeps consuming the deprecated field and does not preserve wire order. Upstream does not document that wire order as normative UI order, so ordering impact remains unverified. Dropping `ModelServiceTier` name/description is independently observable: UIs can show only raw ids.
- `conf-permissions-object-shape` [protocol-mismatch] Permissions.profileSelection encodes an object where upstream expects a plain profile-id string — `CodexKit:Sources/CodexAppServerKit/AppServerRequests.swift:387`
  - Upstream thread/start.permissions (and resume) is `Option<String>`. CodexKit can also encode `{type:"profile", id}` via package-scoped `.profileSelection`; pinned app-server maps the serde mismatch to `invalid_request` (-32600). The public `.profile(id:)` path conforms, so this is a latent package-internal wire break.
- `conf-review-steer-always-rejected` [api-design] CodexReviewSession publicly exposes steer() although upstream categorically rejects steering review turns — `CodexKit:Sources/CodexAppServerKit/CodexDomainTypes.swift:919`
  - turn/steer on a review turn always fails upstream with activeTurnNotSteerable{turnKind: review}. CodexReviewSession.steer(with:) forwards to turn/steer — an API call that can never succeed, whose doc promises 'sends additional input to the running review turn', and whose typed error info is dropped (cross-ref conf-error-payload-discarded) leaving only an opaque message string.
- `conf-service-tier-tristate-collapsed` [protocol-mismatch] Double-option serviceTier tri-state is unexpressible (nil always means omit, never clear) — `CodexKit:Sources/CodexAppServerKit/AppServerRequests.swift:1299`
  - Upstream serviceTier on turn/start, thread/start/resume/fork is Option<Option<String>> (omitted = unchanged, explicit null = clear). CodexKit models plain String? with synthesized Codable that omits nil — a consumer can set or leave unchanged but never clear. Other double-option fields upstream are not implemented by CodexKit, so the gap is confined to serviceTier.
- `cov-experimental-capability-hardcoded` [api-design] experimentalApi capability is hardcoded on with no public control, and public listTurns rides an experimental method — `CodexKit:Sources/CodexAppServerKit/AppServerRequests.swift:233`
  - Initialize.Capabilities defaults experimentalAPI=true and Params.init uses .init() unconditionally; Configuration exposes no knob. The capability gates experimental client→server methods, filters experimental notifications, and strips some experimental fields from server-request payloads; it does not generally determine which request methods the server may send. Public stable-looking `listTurns()` rides experimental `thread/turns/list`, and `optOutNotificationMethods` is unrepresentable.
- `cov-invented-turn-status` [api-design] CodexTurnStatus invents a .cancelled case and alias decodings the v2 protocol never emits — `CodexKit:Sources/CodexAppServerKit/CodexDomainTypes.swift:1836`
  - Upstream TurnStatus is exactly {completed, interrupted, failed, inProgress}; CodexTurnStatus adds .cancelled plus tolerant aliases ('started','succeeded','failure','aborted',...). `.cancelled` is unreachable from current wire, yet consumer code branches on it. A future status normally becomes `.unknown`; it could be misclassified only if its spelling collides with an alias. Smaller instance: CodexThreadItem.Kind invents .diagnostic/.error while upstream's real hookPrompt variant has no typed kind.
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
- `test-store-invented-error-code` [protocol-mismatch] Test thread store returns -32004 for missing app-server threads, unlike the real missing-thread path — `CodexKit:Sources/CodexAppServerKitTesting/CodexAppServerTestRuntime.swift:126`
  - `resumeThreadResponse` / `readThreadResponse` / `listThreadTurnsResponse` throw -32004, while the pinned app-server missing-thread path returns -32600. Other Codex components use -32004, so the mismatch is scoped to this fake versus app-server thread lookup; error-classification tests against the fake would still pin the wrong contract.
- `use-cleanup-nested-array` [api-design] cleanupReview's [[CodexThreadID]] parameter forces awkward array-wrapping at the call site — `CodexKit:Sources/CodexAppServerKit/CodexAppServer.swift:564`
  - The public signature takes additionalCleanupThreadIDs: [[CodexThreadID]] (an internal detail of orderedReviewCleanupThreadIDs leaking into the API). The consumer wraps its flat list in a single-element outer array, which reads like a bug and invites flattening mistakes.
- `use-empty-turnid-sentinel` [workaround] nilIfEmpty defenses against SDK-synthesized empty-string turn IDs — `CodexReviewKit:Sources/CodexReviewAppServer/AppServerCodexReviewBackend.swift:779`
  - CodexKit's router fabricates CodexTurnID(rawValue: "") when a notification lacks turn context, so consumers treat empty string as nil at every identity boundary: appServerReviewIdentity, reviewThreadID comparisons, MCP guards, and ReviewBackendEventSession filters. An Optional-typed SDK contract deletes all of these.
- `use-listed-chat-status-absence` [usability] Sidebar treats absent chat.status as 'finished' by documented convention, replicated at three UI sites — `CodexReviewKit:Sources/ReviewUI/Sidebar/CodexChats/ReviewMonitorCodexSidebarOutline.swift:117`
  - CodexChat.status is nil for listed-but-unloaded chats, so the filter classifies anything not actively running as finished per its own comment; the convention is copied in the row view and context menu. Exists because the SDK list surface can't distinguish 'unknown' from 'idle' — a chat whose status hasn't loaded yet presents as finished.
- `use-test-polling` [test-gap] Test suites poll with yield/sleep loops because the observation pipeline has no drain signal — `CodexReviewKit:Tests/ReviewUITests/ReviewUITests.swift:5414`
  - waitForCondition spins on Task.yield() under a 2s timeout at ~40 call sites; MCP HTTP tests use a 50ms sleep loop. There is no way to await 'all pending CodexChatUpdate/fetched-results transactions applied', so every model-driven UI assertion is time-based, importing load-proportional flakiness. Test-side face of the observation-updates gap.
