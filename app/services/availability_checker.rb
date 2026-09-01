# 空き判定の唯一の入口（仕様書 §4 ／ 別紙A A-2）。
#
# 検索時（週カレンダー）と予約確定時の両方がこのクラスを通る。判定は
# 「このメンバーはこの区間に空いているか」だけを答え、呼び出し順序を知らない。
# 旧動線は区間を固定してメンバーを回し、新動線はメンバーを固定して区間を回すが、
# このクラスから見ればどちらも同じ 1 区間 × 1 メンバーの問い合わせにすぎない。
class AvailabilityChecker
  # available が false のとき reason に理由文字列が入る。
  # 一覧から除外せず理由付きで表示するため（§4.1 ／ 変えてはいけない設計判断 6）。
  Result = Struct.new(:user, :available, :reason, keyword_init: true)

  # start_at / end_at は ActiveSupport::TimeWithZone（JST）で渡す。
  # 文字列からの生成（Time.zone.parse）は呼び出し側の責務（A-1 TZ規約）。
  #
  # tenant_rules を渡すとテナント全体ルールのクエリを省く。週カレンダーは
  # 区間ごとに本クラスを new するため、呼び出し側で1度だけ読み込んで渡す
  # （渡さなければインスタンス内で1回だけクエリしてメモ化）。
  def initialize(start_at:, end_at:, tenant_rules: nil)
    @start_at              = start_at
    @end_at                = end_at
    @injected_tenant_rules = tenant_rules
  end

  # users は includes(:availability_rules) / preload(:calendar_events) 済みで渡す（A-2-4）。
  # メンバーごとに Result を返す。
  def call(users)
    users.map do |user|
      reason = unavailable_reason(user)
      Result.new(user: user, available: reason.nil?, reason: reason)
    end
  end

  # 全員空きなら true。週カレンダーの空き枠判定（WeeklySlotFinder）から呼ぶ。
  def all_available?(users)
    users.all? { |user| unavailable_reason(user).nil? }
  end

  private

  # 判定順は §4.1 のフロー：営業日／営業時間 → block → 予定（終日含む）。
  # 最初に見つかった不可理由を返し、すべて通れば nil（＝空き）。
  def unavailable_reason(user)
    business_hours_reason(user) || blocked_reason(user) || event_reason(user)
  end

  # --- allow：テナントが上限。個人 allow があれば積集合で絞る（BR-12）-----------
  # allow は「狭める方向」にのみ働く。個人設定でテナントの制限は緩められない。
  def business_hours_reason(user)
    wday   = @start_at.wday
    tenant = allow_ranges(tenant_rules, wday)
    return "営業日外" if tenant.empty?

    personal  = allow_ranges(user.availability_rules, wday)
    effective = personal.empty? ? tenant : intersect(tenant, personal)
    return "営業時間外" if effective.empty?

    covered = effective.any? { |from, to| from <= start_min && end_min <= to }
    covered ? nil : "営業時間外"
  end

  # --- block：テナント block ∪ 個人 block。どちらかに重なれば不可（BR-12）-------
  # block は「広げる方向」にのみ働く。重なり判定は allow と違い等号を含めない。
  def blocked_reason(user)
    wday   = @start_at.wday
    blocks = block_rules(tenant_rules, wday) + block_rules(user.availability_rules, wday)
    hit    = blocks.find { |b| minute_of(b.start_time) < end_min && minute_of(b.end_time) > start_min }
    hit ? "予約不可時間（#{hit.label}）" : nil
  end

  # --- 予定との重なり（§4.3：等号を含めない＝隣接は空き ／ BR-01・BR-02）--------
  def event_reason(user)
    if (e = overlapping_event(user)) then return "予定あり（#{e.title}）" end
    if (e = all_day_event(user))     then return "終日予定（#{e.title}）" end

    nil
  end

  # 既存.start_at < 要求.end_at かつ 既存.end_at > 要求.start_at（BR-01）。
  # <= にしないことで隣接予定を空きとする（A-8：面接前後のバッファなし）。
  def overlapping_event(user)
    user.calendar_events.find do |e|
      !e.all_day && e.start_at < @end_at && e.end_at > @start_at
    end
  end

  # 終日予定はその日全体を不可（BR-03 ／ A-7）。
  def all_day_event(user)
    user.calendar_events.find do |e|
      e.all_day && e.start_at.to_date == @start_at.to_date
    end
  end

  # --- ルールの絞り込み ---------------------------------------------------------
  # allow ルールを [開始分, 終了分] の配列に変換する。
  def allow_ranges(rules, wday)
    rules
      .select { |r| r.rule_type == "allow" && r.day_of_week == wday }
      .map { |r| [ minute_of(r.start_time), minute_of(r.end_time) ] }
  end

  def block_rules(rules, wday)
    rules.select { |r| r.rule_type == "block" && r.day_of_week == wday }
  end

  # [開始分, 終了分] の集合同士の積集合。空区間（from >= to）は捨てる。
  def intersect(ranges_a, ranges_b)
    ranges_a.flat_map do |a_from, a_to|
      ranges_b.filter_map do |b_from, b_to|
        from = [ a_from, b_from ].max
        to   = [ a_to, b_to ].min
        [ from, to ] if from < to
      end
    end
  end

  # テナント全体ルール（user_id: nil）。注入されていればそれを使い、
  # なければインスタンスにつき 1 回だけクエリしてメモ化する（A-2-4）。
  def tenant_rules
    @injected_tenant_rules || (@tenant_rules ||= AvailabilityRule.where(user_id: nil).to_a)
  end

  # 深夜 0 時からの経過分。time カラムも start_at も JST の壁時計で読む（A-1）。
  def start_min = minute_of(@start_at)
  def end_min   = minute_of(@end_at)

  def minute_of(time)
    (time.hour * 60) + time.min
  end
end
