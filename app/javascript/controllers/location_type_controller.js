import { Controller } from "@hotwired/stimulus"

// 実施方法（オンライン/対面）に応じて、会議URL⇔場所の入力欄を出し分ける。
// JS無効時は両方とも表示されたままになる（フォールバック。入力自体はどちらも
// 任意項目なので送信は妨げない）。
export default class extends Controller {
  static targets = ["select", "onlineField", "onsiteField"]

  connect() {
    this.toggle()
  }

  toggle() {
    const online = this.selectTarget.value === "online"
    this.onlineFieldTarget.hidden = !online
    this.onsiteFieldTarget.hidden = online
  }
}
