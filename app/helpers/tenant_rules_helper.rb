module TenantRulesHelper
  # テナント全体ルールの種別名。allow/block というDB上の値を画面表記に変換する。
  RULE_TYPE_NAMES = { "allow" => "営業時間", "block" => "固定ブロック" }.freeze

  def tenant_rule_type_name(rule_type) = RULE_TYPE_NAMES.fetch(rule_type)

  # 「10:00–18:00」。time カラムは JST の壁時計として読む（別紙A A-1）。
  def tenant_rule_range(rule)
    "#{rule.start_time.strftime('%H:%M')}–#{rule.end_time.strftime('%H:%M')}"
  end
end
