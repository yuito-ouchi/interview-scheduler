# 別紙A：実装詳細

仕様書の補足資料。設計の主旨は仕様書で完結しているため、本紙は必要に応じて参照。

**根拠の記号**：`H-nn` = Day 2 ヒヤリング面談／`H2-nn` = 追加ヒヤリング／`A-n` = 置いた仮定

## 改訂履歴

| 版 | 変更内容 | 契機 |
|---|---|---|
| 初版 | 技術選定・空き判定・排他制御・ルーティング | — |
| **第2版** | **主動線の入れ替えに伴い A-2-3（週走査）と A-4（ルーティング）を改訂。A-2-1（テナント／個人ルールの合成）と A-5（簡易ログイン）を新設。テストケースを11→16に追加** | **H2-01〜H2-05** |
| **第3版** | **A-3（排他制御）を実装結果に更新**（`isolation: :immediate` は非対応と判明、素の `transaction` で当初目的を達成／過去日時バリデーションを実装済みに更新）。**A-2-3に「あと1人で空き」を追加**（未テストである旨を明記）。**仕様書と重複していた A-1・A-4・A-5 の内容を仕様書側への参照に整理し、本紙は実装コードそのものと差分の説明に絞った** | 実装完了後のUI改修（参加者選択UI・ニアミス表示）とドキュメント総点検 |
| **第4版** | **用語を全面統一。** `interviews`→`meetings`、`interview_attendees`→`meeting_attendees`、`candidate_name`→`guest_name`、`users.interviewer`→`users.participant` にDB・コード・テストを一括リネーム（本紙のコード例もすべて実装コードと一致させた）。「面接／候補者／面接官／採用担当者」の表記を「ミーティング／ゲスト／参加者／主催者」に統一 | 「このツールは採用ツールではなく汎用の時間調整ツール」という指摘 |

---

## A-1. 技術選定

課題文で言語・フレームワーク・DBは自由とされている。選定基準を**「Day 7に任意のコードを指されて説明できること」**に置いた。使い慣れない技術で書いたコードは、動いても説明できない。

| 層 | 採用 | 理由 |
|---|---|---|
| 言語 | Ruby 3.2以上（Rails 8系の要件） | — |
| フレームワーク | Rails 8.1 | 画面・ルーティング・DBアクセスが1つの規約に収まり、10〜15時間の制約に合う |
| DB | SQLite3（Rails標準） | 環境構築が `bin/setup` だけで済む。**書き込みが直列化されるため排他制御の前提を単純にできる**（A-3） |
| ORM | Active Record | マイグレーションと `db/schema.rb` がそのまま設計書として読める |
| 画面 | ERB ＋ Hotwire（Turbo / Stimulus） | フロントとバックを分けないため、9時間の制約下で画面数を確保できる |
| テスト | Minitest（Rails標準） | 追加gemなしで書き始められる |

### 開始時刻の刻みと所要時間・タイムゾーンの規約

**→ 仕様書§4.2・§4.5に記載（実装済み）。** 本紙は仕様書の実装詳細を補うためのものであり、規約自体を重複して書かない。**影響範囲だけ補足する**：`AvailabilityChecker` は刻みの概念を持たず開始・終了時刻を受け取るだけなので、開始時刻の自由化による影響は UI の入力方式（画面①b）と `WeeklySlotFinder::STEP` 定数に限られる。

---

## A-2. 空き判定ロジック

### 骨子

```ruby
# app/services/availability_checker.rb
class AvailabilityChecker
  Result = Struct.new(:user, :available, :reason, keyword_init: true)

  def initialize(start_at:, end_at:)
    @start_at = start_at
    @end_at   = end_at
  end

  # users は includes 済みの配列を渡す（A-2-4 参照）
  def call(users)
    users.map do |user|
      reason = unavailable_reason(user)
      Result.new(user: user, available: reason.nil?, reason: reason)
    end
  end

  # 全員空きなら true。週カレンダーの空き枠判定で使う
  def all_available?(users)
    users.all? { |u| unavailable_reason(u).nil? }
  end

  private

  def unavailable_reason(user)
    business_hours_reason(user) || blocked_reason(user) || event_reason(user)
  end

  def event_reason(user)
    if (e = overlapping_event(user)) then return "予定あり（#{e.title}）" end
    if (e = all_day_event(user))     then return "終日予定（#{e.title}）" end
    nil
  end

  def overlapping_event(user)
    user.calendar_events.find do |e|
      !e.all_day && e.start_at < @end_at && e.end_at > @start_at
    end
  end

  def all_day_event(user)
    user.calendar_events.find do |e|
      e.all_day && e.start_at.to_date == @start_at.to_date
    end
  end
end
```

**メモリ上で絞り込んでいる理由**：週カレンダーでは同じユーザーに対して数百回 `call` を呼ぶ（A-2-3）。`where` でDBに問い合わせる実装だとクエリが爆発するため、**`includes` で読み込んだ配列を Ruby の `find` で走査する。**

### A-2-1. テナントルールと個人ルールの合成

`availability_rules` は `user_id` が NULL ならテナント全体、値があれば個人。**両者の合成規則（BR-12）を実装するのがこの2メソッド。**

```ruby
  # allow：テナントが上限。個人があれば積集合で絞る
  def business_hours_reason(user)
    wday = @start_at.wday
    tenant = rules_for(nil, wday, "allow")
    return "営業日外" if tenant.empty?

    personal = rules_for(user.id, wday, "allow")
    effective = personal.empty? ? tenant : intersect(tenant, personal)
    return "営業時間外" if effective.empty?

    ok = effective.any? { |r| r.start_time <= time_of(@start_at) && time_of(@end_at) <= r.end_time }
    ok ? nil : "営業時間外"
  end

  # block：テナントと個人の和集合。どちらかに重なれば不可
  def blocked_reason(user)
    wday = @start_at.wday
    blocks = rules_for(nil, wday, "block") + rules_for(user.id, wday, "block")
    hit = blocks.find { |b| b.start_time < time_of(@end_at) && b.end_time > time_of(@start_at) }
    hit ? "予約不可時間（#{hit.label}）" : nil
  end
```

**allow は狭める方向、block は広げる方向にのみ働く。** 個人設定でテナントの制限を緩められない。「全社で土曜はミーティングを入れない」と決めたら、個人設定で土曜を開けることはできない。

| 例 | 結果 |
|---|---|
| テナント：平日10-18時 allow ／ 個人：設定なし | 平日10-18時が可能 |
| テナント：平日10-18時 allow ／ 個人：平日13-17時 allow | **平日13-17時のみ**（積集合） |
| テナント：平日10-18時 allow ／ 個人：水曜終日 allow | **水曜は不可**（テナントに水曜allowがない） |
| テナント：12-13時 block ／ 個人：月曜午前 block | 両方とも不可（和集合） |

### A-2-2. 重なり条件を `<` と `>` にした理由

`既存.start_at < 要求end AND 既存.end_at > 要求start` で判定し、等号を含めない。これにより**隣接する予定を「空き」と判定する。**

10:00-11:00 の予定がある人に 11:00-12:00 を入れる場合、`既存.end_at(11:00) > 要求start(11:00)` が偽になるため空きになる。**仮定A-8（ミーティング前後のバッファなし）と1対1で対応している。** バッファが必要になれば、この比較に定数を加算するだけで済む。

### A-2-3. 週カレンダーの空き枠算出

**主動線の入れ替え（H2-05）に伴い追加。** 判定クラスは変更せず、呼び出し側のループだけが変わる。

```ruby
# app/services/weekly_slot_finder.rb
class WeeklySlotFinder
  STEP = 5.minutes

  def initialize(users:, week_of:, duration_min:)
    @users        = users
    @week_of      = week_of        # 週の起点（月曜）
    @duration     = duration_min.minutes
  end

  def call
    (0..6).flat_map { |offset| slots_for(@week_of + offset.days) }
  end

  private

  def slots_for(date)
    open_from, open_to = business_hours(date)
    return [] if open_from.nil?

    slots = []
    cursor = open_from
    while cursor + @duration <= open_to
      checker = AvailabilityChecker.new(start_at: cursor, end_at: cursor + @duration)
      slots << { start_at: cursor, end_at: cursor + @duration } if checker.all_available?(@users)
      cursor += STEP
    end
    slots
  end
end
```

**`AvailabilityChecker` には一切手を入れていない。** 区間を固定してメンバーを回すか、メンバーを固定して区間を回すかの違いに過ぎない。判定を単一クラスに閉じ込めた設計の効果がここに出る。

**実装では、上の骨子から以下を追加している。**

- 営業時間外・営業日外の描画に日ごとの営業時間が要るため、`slots` を `Day`（`date, open_from, open_to, slots, free_windows, near_windows`）に構造化して返す
- 連続する空き開始（`STEP` 差以内）を1本の帯にまとめる `merge_windows`。カレンダー表示は帯単位で行い、帯の中から開始時刻を選ばせる（仕様書§6.6）
- **「あと1人で空き」（実装段階の追加。仕様書§6.4・§6.6）**：`checker.all_available?` の代わりに `checker.call` を使い、不可の人数がちょうど1名の区間を `near_windows` として別途拾う。同じ人がブロックし続ける区間だけを1本の帯にまとめる `merge_near_windows` を追加（`blocking_user` が変わったら帯を区切る）
- `tenant_rules` は呼び出し側で1度だけ読み込んで `AvailabilityChecker.new` に注入する（A-2-4のN+1対策と同じ理由）

### A-2-4. N+1 と走査量

週5日 × 営業8時間 × 5分刻み ＝ **1日あたり最大96区間、週で約480区間**。これをメンバー数分判定する。

**区間ごとにDBを叩くと480回×人数のクエリが飛ぶ。** 必ず事前読み込みしたうえで Ruby 側で判定すること。

```ruby
users = User.where(id: ids, participant: true)
            .includes(:availability_rules)
            .preload(calendar_events: -> { where(start_at: week_range) })
```

**予定の読み込みを週の範囲に絞る**のが重要。全期間を読み込むと、運用が進むにつれてメモリ使用量が増え続ける。

数百名規模になった場合は、1クエリで全予定を取得して `group_by(&:user_id)` する形に変える。

### A-2-5. テストする境界条件

| # | ケース | 期待 |
|---|---|---|
| 1 | 既存の終了＝要求の開始（隣接） | 空き |
| 2 | 既存の開始＝要求の終了（隣接） | 空き |
| 3 | 既存が要求を完全に含む | 不可 |
| 4 | 要求が既存を完全に含む | 不可 |
| 5 | 前方で部分的に重なる | 不可 |
| 6 | 後方で部分的に重なる | 不可 |
| 7 | 終日予定がある日 | 不可 |
| 8 | 要求終了が営業時間を超える（17:30開始60分／営業18:00まで） | 不可 |
| 9 | 土曜・日曜 | 不可 |
| 10 | 個別blockルールと重なる | 不可（ラベル表示） |
| 11 | **JSTで入力しUTCで保存した予定を、JSTで再判定** | 正しく重なりを検出 |
| 12 | **テナント10-18時 allow・個人13-17時 allow で 11:00 を要求** | **不可**（積集合の検証） |
| 13 | **テナント allow なしの曜日に、個人 allow がある** | **不可**（個人設定でテナント制限を緩められないことの検証） |
| 14 | **テナント block と個人 block の両方を持つユーザー** | いずれに重なっても不可（和集合の検証） |
| 15 | **`WeeklySlotFinder` が営業時間外の枠を返さない** | 週走査の検証 |
| 16 | **2名選択時、片方だけ埋まっている区間が空き枠に含まれない** | `all_available?` の検証 |

3〜6は同じ式で処理されるが、**符号の誤りが最も出やすい箇所**のため個別にテストする。12〜14は BR-12（合成規則）の検証で、**allow と block で向きが逆**という設計を守れているかを確認する。

**未着手のテスト（判明している穴）**：「あと1人で空き」（`near_windows`／A-2-3で追加）には、この一覧の時点で単体テストが無い。実装段階の追加機能でありテストが追いついていない。次に着手する場合は「不可がちょうど1名の区間が `near_windows` に入る」「不可が2名以上なら入らない」「ブロック要因の人が変わったら帯を分ける」の3点を境界条件として追加する。

## A-3. 排他制御

### SQLite3（今回の採用構成・実装済み）

SQLiteは書き込みトランザクションを直列化する。トランザクション開始時に書き込みロックを取得したうえで「再判定 → 書き込み」を行えば、その間に他の書き込みが割り込むことはない。

```ruby
# app/controllers/meetings_controller.rb（実装コードそのまま）
def confirm_booking
  return false unless @meeting.valid?(:create) # 過去日時・必須項目・区間はここで弾く

  ActiveRecord::Base.transaction do
    users = User.where(id: @user_ids, participant: true)
                .includes(:availability_rules, :calendar_events)
                .order(:id)
                .to_a

    tenant_rules = AvailabilityRule.where(user_id: nil).to_a
    results = AvailabilityChecker
              .new(start_at: @meeting.start_at, end_at: @meeting.end_at, tenant_rules: tenant_rules)
              .call(users)
    busy = results.reject(&:available)

    if busy.any?
      @booking_error = "#{busy.map { |r| r.user.name }.join('・')} さんの予定が埋まりました。枠を選び直してください。"
      raise ActiveRecord::Rollback
    end

    @meeting.save!
    users.each do |user|
      @meeting.meeting_attendees.create!(user: user)
      @meeting.calendar_events.create!(
        user: user, source: "app", all_day: false,
        title: @meeting.calendar_title, # BR-11：ミーティング：{ゲスト名}様（編集不可）
        start_at: @meeting.start_at, end_at: @meeting.end_at
      )
    end
    true
  end
rescue ActiveRecord::RecordInvalid
  false
end
```

**`isolation: :immediate` は使っていない（検証済みの結論）。** 実装時に試したところ、Rails 8.1 の SQLite3 アダプタは `transaction(isolation: :immediate)` を呼ぶと `TransactionIsolationError` を送出し、**そもそもこの引数を受け付けない。** 一方でこのアダプタは仕様として**全トランザクションを内部的に `BEGIN IMMEDIATE` で開始する**ため、素の `transaction do ... end` を使うだけで当初の目的（トランザクション開始時点での書き込みロック取得）は達成されている。`connection.execute("BEGIN IMMEDIATE")` を直接発行する代替案も検討したが、上記の理由で不要だった。

**ここで再判定に使うのは、週カレンダーの表示に使ったのと同じ `AvailabilityChecker`。** 主動線が「メンバー → 週カレンダー → 空き枠クリック」に変わっても、確定処理は変わらない。**空き枠として表示してから予約ボタンを押すまでの時間差**が問題であり、その構造は動線に依存しないためである。

**過去日時のバリデーション（実装済み）**：空き判定は「予定と重なるか」しか見ておらず、過去日を指定すると全員空きと出る。`app/models/meeting.rb` に以下を実装し、`confirm_booking` の冒頭 `@meeting.valid?(:create)` で弾く。

```ruby
validates :start_at, comparison: { greater_than: -> { Time.current },
                                   message: "は現在より後の日時にしてください" },
          on: :create, if: -> { start_at.present? }
```

### PostgreSQLへ移行する場合

書き込みが直列化されないため、追加の手当てが必要になる。

**(1) 行ロック**：再判定の前に対象ユーザー行をロックする。複数名を押さえるため、**IDの昇順でロックを取ってデッドロックを避ける。**

```ruby
users = User.where(id: params[:user_ids]).order(:id).lock
```

**(2) 排他制約（推奨）**：`btree_gist` を使い、DB制約として重複を禁止する。

```ruby
enable_extension "btree_gist"
execute <<~SQL
  ALTER TABLE calendar_events
    ADD CONSTRAINT no_overlap
    EXCLUDE USING gist (
      user_id WITH =,
      tsrange(start_at, end_at) WITH &&
    ) WHERE (all_day = false);
SQL
```

**Rails特有の注意点**：排他制約は `db/schema.rb` では表現できない。`config.active_record.schema_format = :sql` に切り替えて `db/structure.sql` で管理する。これを忘れると `db:schema:load` で環境を作り直したときに制約が消える。

アプリ側の再判定はユーザー向けエラーメッセージのために残しつつ、**最終的な保証をDBに置く。** アプリのバグや将来の別経路からの書き込みでも重複が発生しなくなる。

---

## A-4. ルーティング

**→ 仕様書§7に実装済み／未実装の内訳を記載。** ここでは補足のみ。

```ruby
# app/controllers/meetings_controller.rb（実装コードそのまま。private部分を抜粋）
def assign_params
  @user_ids = selected_user_ids
  @duration = duration_param
  @week_of  = week_of_param
end

def week_of_param
  (parse_time(params[:week_of]) || Time.current).beginning_of_week
end

def parse_time(raw)
  return if raw.blank?

  Time.zone.parse(raw)
rescue ArgumentError, Date::Error
  nil
end
```

**`Time.zone.parse` を使うこと**（A-1／仕様書§4.5のタイムゾーン規約）。`params[:week_of]` は文字列で届くため、`Time.parse` を使うとサーバーのタイムゾーンで解釈されて日がずれる。**壊れた文字列は `rescue` で今週にフォールバックし、落ちない。**

---

## A-5. 簡易ログイン

**→ 仕様書§6.2に実装コード・理由とも記載済み（実装済み）。本紙は重複させない。**

補足のみ：`sessions_controller.rb` は `switch=1` パラメータで「ログイン済みでも選択フォームを出す」切替に対応している（仕様書§6.2のコード例より実装が1点進んでいる）。トップバーの「切り替える」リンク（仕様書§6.8のUI）がここに繋がる。
