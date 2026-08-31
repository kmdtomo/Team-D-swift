# Team-D iPhone ネイティブ版 要件定義

最終更新: 2026-08-31

参照元snapshot: [`neko-jpg/Team-D@44065d41e8906d34e5d8e11d7cd4cc14b25d17f2`](https://github.com/neko-jpg/Team-D/tree/44065d41e8906d34e5d8e11d7cd4cc14b25d17f2)

## 0. 文書の位置づけ

- 本文書はSwift/iPhone版の機能要件、非機能要件、受け入れ条件の正本である。
- [`task.md`](./task.md)は作業レーン、着手に必要な成果物、統合・最終受け入れの依存を定義する。チェックボックスは最終受け入れ状態だけを表し、後続タスクの一律な着手許可には使わない。本文書の要件を上書きしない。
- 参照元の`requirements.md`、`architecture.md`、OpenSpecは調査根拠であり、SwiftリポジトリにコピーしたりOpenSpec運用を導入したりしない。
- 参照元の`main`が更新されても自動同期しない。要件、API契約、fixture、backend availabilityの差分を確認し、利用者の明示的な承認後にsnapshotと本文書を更新する。
- 矛盾がある場合は、利用者の最新の明示指示、本文書、version固定済みwire contract、`task.md`の順に優先し、独断で機能要件を変えない。

## 1. プロダクトの目的

撮影に不慣れな利用者に、iPhoneのカメラ上で次の行動を1つずつ示し、正面・背面・タグ・採寸用の4枚、着丈・身幅、元商品画素を保持した出品用画像を、利用者自身の確認と明示承認によって完成させる。

インターフェースは「採点者」ではなく「静かな撮影コーチ」として振る舞い、現在の工程、次の行動、保持された進捗、復帰方法を明確にする。

## 2. MVP範囲

| 項目 | 確定範囲 |
|---|---|
| 対応端末 | iPhoneネイティブアプリ |
| UIの起点 | 起動後は`front`のカメラ画面から開始する単一撮影セッション |
| 対象 | 平置きの半袖クルーネックTシャツ1着 |
| 必須写真 | `front → back → tag → measurement`の4枚 |
| ガイド | AVFoundationプレビュー上の固定2Dガイド |
| 撮影中判定 | 端末内数値判定＋LiveKit Agentの意味判定 |
| 受理判定 | `front/back/tag`は撮影後AI、`measurement`はマーカー・全体写り・品質検証 |
| 採寸 | 50mmマーカーを使う着丈・身幅、4端点の利用者補正と明示承認 |
| 背景編集 | `front`だけを背景分離し、商品を含まない背景を生成して合成 |
| 保存 | 元画像または合成画像を利用者が明示選択・承認した後だけ |
| モード | Xcodeだけで完走できる`fixture`と、共有HTTPS backend＋LiveKit Cloudの`live` |

## 3. 確定ユーザーフロー

アプリ起動後の初期ルートは`front`のカメラ画面とする。ホーム、一覧、ダッシュボード、タブバー、ログイン、独立したチュートリアルを前置しない。カメラ権限が未確定の場合だけ、同じ撮影フロー内で利用理由とsystem permissionを示す。採寸準備、採寸確認、背景編集、比較・承認は別機能の入口ではなく、この単一セッションから状態に応じて順に進む。

1. 正面用の固定ガイドとリアルタイム助言を表示し、利用者が手動撮影する。
2. 撮影後AIが撮影種別、品質、欠けを確認し、受理または理由付き撮り直しを示す。
3. 背面、タグで同じループを実行する。
4. 採寸準備で衣類、50mmマーカー、撮影面、真上撮影を案内する。
5. 専用の`measurement`写真を1枚撮影する。
6. 射影補正後の画像上で着丈・身幅の4端点と数値を利用者が補正し、明示承認する。
7. 4枚と採寸承認が揃った場合だけ背景編集を解放する。
8. `front`のmaskと商品を含まない背景を用意し、元の`front`商品RGBだけをforegroundとして合成する。
9. 元画像と合成画像を同条件で比較し、利用者がどちらかを選択する。
10. 利用者が独立した確定操作を行った後だけ、選択された正面画像を保存する。

## 4. 機能要件

### R1. カメラと固定2Dガイド

- アプリはカメラ撮影フローをrootとし、起動後は権限前提を満たして直ちに`front 1/4`を表示する。
- 背面カメラをAVFoundationで起動し、現在の撮影種別、`1/4`から`4/4`の進捗、工程別固定ガイド、主助言、手動シャッターを表示する。
- `front/back`は衣類安全枠またはシルエット、`tag`は矩形、`measurement`は衣類全体枠と右下の50mmマーカー配置枠を使う。
- ガイドはプレビューにだけ重ね、撮影画像の画素へ焼き込まない。
- ARKit、平面検出、ワールドアンカー、3D AR、6DoF、自動撮影を使用しない。

### R2. 撮影中のリアルタイム助言

- 撮影セッション開始時に短命tokenを取得し、LiveKit Roomへ接続してカメラtrackをpublishする。
- 意味判定はstateful Agentが最新frameを選択し、同時推論を1件に限る。定期HTTP upload/polling、全frame保存、30fps全件推論を行わない。
- Agentは有限な`GuidanceEvent`をLiveKit data packetまたはRPCでpushする。別session、別shot、既読以下sequence、期限切れのeventは破棄する。
- 明るさ、ブレ、安定性はApple標準frameworkで端末内判定し、衣類の収まり、距離、中央寄せ、表裏、タグへの移動はAgent画像AIの助言とする。
- 主助言は同時に1件だけ表示し、AI自由文、model名、confidence値をUIに表示しない。
- `READY`は助言であり撮影許可ではない。カメラが撮影可能で多重capture処理中でない限り、`READY`でなくても手動撮影できる。

### R3. 撮影後AI判定

- `front/back/tag`の高解像度写真と現在要求中のshotを共有backendへ送信する。`measurement`はこの受理契約に含めない。
- strictな`ShotAssessment`をdecodeし、schema違反、timeout、provider errorを明示的な再試行可能状態にする。
- 写真の受理と次工程はアプリ所有の受理済みslot状態から決定する。AIの自由文や`nextAction`単独で画面遷移しない。

### R4. 4枚固定フロー

- 必須順序は`front → back → tag → measurement`とし、現在位置と受理済み状態を常に表示する。
- 品質不良、誤撮影種別、衣類の欠け、読めないタグは同じ工程で理由付き撮り直しにする。
- 撮り直し、再接続、provider失敗で他の受理済みslotを失わない。
- `measurement`写真は採寸専用とし、出品画像、背景分離、背景生成へ使用しない。
- カメラ権限がない場合は、Settings導線と写真選択による同一フローへの継続を用意する。

### R5. 50mmマーカーと採寸承認

- 衣類を背面が上になるよう平置きし、襟・袖・裾・しわ・折れを整え、無地で衣類とコントラストのある撮影面を使う。
- 専用マーカーは外形50.0mm角、5mm幅の黒い外枠、内側40.0mm角の白地とし、100%倍率で印刷し、撮影前に定規で外形1辺50mmを確認する。ArUcoを使用しない。
- マーカーは衣類と同一平面の右下へ、衣類から30mm以上離して置く。衣類全体とマーカー全体を真上から1枚に収める。
- 撮影後検証で、最短辺80px未満、四隅が画像端16px以内、最短辺/最長辺0.65未満、衣類との画像上間隔24px未満を不合格とする。
- Apple標準frameworkでマーカー検出、衣類輪郭、射影補正を最初に技術検証する。同じcorpusと精度基準を満たせない場合だけOpenCV iOS版を検討する。
- 補正済み画像へ対するAI提案は`lengthStart`, `lengthEnd`, `widthStart`, `widthEnd`の4点だけとし、cm値や画面遷移を返さない。
- 着丈は背面の襟中央付け根から裾中央、身幅は左右の脇下間の平置き直線距離とし、胸囲へ2倍しない。
- 4端点は補正・微調整可能とし、移動ごとに0.1cm単位で再計算し、既存の承認を解除する。
- 端点が画像外または衣類領域から大きく外れる場合は`ENDPOINTS_INVALID`とし承認を無効にする。着丈20〜100cm、身幅20〜80cmの範囲外は警告後の再確認を要求する。
- 初期状態は必ず未承認とし、利用者が2本の測定線と数値を明示承認した場合だけ`approved_cv`にする。
- CV採寸が完了できない場合は、撮り直しまたは着丈・身幅の手入力を提示する。手入力でも衣類全体が写った4枚目は必須であり、明示承認後に`approved_manual`とする。
- デモ対象Tシャツでは、利用者補正・承認後の着丈・身幅をメジャー実測値に対して各±1.0cm以内とする。自動ドラフト自体の誤差は製品受け入れ条件にしない。

### R6. 背景生成

- 4枚のslotと`approved_cv|approved_manual`が揃った後だけ背景編集へ進める。
- アプリから背景生成APIへ送信できるのは許可されたstyle IDまたはそれから作るテキストだけとする。商品画像、mask、tag、measurementを送信しない。
- 生成背景は商品、人物、文字、ロゴを含まない。失敗時は撮影進捗を保持し、明示的に再試行またはローカル固定背景を選択できる。

### R7. 背景分離と商品画素保持合成

- 背景分離に使うのは元の`front`1枚だけとし、共有backend経由でrembg/BiRefNetからmask-only PNGを取得する。
- 合成画像の商品領域RGBは元の`front`画像だけから取得する。生成AIによる商品の再描画、レタッチ、色・形・傷・汚れの改変を行わない。
- Core ImageまたはCore Graphicsで色空間、orientation、寸法を正規化し、maskにより元`front`をforegroundとして合成する。
- maskが空、全面、寸法不一致、非決定的な場合は合成画像を承認候補にしない。

### R8. 比較・明示承認・保存

- 元の`front`と合成画像を同じcrop/zoom/表示領域で比較できる。
- 初期状態ではどちらも承認済みにしない。画像選択と「この画像を使う」の明示確定を独立した操作とする。
- 明示承認された最終正面画像だけをPNGまたはJPEGとして写真ライブラリまたはシェア先へ出力できる。

### R9. セッション、障害復帰、モード分離

- 画像、mask、判定結果、測定点、採寸値、中間生成物はメモリ中心のセッション内だけで保持し、DB、永続cache、通常のURLCacheへ保存しない。例外は利用者が明示承認した最終画像の出力だけとする。
- LiveKit/Agent切断中も、固定ガイド、端末内品質判定、手動撮影、受理済みslotを保持する。
- AI、mask、背景生成の失敗で進捗を変更せず、保持したものと次にできる操作を明示する。
- `fixture`と`live`はbuild configurationまたは明示設定で一意に決定し、実行中に黙って切り替えない。`live`失敗を`fixture`成功として表示しない。
- API key、LiveKit API secret、rembgの内部URL/portをapp bundle、xcconfig、fixture、log、repositoryへ含めない。

## 5. API・ドメイン契約

### 5.1 有限型

| 契約 | Swift版の固定内容 |
|---|---|
| `Shot` | `front \| back \| tag \| measurement` |
| `GuidanceEvent` | `sessionId`, 1から単調増加する正数`sequence`, `shot`, `code`, `message`, 0...1の`confidence`, epoch millisecondsの`observedAt`/`expiresAt` |
| `GuidanceCode` | `MOVE_CLOSER`, `MOVE_FARTHER`, `CENTER_GARMENT`, `SHOW_FULL_GARMENT`, `WRONG_SIDE`, `MOVE_TO_TAG`, `PLACE_MARKER`, `MARKER_NOT_VISIBLE`, `FLATTEN_GARMENT`, `CAMERA_OVERHEAD`, `HOLD_STEADY`, `READY`, `AGENT_UNAVAILABLE` |
| `LocalQualityHint` | `TOO_DARK`, `TOO_BRIGHT`, `TOO_BLURRY`, `HOLD_STEADY`, `READY`, `ANALYZER_UNAVAILABLE` |
| `ShotAssessment` | `shotType: front\|back\|tag\|unknown`, `quality: ok\|retry`, 有限な`issues`, `missingShots: [front\|back\|tag]`, `nextAction: RETAKE\|REQUEST_NEXT\|COMPLETE` |
| `ProviderError` | `provider`, `code`, `message`, `retryable`。providerは`shot-assessor`, `vision-guidance`, `measurement-line`, `background-generator`, `garment-masker` |
| `NormalizedPoint` | strictな`{x, y}`、各値0...1、unknown keyなし |
| `MeasurementDraft` | `imageId`, nullableな`marker {knownSideCm=5, corners[4], pxPerCm}`, 着丈線、身幅線、`source: ai\|contour\|user`, `status: needs_review\|approved_cv\|approved_manual` |
| `MeasurementFailure` | `MARKER_MISSING`, `MARKER_MULTIPLE`, `MARKER_TOO_SMALL`, `MARKER_OCCLUDED`, `GARMENT_OUT_OF_FRAME`, `GARMENT_MARKER_OVERLAP`, `SEGMENTATION_FAILED`, `ENDPOINTS_INVALID` |

- `ShotAssessment`の要求・応答は`front/back/tag`に限り、`measurement`を混在させない。
- 測定点提案responseは4点だけとし、`confidence`、cm値、UI文言、画面遷移を含めない。
- 参照元TypeScript schemaは`sequence=0`を許容する一方、実装済みPython backendは1以上を要求する。Swiftは現行backend wireに合わせて0を拒否し、参照元の差分は別途解消する。

### 5.2 HTTP/LiveKit surface

| surface | 必須入出力 | snapshot時点の参照元実装 |
|---|---|---|
| `GET /api/health` | backend稼働状態。secretを含めない | 実装済み |
| `POST /api/livekit-token` | requestはstrictな`{sessionId}`。responseは`token`, `participantIdentity`, `roomName`, `expiresAt`, `livekitUrl` | 実装済み |
| LiveKit Agent | camera track限定購読、capacity 1の最新frame、同時推論1件、Guidance push | transport coreは実装済み。実vision providerとpush配線は未実装 |
| `POST /api/analyze-shot` | 高解像度写真＋要求shot → `ShotAssessment` | 未実装 |
| `POST /api/suggest-measurement-points` | 補正済みmeasurement → 4つの`NormalizedPoint` | 未実装 |
| `POST /api/generate-background` | 許可style ID/テキスト → 商品なし背景 | 未実装 |
| `POST /api/remove-background` | 元`front` → 同寸法mask-only PNG | 未実装 |

- tokenの既定TTLは90秒、hard maxは300秒。camera publish/data publishを許可し、subscribeは許可しない。
- 未実装backend surfaceはSwift repo内に代替実装しない。fixtureでclient開発を進めてもlive完了としない。
- 実装開始前にversion付きJSON Schema/OpenAPI、content type、error envelope、timeout、golden payloadを固定する。

## 6. fixture要件

- fixtureモードはXcodeとSimulatorだけで、開始から4枚撮影、採寸、背景、合成、比較、承認、保存spyまで決定的に完走できる。
- 参照元の既存9画像`front/back/tag/dark/blur/wrong-shot/known-front-mask/known-back-mask/known-tag-mask`は、出典、利用許諾、hash、寸法、用途を確認したものだけコピーできる。
- 採寸・50mmマーカーcorpus、既知四隅、ground truth、射影異常、マーカー失敗、既知背景、Guidanceの逆順/期限切れ/別session、API golden JSONはSwift側で新規整備する。
- 正常系だけでなく、各有限failure code、timeout、schema不正、切断、無効mask、保存拒否をfixture化する。
- fixtureは由来、生成方法、SHA-256、期待値、許諾をmanifestで追跡し、利用許諾不明のbinaryをcommitしない。

## 7. iPhone UI・アクセシビリティ要件

- UIはカメラ画面をrootとする単一の直線フローにする。ホーム、タブ、サイドバー、別の機能一覧を作らず、各確認画面は現在の撮影セッションの次状態として表示する。
- SwiftUIのシステムコンポーネント、semantic text style、semantic color、safe areaを優先し、Webのpx/CSS/object-fit前提を持ち込まない。
- カメラ映像を主役にし、進捗、主助言、シャッター、復帰操作の位置を一時的な助言で動かさない。
- タップ可能領域はプロジェクト基準と44×44pt以上とし、操作をdrag、色、動き、hapticだけに依存させない。
- Dynamic Typeの最大accessibility size、VoiceOver、Voice Control/Switch Control相当のラベル、Reduce Motion、Increase Contrast、Differentiate Without Colorを考慮する。
- VoiceOverはframeごとに助言を読み上げず、安定した主状態の変化だけを通知する。シャッターは`READY`外でも操作可能にする。
- 採寸端点は44pt以上のhit areaとVoiceOver調整操作を持ち、元/合成の選択状態は名前と値で読み上げる。
- カメラ権限は機能を使う文脈で許可を求め、拒否・制限・中断・復帰を別の状態として設計する。
- カメラ関連UIはPreview/Simulatorだけで完了とせず、対応iPhone実機でnotch/Dynamic Island、home indicator、回転、中断、カメラ実映像上の可読性を確認する。

## 8. 非機能要件

### NFR-1. パフォーマンス

- 端末内品質判定は解析用ROIを最大辺320px以下とし、4Hz以上、状態変化からUI表示までp95 500ms以内を目標とする。
- Agent観測からUI表示までp95 2秒以内を目標とする。
- frame queueをcapacity 1とし、処理中の中間frameを溜めず、メモリが継続増加しない。

### NFR-2. 開発環境

- iOS client開発にDockerを必須としない。fixtureはXcodeだけでbuild/testできる。
- 新しい開発者がcloneからSimulatorのfixture test実行まで1時間以内に到達できる。
- liveは共有HTTPS backendとLiveKit Cloudへ接続し、ローカルbackendは任意手順として分離する。
- 環境値はxcconfig等で管理するが、secretはcommitしない。実機はXcode自動署名を基本とする。

### NFR-3. テストと証跡

- domain/geometry/codecはSwift TestingまたはXCTest、統合はXCTest、主要ユーザーフローはXCUITestで検証する。
- 各production変更では、対象targetのbuildと、その変更を直接検証する最小のunit/contract/snapshot testを同じ変更内で実行する。影響packageの全testは統合waveごと、全XCUITestはユーザーフローの縦スライスまたはT17/T19の節目、clean clone・長時間性能・実機matrix・live end-to-endは該当Milestoneと最終受け入れで実行する。
- 同じ未変更範囲の全suite、全XCUITest、clean clone、長時間実機試験を各小タスクや各commitで重複実行しない。契約、共有project設定、依存version、状態遷移、画像処理式などの変更で影響範囲が広がった場合だけ、必要な層まで前倒しして再実行する。
- `fixture/live: 両方`は独立した2つの合格を意味し、fixture成功をlive成功の代用にしない。
- カラー、レイアウト、撮影、回転、LiveKit publish、熱、採寸精度、保存は`task.md`で指定した実機gateを満たす。

### NFR-4. 開発進行と並行性

- `task.md`の`[x]`は、列挙された完了条件、自動テスト、fixture/live、実機確認をすべて満たした**最終受け入れ済み**だけを表す。`[ ]`は未着手、進行中、実装準備済み、統合待ち、外部block中を含み、`[ ]`であること自体を後続タスクの着手禁止理由にしない。
- 後続タスクは、必要なversion付き契約、有限型、protocol、fixture、golden payload、mock/fake、画像期待値、または技術判断が利用可能で安定していれば、先行タスクが未受け入れでも分離可能な実装とfocused testへ着手できる。先行タスクIDだけを理由に待機せず、欠けている具体的な成果物または未決定事項を示す。
- 依存は「着手依存」「統合依存」「受け入れ依存」に分ける。未確定のwire意味、共有schema/protocol、同一fileの並行owner、未承認の不可逆な技術判断、未解決の機能要件だけを着手blockerとする。実機、credential、共有backend、live環境の不在は、分離可能なfixture/mock実装を止めず、該当する統合または最終受け入れだけをblockする。
- 作業状態は少なくとも`planned`、`in_progress`、`implementation_ready`、`integration_ready`、`accepted`、`blocked`を区別する。`implementation_ready`はfocused testを通した分離実装、`integration_ready`は必要な他レーンとの接続確認済み、`accepted`だけが`[x]`に対応する。
- 各並列sliceは開始時に、参照するartifactとversion、所有file、focused test、まだ満たしていない統合・live・実機・受け入れgateを記録する。部分成果を`[x]`にせず、後続workerが再調査や重複検証なしで利用できる状態にする。
- 並列実行が許可され利用可能な場合、親AIは競合しないレーンを空けたまま直列待機せず、安定した契約面を先に固定して複数のbounded taskを並行委譲する。各workerは原則1タスクID・1レーン・専用branch/worktreeを所有し、`project.pbxproj`、共有scheme、package lock、契約schema、root navigation、`task.md`の更新は単独integration ownerが直列に扱う。
- 50mmマーカーのApple標準framework採用判断、live経路の成功、カメラ実機挙動、採寸精度、元RGB由来、privacy、明示承認、保存の最終gateは省略・緩和しない。並行化は着手と実装の待ち時間を減らすためのもので、fixtureをlive、Simulatorを実機、部分実装を最終受け入れとして扱うものではない。

## 9. 非対象・移植禁止

- React/React DOM、Vite、TypeScript、Zod、`useReducer`前提の実装
- `getUserMedia`、`HTMLVideoElement`、Canvas、Blob、object URL、Web frame callback
- Web Worker、OpenCV.js、WASM固有処理、`object-fit`前提の座標変換
- document-autocapture由来のSafari対応、`visibilitychange`、`pagehide`、Node.js旧baseline API
- Webテスト、build設定、CSS、Storybook、React用repo skill、OpenSpec用skill
- ARKit、WebXR、3D AR、6DoF、自動撮影
- マーカーなし完全自動採寸、Tシャツ以外、着丈・身幅以外、商品自体の生成・改変
- Python FastAPI、LiveKit Agent、rembg/BiRefNet backendのSwiftへの移植

## 10. 受け入れ条件

- **AC-UI-001:** cold launch後は、カメラ権限が未確定なら撮影フロー内の権限案内、それ以外なら`front 1/4`のカメラ画面が最初に表示され、ホーム・一覧・タブを経由しない。
- **AC-CAP-001:** 実機で工程別の固定2Dガイドとリアルタイム助言が表示される。
- **AC-CAP-002:** 実機camera trackがLiveKit Roomへpublishされ、Agent助言が定期HTTP pollingなしでpushされる。
- **AC-CAP-003:** 衣類の欠け、距離、表裏、タグ移動に対し、有限codeから作る1つの行動助言が撮影前に変化する。
- **AC-CAP-004:** 別session/shot、逆順、期限切れeventで助言や撮影工程が巻き戻らない。
- **AC-CAP-005:** `READY`以外でも手動撮影でき、撮影原本にガイドやUIが含まれない。
- **AC-CAP-006:** `front/back/tag`の誤りや品質不良は理由付き撮り直しになり、他の受理済みslotは保持される。
- **AC-FLOW-001:** `1/4 front → 2/4 back → 3/4 tag → 4/4 measurement`が常に明示され、順序を飛ばさない。
- **AC-MEAS-001:** 採寸写真1枚から着丈・身幅の4端点と数値が提案され、利用者が補正・明示承認できる。
- **AC-MEAS-002:** 自動解析失敗時に撮り直しと手入力が提示され、自動成功に偽装されない。
- **AC-MEAS-003:** 利用者補正・承認後の着丈・身幅がデモTシャツの実測値に対して各±1.0cm以内になる。
- **AC-GATE-001:** 4枚と`approved_cv|approved_manual`が揃うまで背景編集へ進めない。
- **AC-EDIT-001:** `front`だけが背景分離され、`back/tag/measurement`は背景処理の入力にならない。
- **AC-EDIT-002:** 背景生成APIには許可styleのテキストだけが送信され、商品画像は送信されない。
- **AC-EDIT-003:** 最終合成画像の商品領域RGBが元`front`画像とpixel単位で一致する。
- **AC-APPROVAL-001:** 採寸、元/合成画像は初期未承認で、利用者の独立した明示操作だけが承認になる。
- **AC-DATA-001:** セッション終了後に承認済み出力以外の画像、mask、判定、採寸、中間生成物が残らない。
- **AC-MODE-001:** fixtureモードは開始から保存spyまで決定的に完走し、live障害時にfixtureへ暗黙切替しない。
- **AC-DEVICE-001:** カメラ、回転、中断復帰、LiveKit publish、撮影原本、VoiceOver、最大Dynamic Typeを対応iPhone実機で確認する。

## 11. ライセンスと出典

- 参照元から資産を持ち込む前に、出典、固定version/commit、利用範囲、license、NOTICE要否、hashを記録する。
- LiveKit Agents/SDK/serverのApache-2.0表記とNOTICE要否を固定versionごとに確認する。
- rembgコードのMITとBiRefNet model weightの配布条件は別資産として確認し、model名、source、checksum、確認日を記録する。
- OpenCV iOS版は技術gateを通過した場合だけ、binary size、build時間、license/NOTICE、privacyを評価して採用する。
- 利用許諾が確認できない画像、アイコン、フォント、model、ブランド資産をrepositoryやapp bundleに含めない。
