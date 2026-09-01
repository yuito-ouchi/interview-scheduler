class InterviewsController < ApplicationController
  # GET /interviews/new
  # 面接官選択・所要時間・週送りのフォーム＋週カレンダー（Turbo Frame）。
  def new
    assign_params
    @interviewers = User.where(interviewer: true).order(:name)
    load_calendar if @user_ids.any?
  end

  # GET /interviews/calendar
  # フォーム送信・週送りの受け口。週カレンダー部分だけ差し替える。
  def calendar
    assign_params
    load_calendar if @user_ids.any?
    render partial: "week_grid"
  end

  private

  def assign_params
    @user_ids = Array(params[:user_ids]).reject(&:blank?).map(&:to_i)
    @duration = duration_param
    @week_of  = week_of_param
  end

  # プリセットは 15/30/45/60/90 だが制約ではない（BR-08）。正の整数なら受ける。
  def duration_param
    d = params[:duration].to_i
    d.positive? ? d : 60
  end

  # A-1/A-4：文字列からの生成は Time.zone.parse のみ。壊れた入力は今週にフォールバック。
  def week_of_param
    (parse_week(params[:week_of]) || Time.current).beginning_of_week
  end

  def parse_week(raw)
    return if raw.blank?

    Time.zone.parse(raw)
  rescue ArgumentError, Date::Error
    nil
  end

  # A-2-4：予定とルールを事前読み込みし、区間ごとにDBを叩かない。
  # AvailabilityChecker は user.calendar_events を参照するだけなので、その中身を
  # 「表示する週の予定」に差し替えて渡す（運用が進んでもメモリが増え続けない）。
  def load_calendar
    @tenant_rules = AvailabilityRule.where(user_id: nil).to_a
    @users = User.where(id: @user_ids, interviewer: true)
                 .includes(:availability_rules)
                 .order(:name)
                 .to_a
    attach_week_events(@users, @week_of.all_week)

    @days = WeeklySlotFinder.new(users: @users, week_of: @week_of,
                                 duration_min: @duration,
                                 tenant_rules: @tenant_rules).call
  end

  # 全員分の予定を1クエリで取り、週の範囲に絞って各 user の association に載せる。
  # 以後 user.calendar_events はこの配列を返し、追加クエリを発行しない。
  def attach_week_events(users, week_range)
    by_user = CalendarEvent.where(user_id: users.map(&:id), start_at: week_range).group_by(&:user_id)
    users.each do |user|
      assoc = user.association(:calendar_events)
      assoc.target = by_user.fetch(user.id, [])
      assoc.loaded!
    end
  end
end
