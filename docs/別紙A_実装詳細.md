# 別紙A：実装詳細

仕様書の補足資料。設計の主旨は仕様書で完結しているため、本紙は必要に応じて参照。

**根拠の記号**：`H-nn` = Day 2 ヒヤリング面談／`H2-nn` = 追加ヒヤリング／`A-n` = 置いた仮定

## 改訂履歴

| 版 | 変更内容 | 契機 |
|---|---|---|
| 初版 | 技術選定・空き判定・排他制御・ルーティング | — |
| **第2版** | **主動線の入れ替えに伴い A-2-3（週走査）と A-4（ルーティング）を改訂。A-2-1（テナント／個人ルールの合成）と A-5（簡易ログイン）を新設。テストケースを11→16に追加** | **H2-01〜H2-05** |

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

### 開始時刻の刻みと所要時間

**固定値を持たない。**（H2-01）

| 項目 | 方式 |
|---|---|
| 開始時刻 | `<input type="time" step="300">`（5分刻み） |
| 所要時間 | 数値入力（分）＋ プリセット 15／30／45／60／90分 |

**刻みを5分にすれば、10分刻みも15分刻みも30分刻みもすべて表現できる。** 設定テーブル・編集画面・初期値の管理を作らずに柔軟性が得られる。

**`AvailabilityChecker` は刻みの概念を持たない。** 開始時刻と終了時刻を受け取るだけなので、影響は UI の入力方式と `WeeklySlotFinder::STEP` の定数に限られる。

### タイムゾーンの規約

Active RecordはDBにUTCで保存し、`config.time_zone = "Tokyo"` で表示・入力を変換する。**日程調整アプリではここが最大のバグ源になる**ため、以下を規約として固定する。

- 現在時刻は `Time.current` のみ。`Time.now` は禁止
- 文字列からの生成は `Time.zone.parse` のみ。`Time.parse` は禁止
- 比較・保存はすべて `ActiveSupport::TimeWithZone` で統一

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

**allow は狭める方向、block は広げる方向にのみ働く。** 個人設定でテナントの制限を緩められない。「全社で土曜は面接しない」と決めたら、個人設定で土曜を開けることはできない。

| 例 | 結果 |
|---|---|
| テナント：平日10-18時 allow ／ 個人：設定なし | 平日10-18時が可能 |
| テナント：平日10-18時 allow ／ 個人：平日13-17時 allow | **平日13-17時のみ**（積集合） |
| テナント：平日10-18時 allow ／ 個人：水曜終日 allow | **水曜は不可**（テナントに水曜allowがない） |
| テナント：12-13時 block ／ 個人：月曜午前 block | 両方とも不可（和集合） |

### A-2-2. 重なり条件を `<` と `>` にした理由

`既存.start_at < 要求end AND 既存.end_at > 要求start` で判定し、等号を含めない。これにより**隣接する予定を「空き」と判定する。**

10:00-11:00 の予定がある人に 11:00-12:00 を入れる場合、`既存.end_at(11:00) > 要求start(11:00)` が偽になるため空きになる。**仮定A-8（面接前後のバッファなし）と1対1で対応している。** バッファが必要になれば、この比較に定数を加算するだけで済む。

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

### A-2-4. N+1 と走査量

週5日 × 営業8時間 × 5分刻み ＝ **1日あたり最大96区間、週で約480区間**。これをメンバー数分判定する。

**区間ごとにDBを叩くと480回×人数のクエリが飛ぶ。** 必ず事前読み込みしたうえで Ruby 側で判定すること。

```ruby
users = User.where(id: ids, interviewer: true)
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

## A-3. 排他制御

### SQLite3（今回の採用構成）

SQLiteは書き込みトランザクションを直列化する。トランザクション開始時に書き込みロックを取得したうえで「再判定 → 書き込み」を行えば、その間に他の書き込みが割り込むことはない。

```ruby
def create
  ActiveRecord::Base.transaction(isolation: :immediate) do
    users   = User.where(id: params[:user_ids], interviewer: true).order(:id)
                  .includes(:availability_rules)
                  .preload(calendar_events: -> { where(start_at: day_range) })
    results = AvailabilityChecker.new(start_at:, end_at:).call(users)
    busy    = results.reject(&:available)

    if busy.any?
      @error = "#{busy.map { _1.user.name }.join('・')} さんの予定が埋まりました"
      raise ActiveRecord::Rollback
    end

    interview = Interview.create!(interview_params.merge(created_by: current_user))
    users.each do |user|
      InterviewAttendee.create!(interview:, user:)
      CalendarEvent.create!(
        user:, interview:, source: "app",
        title: "面接：#{interview.candidate_name}様",   # BR-11：固定フォーマット
        start_at:, end_at:, all_day: false
      )
    end
  end
end
```

`isolation: :immediate` は `BEGIN IMMEDIATE` に相当し、開始時点で書き込みロックを取る。**Rails 8.1のSQLite3アダプタでの挙動を実装時に確認する。** 対応していない場合は `connection.execute("BEGIN IMMEDIATE")` を直接使う。

**ここで再判定に使うのは、週カレンダーの表示に使ったのと同じ `AvailabilityChecker`。** 主動線が「メンバー → 週カレンダー → 空き枠クリック」に変わっても、確定処理は変わらない。**空き枠として表示してから予約ボタンを押すまでの時間差**が問題であり、その構造は動線に依存しないためである。

**過去日時のバリデーション**：空き判定は「予定と重なるか」しか見ておらず、過去日を指定すると全員空きと出る。`Interview` に `validates :start_at, comparison: { greater_than: -> { Time.current } }` 相当の検証を入れること。**未実装のため実装時に確認する。**

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

**主動線の入れ替え（H2-05）を反映済み。**

```ruby
# config/routes.rb
Rails.application.routes.draw do
  root "interviews#new"

  get  "login", to: "sessions#new"
  post "login", to: "sessions#create"

  resources :interviews, only: %i[index new create show] do
    collection do
      get :calendar   # Turbo Frame で選択メンバーの週カレンダーを返す
    end
  end

  resources :users
  resources :calendar_connections, only: %i[index]
  resource  :availability_rules,   only: %i[show update]
end
```

| メソッド | パス | 用途 |
|---|---|---|
| GET | `/login` | 操作者選択 |
| POST | `/login` | セッションに `user_id` を保持 |
| GET | `/interviews/new` | 面接を組む（面接官選択＋週カレンダー） |
| GET | `/interviews/calendar?user_ids[]=&week_of=&duration=` | **選択メンバーの週カレンダー（Turbo Frame）** |
| POST | `/interviews` | 予約確定（再判定つき）。競合時 422 |
| GET | `/interviews` `/interviews/:id` | 一覧・詳細 |
| — | `/users` 一式 | メンバー管理 |
| GET | `/calendar_connections` | カレンダー連携状態 |
| GET/PATCH | `/availability_rules` | 営業時間・予約不可時間 |

`calendar` は `_week_grid.html.erb` パーシャルを返す。**空き枠だけでなく、埋まっている区間も「誰の何の予定か」を付けて渡す。** 表示側で消すかどうかを判断できるようにするためである。

### パラメータの扱い

```ruby
def calendar
  @users    = User.where(id: params[:user_ids], interviewer: true)
                  .includes(:availability_rules)
                  .preload(calendar_events: -> { where(start_at: week_range) })
  @duration = params[:duration].to_i
  @week_of  = Time.zone.parse(params[:week_of]).beginning_of_week
  @slots    = WeeklySlotFinder.new(users: @users, week_of: @week_of,
                                   duration_min: @duration).call
  render partial: "week_grid"
end
```

**`Time.zone.parse` を使うこと**（A-1のタイムゾーン規約）。`params[:week_of]` は文字列で届くため、`Time.parse` を使うとサーバーのタイムゾーンで解釈されて日がずれる。

---

## A-5. 簡易ログイン

**パスワード認証を行わない。操作者を選択してセッションに保持するだけ。**

```ruby
# app/controllers/sessions_controller.rb
class SessionsController < ApplicationController
  skip_before_action :require_operator, only: %i[new create]

  def new
    @operators = User.where(operator: true).order(:name)
  end

  def create
    user = User.find_by(id: params[:user_id], operator: true)
    if user
      session[:user_id] = user.id
      redirect_to root_path
    else
      redirect_to login_path, alert: "操作者を選択してください"
    end
  end
end
```

```ruby
# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  before_action :require_operator
  helper_method :current_user

  private

  def current_user
    @current_user ||= User.find_by(id: session[:user_id], operator: true)
  end

  def require_operator
    redirect_to login_path unless current_user
  end
end
```

**`find_by` に `operator: true` を付けている理由**：セッションのIDだけで引くと、**後から `operator` を false に変更されたユーザーがログインしたままになる。** 毎回確認することで、権限を落とした瞬間から操作できなくなる。

**セキュリティ上の位置づけ**：`user_id` を選ぶだけなので**他人になりすませる。** 社内ツールであり本番データを扱わないため Phase 1 では許容する。Phase 2 で認証・権限制御（F-52）として実装する。**明示的な判断であり、実装漏れではない。**
