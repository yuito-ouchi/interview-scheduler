class TenantRulesController < ApplicationController
  # 設定の子ページ：テナント全体の予約可能・不可時間（判断メモ D-11 / D-13）。admin 限定。
  #
  # AvailabilityRule は「テナント/個人」×「allow/block」を1テーブルで持つ汎用モデル
  # だが、このコントローラーが扱うのは常に user_id: nil のルールだけ。
  #   - allow … 営業時間（F-11）
  #   - block … 固定ブロック（F-12・F-13）
  # 個人ルール（user_id あり）の編集画面は対象外（未着手）。
  #
  # rule_type は URL のクエリ（new/create）か既存レコード（edit/update）からのみ決まり、
  # フォームの送信値（availability_rule ハッシュ）からは絶対に受け取らない。
  before_action :require_admin
  before_action :set_rule_type,   only: %i[new create]
  before_action :set_tenant_rule, only: %i[edit update destroy]

  # GET /tenant_rules
  # 営業時間と固定ブロックを1画面に集約する（判断メモ D-13）。
  # 1度のクエリで両方を読み、Ruby側で振り分ける。
  def index
    rules        = AvailabilityRule.tenant_wide.order(:day_of_week, :start_time).to_a
    @allow_rules = rules.select { |r| r.rule_type == "allow" }
    @block_rules = rules.select { |r| r.rule_type == "block" }
  end

  # GET /tenant_rules/new?rule_type=allow
  def new
    @tenant_rule = AvailabilityRule.new(rule_type: @rule_type)
  end

  # POST /tenant_rules?rule_type=allow
  def create
    @tenant_rule = AvailabilityRule.new(tenant_rule_params.merge(user_id: nil, rule_type: @rule_type))

    if @tenant_rule.save
      redirect_to tenant_rules_path, notice: "#{rule_type_name}を追加しました"
    else
      render :new, status: :unprocessable_entity
    end
  end

  # GET /tenant_rules/:id/edit
  def edit
  end

  # PATCH /tenant_rules/:id
  # rule_type は既存レコードのものを保つ（許可パラメータに含めていない）。
  def update
    if @tenant_rule.update(tenant_rule_params)
      redirect_to tenant_rules_path, notice: "#{rule_type_name}を更新しました"
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # DELETE /tenant_rules/:id
  def destroy
    @tenant_rule.destroy
    redirect_to tenant_rules_path, notice: "#{rule_type_name}を削除しました", status: :see_other
  end

  private

  # 未知の rule_type は 404。allow / block 以外をこの画面から作らせない。
  def set_rule_type
    @rule_type = params[:rule_type].presence_in(AvailabilityRule::RULE_TYPES)
    raise ActiveRecord::RecordNotFound unless @rule_type
  end

  # tenant_wide に絞って find するため、URLのidを差し替えても
  # 個人ルールをこの画面から編集・削除できない。
  def set_tenant_rule
    @tenant_rule = AvailabilityRule.tenant_wide.find(params[:id])
    @rule_type   = @tenant_rule.rule_type
  end

  def rule_type_name = helpers.tenant_rule_type_name(@rule_type)

  # rule_type と user_id はここに含めない（上の2つの before_action で決める）。
  def tenant_rule_params
    params.expect(availability_rule: %i[day_of_week start_time end_time label])
  end
end
