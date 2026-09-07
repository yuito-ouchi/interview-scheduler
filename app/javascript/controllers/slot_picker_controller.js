import { Controller } from "@hotwired/stimulus"

// 週カレンダーの空き帯（a.seg--free）に付く。クリックした縦位置を開始時刻に変換して
// href の start_at / end_at を差し替えてから、Turbo Frame（booking_form）へ遷移させる。
//
// 縦スケールは 1px = 1分（MeetingsHelper::PX_PER_MIN）。帯の data 属性から
//   start-min       … 帯の先頭時刻（0時起点の分）
//   last-start-min  … 帯の中で選べる最後の開始（0時起点の分）
//   duration        … 所要（分）
// を受け取り、クリック位置を5分丸め＋帯内にクランプする。
// href は元々「帯の先頭時刻」で組んであるので、JS無効時やキーボードの Enter
// （clientY が 0 になり必ず先頭にクランプされる）でもそのまま予約フォームが開く。
export default class extends Controller {
  static values = { startMin: Number, lastStartMin: Number, duration: Number }

  open(event) {
    const rect = this.element.getBoundingClientRect()
    const offsetMin = event.clientY - rect.top // 帯の上端からの分数（1px=1分）
    const snapped = Math.round((this.startMinValue + offsetMin) / 5) * 5
    const startMin = Math.min(Math.max(snapped, this.startMinValue), this.lastStartMinValue)

    const url = new URL(this.element.href)
    const base = url.searchParams.get("start_at") // 帯の先頭時刻の ISO（日付・オフセットの雛形）
    url.searchParams.set("start_at", this.replaceTime(base, startMin))
    url.searchParams.set("end_at", this.replaceTime(base, startMin + this.durationValue))
    // Turbo の document クリックハンドラは、この要素自身のハンドラ（ここ）の後に
    // 走って href を読むため、ここで書き換えれば新しい URL で遷移する。
    this.element.href = url.toString()
  }

  // "YYYY-MM-DDTHH:MM:SS+09:00" の日付・秒・オフセットを保ち、時刻だけ差し替える。
  replaceTime(iso, minutesOfDay) {
    const h = String(Math.floor(minutesOfDay / 60)).padStart(2, "0")
    const m = String(minutesOfDay % 60).padStart(2, "0")
    return iso.replace(/T\d{2}:\d{2}/, `T${h}:${m}`)
  }
}
