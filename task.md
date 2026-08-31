# Team-D iPhone ネイティブ版 開発タスク

## 0. この計画の前提

- 参照元は [`neko-jpg/Team-D`](https://github.com/neko-jpg/Team-D) の `44065d41e8906d34e5d8e11d7cd4cc14b25d17f2`（2026-08-31 18:38 JST時点の`main`）に固定する。参照元は読み取り専用とし、変更・commit・pushしない。
- 利用者向けの振る舞いは参照元の OpenSpec `specs/`、受け入れ条件は `requirements.md`、API・OSS境界は `architecture.md` を正とする。ただしWeb固有の実装選択は継承しない。矛盾が見つかった場合は、要件を変更せず契約差分として記録し、解消するまで実装を進めない。
- このファイルのチェックは、既存Web版の完了状態と無関係に**すべて未完了から開始**する。Web版は並行して維持する。
- 対象は平置きの半袖クルーネックTシャツ1着、必須写真は `front → back → tag → measurement` の4枚、採寸項目は着丈と身幅だけとする。
- UIはSwiftUI、カメラはAVFoundation、非同期処理はSwift Concurrency、通信はURLSession、ライブ映像はLiveKit Swift SDK、画像処理はVision/Core Image/Accelerate/ImageIO/simd、合成はCore ImageまたはCore Graphics、テストはSwift Testing/XCTest/XCUITestを第一候補とする。
- iOSクライアント開発にDockerを必須としない。fixtureモードはXcodeだけで完走でき、liveモードは共有HTTPS backendとLiveKit Cloudへ接続する。ローカルbackendは任意手順に分離する。
- ARKit、WebXR、3D AR、6DoF、自動撮影は使用しない。AVFoundationプレビュー上の固定2Dガイドだけを使用する。
- 参照元snapshotには、Python FastAPIの`/api/health`と`/api/livekit-token`、短命・最小権限token発行、LiveKit Agentのcamera track限定購読、capacity 1のlatest-frame処理、同時推論1件、`VisionGuidanceProvider`契約、`GuidanceStateMachine`、JS Room接続smoke、Python/TypeScriptのcontract testが実装済みである。これらはSwiftへ移植せず、共有backendとして再利用する。
- 同snapshotで未実装なのは、実際のvision providerをAgentへ接続してGuidance data packet/RPCをpushする配線、`POST /api/analyze-shot`、`/api/suggest-measurement-points`、`/api/generate-background`、`/api/remove-background`である。Swift側でbackendを実装せず、各live taskの外部依存として明示する。未提供中もfixture開発は止めず、liveを利用可能と偽らない。

調査根拠は、同snapshotの [`requirements.md`](https://github.com/neko-jpg/Team-D/blob/44065d41e8906d34e5d8e11d7cd4cc14b25d17f2/requirements.md)、[`architecture.md`](https://github.com/neko-jpg/Team-D/blob/44065d41e8906d34e5d8e11d7cd4cc14b25d17f2/architecture.md)、[OpenSpec design](https://github.com/neko-jpg/Team-D/blob/44065d41e8906d34e5d8e11d7cd4cc14b25d17f2/openspec/changes/build-listing-photo-assistant-mvp/design.md)、[`guided-garment-capture` spec](https://github.com/neko-jpg/Team-D/blob/44065d41e8906d34e5d8e11d7cd4cc14b25d17f2/openspec/changes/build-listing-photo-assistant-mvp/specs/guided-garment-capture/spec.md)、[`background-preserving-edit` spec](https://github.com/neko-jpg/Team-D/blob/44065d41e8906d34e5d8e11d7cd4cc14b25d17f2/openspec/changes/build-listing-photo-assistant-mvp/specs/background-preserving-edit/spec.md)、[`backend/`](https://github.com/neko-jpg/Team-D/tree/44065d41e8906d34e5d8e11d7cd4cc14b25d17f2/backend)、[`tests/`](https://github.com/neko-jpg/Team-D/tree/44065d41e8906d34e5d8e11d7cd4cc14b25d17f2/tests)とする。

### 引き継ぐ契約の要約

| 契約 | Swift版で固定する内容 |
|---|---|
| `Shot` | `front \| back \| tag \| measurement`。`ShotAssessment`の要求・応答だけは `front \| back \| tag` に限定し、`measurement`を混在させない |
| `GuidanceEvent` | `sessionId`, sessionごとに1から単調増加する正整数`sequence`, `shot`, `code`, `message`, 0...1の`confidence`, epoch millisecondsの`observedAt`/`expiresAt`。別session/shot、既読以下、期限切れは破棄 |
| `GuidanceCode` | `MOVE_CLOSER`, `MOVE_FARTHER`, `CENTER_GARMENT`, `SHOW_FULL_GARMENT`, `WRONG_SIDE`, `MOVE_TO_TAG`, `PLACE_MARKER`, `MARKER_NOT_VISIBLE`, `FLATTEN_GARMENT`, `CAMERA_OVERHEAD`, `HOLD_STEADY`, `READY`, `AGENT_UNAVAILABLE` |
| `LocalQualityHint` | `TOO_DARK`, `TOO_BRIGHT`, `TOO_BLURRY`, `HOLD_STEADY`, `READY`, `ANALYZER_UNAVAILABLE` |
| `ShotAssessment` | `shotType: front\|back\|tag\|unknown`, `quality: ok\|retry`, 有限な`issues`, `missingShots: [front\|back\|tag]`, `nextAction: RETAKE\|REQUEST_NEXT\|COMPLETE`。AIの自由文や`nextAction`だけで遷移しない |
| `ShotIssueCode` | `TOO_DARK`, `TOO_BRIGHT`, `TOO_BLURRY`, `BLURRY`, `GARMENT_CROPPED`, `TAG_UNREADABLE`, `WRONG_SHOT`。backendとの契約凍結時に追加・廃止をversion管理する |
| `ProviderError` | `provider`, `code`, `message`, `retryable`。providerは`shot-assessor`, `vision-guidance`, `measurement-line`, `background-generator`, `garment-masker`、codeは`TIMEOUT`, `UNAVAILABLE`, `INVALID_RESPONSE`, `INVALID_INPUT`, `UNKNOWN` |
| `MeasurementDraft` | `imageId`, nullableな`marker { knownSideCm=5, corners[4], pxPerCm }`, 着丈線、身幅線、`source: ai\|contour\|user`, `status: needs_review\|approved_cv\|approved_manual` |
| 測定点提案 | 補正済みmeasurement 1枚に対する`lengthStart`, `lengthEnd`, `widthStart`, `widthEnd`の0...1正規化座標。cm値、UI文言、画面遷移は返さない |
| 採寸失敗コード | `MARKER_MISSING`, `MARKER_MULTIPLE`, `MARKER_TOO_SMALL`, `MARKER_OCCLUDED`, `GARMENT_OUT_OF_FRAME`, `GARMENT_MARKER_OVERLAP`, `SEGMENTATION_FAILED`, `ENDPOINTS_INVALID` |
| LiveKit token | requestはstrictな`sessionId`だけ。responseは`token`, `participantIdentity`, `roomName`, `expiresAt`, `livekitUrl`。既定TTL 90秒、hard max 300秒、camera publish/data可・subscribe不可 |
| 外部処理 | `POST /api/livekit-token`, `/api/analyze-shot`, `/api/suggest-measurement-points`, `/api/generate-background`, `/api/remove-background`。実装開始前にversion付きJSON Schema/OpenAPIとgolden payloadで確定する |

`NormalizedPoint`はstrictな`{ "x": number, "y": number }`で各値0...1、測定点提案は4点だけとし`confidence`を含めない。なお最新TypeScript schemaは`sequence=0`を許す一方、Python backendは1以上を要求するため、Swiftは実装済みbackend wireに合わせて0を拒否し、source側のschema差分をT03-01で解消する。未実装4 endpointのresponse/content-type/error envelopeと、再接続時に新しいAgent processへ跨ぐsequence同期はT03-01/T03-02で確定するまで推測でwire実装しない。

### 絶対に維持するガード

- `READY`でなくてもカメラが利用可能なら手動撮影でき、ガイドを撮影画像へ焼き込まない。
- 受理済みの別スロットは撮り直しや外部処理失敗で失わない。
- 4枚を保持し、採寸が`approved_cv`または`approved_manual`になるまで背景編集へ進ませない。
- 採寸画像は出品画像、背景分離、背景生成へ使用しない。
- 背景生成サービスへ送るのは許可styleから作るテキストだけとし、商品画像、mask、tag、measurementを送らない。
- 商品領域のRGBは元の`front`画像だけから取得し、生成AIによる描き直し、レタッチ、色・形・傷・汚れの改変をしない。
- 画像、mask、判定、測定点、採寸値、中間生成物はセッション内だけで保持する。利用者が明示承認した最終正面画像の保存だけを例外とする。
- live失敗を黙ってfixture成功へ切り替えない。fallbackは理由とモードを画面に明示する。
- APIキー、LiveKit API secret、rembg内部URL/portをアプリ、xcconfig、ログ、fixtureへ含めない。

### 移行境界

引き継いでよいのは、確定要件、有限コードとAPIの意味、座標・幾何の定義、テスト期待値、利用許諾を確認できたfixture、プラットフォーム非依存の数式と状態ガードだけである。React/React DOM、Vite/TypeScript/Zod、`useReducer`実装、`getUserMedia`、`HTMLVideoElement`、Canvas、Blob、object URL、Webのframe callback、Web Worker、OpenCV.js/WASM、`object-fit`変換、Safari/page lifecycle対応、Node.js baseline API、Webテスト/build/CSS/Storybook、不採用OSSはコピーしない。backendをSwiftへ移植するタスクも作らない。

## 作業レーンと競合回避

| レーン | 主な所有範囲 | 原則的に変更しない範囲 |
|---|---|---|
| A 基盤・契約・状態管理 | `App/`, `Packages/DomainKit`, `Packages/ContractKit`, `Config/` | カメラ、採寸、合成の内部実装 |
| B カメラ・撮影UI | `Packages/CaptureKit`, `Features/Capture/` | API schema、採寸幾何、合成 |
| C LiveKit・backend接続 | `Packages/LiveKitBridge`, `Packages/APIClient` | 画面遷移、画像処理 |
| D 採寸・画像処理 | `Packages/MeasurementKit`, `Features/Measurement/` | LiveKit、保存UI |
| E 合成・保存 | `Packages/CompositionKit`, `Features/Editing/` | カメラsession、採寸検出 |
| F fixture・テスト・実機QA | `TestSupport/`, `Fixtures/`, UI test、`docs/runbooks/` | productionコードはテスト可能性に必要なprotocol境界だけ提案 |

`project.pbxproj`、共有scheme、package lock、契約schema、共通ナビゲーションはレーンAの単独ownerが統合する。各featureはprotocolとテストfixtureを先に合意し、別package/target内で作業する。

## 依存関係の読み方

- タスクIDは参照用であり、実行順は`依存する先行タスク`、Milestone M0、末尾のクリティカルパスで決める。依存を満たせば異なる章を並行実行できる。
- 章番号は要求された成果物構成であり、実行順そのものではない。**T11-01〜T11-03はT02/T03直後に実行する最初の技術検証Milestone M0**とし、Apple標準frameworkの採寸可否をfeature実装より先に判定する。
- `fixture / live`は、そのタスクの確認モードを表す。`両方`はfixtureとliveを別々に合格させる意味であり、自動fallbackを意味しない。
- 自動テストだけでカメラ関連を完了扱いにしない。`実機確認: 必須`のタスクは、runbookの証跡を残して初めて完了する。

## 1. 既存資産の棚卸しと移行境界

- [ ] **T01-01 参照元snapshotと要件トレーサビリティを固定する**
  - 担当する責務: レーンAが、参照元commitとSwift版へ継ぐ要件・受け入れ条件を一意に追跡できるようにする。
  - 依存する先行タスク: なし。
  - 実装対象: `docs/migration/source-manifest.md`相当のsnapshot記録、OpenSpec/requirements/architectureからSwiftタスクへの対応表、未解決差分一覧。
  - 完了条件: source repo URLとcommit SHAが固定され、全受け入れ条件が少なくとも1つの本ファイル内タスクへ紐付き、現行3slot実装を正本にしないことが明記されている。
  - 自動テスト方法: CIでmanifestのSHA形式、参照リンク、受け入れ条件IDの重複・未割当をlintする。
  - 実機確認が必要か: 不要。
  - fixture / live: 両方の設計境界を確認する。

- [ ] **T01-02 コピー可否、fixture、ライセンスを資産単位で判定する**
  - 担当する責務: レーンA/Fが、必要資産だけを安全に持ち込み、Web固有物と権利不明物を除外する。
  - 依存する先行タスク: T01-01。
  - 実装対象: allowlist/denylist、fixtureのsource path・SHA-256・寸法・期待値・生成方法・権利/ライセンスを持つmanifest。既存9画像（`front/back/tag/dark/blur/wrong-shot/known-front-mask/known-back-mask/known-tag-mask`）をすべて棚卸しし、back/tag maskやWeb UI画像は用途がなければコピー対象から除外する。
  - 完了条件: 各候補が「コピー」「再生成」「不採用」のいずれかになり、利用許諾を確認できないbinaryはコピーされず、React/TS/Web build/Node baseline/OpenCV.js/不採用OSSがallowlistにない。
  - 自動テスト方法: fixture hash検証、許可拡張子/配置lint、denylist文字列とWeb依存packageの混入検査をCIで行う。
  - 実機確認が必要か: 不要。
  - fixture / live: fixtureを主に確認し、live用第三者依存も棚卸しする。

## 2. Xcode／SwiftUIプロジェクトのscaffold

- [ ] **T02-01 Xcode workspaceと分割targetを作る**
  - 担当する責務: レーンAが、複数人で`project.pbxproj`競合を起こしにくいSwiftUIアプリ基盤を提供する。
  - 依存する先行タスク: T01-01, T01-02。
  - 実装対象: app target、`DomainKit`, `ContractKit`, `CaptureKit`, `APIClient`, `LiveKitBridge`, `MeasurementKit`, `CompositionKit`, `TestSupport`のlocal package/target、unit/UI test target、共有scheme。
  - 完了条件: clean cloneからXcodeで開き、Simulator向けDebug fixture buildが警告を放置せず成功し、各packageの依存が一方向で循環しない。最低iOS/Xcode/Swift版は選定根拠とともに固定される。
  - 自動テスト方法: `xcodebuild`でbuild-for-testingと空のtest suiteを実行し、package依存循環を検査する。
  - 実機確認が必要か: 不要。
  - fixture / live: fixture。

- [ ] **T02-02 SwiftUI app shellと依存注入点を作る**
  - 担当する責務: レーンAが、fixture/live providerを画面コードから分離し、型安全に起動できる入口を持つ。
  - 依存する先行タスク: T02-01。
  - 実装対象: `App` entry、root navigation、session composition root、clock/UUID/provider/image storeのprotocol注入、Preview用stub。
  - 完了条件: 同一UIをfixture providerとlive providerのどちらでもcompositionでき、feature側が環境変数やsingletonへ直接アクセスしない。
  - 自動テスト方法: dependency graphの生成テスト、fixture/live各compositionのsmoke test、SwiftUI Preview build。
  - 実機確認が必要か: 不要。
  - fixture / live: 両方。

- [ ] **T02-03 開発者が1時間以内にSimulator testへ到達できるbaselineを作る**
  - 担当する責務: レーンA/Fが、Xcode以外の必須ローカルserviceなしで初回実行できる環境を定義する。
  - 依存する先行タスク: T02-01, T02-02。
  - 実装対象: clone→設定→build→fixture UI testの手順、対応Xcode、任意のCLI手順、トラブルシュート、計測チェックシート。
  - 完了条件: 新規環境またはクリーンなユーザーで手順を計時し、秘密情報やDockerなしで60分以内にSimulatorのfixtureテストが1本成功する。
  - 自動テスト方法: 記載コマンドをCIで順番に実行するdocs smoke jobを用意する。
  - 実機確認が必要か: 不要。
  - fixture / live: fixture。

## 3. fixture／live設定とAPI契約

- [ ] **T03-01 Swift domain型とstrict codecを確定する**
  - 担当する責務: レーンAが、有限コード、時刻、座標、エラーをbackendと同じ意味で型安全に扱う。
  - 依存する先行タスク: T01-01, T02-01。
  - 実装対象: `Shot`, `GuidanceEvent`, `LocalQualityHint`, `ShotAssessment`, `ProviderError`, `MeasurementDraft`, `{x,y}`正規化`Point`、token request/response、各有限enum、参照元contract testから作るversion付きgolden JSON。
  - 完了条件: epoch milliseconds、confidence 0...1、point 0...1、token field、nullable markerを参照元実装と一致させ、欠落、型違い、範囲外、非有限数、未知キー、`sequence=0`を拒否する。Swift `Codable`の未知キー無視に依存せず、Pythonが1以上・TypeScriptが0以上というsequence差分を参照元で解消または互換方針として記録する。
  - 自動テスト方法: 参照元`tests/test_guidance_contract.py`、`tests/test_livekit_token.py`、TypeScript schema fixtureと同じgolden payloadをround-tripし、未知キー/欠落/unknown enum/NaN/0...1外/sequence 0/期限境界のnegative table testをSwift Testingで行う。
  - 実機確認が必要か: 不要。
  - fixture / live: 両方。

- [ ] **T03-02 version付きHTTP契約とclient境界を固定する**
  - 担当する責務: レーンA/Cが、既存Python FastAPIを共用するiOS向け契約を凍結し、backend実装の有無を可視化する。
  - 依存する先行タスク: T03-01。
  - 実装対象: 実装済みhealth/tokenと、未実装のshot判定、測定点提案、背景生成、mask取得のavailability matrix、OpenAPI/JSON Schema、multipart仕様、timeout（初期値 analyze 20秒、mask 35秒、背景60秒）、error envelope/idempotency方針。
  - 完了条件: 実装済みtokenは参照元Pydantic contractとgolden responseを正とし、残る4 endpointはrequest/response/content-type/status/error/retry可否がgolden sample付きで確定する。未実装endpointやAgent push配線を「利用可能」と偽らずblockerとして一覧化し、`/api/analyze-live`は定義しない。
  - 自動テスト方法: schema lint、golden payload validation、mock serverに対するURLSession contract testを実行する。
  - 実機確認が必要か: 不要。
  - fixture / live: 両方。

- [ ] **T03-03 fixture/live設定と秘密情報境界を実装する**
  - 担当する責務: レーンA/Cが、モードを明示し、live障害をfixture成功へ偽装できない構成にする。
  - 依存する先行タスク: T02-02, T03-02。
  - 実装対象: `Debug-Fixture`, `Debug-Live`, `Release` configuration、`.xcconfig` template、HTTPS base URL/LiveKit URLの非秘密値、ephemeral/no-cache URLSession configuration、gitignore、起動画面のモード表示。
  - 完了条件: build configurationでproviderが一意に決まり、実行中の暗黙切替がなく、live errorはlive errorとして表示される。API key/LiveKit secretがapp bundle・repository・ログに存在せず、session内API responseを通常URLCacheへ残さない。
  - 自動テスト方法: built productのsecret pattern scan、configuration別composition test、live stub failure時にfixture providerが呼ばれないspy test。
  - 実機確認が必要か: 不要。
  - fixture / live: 両方を別buildで確認する。

- [ ] **T03-04 決定的fixtureカタログを整備する**
  - 担当する責務: レーンFが、外部serviceなしで正常・失敗・遅延・逆順を再現できるテスト入力を所有する。
  - 依存する先行タスク: T01-02, T03-01, T03-02。
  - 実装対象: 許諾済み画像、期待`ShotAssessment`、`GuidanceEvent`の正常/expired/逆順/別session、provider timeout/schema error、既知mask、固定背景、manifest。
  - 完了条件: fixtureごとに期待コード・寸法・hash・由来があり、同じseed/clockで毎回同じ結果を返し、成功fixtureと失敗fixtureをUIから明示選択できる。
  - 自動テスト方法: manifest/hash/期待JSONを全件parameterized testで読み、欠落資産と未参照fixtureを失敗させる。
  - 実機確認が必要か: 不要。
  - fixture / live: fixture。

- [ ] **T03-05 参照元の実装済みPython backend／LiveKit Agentを共用し、残るbackend gapを固定する**
  - 担当する責務: レーンC/Fが、参照元のLiveKit実装をSwiftへコピーせず共有serviceとして再利用し、実装済みと未実装を混同しない。
  - 依存する先行タスク: T03-02, T03-03。
  - 実装対象: `backend/app.py`, `livekit_token.py`, `live_agent.py`, `guidance_state_machine.py`, `providers/vision_guidance.py`、対応Python test、`requirements-backend.txt`、共有HTTPS staging、backend availability matrix。browser smokeのVITE token手順はSwiftへ持ち込まない。
  - 完了条件: source SHAとruntime pin（FastAPI 0.116.1、LiveKit Python 1.1.15、Agents 1.7.1、API 1.2.1）を記録し、health/token、camera-only subscribe、capacity 1、同時推論1、Guidance contract/state machineを「実装済み」とする。既定dev serverがまだNodeで共有HTTPSへのFastAPI統合が未完了であること、実AI推論→lossy/reliable push、1〜2fps sampling、shot/measurement/background/maskの4 endpointを「未実装の参照元backend blocker」として所有者・契約・必要時期付きで記録し、Swift repoに代替backendを作らない。`requirements-livekit-smoke.txt`の別pinはsmoke限定としてproduction runtimeに使わない。
  - 自動テスト方法: 参照元lockで`tests/test_livekit_token.py`, `test_live_agent.py`, `test_guidance_contract.py`を実行し、保護されたstagingでhealth/token claim/Room join/camera subscribeをsmokeする。未実装surfaceは期待どおりavailability matrixでfalseとなり、提供後に各dependent taskのcontract smokeを追加する。
  - 実機確認が必要か: 不要（camera publishの実機確認はT08-02）。
  - fixture / live: 両方。実装済みtransportはliveで確認し、未実装surfaceの間もfixture開発は継続する。

## 4. 型安全な撮影状態遷移

- [ ] **T04-01 enum中心の状態機械と遷移表を定義する**
  - 担当する責務: レーンAが、AI自由文とUIの偶発状態から画面遷移を切り離す。
  - 依存する先行タスク: T03-01。
  - 実装対象: `capture(shot)`, `analyzingShot`, `measurementPrep`, `validatingMeasurement`, `measurementReview`, `readyToEdit`, `processingEdit`, `preview`, `approval`, `done`等のassociated-value enum、event、guard、pure transition function。LiveKitの`connecting/reconnecting`はこの撮影phaseへ含めない。
  - 完了条件: front→back→tag→measurementの順序、retake、manual input、approve、edit gateを遷移表で表現し、不正遷移をコンパイル時または明示errorで拒否する。`nextAction`単独では状態が変わらず、LiveKitがconnecting/reconnecting/disconnectedでも`capture(shot)`と手動撮影を維持できる。
  - 自動テスト方法: 全state×eventのtable test、到達可能性test、illegal transition、retake時の他slot保持、4枚未満/未承認でedit不可を検証する。
  - 実機確認が必要か: 不要。
  - fixture / live: fixture。

- [ ] **T04-02 セッション内storeと終了時破棄を定義する**
  - 担当する責務: レーンAが、画像・判定・採寸・中間生成物の所有権と寿命を一元管理する。
  - 依存する先行タスク: T04-01。
  - 実装対象: 4slot原本、assessment、measurement draft/approval、mask/background/composite候補、session/request/image ID、operation version、in-memory/保護付き一時file方針、明示的`endSession`。
  - 完了条件: cancel・撮り直し・session変更後に完了した古い非同期結果が現在stateを変更せず、session終了・新規開始・異常終了復帰時に中間物が参照不能になる。DB/UserDefaults/通常URLCacheへ保存せず、最終承認画像の利用者操作による保存だけを別扱いにする。
  - 自動テスト方法: controlled continuationとfake image storeで古い完了結果の破棄、deallocation/cleanup、session切替、URLCache不使用、state snapshotにbinaryやsecretが入らないことを検証する。
  - 実機確認が必要か: 不要。
  - fixture / live: 両方。

- [ ] **T04-03 ライブ接続状態と助言順序を撮影状態から分離する**
  - 担当する責務: レーンA/Cが、切断・再接続・古いeventで撮影進捗を巻き戻さない。
  - 依存する先行タスク: T03-01, T04-01。
  - 実装対象: `connecting/connected/reconnecting/disconnected`の直交状態、shot別last sequence、clock注入、GuidanceEvent filter/dedupe。
  - 完了条件: session/shot不一致、既読以下sequence、expired eventを捨て、接続状態が変わっても4slotと現在shotを保持する。
  - 自動テスト方法: fake clockでexpiry境界、out-of-order/duplicate/別session/再接続後sequenceをparameterized testする。
  - 実機確認が必要か: 不要。
  - fixture / live: 両方。

## 5. AVFoundationカメラ制御

- [ ] **T05-01 単一のAVCaptureSessionでpreview・解析・静止画を供給する**
  - 担当する責務: レーンBが、背面カメラを安全に所有し、高解像度原本と解析frameを分離する。
  - 依存する先行タスク: T02-02, T04-01。
  - 実装対象: camera authorization、背面device選択、session queue/actor、`AVCaptureVideoDataOutput`, `AVCapturePhotoOutput`, SwiftUI preview bridge、start/stop、エラー写像。
  - 完了条件: preview表示中に最大1本のcapture sessionだけがカメラを所有し、sample bufferと高解像度photoを取得でき、ガイドなしの撮影原本を正しい向き/色空間metadataでsession storeへ渡す。
  - 自動テスト方法: protocol化したcapture device/outputで権限・構成失敗・start/stop idempotency・photo callbackをXCTestする。
  - 実機確認が必要か: 必須。背面カメラ、ガイドなし撮影原本、session解放を確認する。
  - fixture / live: live（fixtureではfake cameraで自動確認）。

- [ ] **T05-02 回転、mirror、EXIF、座標系を一元化する**
  - 担当する責務: レーンB/Dが、preview、pixel buffer、保存原本、採寸座標の向き不整合を防ぐ。
  - 依存する先行タスク: T05-01。
  - 実装対象: device/interface orientation mapper、ImageIO metadata、previewLayer座標変換、normalized image coordinate、解析用upright copy。
  - 完了条件: portrait/landscapeの許可方針が決まり、各向きでoverlay ROIと撮影原本が一致し、原本を不要に再encodeせず解析copyだけを正規化する。
  - 自動テスト方法: 8つのEXIF orientationとaspect-fill crop/letterboxのgolden coordinate test、round-trip誤差test。
  - 実機確認が必要か: 必須。回転前後のpreview/撮影/採寸point対応を確認する。
  - fixture / live: 両方。

- [ ] **T05-03 権限拒否・中断・画像選択fallbackを扱う**
  - 担当する責務: レーンBが、カメラを使えない場合も同じ4枚フローを維持する。
  - 依存する先行タスク: T05-01, T04-02。
  - 実装対象: permission UI、Settings導線、PhotosPicker/file import adapter、AVCaptureSession interruption/runtime error、foreground復帰。
  - 完了条件: 権限拒否時に各slotへ端末画像を明示選択でき、中断時も受理済みslotを保持し、復帰/再試行/選択fallbackが表示される。選択画像も同じ判定・採寸経路を通る。
  - 自動テスト方法: permission state matrix、interruption notification、picker stub、cancel/retryのstate testとXCUITest。
  - 実機確認が必要か: 必須。拒否→Settings/画像選択、電話相当の中断、background復帰を確認する。
  - fixture / live: 両方。

## 6. 固定2Dガイドと撮影UI

- [ ] **T06-01 shot別固定ガイドとROI座標を作る**
  - 担当する責務: レーンBが、ARKitなしで現在shotの構図を一貫して案内し、解析ROIと同じ幾何を共有する。
  - 依存する先行タスク: T05-02。
  - 実装対象: front/back安全枠またはシルエット、tag矩形、measurement衣類全体枠＋右下50mmマーカー枠、safe area、preview座標→buffer座標変換。
  - 完了条件: 全shotでガイドがpreview上にだけ描画され、aspect ratio/回転/画面寸法変更時にROIを再計算して安定履歴をresetし、静止画pixelにoverlay色が含まれない。
  - 自動テスト方法: 複数画面寸法のsnapshot/golden座標testと、既知raw fixtureにoverlay pixelが混入しないcapture test。
  - 実機確認が必要か: 必須。各shot、回転、Dynamic Typeで確認する。
  - fixture / live: 両方。

- [ ] **T06-02 進捗・主助言・手動シャッターUIを作る**
  - 担当する責務: レーンBが、現在shot、`1/4...4/4`、完了/残数、ローカル/Agent助言、接続状態を誤解なく表示する。
  - 依存する先行タスク: T04-01, T04-03, T06-01。
  - 実装対象: capture screen、progress、有限コード→固定localized文言、主助言selector、shutter、busy/retake、VoiceOver/Dynamic Type/haptic方針。
  - 完了条件: 主助言は常に1件とし、優先順位を「工程不成立（表裏/tag/marker）→衣類欠け→距離/中央→真上/しわ→明るさ/ブレ→安定性→READY」に固定する。同一codeをdedupeし、enter/clear hysteresisを設定値として固定し、600ms安定前に`READY`へしない。`READY`以外でもshutterが有効で、AI messageは補助表示に留まり遷移を駆動せず、Agent切断表示中も固定ガイド・ローカル助言・shutterが残る。
  - 自動テスト方法: 全Guidance/LocalQuality code、競合するAgent/local入力、閾値前後の揺れ、expiry/dedupeをfake clockで検証し、view-state snapshot、`READY`外tap、接続状態matrixをSwiftUI/XCUITestする。
  - 実機確認が必要か: 必須。屋内で可読性、操作領域、VoiceOver、手動撮影を確認する。
  - fixture / live: 両方。

## 7. 明るさ・ブレ・安定性の端末内判定

- [ ] **T07-01 Apple標準frameworkでローカル品質primitiveを作る**
  - 担当する責務: レーンB/Dが、AIに依存せず明るさ・ブレ・動きを数値化する。
  - 依存する先行タスク: T05-01, T06-01。
  - 実装対象: Core Image/AccelerateによるROI縮小・grayscale、平均輝度、Laplacian分散、正規化frame差分、閾値設定。
  - 完了条件: ROI最大辺320px以下、初期閾値（輝度45...215、Laplacian分散24以上、frame delta 0.020未満が600ms）を設定注入でき、6種の`LocalQualityHint`だけを返す。
  - 自動テスト方法: dark/bright/blur/detail/motion/stableの数値fixtureと境界値をSwift Testingで判定し、同一入力が決定的な結果になることを検証する。
  - 実機確認が必要か: 必須。照明変更、手ブレ、静止で助言が期待方向へ変化することを確認する。
  - fixture / live: 両方。

- [ ] **T07-02 4Hz scheduler、backpressure、性能計測を作る**
  - 担当する責務: レーンBが、frameを溜めず最新状態を優先しUIを阻害しない実行制御を持つ。
  - 依存する先行タスク: T07-01。
  - 実装対象: actor/AsyncStreamのcapacity 1、最大同時解析1、4Hz sampling、cancellation、signpost/metric収集、過負荷時`ANALYZER_UNAVAILABLE`。
  - 完了条件: 処理中の中間frameを破棄し、完了後は最新frameから再開する。基準実機で4Hz以上、状態変化→UI p95 500ms以内を満たし、queueが無制限に増えない。
  - 自動テスト方法: test clockと遅いanalyzerでcoalescing、同時数、cancel、p95集計を検証し、memory growth testを行う。
  - 実機確認が必要か: 必須。基準実機のsignpost結果を保存する。
  - fixture / live: 両方。

## 8. LiveKit Swift SDKとリアルタイムAgent接続

- [ ] **T08-01 AVFoundationとLiveKitのカメラ所有方式を技術検証する**
  - 担当する責務: レーンB/Cが、静止画・端末解析・WebRTC publishのためにカメラを二重起動しない方式を選ぶ。
  - 依存する先行タスク: T05-01, T03-02。
  - 実装対象: LiveKit Swift SDKの固定version、そのversionで正式提供される`BufferCapturer`相当のapp-produced-frame APIまたはcustom video sourceによる共有capture pipelineのspike、photo output併用、向き/解像度/熱の計測。
  - 完了条件: 単一AVCaptureSessionからpreview・local analysis・高解像度photo・LiveKit trackを供給できる方式をADRに記録し、二重camera sessionや撮影中断がない。失敗時はSDK issueと代案を明示する。
  - 自動テスト方法: fake frame sourceでpublish adapterの順序・cancel・frame dropをtestし、spike buildをCIに含める。
  - 実機確認が必要か: 必須。5分間publishしながら複数回撮影し、停止/再開とthermal/memoryを記録する。
  - fixture / live: live。

- [ ] **T08-02 token取得、Room接続、camera publish、助言購読を接続する**
  - 担当する責務: レーンCが、秘密を持たずにstateful Agentとの持続接続を成立させる。
  - 依存する先行タスク: T03-02, T03-03, T03-05, T04-03, T08-01。
  - 実装対象: 実装済み`/api/livekit-token`へのsession ID request、Room join/leave、local video publish、lossy/reliable data受信、GuidanceEvent strict decode、接続status adapter。Agent側の実AI→packet配線は参照元backendの外部依存としSwiftへ実装しない。
  - 完了条件: 実装済みtoken issuerとcamera-only subscriberを再利用して実機camera trackをAgentがsubscribeし、参照元backend側のpush配線提供後に、定期HTTP/静止画pollingなしで有限助言がpushされる。token/API secretを保存・logせず、観測→表示p95 2秒の計測値を取得できる。
  - 自動テスト方法: mock token endpoint、fake Room delegate、invalid packet、publish/leave idempotency、HTTP request recorderでanalyze-live pollingがないことを検証する。
  - 実機確認が必要か: 必須。共有LiveKit Cloud＋Agentでpublish/subscription/pushを確認する。
  - fixture / live: live（packet処理はfixtureでも自動確認）。

- [ ] **T08-03 再接続、reliable同期、Agent不在fallbackを作る**
  - 担当する責務: レーンC/Aが、ネットワーク断で進捗を失わず、古い助言で巻き戻らないようにする。
  - 依存する先行タスク: T04-03, T08-02。
  - 実装対象: reconnect policy/status、現在shot＋last sequenceのRPC同期、step/受理用reliable message、Agent不在表示、manual retry。
  - 完了条件: 接続断中もガイド・ローカル品質・shutter・受理slotを維持し、復旧後は同期した新sequenceから再開する。live断をfixture結果へ置換しない。
  - 自動テスト方法: fake Roomでdisconnect→逆順packet→reconnect→rehydrateを再現し、state不変とdedupeを検証する。
  - 実機確認が必要か: 必須。機内モード/回線切替/Agent停止・復旧をrunbookで確認する。
  - fixture / live: 両方。

## 9. 撮影後AI判定

- [ ] **T09-01 front/back/tagの高解像度判定clientを作る**
  - 担当する責務: レーンCが、撮影前助言と最終受理を分離し、strictな`ShotAssessment`だけを返す。
  - 依存する先行タスク: T03-01, T03-02, T03-05, T05-01。
  - 実装対象: Swift側の`/api/analyze-shot` multipart client、`requestedShot`、画像normalization policy、timeout/cancel、response validation、provider protocol。endpoint本体は参照元で未実装の外部依存であり、このrepoでは作らない。
  - 完了条件: requestedShotをfront/back/tagに限定し、measurementを送らない。未知field/enum、欠落、requested shotと矛盾する`ok`を受理せず、高解像度結果だけをslot受理判定へ渡す。
  - 自動テスト方法: URLProtocol mockでmultipart field/bytes/content-type、全valid/invalid response、20秒timeout/cancel、measurement送信拒否を検証する。
  - 実機確認が必要か: 必須。3種の正常・誤種別・品質不良を共有backendで確認する。
  - fixture / live: 両方。

- [ ] **T09-02 retry/error UXと進捗不変性を接続する**
  - 担当する責務: レーンA/B/Cが、暗い・ぼけ・欠け・tag読取不能・誤種別・service errorを有限理由で回復させる。
  - 依存する先行タスク: T04-01, T06-02, T09-01。
  - 実装対象: issue code→固定文言、same-image retry、retake、cancel、loading/error state、重複送信防止。
  - 完了条件: `quality=retry`またはerrorで現在stepに留まり、対象slotを受理せず、他slotを保持する。ライブ`READY`と矛盾しても撮影後判定を優先する。
  - 自動テスト方法: issue/error全ケースのstate/view test、double tap、cancel、retry成功、別slot保持を検証する。
  - 実機確認が必要か: 必須。少なくともdark/blur/wrong-shot/tag unreadableを再現する。
  - fixture / live: 両方。

## 10. 4枚固定フローとfallback

- [ ] **T10-01 4slotの固定順・撮り直し・採寸準備を統合する**
  - 担当する責務: レーンA/Bが、常に同じ順序と完了条件で撮影を進める。
  - 依存する先行タスク: T04-01, T04-02, T06-02, T09-02。
  - 実装対象: slot repository、progress UI、front/back/tag受理、measurement preparation checklist（背面を上、襟/袖/裾を広げてしわ/折れを伸ばす、無地で高contrastの床、markerを100%印刷して定規確認、同一平面の右下へ衣類から30mm以上離す、真上から両方の全体を写す）、`4/4`開始guard。
  - 完了条件: front→back→tagの各受理後だけ次へ進み、tag後は編集でなく採寸準備を表示する。半袖クルーネックTシャツだけを対象とし、フード/襟付き/長袖/パンツ/スカート/ワンピースを対応対象と表示しない。4枚と採寸承認が揃うまでedit actionが存在しないかdisabledで理由を示す。
  - 自動テスト方法: happy path、各step retake、途中再試行、他slot保持、3枚だけでedit不可のstate/XCUITest。
  - 実機確認が必要か: 必須。カメラと画像選択の両経路で順序を確認する。
  - fixture / live: 両方。

- [ ] **T10-02 共通fallbackを状態機械へ統合する**
  - 担当する責務: レーンA/Fが、権限、Agent、AI、採寸、mask、背景生成の失敗を成功扱いせず回復可能にする。
  - 依存する先行タスク: T03-03, T05-03, T08-03, T09-02, T10-01。
  - 実装対象: retry/retake/photo import/manual measurement/fixed background/original-front採用の有限eventと表示、進捗保持規則。
  - 完了条件: 各障害に少なくとも1つの明示的回復操作があり、モードと失敗理由を表示し、成功fixtureへの暗黙遷移と自動scale推定がない。
  - 自動テスト方法: failure injection matrixでstate/slot不変、表示される回復操作、fixture provider非呼出を検証する。
  - 実機確認が必要か: 必須。ネットワーク断、権限拒否、backend停止を確認する。
  - fixture / live: 両方。

## 11. 50mmマーカー検出の技術検証（最初に実行するMilestone M0）

- [ ] **T11-01 採寸fixtureと物理撮影corpusを先に作る**
  - 担当する責務: レーンD/Fが、Apple標準frameworkと必要時のOpenCV iOSを同じ入力で公平に評価できるようにする。
  - 依存する先行タスク: T01-02, T02-01。物理corpusはiPhone標準カメラ等で先行撮影し、API/backend契約やアプリのカメラ完成を待たない。
  - 実装対象: 50.0mm外形/5mm黒枠/40mm白地の100%印刷marker、valid、遠近歪み、missing、multiple、too-small、edge 16px、ratio 0.65境界、occluded、overlap 24px境界、garment out-of-frame、segmentation failure、dark/blur、期待corner/scale/mask/実測値manifest。
  - 完了条件: すべての有限失敗コードに正例・負例があり、markerの実寸を定規で確認した基準実機の物理撮影を少なくとも30枚（距離・軽い傾き・照明を分散）収録し、個人情報と権利情報を確認する。
  - 自動テスト方法: asset hash、annotation範囲、expected code、corner order、実測値のschemaをlintする。
  - 実機確認が必要か: 必須。印刷倍率と30枚の撮影条件を記録する。
  - fixture / live: fixtureを主に、実機corpusも使用する。

- [ ] **T11-02 Vision/Core Image/Accelerate/simdでmarker・輪郭・射影補正PoCを行う**
  - 担当する責務: レーンDが、OpenCVなしで二重正方形検出と安全なscale取得が可能か最初に検証する。
  - 依存する先行タスク: T11-01。
  - 実装対象: `VNDetectRectanglesRequest`/`VNDetectContoursRequest`候補、二重輪郭検証、corner順序、Core Image perspective correction、simd座標変換、foreground/contrast segmentation候補、失敗理由分類。
  - 完了条件: 決定的fixtureを全件正しく分類し、有効な物理corpusのmarker検出率95%以上、無効条件を誤ってscale採用する件数0、px/cm相対誤差1%以下、基準実機p95 1秒以内を満たす。結果とraw計測をADRへ残す。
  - 自動テスト方法: annotationとのcorner/scale比較、境界値、失敗code、再現性、性能measure testを同一corpusで実行する。
  - 実機確認が必要か: 必須。基準実機でaccuracy/latency/memoryを測る。
  - fixture / live: fixture＋実機offline解析。

- [ ] **T11-03 OpenCV iOS採用判断ゲートを通す**
  - 担当する責務: レーンD/Aが、精度未達の場合だけ追加依存を採用し、理由とコストを可視化する。
  - 依存する先行タスク: T11-02。
  - 実装対象: Apple標準案のtuning結果、同一corpus比較、OpenCV iOS wrapper protocol、binary size/build時間/license/NOTICE/privacy評価、ADR。
  - 完了条件: T11-02の全基準をApple標準案が満たせばOpenCVを追加しない。Apple標準案が基準未達の場合だけ同一corpusでOpenCV iOSを比較し、T11-02の全基準を満たし、かつApple案の失敗指標を解消した場合にだけ採用する。両方が未達なら基準を緩めずOpenCVも採用せず、理由付きretake／4点配置／manual inputを製品fallbackとする。採用してもOpenCV.js/WASM/Web Worker/ArUcoは持ち込まない。
  - 自動テスト方法: どちらのengineも同じcontract test suiteを通し、選択engine以外がproduction dependency graphへ混入しないことをCIで検査する。
  - 実機確認が必要か: 必須。選択engineでT11-02の基準を再測定する。
  - fixture / live: fixture＋実機offline解析。

## 12. 射影補正、px/cm換算、着丈・身幅計算

- [ ] **T12-01 選択engineで採寸geometry pipelineを製品化する**
  - 担当する責務: レーンDが、検証済みmarkerだけから補正面と物理scaleを得る。
  - 依存する先行タスク: T11-03。
  - 実装対象: upright image→marker検証→homography/perspective correction→px/cm→garment mask、Double精度の点変換、cancellation、result/error型。
  - 完了条件: 最短辺80px以上、全cornerが端から16px超、短辺/長辺0.65以上、衣類間隔24px以上、全体in-frame、明るさ/ブレ条件を満たす場合だけscaleを返し、それ以外は対応有限codeで停止する。
  - 自動テスト方法: thresholdの直前/一致/直後、corner順序、homography round-trip、既知5.0cmのscale、invalid時に値を返さないことを全fixtureで検証する。
  - 実機確認が必要か: 必須。異なる距離/傾きでscale再現性を確認する。
  - fixture / live: 両方。

- [ ] **T12-02 測定点提案APIを1回だけ呼びstrictに検証する**
  - 担当する責務: レーンC/Dが、補正済み画像から意味的4端点だけを取得し、cm決定を端末幾何に残す。
  - 依存する先行タスク: T03-02, T03-05, T12-01。
  - 実装対象: Swift側の`/api/suggest-measurement-points` client、`{x,y}`形式のlengthStart/End・widthStart/End、0...1検査、single-flight/call count、timeout/schema fallback。responseに`confidence`を含めず、endpoint本体は参照元で未実装の外部依存とする。
  - 完了条件: 1枚のmeasurementにつき撮影後1回だけ補正済みcopyを送り、cm/UI文言/遷移をresponseから受けない。timeout/schema不正/画像外座標時も写真とscaleを保持し、contour/user placementへ明示移行する。
  - 自動テスト方法: URLProtocol spyで送信回数1、payload image、strict key/range、timeout/cancel、fallback stateを検証する。
  - 実機確認が必要か: 必須。共有backendの正常/timeoutを確認する。
  - fixture / live: 両方。

- [ ] **T12-03 4端点から着丈・身幅を0.1cm単位で計算する**
  - 担当する責務: レーンDが、AIの提案を補正面へ写像し、物理量を決定的に算出する。
  - 依存する先行タスク: T12-01, T12-02。
  - 実装対象: normalized point mapping、着丈=背面襟中央付け根→裾中央、身幅=左右脇下間、Euclidean distance/pxPerCm、丸め規則。
  - 完了条件: 身幅を2倍せず、同じ4点とscaleから常に同じ0.1cm値を返し、画像外/非有限/scaleなしでは結果を返さない。
  - 自動テスト方法: 既知geometry、向き/解像度違い、rounding境界、NaN/Infinity/zero scaleのtable test。
  - 実機確認が必要か: 不要（最終精度はT18-03で必須）。
  - fixture / live: fixture。

## 13. 測定端点の編集・承認・手入力

- [ ] **T13-01 4端点drag editorと再計算UIを作る**
  - 担当する責務: レーンDが、利用者に測定線の意味と修正結果を直接確認させる。
  - 依存する先行タスク: T12-03。
  - 実装対象: 補正画像overlay、4つのdrag handle、zoom時の座標変換、着丈/身幅label、VoiceOver調整操作、未承認状態。
  - 完了条件: 各handleを独立に動かすたび0.1cm値が更新され、初期draftは必ず`needs_review`で、誤tapやscrollで自動承認されない。
  - 自動テスト方法: drag座標→model座標→再描画のround-trip、snapshot、accessibility action、初期未承認をXCTest/XCUITestする。
  - 実機確認が必要か: 必須。片手操作、zoom、細かな端点補正を確認する。
  - fixture / live: 両方。

- [ ] **T13-02 endpoint検証、範囲警告、明示承認を作る**
  - 担当する責務: レーンD/Aが、不正な線を確定させず、警告値は再確認後にのみ許可する。
  - 依存する先行タスク: T13-01。
  - 実装対象: image/garment領域検査、`ENDPOINTS_INVALID`、着丈20...100cm/身幅20...80cm warning、confirm dialog、`approved_cv` event。
  - 完了条件: 画像外または衣類領域から大きく外れた点では承認不能。「大きく外れた」の数値toleranceを実装前に契約へ固定し、範囲外値は警告するが二段階の再確認後は承認でき、線と数値の明示操作だけが`approved_cv`を作る。
  - 自動テスト方法: valid/invalid endpoint、固定したtoleranceの直前/一致/直後、範囲境界、warning confirm/cancel、承認eventのstate test。
  - 実機確認が必要か: 必須。invalid handleと範囲外再確認を確認する。
  - fixture / live: 両方。

- [ ] **T13-03 撮り直し・4点手配置・数値手入力fallbackを作る**
  - 担当する責務: レーンDが、marker/segmentation/AI提案失敗をfixture成功に置換せず完走可能にする。
  - 依存する先行タスク: T10-02, T12-02, T13-02。
  - 実装対象: failure code別案内、retake、contour draft、user 4-point placement、着丈/身幅numeric input、`approved_manual`。
  - 完了条件: 衣類全体が写るmeasurement原本なしではmanual approvalできず、manual値をCV値と区別し、明示承認後だけ`approved_manual`になる。
  - 自動テスト方法: 各failure code→操作、measurement欠落、入力validation、manual/CV status混同防止をstate/XCUITestする。
  - 実機確認が必要か: 必須。markerなしからretakeまたはmanual完了を確認する。
  - fixture / live: 両方。

## 14. 背景分離・背景生成APIとの接続

- [ ] **T14-01 編集gate後にfrontだけをmask APIへ送る**
  - 担当する責務: レーンC/Eが、正面原本以外を変更・送信せず、mask-only結果を検証する。
  - 依存する先行タスク: T03-02, T03-05, T04-02, T10-01, T13-02またはT13-03。
  - 実装対象: Swift側の`/api/remove-background` multipart client、front original ID、PNG decode、寸法/空/全面mask検証、35秒timeout/retry、original fallback。endpoint本体は参照元で未実装の外部依存とする。
  - 完了条件: 4枚＋採寸承認gate通過後にだけ呼ばれ、front以外のbytesを送らない。有効maskだけをsessionへ保持し、invalid/timeout時は合成承認を禁止してretryまたは元画像採用を提示する。
  - 自動テスト方法: request recorderでgate/front-only/model非露出、空/全面/寸法不一致/非PNG、timeout、retryを検証する。
  - 実機確認が必要か: 必須。共有FastAPI→rembg/BiRefNetの正常/停止を確認する。
  - fixture / live: 両方。

- [ ] **T14-02 許可styleから背景だけを生成する**
  - 担当する責務: レーンC/Eが、商品情報を生成APIへ渡さず空の撮影背景候補を取得する。
  - 依存する先行タスク: T03-02, T03-05, T10-01, T13-02またはT13-03。
  - 実装対象: style allowlist、人物/衣類/ハンガー/文字/ロゴを除外するbackend固定prompt契約、Swift側の`/api/generate-background` request、image validation、60秒timeout/retry、ライセンス確認済み固定背景fallback。endpoint本体は参照元で未実装の外部依存とする。
  - 完了条件: request bodyがstyle ID等のテキスト情報だけで、商品原本/mask/tag/measurementを含まず、backendが空の撮影背景用固定promptへ写像する。利用不能な生成結果や失敗時も4枚を保持し、固定背景またはretryを明示選択できる。
  - 自動テスト方法: request bodyのbinary/image field不在、未知style拒否、timeout/invalid image/fixed background fallbackを検証する。
  - 実機確認が必要か: 必須。共有backendの生成とnetwork failureを確認する。
  - fixture / live: 両方。

## 15. 元商品画素を保持する画像合成

- [ ] **T15-01 Core Image/Core Graphics compositorを作る**
  - 担当する責務: レーンEが、生成背景と元front RGBをmaskだけで合成する。
  - 依存する先行タスク: T14-01, T14-02。
  - 実装対象: color space/orientation統一、背景のcrop/resize、元frontをforegroundにしたmask blend、preview/output render、cancellation。
  - 完了条件: product領域のsourceは常に元frontで、商品を生成/補完/retouchせず、元画像のaspect ratioを維持する。同じ入力で決定的な合成を返す。
  - 自動テスト方法: 小さな既知RGBA fixtureでalpha blend式、orientation/color space、determinism、snapshotをpixel testする。
  - 実機確認が必要か: 必須。高解像度frontで表示品質、memory、時間を確認する。
  - fixture / live: 両方。

- [ ] **T15-02 商品画素provenanceとmask不正を自動検証する**
  - 担当する責務: レーンE/Fが、「商品RGBは元frontのみ」を回帰不能なテスト契約にする。
  - 依存する先行タスク: T15-01。
  - 実装対象: opaque product pixelの比較、alpha edgeの期待blend、mask外背景比較、empty/full/size mismatch guard、back/tag/measurement不変hash。
  - 完了条件: mask=1の内部pixelがlossless renderで元frontと一致し、edgeは元frontと背景のalpha合成式だけで説明でき、mask外だけが背景になる。不正maskではcompositeを返さない。
  - 自動テスト方法: per-pixel provenance、source hash、negative mask suiteをCIで全件実行する。
  - 実機確認が必要か: 不要（見た目確認はT15-01）。
  - fixture / live: fixture。

## 16. 比較・明示承認・画像保存

- [ ] **T16-01 元画像/合成画像の同一領域比較と選択を作る**
  - 担当する責務: レーンEが、利用者が差を確認して原本または合成を明示選択できるようにする。
  - 依存する先行タスク: T15-01, T15-02。
  - 実装対象: side-by-side/slider等の比較、同一viewport/zoom、original/composite selection、未選択初期値、再生成/元採用。
  - 完了条件: 初期状態は未承認で、同じcrop/scaleで比較でき、利用者の明示選択だけがapproved output IDを設定する。不完全compositeは選択肢に出ない。
  - 自動テスト方法: initial unapproved、viewport同期、original/composite選択、invalid compositeのview/state testとXCUITest。
  - 実機確認が必要か: 必須。画面サイズ、zoom、VoiceOverで比較と選択を確認する。
  - fixture / live: 両方。

- [ ] **T16-02 承認済み正面画像だけを保存しsessionを終了する**
  - 担当する責務: レーンE/Aが、利用者が選んだ最終画像だけをPNG/JPEGで端末へ出力する。
  - 依存する先行タスク: T04-02, T16-01。
  - 実装対象: Photos add-onlyまたはshare/export、PNG/JPEGのformat/metadata方針、permission/error UI、approved output guard、保存後/終了時cleanup。
  - 完了条件: 未承認previewや中間画像は保存できず、選択した正面画像だけを出力する。cancel/error時は再試行でき、session終了時にback/tag/measurement/mask/draft/cacheを破棄する。
  - 自動テスト方法: fake photo libraryでapproval guard、format、cancel/error/retry、cleanup、出力hashを検証する。
  - 実機確認が必要か: 必須。写真ライブラリまたはFilesへ保存し、選択画像と一致することを確認する。
  - fixture / live: 両方。

## 17. fixtureテスト、統合テスト、XCUITest

- [ ] **T17-01 pure domain/image test suiteを完成させる**
  - 担当する責務: レーンFと各ownerが、状態・契約・画像処理の境界値をSimulator/CIで高速に検証する。
  - 依存する先行タスク: T04-03, T07-02, T12-03, T15-02。
  - 実装対象: transition/codec/Guidance filter/local quality/geometry/compositor/session cleanupのSwift Testing/XCTest suite、coverage設定。
  - 完了条件: 全有限code、全state guard、全marker threshold、全mask invalid case、live→fixture非fallbackを網羅し、flaky testなしで繰り返し成功する。
  - 自動テスト方法: Simulatorでseed固定の全unit/image testを複数回実行し、主要pure moduleの未試験branch一覧を0にする。
  - 実機確認が必要か: 不要。
  - fixture / live: fixture。

- [ ] **T17-02 client↔backend/LiveKit契約統合テストを作る**
  - 担当する責務: レーンC/Fが、schema drift、timeout、packet順序、privacy違反をrelease前に検出する。
  - 依存する先行タスク: T03-05, T08-03, T09-02, T12-02, T14-01, T14-02。
  - 実装対象: mock FastAPI/recorded response、optional shared staging smoke、fake LiveKit packet stream、request privacy assertions、contract version check。
  - 完了条件: 全endpointの正常/invalid/timeout、push順序、reconnectを自動化し、背景生成requestに画像がないこと、front以外がmask APIへ行かないこと、token secretが返らないことを検証する。
  - 自動テスト方法: PRではmock contract suite、secretを使える保護branchでは明示live smokeを実行し、失敗をfixtureで上書きしない。
  - 実機確認が必要か: 不要（live実機はT18）。
  - fixture / live: 両方を別jobで確認する。

- [ ] **T17-03 fixtureの開始→保存と主要失敗をXCUITest化する**
  - 担当する責務: レーンFが、外部serviceなしで中心体験を決定的に完走させる。
  - 依存する先行タスク: T10-02, T13-03, T16-02, T17-01。
  - 実装対象: 4枚happy path、各retake、expired guidance、Agent disconnect、AI error、marker failure→manual、mask invalid、background failure→fixed、original/composite approval、save spy。
  - 完了条件: `1/4`開始から4枚、採寸明示承認、edit gate、比較、明示選択、保存まで自動完走し、3枚/未承認ではeditへ進めない。失敗scenarioは進捗保持をassertする。
  - 自動テスト方法: clean Simulatorで全scenarioをseed/clock固定実行し、screenshotとstate accessibility IDをartifact化する。
  - 実機確認が必要か: 不要。
  - fixture / live: fixture。

## 18. 実機カメラ・回転・中断・復帰・性能確認

- [ ] **T18-01 実機compatibility matrixを完走する**
  - 担当する責務: レーンB/Fが、Simulatorで確認できないcamera lifecycleを基準端末で検証する。
  - 依存する先行タスク: T05-03, T06-02, T08-03, T10-02。
  - 実装対象: 初回/拒否済み権限、portrait/許可landscape、background/foreground、lock、電話/Control Center相当中断、camera runtime error、回線切替、長時間session。
  - 完了条件: 各ケースでcrash/黒画面/二重sessionがなく、復帰または明示fallbackができ、受理済みslotと現在stepを保持する。runbookに端末/OS/build/結果/証跡を残す。
  - 自動テスト方法: lifecycleの注入可能部分はXCTestし、実機項目は署名付きmanual checklistをCI artifactまたはrelease evidenceへ添付する。
  - 実機確認が必要か: 必須。
  - fixture / live: 両方。

- [ ] **T18-02 性能・memory・thermal・privacyを実機計測する**
  - 担当する責務: レーンB/C/D/E/Fが、継続撮影と高解像度処理が端末を不安定にしないことを確認する。
  - 依存する先行タスク: T07-02, T08-02, T12-01, T15-01, T16-02。
  - 実装対象: Instruments/signpost、4Hz/p95、Agent p95、frame queue、memory peak/leak、thermal state、network request/log/cache、session cleanup。
  - 完了条件: ローカルUI p95 500ms、Agent観測→表示p95 2秒の目標を計測し、queue capacity 1、同時解析1、30分session後の継続的memory増加なし、画像/token/secretのlog/cache残存なしを証跡化する。
  - 自動テスト方法: XCTMetricで再現可能なoffline部分を計測し、閾値超過をreportする。network/privacy scanを自動化する。
  - 実機確認が必要か: 必須。
  - fixture / live: 両方。

- [ ] **T18-03 代表Tシャツの採寸精度とlive縦スライスを確認する**
  - 担当する責務: レーンD/Fが、利用者補正後の物理精度と全外部service経路を最終確認する。
  - 依存する先行タスク: T08-03, T09-02, T13-03, T14-02, T16-02, T18-01。
  - 実装対象: 50mm marker実寸確認、メジャーground truth、複数回撮影、端点補正/承認、LiveKit/AI/rembg/BiRefNet/背景生成/保存の共有環境run。
  - 完了条件: 代表Tシャツの着丈・身幅が補正・承認後にそれぞれ実測±1.0cm以内で、liveモードを最初から保存まで完走する。自動draft精度だけを合否条件にしない。
  - 自動テスト方法: 計算と差分report生成は自動化し、測定値/ground truth/build IDをmachine-readable artifactにする。
  - 実機確認が必要か: 必須。
  - fixture / live: live。

## 19. CI、runbook、ライセンス、最終受け入れ確認

- [ ] **T19-01 iOS CIとmerge gateを固定する**
  - 担当する責務: レーンA/Fが、再現可能なbuild/test/contract/license検査をPR必須条件にする。
  - 依存する先行タスク: T02-03, T17-01, T17-02, T17-03。
  - 実装対象: pinned Xcode runner、resolve/build/test、Simulator XCUITest、fixture hash、schema drift、secret scan、license inventory、artifact保存、cache方針。
  - 完了条件: clean CIでfixtureの全testが成功し、失敗時にmerge不能となる。live secretは保護環境だけに置き、PR/fork/build log/app artifactへ露出しない。
  - 自動テスト方法: CI自身のrequired checksをbranch protectionで強制し、意図的なschema/hash/secret違反fixtureでjobが失敗することを確認する。
  - 実機確認が必要か: 不要。
  - fixture / live: fixture必須、live smokeは保護環境で明示実行。

- [ ] **T19-02 開発・任意local backend・実機・障害対応runbookを完成させる**
  - 担当する責務: レーンF/Cが、新規開発者とデモ担当者が迷わず同じ経路を再現できるようにする。
  - 依存する先行タスク: T03-03, T18-01, T18-03。
  - 実装対象: Xcode-only fixture、共有HTTPS/LiveKit Cloud live、自動署名の実機手順、任意local FastAPI/rembg手順、preflight/health、timeout/retry、データ消去、障害切り分け。
  - 完了条件: fixture手順が1時間以内、live手順が秘密をappへ入れず完走し、local backendが明確に任意である。デモ前にmarker 50mm、backend/Agent/rembg prewarm、接続、保存を確認できる。
  - 自動テスト方法: docs command smoke、リンクlint、設定templateと実際のkey一覧差分testを行う。
  - 実機確認が必要か: 必須。別開発者がrunbookだけでfixtureとliveを再現する。
  - fixture / live: 両方。

- [ ] **T19-03 第三者依存・fixture・modelのライセンス表記を確定する**
  - 担当する責務: レーンA/Fが、配布物に必要なnoticeと出典を漏れなく、不要なWeb資産を持ち込まず管理する。
  - 依存する先行タスク: T01-02, T08-01, T11-03, T14-01。
  - 実装対象: LiveKit Swift SDK、必要時のみOpenCV iOS、共有backendのrembg/BiRefNet、コピー/再生成fixture、固定背景、参考コードのSBOM/NOTICE/source/version/checksum/確認日。
  - 完了条件: lockfileの全直接依存とbundled assetがinventoryに一致し、license/NOTICE義務を満たす。document-autocaptureのWebコードをコピーしない場合はnoticeを機械的に継承せず、コードを翻案した場合だけ出典commentとMIT noticeを付ける。不採用modelをdownload/bundleしない。
  - 自動テスト方法: dependency/asset inventory差分、NOTICE存在、version/checksum、禁止asset scanをCIで行う。
  - 実機確認が必要か: 不要。
  - fixture / live: 両方。

- [ ] **T19-04 最終受け入れchecklistを証跡付きで承認する**
  - 担当する責務: 全レーンが、確定要件をfixtureと実機liveの両方で一項目ずつ閉じる。
  - 依存する先行タスク: T19-01, T19-02, T19-03, T18-02, T18-03。
  - 実装対象: 要件trace matrix、build/commit/device/backend version、test result、screenshots/video、性能/採寸report、既知制約、sign-off。
  - 完了条件: 実機固定ガイドとpush助言、pollingなしpublish、古いevent破棄、READY外撮影、ガイド非焼込、理由付きretake、4枚固定順、採寸補正/明示承認、edit gate、front-only mask、text-only背景生成、元RGB合成、比較/明示承認/保存、fixture決定的完走、live完走、±1.0cm目標をすべて証跡で確認する。Simulatorだけの項目を残さない。
  - 自動テスト方法: trace matrixからCI artifact/test ID/実機evidenceへのリンク切れと未合格項目をlintし、未完了が1つでもあればrelease jobを失敗させる。
  - 実機確認が必要か: 必須。
  - fixture / live: 両方を独立に合格させる。

## クリティカルパス

```text
T01 棚卸し
→ T02 scaffold
→ T11 Apple標準framework PoCと判断gate（最初の技術検証）
→ T03-01〜T03-04 契約・mode・fixtureとの合流
→ T04 状態機械
→ T05/T06 カメラと撮影UI
→ T08/T09 LiveKitと撮影後判定
→ T10 4枚統合
→ T12/T13 採寸計算・補正・承認
→ T14/T15 背景API・元画素合成
→ T16 比較・承認・保存
→ T17/T18 自動/実機検証
→ T19 release gate
```

最大の不確実性は、(1) 単一AVCaptureSessionからLiveKit publishと高解像度撮影を両立する方式、(2) Apple標準frameworkだけで50mm二重正方形・衣類輪郭・射影補正が精度条件を満たすか、(3) 参照元の実装済みLiveKit transport coreへ実AI→data packet/RPCを配線し、残る4つのFastAPI endpointを共有環境で提供できるか、の3点である。T11-02/T11-03を最初に実施し、T08-01とT03-02/T03-05も後続のUI量産前に閉じる。T03-05はM0をblockせず、各live taskの完了前に必要なbackend surfaceだけを合流させる。

## 並行実行可能なまとまり

- T02完了後、T11の採寸PoCを最初に開始する。同時にレーンA/CのT03契約、レーンFのfixture provenance作業を並行できる。T03-01完了後はT04、T04開始後はT05基盤も並行する。
- T05-01後、T06のガイド/UI、T07のローカル品質、T08-01のLiveKit camera spikeを別packageで並行できる。
- T03-02後、T09撮影後判定client、T12-02測定点client、T14 mask/background clientをレーンC内で担当分割できる。ただし実際の呼出gateはT10/T13完了まで開けない。
- T11の採寸PoC中に、レーンEは既知mask/固定背景でT15/T16のfixture実装を進められる。
- T17のunit/contract/UI testは各feature ownerがproduction taskと同時に追加し、レーンFが共通fixtureと最終suiteを統合する。

## 最初の実機縦スライスの完了条件

最初の縦スライスは、採寸や背景編集を仮実装で先送りして完走扱いにせず、まず`front` 1slotの本物の経路を端から端まで確認する。以下をすべて満たした時点を完了とする。

1. 自動署名した基準iPhoneで背面カメラを起動し、front固定2Dガイド、`1/4 正面`、接続状態、端末内品質助言を表示する。
2. 単一AVCaptureSessionの映像をLiveKit Swift SDK経由で共有Roomへpublishし、Agentがsubscribeする。
3. Agentの有限`GuidanceEvent`がHTTP pollingなしでpushされ、別session/shot、逆順、期限切れeventはUIへ反映されない。
4. `READY`以外でも手動撮影でき、高解像度原本にガイドが焼き込まれていない。
5. 原本を共有FastAPIの`/api/analyze-shot`へ送り、validな`ShotAssessment`だけをstrict decodeする。
6. `ok`ならfront slotを保持して`2/4 背面`へ進み、`retry`/timeout/schema errorならfront stepに留まって理由と再試行/撮り直しを表示する。
7. 撮影中にAgentまたは回線を切断してもガイド、端末内品質、shutter、保持済みslotを失わず、再接続後に古いeventで巻き戻らない。
8. 同じ画面・状態経路をfixture buildでも決定的に再現し、live障害時にfixtureへ自動切替しない。
9. セッション終了時にcamera、published track、Room、解析Task、保持中pixel bufferを解放し、直後に新規セッションを開始できる。

実装済みのtoken／camera subscriberだけで縦スライス完了とはしない。参照元backendのGuidance push配線または`analyze-shot`が未提供・契約不一致なら、この実機live縦スライスは未完了のままとする。fixtureで同じ画面を通せても、live完了の代用にはしない。
