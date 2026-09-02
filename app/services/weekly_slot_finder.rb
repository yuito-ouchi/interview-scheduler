# 週カレンダーの空き枠算出（仕様書 §6.6 ／ 別紙A A-2-3）。
#
# 判定そのものは AvailabilityChecker をそのまま呼ぶ。旧動線は区間を固定して
# メンバーを回し、新動線（これ）はメンバーを固定して区間を回す。呼び出し側の
# ループが変わるだけで、判定クラスには一切手を入れない。
#
# 骨子（A-2-3）は空き枠を flat_map で平坦化して返していたが、§6.6 の
# 「営業日外・営業時間外はグレーアウト」を描くには日ごとの営業時間が要るため、
# 日単位（Day）に構造化して返す。中核の走査ループは骨子のまま：
# 営業時間内を STEP 刻みで cursor を進め、AvailabilityChecker#all_available? を呼ぶ。
class WeeklySlotFinder
  STEP = 5.minutes # BR-08：開始時刻は5分刻み

  Day = Struct.new(:date, :open_from, :open_to, :slots, :free_windows, :near_windows, keyword_init: true) do
    # 営業日でない（テナント allow がその曜日に無い）
    def closed? = open_from.nil?
  end

  # users は includes(:availability_rules) / preload(:calendar_events) 済みで渡す（A-2-4）。
  # tenant_rules も呼び出し側で1度だけ読み込んで渡す（区間ごとに引かない）。
  def initialize(users:, week_of:, duration_min:, tenant_rules:)
    @users        = users
    @week_of      = week_of.to_date.beginning_of_week # 週の起点＝月曜
    @duration     = duration_min.to_i.minutes
    @tenant_rules = tenant_rules
  end

  # 月曜からの7日分を Day で返す。
  def call
    (0..6).map { |offset| build_day(@week_of + offset) }
  end

  private

  def build_day(date)
    open_from, open_to = business_hours(date)
    return Day.new(date: date, slots: [], free_windows: [], near_windows: []) if open_from.nil?

    slots, near_slots = scan(open_from, open_to)
    Day.new(date: date, open_from: open_from, open_to: open_to,
            slots: slots, free_windows: merge_windows(slots),
            near_windows: merge_near_windows(near_slots))
  end

  # 営業時間内を STEP 刻みで走査し、全員空きの区間を拾う（A-2-3 の骨子ループ）。
  # ついでに「あと1人を除けば空く」区間も拾う（脳内で「この人抜こう」を試す
  # 前に、そもそも抜く価値があるか見えた方がいい、というUX要望から追加）。
  # 判定そのものは AvailabilityChecker#call のまま。誰が不可かを見るために
  # all_available? の代わりに call を使うが、判定ロジックには一切手を入れない。
  def scan(open_from, open_to)
    found = []
    near  = []
    cursor = open_from
    while cursor + @duration <= open_to
      checker = AvailabilityChecker.new(start_at: cursor, end_at: cursor + @duration,
                                        tenant_rules: @tenant_rules)
      results = checker.call(@users)
      busy    = results.reject(&:available)

      case busy.size
      when 0 then found << { start_at: cursor, end_at: cursor + @duration }
      when 1 then near  << { start_at: cursor, end_at: cursor + @duration, blocking_user: busy.first.user }
      end

      cursor += STEP
    end
    [ found, near ]
  end

  # 連続する空き開始（隣同士が STEP 差）を1本の空き帯にまとめる。
  # 帯は [最初の開始, 最後の枠の終了]。表示ではこの帯の中から開始位置を選ばせる想定。
  def merge_windows(slots)
    slots.each_with_object([]) do |slot, windows|
      last = windows.last
      if last && (slot[:start_at] - last[:last_start] <= STEP.to_i)
        last[:last_start] = slot[:start_at]
        last[:end_at]     = slot[:end_at]
      else
        windows << { start_at: slot[:start_at], last_start: slot[:start_at], end_at: slot[:end_at] }
      end
    end
  end

  # near も同様に連続をまとめるが、ブロック要因の人が変わったら別の帯にする
  # （「あと1人＝伊藤」の帯と「あと1人＝佐藤」の帯を混ぜて見せない）。
  def merge_near_windows(slots)
    slots.each_with_object([]) do |slot, windows|
      last = windows.last
      if last && last[:blocking_user] == slot[:blocking_user] &&
         (slot[:start_at] - last[:last_start] <= STEP.to_i)
        last[:last_start] = slot[:start_at]
        last[:end_at]     = slot[:end_at]
      else
        windows << { start_at: slot[:start_at], last_start: slot[:start_at],
                      end_at: slot[:end_at], blocking_user: slot[:blocking_user] }
      end
    end
  end

  # その日の営業時間 [開始, 終了]。テナント allow が無ければ [nil, nil]（営業日外）。
  # allow が複数あれば最も早い開始〜最も遅い終了を外枠とする。
  def business_hours(date)
    allows = @tenant_rules.select { |r| r.rule_type == "allow" && r.day_of_week == date.wday }
    return [ nil, nil ] if allows.empty?

    [ allows.map { |r| at(date, r.start_time) }.min,
      allows.map { |r| at(date, r.end_time) }.max ]
  end

  # time カラム（2000-01-01 の TimeWithZone）を対象日の JST 時刻に組み替える（A-1）。
  def at(date, time_value)
    Time.zone.local(date.year, date.month, date.day, time_value.hour, time_value.min)
  end
end
